import CoreVideo
import Foundation

/// YOLOv26n（ncnn）在 iOS 上的封装：模型从 App Bundle 加载，输入直接吃 CVPixelBuffer
///
/// 前后处理在 `PodYolo.mm` 里，与安卓 `cpp/yolov26ncnn.cpp` 逐项一致：
/// letterbox(114 灰边) / 0..1 归一化 / 转置自适应 / 自适应 sigmoid / 阈值 0.20 / NMS 0.50
final class YoloDetector {

    /// 与安卓 `kClassNamesZh` 前 10 项一致（现役模型就是 10 类）
    static let labelsZh = [
        "上台阶", "下台阶", "柱子", "行人", "车辆",
        "门", "坑", "坡道", "障碍", "路缘"
    ]

    struct Det {
        let label: Int
        let name: String
        let prob: Float
        let cx: Float     // 归一化中心
        let cy: Float
        let w: Float
        let h: Float
    }

    private let yolo = PodYolo()
    private(set) var isLoaded = false
    private(set) var lastError = ""

    /// 从 Bundle 加载 yolo26n.ncnn.param / .bin（构建时作为资源打进 App）
    func load() {
        guard !isLoaded else { return }
        guard let param = Bundle.main.path(forResource: "yolo26n.ncnn", ofType: "param"),
              let bin = Bundle.main.path(forResource: "yolo26n.ncnn", ofType: "bin") else {
            lastError = "Bundle 内缺 yolo26n.ncnn.param/.bin"
            return
        }
        if yolo.loadParamPath(param, modelPath: bin) {
            isLoaded = true
            lastError = ""
        } else {
            lastError = "ncnn 加载模型失败（param/bin 不匹配？）"
        }
    }

    /// 检测一帧（BGRA8）
    func detect(pixelBuffer: CVPixelBuffer) -> [Det] {
        guard isLoaded else { return [] }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return [] }

        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        let bpr = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let need = w * 4

        // CVPixelBuffer 常带行填充（bytesPerRow > w*4），ncnn 按紧凑像素读，先拷成紧凑缓冲
        var buf = [UInt8](repeating: 0, count: need * h)
        buf.withUnsafeMutableBytes { dst in
            guard let d = dst.baseAddress else { return }
            for y in 0..<h {
                memcpy(d.advanced(by: y * need), base.advanced(by: y * bpr), need)
            }
        }
        return buf.withUnsafeBufferPointer { p -> [Det] in
            guard let addr = p.baseAddress else { return [] }
            return map(yolo.detectBGRA(addr, width: Int32(w), height: Int32(h)))
        }
    }

    private func map(_ arr: [PodDet]) -> [Det] {
        arr.map { d in
            let idx = Int(d.label)
            let name = (idx >= 0 && idx < YoloDetector.labelsZh.count)
                ? YoloDetector.labelsZh[idx] : "未知"
            return Det(label: idx, name: name, prob: d.prob,
                       cx: d.cx, cy: d.cy, w: d.w, h: d.h)
        }
    }
}
