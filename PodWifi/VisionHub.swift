import CoreVideo
import Foundation
import QuartzCore

/// 视觉中枢：YOLO 检测 + 双目深度，跑在后台队列，最多 5fps，不阻塞收流
///
/// 标定常数来源（与安卓 CamCalib / fusion_v25.h 完全一致）：
///   pair_model_ar0144_v3_20260923_111327.npz → A=24.59061297, C=16.68971838, 基线 tx=0.052m
///   Z = A / (d640 − C)，d640 为 **640 宽** 图像上的视差（像素）
final class VisionHub: ObservableObject {

    static let shared = VisionHub()

    // MARK: - 标定常数（单一来源，改这里）
    static let calA: Double = 24.59061297352434
    static let calC: Double = 16.68971838
    static let refWidth: Double = 640.0
    static let baselineM: Double = 0.052

    @Published var detsText: String = "—"
    @Published var depthText: String = "—"
    @Published var visFps: Double = 0
    @Published var ready: Bool = false

    private let yolo = YoloDetector()
    private let queue = DispatchQueue(label: "pod.vision", qos: .userInitiated)
    private var busy = false
    private var lastAt: CFTimeInterval = 0
    private var frames = 0
    private var windowStart: CFTimeInterval = 0

    private init() {}

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

    /// 收流回调里调用（主线程）。内部节流到 5fps，且同一时刻只跑一帧。
    func process(left: CVPixelBuffer, right: CVPixelBuffer?, ts: UInt32) {
        let now = CACurrentMediaTime()
        if now - lastAt < 0.2 { return }   // 5 fps 上限：视觉慢一点没关系，串流不能卡
        lastAt = now
        if busy { return }
        busy = true

        // 拷一份引用（CVPixelBuffer 是引用计数对象，后台读安全）
        let l = left
        let r = right

        queue.async { [weak self] in
            guard let self = self else { return }
            let t0 = CACurrentMediaTime()

            // 1) 检测
            let dets = self.yolo.detect(pixelBuffer: l)
            let detText = Self.formatDets(dets)

            // 2) 深度（有右眼才算）
            var depthLine = "无右眼（单目流）"
            if let r = r {
                if let m = Self.depthMeters(left: l, right: r) {
                    depthLine = String(format: "中心 %.2f m", m.distance)
                    if m.validRatio < 0.15 {
                        depthLine += "（低置信）"
                    }
                } else {
                    depthLine = "深度无效（纹理不足/超量程）"
                }
            }

            let dt = CACurrentMediaTime() - t0
            self.frames += 1
            if self.windowStart == 0 { self.windowStart = CACurrentMediaTime() }
            let win = CACurrentMediaTime() - self.windowStart
            var fps = self.visFps
            if win > 2.0 {
                fps = Double(self.frames) / win
                self.frames = 0
                self.windowStart = CACurrentMediaTime()
            }

            DispatchQueue.main.async {
                self.detsText = detText
                self.depthText = depthLine
                self.visFps = fps
                self.busy = false
                _ = dt
            }
        }
    }

    // MARK: - 深度

    struct DepthReading {
        let distance: Double     // 米
        let disparity640: Double
        let validRatio: Float
    }

    static func depthMeters(left: CVPixelBuffer, right: CVPixelBuffer) -> DepthReading? {
        let w = CVPixelBufferGetWidth(left)
        let h = CVPixelBufferGetHeight(left)
        guard w == CVPixelBufferGetWidth(right), h == CVPixelBufferGetHeight(right),
              w >= 64, h >= 64 else { return nil }

        guard let gl = gray(from: left, width: w, height: h),
              let gr = gray(from: right, width: w, height: h) else { return nil }

        var res: PodDepthResult?
        gl.withUnsafeBufferPointer { lp in
            gr.withUnsafeBufferPointer { rp in
                guard let lb = lp.baseAddress, let rb = rp.baseAddress else { return }
                res = PodDepth.computeLeft(lb, right: rb,
                                           width: Int32(w), height: Int32(h),
                                           maxDisparity: 48)
            }
        }
        guard let d = res else { return nil }

        let hw = Int(d.width), hh = Int(d.height)
        let x0 = Int(Double(hw) * 0.30), x1 = Int(Double(hw) * 0.70)
        let y0 = Int(Double(hh) * 0.35), y1 = Int(Double(hh) * 0.75)
        let halfD = d.medianInX0(Int32(x0), y0: Int32(y0), x1: Int32(x1), y1: Int32(y1))
        guard halfD > 0 else { return nil }

        // 半分辨率视差 → 640 宽基准下的视差
        let d640 = Double(halfD) * 2.0 * (refWidth / Double(w))
        guard d640 > calC + 1.0 else { return nil }   // 太近会超量程，除以近零会炸
        let z = calA / (d640 - calC)
        guard z > 0.05, z < 30 else { return nil }
        return DepthReading(distance: z, disparity640: d640, validRatio: d.validRatio)
    }

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
