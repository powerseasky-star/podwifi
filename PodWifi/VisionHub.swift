import CoreVideo
import Foundation
import QuartzCore

/// 视觉中枢：相机识别 + YOLO 检测 + 双目深度 + ToF 融合 + 避障分发
///
/// ## v0.7.0 起：由**相机档案**驱动，不再是"一套常数走天下"
/// 连上之后先认型号（协议 v3 的 `codec=0x13 CAMINFO` → flags → 尺寸推断），
/// 认出之后**内参与能力全部跟着换**：
///
/// | 认出 | fy(单眼宽 640) | 双目 SAD | 距离来源 |
/// |---|---|---|---|
/// | AR0144 双目 | 472.90 | 跑 | `A/(d640−C)` × ToF 融合 |
/// | OV5640 单目 | 232.50（HFOV 108°） | **完全不跑** | ToF 优先，框高估算兜底 |
///
/// 单目不跑 SAD 不只是省 CPU：在一张和自身完全相同的图上搜视差恒为 0，
/// 结果必然是"无有效视差"，看起来像算法坏了——那是假故障。
///
/// ## 每帧产出
///  1. 每个检测框的独立距离（双目=框内视差中位数 / 单目=框高反推或 ToF）
///  2. 方位角 + 高度（内参按相机档案取，按眼宽等比缩放）
///  3. 中心区双目 ↔ ToF 融合结果
///  4. 诊断数据与最近 30 帧统计（供 DepthAdvisor 自动调参）
///
final class VisionHub: ObservableObject {

    static let shared = VisionHub()

    // MARK: - AR0144 标定参考常量（实际计算一律走 CameraProfile）
    //    来源 pair_model_ar0144_v3_20260923_111327.npz
    static let calA: Double = 24.59061297352434
    static let calC: Double = 16.68971837761396
    static let refWidth: Double = 640.0
    static let baselineM: Double = 0.052
    /// 640 宽图像上的焦距（像素）≈ 472.90
    static var fy640: Double { calA / baselineM }

    // MARK: - 对外状态（全部在主线程更新）

    /// "OV5640 单目（声明）"
    @Published var cameraText: String = "未识别（等待首帧）"
    @Published var cameraWarn: String = ""
    /// "双目 SAD+ToF" / "单目·仅 ToF"
    @Published var depthModeText: String = "—"
    @Published var detsText: String = "—"
    @Published var depthText: String = "—"
    @Published var fuseText: String = "—"
    @Published var diagText: String = "—"
    @Published var tofText: String = "—"
    @Published var obsText: String = "—"
    @Published var visFps: Double = 0
    @Published var ready: Bool = false
    @Published var lastMs: Double = 0
    /// 当前相机档案（调参页 / UI 要读）
    @Published private(set) var camera: ResolvedCamera = CameraIdentity.resolve(
        info: nil, flags: nil, frameW: 0, frameH: 0)

    // MARK: - 内部

    private let yolo = YoloDetector()
    private let queue = DispatchQueue(label: "pod.vision", qos: .userInitiated)
    private var busy = false
    private var lastAt: CFTimeInterval = 0
    private var frames = 0
    private var windowStart: CFTimeInterval = 0

    /// 当前 SAD 参数（跨线程：写发生在主线程设置页，读发生在视觉队列）
    private let lock = NSLock()
    private var _params: DepthParams = DepthParams.load()
    private var _emaZ: Double?

    /// CAMINFO 与解析缓存（每帧都解析会浪费，按 flags/尺寸/序号做 key 缓存）
    private var _camInfo: PodCamInfo?
    private var _camSeq = 0
    private var _resolved: ResolvedCamera?
    private var _resolvedKey = ""

    /// 最近 30 帧统计（自动调参用，只对双目累积）
    private var statRatio: [Double] = []
    private var statRelErr: [Double] = []
    private var statStereo: [Double] = []
    private var statTof: [Double] = []
    private static let statWindow = 30

    private init() {}

    // MARK: - 参数读写

    var params: DepthParams {
        get { lock.lock(); defer { lock.unlock() }; return _params }
        set {
            lock.lock()
            _params = newValue
            _emaZ = nil
            // 换参数就重开统计窗口：否则新旧参数的有效比例/误差会被平均到一起，建议全错
            statRatio.removeAll(); statRelErr.removeAll()
            statStereo.removeAll(); statTof.removeAll()
            lock.unlock()
            newValue.save()
        }
    }

    func reloadParams() {
        lock.lock(); _params = DepthParams.load(); _emaZ = nil; lock.unlock()
    }

    // MARK: - 相机识别

    /// 收到 CAMINFO（主线程调用）。协议 v3：连上立刻来一次，之后约 5s 一次。
    func acceptCamInfo(_ info: PodCamInfo) {
        lock.lock()
        _camInfo = info
        _camSeq += 1
        _resolved = nil
        _resolvedKey = ""
        lock.unlock()

        // 立刻按 CAMINFO 自带尺寸重算一次，界面马上能显示型号（不等下一帧）
        let r = CameraIdentity.resolve(info: info, flags: nil,
                                       frameW: info.frameW ?? 0, frameH: info.frameH ?? 0)
        DispatchQueue.main.async {
            self.camera = r
            self.cameraText = r.text
            self.cameraWarn = r.warnings.joined(separator: "；")
            self.depthModeText = Self.modeText(r.profile)
        }
    }

    private func resolveCamera(flags: UInt8, frameW: Int, frameH: Int) -> ResolvedCamera {
        lock.lock()
        let key = "\(flags)-\(frameW)-\(frameH)-\(_camSeq)"
        if let r = _resolved, _resolvedKey == key {
            lock.unlock()
            return r
        }
        let info = _camInfo
        lock.unlock()

        let r = CameraIdentity.resolve(info: info, flags: flags, frameW: frameW, frameH: frameH)

        lock.lock()
        _resolved = r
        _resolvedKey = key
        lock.unlock()
        return r
    }

    private static func modeText(_ p: CameraProfile) -> String {
        if p.depthCapable { return "双目 SAD+ToF" }
        if p.isStereo { return "双目·深度不可用（缺基线或固件自评 false）" }
        return "单目·仅 ToF"
    }

    // MARK: - 生命周期

    func warmUp() {
        guard !ready else { return }
        queue.async { [weak self] in
            guard let self = self else { return }
            self.yolo.load()
            DispatchQueue.main.async {
                self.ready = self.yolo.isLoaded
                if !self.ready { self.detsText = self.yolo.lastError }
            }
        }
    }

    // MARK: - 主流程

    /// 收流回调里调用（后台队列）。内部节流到 5fps，且同一时刻只跑一帧。
    func process(frame f: PodFrame) {
        let now = CACurrentMediaTime()
        if now - lastAt < 0.2 { return }   // 5 fps 上限：视觉慢一点没关系，串流不能卡
        lastAt = now
        if busy { return }
        busy = true

        let cam = resolveCamera(flags: f.flags, frameW: f.frameW, frameH: f.frameH)
        let l = f.left
        let r = f.right          // 单目时为 nil —— 不再用左眼冒充
        let tofM = SensorBus.shared.freshToF()?.meters

        queue.async { [weak self] in
            guard let self = self else { return }
            let t0 = CACurrentMediaTime()

            let p = self.params
            let prof = cam.profile
            let eyeW = CVPixelBufferGetWidth(l)
            let eyeH = CVPixelBufferGetHeight(l)
            let fy = prof.fy(eyeW: eyeW)

            // ---- 1) 检测（单目照跑：YOLO 与深度无关）----
            let dets = self.yolo.detect(pixelBuffer: l)

            // ---- 2) 深度：只有真双目才跑 SAD ----
            var diag = DepthDiag()
            diag.width = eyeW
            diag.height = eyeH
            var fused: DepthFusion.Output?
            var dispMap: PodDepthResult?

            if prof.depthCapable, let rr = r,
               eyeW == CVPixelBufferGetWidth(rr), eyeH == CVPixelBufferGetHeight(rr) {
                let res = Self.disparity(left: l, right: rr, width: eyeW, height: eyeH, params: p)
                dispMap = res
                if let d = res {
                    let hw = Int(d.width), hh = Int(d.height)
                    let halfD = d.median(inX0: Int32(Double(hw) * 0.30), y0: Int32(Double(hh) * 0.35),
                                         x1: Int32(Double(hw) * 0.70), y1: Int32(Double(hh) * 0.75))
                    diag.validRatio = d.validRatio()
                    if halfD > 0 {
                        let d640 = Double(halfD) * 2.0 * (Self.refWidth / Double(eyeW))
                        diag.disparity640 = d640
                        diag.stereoM = Self.metersFromD640(d640, params: p, profile: prof) ?? 0
                    }
                }
            }

            // ---- 3) ToF + 融合（单目时 stereo 恒 nil，天然退化为 ToF-only）----
            diag.tofM = tofM ?? 0
            fused = DepthFusion.fuse(.init(stereo: diag.stereoM > 0 ? diag.stereoM : nil,
                                           stereoRatio: diag.validRatio,
                                           tof: tofM))
            if var fo = fused {
                self.lock.lock()
                let old = self._emaZ
                let z = DepthFusion.smooth(new: fo.meters, old: old, alpha: p.emaAlpha)
                self._emaZ = z
                self.lock.unlock()
                fo = DepthFusion.Output(meters: z, source: fo.source, agree: fo.agree,
                                        wStereo: fo.wStereo, wTof: fo.wTof, note: fo.note)
                fused = fo
            }

            diag.ms = (CACurrentMediaTime() - t0) * 1000

            // ---- 4) 检测框 → 方位角/距离/高度（内参与距离来源都按相机档案选）----
            let obstacles = Self.toObstacles(dets: dets, disp: dispMap, profile: prof,
                                             eyeW: eyeW, eyeH: eyeH, fy: fy,
                                             params: p, fallback: fused?.meters,
                                             tofMeters: tofM)

            // ---- 5) 统计累积（只对双目有意义）----
            if prof.depthCapable { self.accumulate(diag) }

            // ---- 6) FPS ----
            self.frames += 1
            if self.windowStart == 0 { self.windowStart = CACurrentMediaTime() }
            let win = CACurrentMediaTime() - self.windowStart
            var fps = self.visFps
            if win > 2.0 {
                fps = Double(self.frames) / win
                self.frames = 0
                self.windowStart = CACurrentMediaTime()
            }

            let detText = Self.formatDets(dets)
            let depthLine: String
            if !prof.depthCapable {
                depthLine = fused.map { "\($0.text)（单目，仅 ToF）" } ?? "单目无深度 · ToF 无数据"
            } else {
                depthLine = fused.map { $0.text } ?? "无（双目无有效视差 且 无 ToF）"
            }
            let fuseLine = fused?.note ?? "—"
            let dLine = prof.depthCapable
                ? diag.text
                : String(format: "单目（跳过 SAD）  %.1fms %d×%d", diag.ms, eyeW, eyeH)
            let tLine = SensorBus.shared.summary
            let ms = diag.ms
            let mono = !prof.depthCapable

            DispatchQueue.main.async {
                self.camera = cam
                self.cameraText = cam.text
                self.cameraWarn = cam.warnings.joined(separator: "；")
                self.depthModeText = Self.modeText(prof)
                self.detsText = detText
                self.depthText = depthLine
                self.fuseText = fuseLine
                self.diagText = dLine
                self.tofText = tLine
                self.lastMs = ms
                self.visFps = fps
                self.busy = false
                ObstacleAlerter.shared.consider(obstacles: obstacles,
                                                tofMeters: tofM,
                                                monoMode: mono)
                self.obsText = ObstacleAlerter.shared.line
            }
        }
    }

    /// 兼容 v0.6.0 的旧入口（测试用）。
    /// 旧调用点在单目时传的是**同一个对象** `(full, full)`，靠 `===` 就能认出来。
    func process(left: CVPixelBuffer, right: CVPixelBuffer?, ts: UInt32) {
        let w = CVPixelBufferGetWidth(left)
        let h = CVPixelBufferGetHeight(left)
        let sameObject = (right as AnyObject?) === (left as AnyObject)
        let realStereo = (right != nil) && !sameObject
        process(frame: PodFrame(left: left,
                                right: realStereo ? right : nil,
                                ts: ts,
                                flags: realStereo ? 1 : 0,
                                frameW: realStereo ? w * 2 : w,
                                frameH: h))
    }

    // MARK: - 统计累积

    private func accumulate(_ d: DepthDiag) {
        lock.lock()
        statRatio.append(Double(d.validRatio))
        statRelErr.append(d.tofM > 0 && d.stereoM > 0 ? d.relError : 0)
        if d.stereoM > 0 { statStereo.append(d.stereoM) }
        if d.tofM > 0 { statTof.append(d.tofM) }
        if statRatio.count > Self.statWindow {
            statRatio.removeFirst(statRatio.count - Self.statWindow)
            statRelErr.removeFirst(max(0, statRelErr.count - Self.statWindow))
            statStereo.removeFirst(max(0, statStereo.count - Self.statWindow))
            statTof.removeFirst(max(0, statTof.count - Self.statWindow))
        }
        lock.unlock()
    }

    struct Stats {
        let ratio: Double
        let relErr: Double
        let stereoAvg: Double
        let tofAvg: Double
        let samples: Int
        let tofAvailable: Bool
    }

    func stats() -> Stats {
        lock.lock()
        let r = statRatio, e = statRelErr, s = statStereo, t = statTof
        lock.unlock()
        func avg(_ a: [Double]) -> Double { a.isEmpty ? 0 : a.reduce(0, +) / Double(a.count) }
        // relErr 只对"有 ToF 的帧"求平均（无 ToF 的帧记 0 会把误差稀释掉）
        let validErr = e.filter { $0 > 0 }
        return Stats(ratio: avg(r), relErr: avg(validErr),
                     stereoAvg: avg(s), tofAvg: avg(t),
                     samples: r.count, tofAvailable: validErr.count >= 3)
    }

    // MARK: - 深度

    struct DepthReading {
        let distance: Double
        let disparity640: Double
        let validRatio: Float
    }

    /// 视差图（半分辨率）；nil = 无法计算
    static func disparity(left: CVPixelBuffer,
                          right: CVPixelBuffer,
                          width w: Int,
                          height h: Int,
                          params p: DepthParams) -> PodDepthResult? {
        guard let gl = gray(from: left, width: w, height: h),
              let gr = gray(from: right, width: w, height: h) else { return nil }

        var res: PodDepthResult?
        gl.withUnsafeBufferPointer { lp in
            gr.withUnsafeBufferPointer { rp in
                guard let lb = lp.baseAddress, let rb = rp.baseAddress else { return }
                res = PodDepth.computeLeft(lb, right: rb,
                                           width: Int32(w), height: Int32(h),
                                           maxDisparity: Int32(p.maxDisparity),
                                           windowRadius: Int32(p.winRadius),
                                           uniquenessPct: Float(p.uniquenessPct),
                                           uniquenessMargin: Int32(p.uniquenessMargin),
                                           lrcTol: Int32(p.lrcTol),
                                           textureGate: Int32(p.textureGate))
            }
        }
        return res
    }

    /// 视差 → 距离（含 calScale 修正）。**A/C 来自相机档案**，不是写死常数。
    static func metersFromD640(_ d640: Double,
                               params p: DepthParams,
                               profile: CameraProfile = .ar0144Stereo) -> Double? {
        guard profile.depthCapable else { return nil }
        let denom = d640 - profile.stereoC
        guard denom > 1.0 else { return nil }         // 太近超量程，除以近零会炸
        let z = (profile.stereoA * p.calScale) / denom
        guard z.isFinite, z > 0.05, z < 40 else { return nil }
        return z
    }

    // MARK: - 检测框 → 目标

    static func toObstacles(dets: [YoloDetector.Det],
                            disp: PodDepthResult?,
                            profile: CameraProfile,
                            eyeW w: Int,
                            eyeH h: Int,
                            fy: Double,
                            params p: DepthParams,
                            fallback: Double?,
                            tofMeters: Double?) -> [VisionObstacle] {
        guard !dets.isEmpty else { return [] }
        let fx = fy      // 方像素：fx = fy

        return dets.map { d in
            // 方位角：归一化中心 → 像素偏移 → atan
            // 内参已按眼宽缩放且来自相机档案，所以 OV5640(108°) 与 AR0144(68°) 都对
            let dxPx = (Double(d.cx) - 0.5) * Double(w)
            let azDeg = atan2(dxPx, fx) * 180.0 / .pi

            var z = 0.0
            var estimate = false

            // A) 双目：框内视差中位数（比全图中心值准，尤其是侧方目标）
            if profile.depthCapable, let mp = disp {
                let hw = Double(mp.width), hh = Double(mp.height)
                let x0 = (Double(d.cx - d.w / 2)) * hw
                let x1 = (Double(d.cx + d.w / 2)) * hw
                let y0 = (Double(d.cy - d.h / 2)) * hh
                let y1 = (Double(d.cy + d.h / 2)) * hh
                let halfD = mp.median(inX0: Int32(max(0, x0)), y0: Int32(max(0, y0)),
                                      x1: Int32(min(hw - 1, x1)), y1: Int32(min(hh - 1, y1)),
                                      stride: 2)
                if halfD > 0 {
                    let d640 = Double(halfD) * 2.0 * (refWidth / Double(w))
                    z = metersFromD640(d640, params: p, profile: profile) ?? 0
                }
            }

            // B) 单目：ToF 优先（ToF 测的是"正前方最近物"，对侧方目标不成立，
            //    所以只在目标靠近画面中心时才借用），否则用框高反推
            if z <= 0, !profile.depthCapable {
                if let t = tofMeters, abs(d.cx - 0.5) < 0.25 {
                    z = t
                } else if let est = MonoRange.meters(name: d.name, hNorm: d.h,
                                                     fy: fx, frameH: h) {
                    z = est
                    estimate = true
                }
            }

            // C) 兜底：中心融合值（只对靠中间的目标有意义）
            if z <= 0, let f = fallback, abs(d.cx - 0.5) < 0.30 {
                z = f
                estimate = true
            }

            // 高度：H = h_norm × 帧高 × Z / fy
            var hm = 0.0
            if z > 0 { hm = Double(d.h) * Double(h) * z / fx }

            let inPath = abs(azDeg) <= ObstacleAlerter.corridorDeg
            return VisionObstacle(label: d.label, name: d.name, prob: d.prob,
                                  azimuthDeg: azDeg,
                                  meters: z > 0 ? z : 99.0,   // 测不到距离 = 不参与危险排序
                                  heightM: hm,
                                  inPath: inPath,
                                  estimated: estimate)
        }
    }

    // MARK: - 灰度

    /// CVPixelBuffer(BGRA) → 灰度（亮度加权），返回紧凑缓冲
    private static func gray(from pb: CVPixelBuffer, width: Int, height: Int) -> [UInt8]? {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        var out = [UInt8](repeating: 0, count: width * height)
        let p = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            let row = p + y * bpr
            let o = y * width
            for x in 0..<width {
                let i = x * 4
                let b = Int(row[i])
                let g = Int(row[i + 1])
                let r = Int(row[i + 2])
                out[o + x] = UInt8((r * 299 + g * 587 + b * 114) / 1000)
            }
        }
        return out
    }

    private static func formatDets(_ dets: [YoloDetector.Det]) -> String {
        if dets.isEmpty { return "无目标" }
        let top = dets.sorted { $0.prob > $1.prob }.prefix(3)
        return top.map { String(format: "%@ %.2f", $0.name, $0.prob) }.joined(separator: " · ")
    }
}
