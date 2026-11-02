import CoreVideo
import Foundation
import QuartzCore

/// 视觉中枢：YOLO 检测 + 双目深度 + ToF 融合 + 避障分发，跑在后台队列，最多 5fps，不阻塞收流
///
/// ## 标定常数来源（与安卓 CamCalib / fusion_v25.h 完全一致）
///   `pair_model_ar0144_v3_20260923_111327.npz` → A = 24.59061297, C = 16.68971838, 基线 tx = 0.052 m
///   测距：`Z = (A × calScale) / (d640 − C)`，d640 为**换算到 640 宽**的视差（像素）
///   内参：`fy = A / tx ≈ 472.90`（对应 640 宽图像），`fx = fy`（方像素）
///         → HFOV = 2·atan(320/472.90) = 68.2°，VFOV(360 高) = 41.7°（与实测一致）
///
/// ## ⚠️ 内参随分辨率缩放（v0.6.0 修正）
/// 0.5.0 里 fy 被当成固定 472.9，只在 640 宽时成立。若送进来的是 1280 宽，
/// 用它算方位角会把角度砍半（＝把正前方的车报成"前方偏左 15 度"）。
/// 所以这里统一按**宽度比例**换算：`fx = fy640 × (w / 640)`。
/// 这样 HFOV 恒定（镜头属性），方位角在任何分辨率下都对。
///
/// ## 每帧产出
///  1. 每个检测框的**独立**距离（框内视差中位数，不是全图共用中心值）
///  2. 方位角 + 高度（H = h_norm × 帧高 × Z / fy）
///  3. 中心区双目 ↔ ToF 融合结果
///  4. 诊断数据（有效比例/视差/耗时）与最近 30 帧统计（供 DepthAdvisor 自动调参）
///
final class VisionHub: ObservableObject {

    static let shared = VisionHub()

    // MARK: - 标定常数（单一来源，改这里）
    static let calA: Double = 24.59061297352434
    static let calC: Double = 16.68971838
    static let refWidth: Double = 640.0
    static let baselineM: Double = 0.052

    /// 640 宽图像上的焦距（像素）
    static var fy640: Double { calA / baselineM }      // ≈ 472.90

    // MARK: - 对外状态（全部在主线程更新）

    @Published var detsText: String = "—"
    @Published var depthText: String = "—"      // 融合后的中心距离
    @Published var fuseText: String = "—"       // 融合细节（权重/一致性）
    @Published var diagText: String = "—"       // 有效比例/视差/耗时
    @Published var tofText: String = "—"
    @Published var obsText: String = "—"        // 避障引擎的走廊判定结果
    @Published var visFps: Double = 0
    @Published var ready: Bool = false
    @Published var lastMs: Double = 0

    // MARK: - 内部

    private let yolo = YoloDetector()
    private let queue = DispatchQueue(label: "pod.vision", qos: .userInitiated)
    private var busy = false
    private var lastAt: CFTimeInterval = 0
    private var frames = 0
    private var windowStart: CFTimeInterval = 0

    /// 当前 SAD 参数（跨线程读写用锁保护：写发生在主线程的设置页，读发生在视觉队列）
    private let lock = NSLock()
    private var _params: DepthParams = DepthParams.load()
    /// 上一帧融合距离（做 EMA）
    private var _emaZ: Double?

    /// 最近 30 帧统计（自动调参用）
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

    // MARK: - 统计（供 DepthAdvisor）

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
        // relErr 只对"有 ToF 的帧"求平均（无 ToF 的帧 relErr 记 0 会把误差稀释掉）
        let validErr = e.filter { $0 > 0 }
        return Stats(ratio: avg(r),
                     relErr: avg(validErr),
                     stereoAvg: avg(s),
                     tofAvg: avg(t),
                     samples: r.count,
                     tofAvailable: validErr.count >= 3)
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

    /// 收流回调里调用（后台队列）。内部节流到 5fps，且同一时刻只跑一帧。
    func process(left: CVPixelBuffer, right: CVPixelBuffer?, ts: UInt32) {
        let now = CACurrentMediaTime()
        if now - lastAt < 0.2 { return }   // 5 fps 上限：视觉慢一点没关系，串流不能卡
        lastAt = now
        if busy { return }
        busy = true

        let l = left
        let r = right

        queue.async { [weak self] in
            guard let self = self else { return }
            let t0 = CACurrentMediaTime()

            let p = self.params
            let w = CVPixelBufferGetWidth(l)
            let h = CVPixelBufferGetHeight(l)

            // ---- 1) 检测 ----
            let dets = self.yolo.detect(pixelBuffer: l)

            // ---- 2) 深度（有右眼才算）----
            var diag = DepthDiag()
            diag.width = w
            diag.height = h
            var fused: DepthFusion.Output?
            var dispMap: PodDepthResult?

            if let r = r, w == CVPixelBufferGetWidth(r), h == CVPixelBufferGetHeight(r) {
                let res = Self.disparity(left: l, right: r, width: w, height: h, params: p)
                dispMap = res
                if let d = res {
                    let hw = Int(d.width), hh = Int(d.height)
                    let x0 = Int32(Double(hw) * 0.30), x1 = Int32(Double(hw) * 0.70)
                    let y0 = Int32(Double(hh) * 0.35), y1 = Int32(Double(hh) * 0.75)
                    // Swift 把 ObjC 的 medianInX0:y0:x1:y1: 导入成 median(inX0:y0:x1:y1:)
                    let halfD = d.median(inX0: x0, y0: y0, x1: x1, y1: y1)
                    diag.validRatio = d.validRatio()
                    if halfD > 0 {
                        let d640 = Double(halfD) * 2.0 * (Self.refWidth / Double(w))
                        diag.disparity640 = d640
                        diag.stereoM = Self.metersFromD640(d640, params: p) ?? 0
                    }
                }
            }

            // ---- 3) ToF + 融合 ----
            let tof = SensorBus.shared.freshToF()?.meters
            diag.tofM = tof ?? 0
            fused = DepthFusion.fuse(.init(stereo: diag.stereoM > 0 ? diag.stereoM : nil,
                                           stereoRatio: diag.validRatio,
                                           tof: tof))
            // EMA 平滑（跳变直通，见 DepthFusion.smooth）
            if var f = fused {
                self.lock.lock()
                let old = self._emaZ
                let z = DepthFusion.smooth(new: f.meters, old: old, alpha: p.emaAlpha)
                self._emaZ = z
                self.lock.unlock()
                f = DepthFusion.Output(meters: z, source: f.source, agree: f.agree,
                                       wStereo: f.wStereo, wTof: f.wTof, note: f.note)
                fused = f
            }

            diag.ms = (CACurrentMediaTime() - t0) * 1000

            // ---- 4) 检测框 → 方位角/距离/高度 ----
            let obstacles = Self.toObstacles(dets: dets,
                                             disp: dispMap,
                                             frameW: w, frameH: h,
                                             params: p,
                                             fallback: fused?.meters)

            // ---- 5) 统计累积 ----
            self.accumulate(diag)

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
            let depthLine = fused.map { $0.text } ?? "无（双目无有效视差 且 无 ToF）"
            let fuseLine = fused?.note ?? "—"
            let dLine = diag.text
            let tLine = SensorBus.shared.summary
            let ms = diag.ms

            DispatchQueue.main.async {
                self.detsText = detText
                self.depthText = depthLine
                self.fuseText = fuseLine
                self.diagText = dLine
                self.tofText = tLine
                self.lastMs = ms
                self.visFps = fps
                self.busy = false
                // 避障也是主线程（要动 TTS 与 BLE）
                ObstacleAlerter.shared.consider(obstacles: obstacles, tofMeters: tof)
                self.obsText = ObstacleAlerter.shared.line
            }
        }
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

    // MARK: - 深度

    struct DepthReading {
        let distance: Double     // 米
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

    /// 兼容 v0.5.0 的旧入口（内部走当前参数）
    static func depthMeters(left: CVPixelBuffer, right: CVPixelBuffer) -> DepthReading? {
        let w = CVPixelBufferGetWidth(left)
        let h = CVPixelBufferGetHeight(left)
        guard w == CVPixelBufferGetWidth(right), h == CVPixelBufferGetHeight(right),
              w >= 64, h >= 64 else { return nil }
        let p = DepthParams.load()
        guard let d = disparity(left: left, right: right, width: w, height: h, params: p) else { return nil }
        let hw = Int(d.width), hh = Int(d.height)
        let halfD = d.median(inX0: Int32(Double(hw) * 0.30), y0: Int32(Double(hh) * 0.35),
                             x1: Int32(Double(hw) * 0.70), y1: Int32(Double(hh) * 0.75))
        guard halfD > 0 else { return nil }
        let d640 = Double(halfD) * 2.0 * (refWidth / Double(w))
        guard let z = metersFromD640(d640, params: p) else { return nil }
        return DepthReading(distance: z, disparity640: d640, validRatio: d.validRatio())
    }

    /// 视差 → 距离（含 calScale 修正）
    static func metersFromD640(_ d640: Double, params p: DepthParams) -> Double? {
        let denom = d640 - calC
        guard denom > 1.0 else { return nil }         // 太近超量程，除以近零会炸
        let z = (calA * p.calScale) / denom
        guard z.isFinite, z > 0.05, z < 40 else { return nil }
        return z
    }

    // MARK: - 检测框 → 目标

    static func toObstacles(dets: [YoloDetector.Det],
                            disp: PodDepthResult?,
                            frameW w: Int,
                            frameH h: Int,
                            params p: DepthParams,
                            fallback: Double?) -> [VisionObstacle] {
        guard !dets.isEmpty else { return [] }
        let fy = fy640 * (Double(w) / refWidth)      // 内参按宽度缩放（见文件头注释）
        let fx = fy

        return dets.map { d in
            // 方位角：归一化中心 → 像素偏移 → atan
            let dxPx = (Double(d.cx) - 0.5) * Double(w)
            let azDeg = atan2(dxPx, fx) * 180.0 / .pi

            // 每框独立距离：框内视差中位数（比全图中心值准得多，尤其是侧方目标）
            var z = 0.0
            if let mp = disp {
                let hw = Double(mp.width), hh = Double(mp.height)
                let x0 = (Double(d.cx - d.w / 2)) * hw
                let x1 = (Double(d.cx + d.w / 2)) * hw
                let y0 = (Double(d.cy - d.h / 2)) * hh
                let y1 = (Double(d.cy + d.h / 2)) * hh
                let stride: Int32 = 2      // 抽样：框内 1/4 像素就够稳，省 4 倍排序时间
                let halfD = mp.median(inX0: Int32(max(0, x0)), y0: Int32(max(0, y0)),
                                      x1: Int32(min(hw - 1, x1)), y1: Int32(min(hh - 1, y1)),
                                      stride: stride)
                if halfD > 0 {
                    let d640 = Double(halfD) * 2.0 * (refWidth / Double(w))
                    z = metersFromD640(d640, params: p) ?? 0
                }
            }
            // 框内没有有效视差：用中心融合值兜底（只对靠中间的目标有意义）
            if z <= 0, let f = fallback, abs(d.cx - 0.5) < 0.30 {
                z = f
            }

            // 高度：H = h_norm × 帧高 × Z / fy
            var hm = 0.0
            if z > 0 {
                hm = Double(d.h) * Double(h) * z / fy
            }

            let inPath = abs(azDeg) <= ObstacleAlerter.corridorDeg
            return VisionObstacle(label: d.label, name: d.name, prob: d.prob,
                                  azimuthDeg: azDeg,
                                  meters: z > 0 ? z : 99.0,      // 测不到距离 = 不参与危险排序
                                  heightM: hm, inPath: inPath)
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
