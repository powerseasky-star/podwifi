//
//  WifiStereoReceiver.swift
//  导盲 Pod 无线视频源（iOS 侧）v1 — 2026-11-01
//
//  为什么要它：iPhone 不支持外接 UVC 相机（Apple 只有 iPad USB-C 支持 external camera），
//  所以 iOS 上唯一能拿到双目画面的路，就是 Pod 把压缩视频推过来、手机解码。
//
//  协议：导盲Pod_无线视频协议_v1_20261101.md（24 字节大端帧头 + 负载）
//    0..1 'P','O' | 2 version=1 | 3 codec(1=MJPEG,2=H264,3=NV21) | 4 flags(bit0 并排, bit1 关键帧)
//    6..9 seq u32 | 10..13 ts_ms u32 | 14..15 w u16 | 16..17 h u16 | 18..19 rsvd | 20..23 len u32
//
//  ⚠️ 状态：**未在 macOS/Xcode 上编译验证**（开发机是 Windows）。
//      MJPEG 路径逻辑完整；H.264 路径需要用 VideoToolbox（VTDecompressionSession）补齐，
//      已在标记处留出接口，别当成已完成直接上线。
//
//  用法：
//      let rx = WifiStereoReceiver(host: "192.168.4.1", port: 5000)
//      rx.onStereoFrame = { left, right, tsMs in
//          // left/right 是 CVPixelBuffer（BGRA），直接喂 Vision / CoreML
//      }
//      rx.onState = { ok, msg in print(ok, msg) }
//      rx.start()
//

import Foundation
import Network
import CoreVideo
import CoreGraphics
import ImageIO
import VideoToolbox

public final class WifiStereoReceiver {

    /// 左右眼画面回调（BGRA CVPixelBuffer，按协议已切好）
    public var onStereoFrame: ((CVPixelBuffer, CVPixelBuffer, UInt32) -> Void)?
    /// 状态回调：true=起流，false=断开/异常
    public var onState: ((Bool, String) -> Void)?

    /// 协议 v2：传感器 JSON 文本（codec=0x10）——单目方案的主力数据源
    public var onSensorJson: ((String) -> Void)?
    /// 协议 v2：导航播报文本（codec=0x11，UTF-8）——直接交给 AVSpeechSynthesizer
    public var onNavText: ((String) -> Void)?
    /// 协议 v2：事件/告警文本（codec=0x12）
    public var onEvent: ((String) -> Void)?

    public private(set) var fps: Double = 0
    public private(set) var dropFrames: UInt32 = 0

    private let host: String
    private let port: UInt16
    private let queue = DispatchQueue(label: "pod.wifi.video", qos: .userInitiated)

    private var conn: NWConnection?
    // ⚠️ 必须用 [UInt8] 而不是 Data：
    //   Data 是切片语义，removeFirst() 之后 startIndex 会偏移，
    //   再用绝对下标 subdata(in: 24..<total) 就会越界 trap
    //   （2026-11-02 实机崩溃：EXC_BREAKPOINT in Data.subdata(in:) on queue pod.wifi.video）。
    //   Array 的 startIndex 恒为 0，从根上避免这类错误。
    private var buffer: [UInt8] = []             // 半包缓冲（TCP 是字节流，必须自己拼帧）
    private var running = false
    private var lastSeq: UInt32 = 0
    private var hasSeq = false
    private var statT = Date()
    private var statN = 0
    private var h264: H264Decoder?

    private static let headerLen = 24
    private static let maxPayload = 8 * 1024 * 1024

    public init(host: String, port: UInt16 = 5000) {
        self.host = host
        self.port = port
    }

    // MARK: - 生命周期

    public func start() {
        guard !running else { return }
        running = true
        connect()
    }

    public func stop() {
        running = false
        conn?.cancel()
        conn = nil
        buffer.removeAll()
        h264?.invalidate()
        h264 = nil
    }

    private func connect() {
        guard running else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // 视频流不能被 Nagle 攒包
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            tcp.connectionTimeout = 4
        }
        let c = NWConnection(host: NWEndpoint.Host(host),
                             port: NWEndpoint.Port(rawValue: port) ?? 5000,
                             using: params)
        conn = c
        c.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.onState?(true, "已连接 \(self.host):\(self.port)")
                self.receiveLoop()
            case .failed(let err):
                self.onState?(false, "连接失败：\(err.localizedDescription)")
                self.scheduleReconnect()
            case .cancelled:
                break
            case .waiting(let err):
                self.onState?(false, "等待网络：\(err.localizedDescription)")
            default:
                break
            }
        }
        c.start(queue: queue)
    }

    private func scheduleReconnect() {
        guard running else { return }
        conn?.cancel()
        conn = nil
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.connect()
        }
    }

    private func receiveLoop() {
        conn?.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty {
                self.buffer.append(contentsOf: data)
                self.parseAvailable()
            }
            if isComplete || error != nil {
                self.onState?(false, "链路断开：\(error?.localizedDescription ?? "对端关闭")")
                self.scheduleReconnect()
                return
            }
            self.receiveLoop()
        }
    }

    // MARK: - 拆帧

    private func parseAvailable() {
        while buffer.count >= WifiStereoReceiver.headerLen {
            let hdr = Array(buffer[0..<WifiStereoReceiver.headerLen])
            guard hdr[0] == 0x50, hdr[1] == 0x4F else {
                // 失步：整条连接作废重连，比在这里猜偏移安全
                onState?(false, "帧头魔数不匹配，重连")
                buffer.removeAll()
                scheduleReconnect()
                return
            }
            let version = hdr[2]
            guard version == 1 else {
                onState?(false, "协议版本不支持：\(version)")
                buffer.removeAll()
                scheduleReconnect()
                return
            }
            let codec = hdr[3]
            let flags = hdr[4]
            let seq = beU32(hdr, 6)
            let ts = beU32(hdr, 10)
            let w = Int(beU16(hdr, 14))
            let h = Int(beU16(hdr, 16))
            let len = Int(beU32(hdr, 20))

            guard len > 0, len <= WifiStereoReceiver.maxPayload else {
                onState?(false, "负载长度异常：\(len)")
                buffer.removeAll()
                scheduleReconnect()
                return
            }
            let total = WifiStereoReceiver.headerLen + len
            guard buffer.count >= total else { return }   // 半包，等更多数据

            let payload = Data(buffer[WifiStereoReceiver.headerLen..<total])
            buffer.removeFirst(total)

            if hasSeq, seq > lastSeq &+ 1 {
                dropFrames &+= (seq &- lastSeq &- 1)
            }
            lastSeq = seq
            hasSeq = true
            countStat()

            handleFrame(codec: codec, flags: flags, w: w, h: h, ts: ts, payload: payload)
        }
    }

    private func handleFrame(codec: UInt8, flags: UInt8, w: Int, h: Int, ts: UInt32, payload: Data) {
        switch codec {
        case 1:
            if let px = WifiStereoReceiver.decodeJPEG(payload) {
                emit(px, flags: flags, ts: ts)
            }
        case 2:
            if h264 == nil { h264 = H264Decoder(log: { [weak self] in self?.onState?(false, $0) }) }
            // ⚠️ TODO(macOS): 这里要返回解码后的 CVPixelBuffer。
            //   实现要点：从 Annex-B 里取 SPS/PPS 建 CMVideoFormatDescription，
            //   再 VTDecompressionSessionDecodeFrame 出 CVPixelBuffer。
            //   本文件不提供半成品实现，避免"看起来做完了其实没跑过"。
            _ = h264?.feed(payload: payload, width: w, height: h)
        case 3:
            if let px = WifiStereoReceiver.nv21ToPixelBuffer(payload, width: w, height: h) {
                emit(px, flags: flags, ts: ts)
            }
        case 0x10:   // SENSOR JSON
            if let s = String(data: payload, encoding: .utf8) { onSensorJson?(s) }
        case 0x11:   // NAV TEXT
            if let s = String(data: payload, encoding: .utf8) { onNavText?(s) }
        case 0x12:   // EVENT
            if let s = String(data: payload, encoding: .utf8) { onEvent?(s) }
        default:
            break
        }
    }

    /// 按协议切左右眼后回调
    private func emit(_ full: CVPixelBuffer, flags: UInt8, ts: UInt32) {
        let w = CVPixelBufferGetWidth(full)
        let h = CVPixelBufferGetHeight(full)
        guard w > 4 else { return }
        if flags & 0x01 != 0 {
            let half = w / 2
            guard let l = WifiStereoReceiver.crop(full, x: 0, w: half, h: h),
                  let r = WifiStereoReceiver.crop(full, x: half, w: half, h: h) else { return }
            onStereoFrame?(l, r, ts)
        } else {
            onStereoFrame?(full, full, ts)
        }
    }

    private func countStat() {
        statN += 1
        let dt = Date().timeIntervalSince(statT)
        if dt >= 2 {
            fps = Double(statN) / dt
            statN = 0
            statT = Date()
        }
    }

    // MARK: - 工具

    private func beU16(_ b: [UInt8], _ o: Int) -> UInt16 {
        (UInt16(b[o]) << 8) | UInt16(b[o + 1])
    }

    private func beU32(_ b: [UInt8], _ o: Int) -> UInt32 {
        (UInt32(b[o]) << 24) | (UInt32(b[o + 1]) << 16) | (UInt32(b[o + 2]) << 8) | UInt32(b[o + 3])
    }

    static func decodeJPEG(_ data: Data) -> CVPixelBuffer? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return pixelBuffer(from: cg)
    }

    static func pixelBuffer(from cg: CGImage) -> CVPixelBuffer? {
        let w = cg.width
        let h = cg.height
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var pb: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, w, h,
                                  kCVPixelFormatType_32BGRA,
                                  attrs as CFDictionary, &pb) == kCVReturnSuccess,
              let buf = pb else { return nil }
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        guard let base = CVPixelBufferGetBaseAddress(buf) else { return nil }
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(buf),
                                  space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                            | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return buf
    }

    static func crop(_ src: CVPixelBuffer, x: Int, w: Int, h: Int) -> CVPixelBuffer? {
        CVPixelBufferLockBaseAddress(src, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(src, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(src) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(src)
        let bpp = 4
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        var pb: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA,
                                  attrs as CFDictionary, &pb) == kCVReturnSuccess,
              let dst = pb else { return nil }
        CVPixelBufferLockBaseAddress(dst, [])
        defer { CVPixelBufferUnlockBaseAddress(dst, []) }
        guard let dstBase = CVPixelBufferGetBaseAddress(dst) else { return nil }
        let dstStride = CVPixelBufferGetBytesPerRow(dst)
        for row in 0..<h {
            let s = base.advanced(by: row * stride + x * bpp)
            let d = dstBase.advanced(by: row * dstStride)
            memcpy(d, s, w * bpp)
        }
        return dst
    }

    static func nv21ToPixelBuffer(_ data: Data, width: Int, height: Int) -> CVPixelBuffer? {
        guard data.count >= width * height * 3 / 2 else { return nil }
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                  kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                  attrs as CFDictionary, &pb) == kCVReturnSuccess,
              let buf = pb else { return nil }
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(buf, 0),
              let uvBase = CVPixelBufferGetBaseAddressOfPlane(buf, 1) else { return nil }
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(buf, 0)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(buf, 1)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let src = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            for row in 0..<height {
                memcpy(yBase.advanced(by: row * yStride), src.advanced(by: row * width), width)
            }
            // NV21: VU 交错 -> NV12: UV 交错，逐对交换
            let uvH = height / 2
            let uvW = width / 2
            for row in 0..<uvH {
                let s = src.advanced(by: width * height + row * width)
                let d = uvBase.advanced(by: row * uvStride).assumingMemoryBound(to: UInt8.self)
                for col in 0..<uvW {
                    d[col * 2]     = s[col * 2 + 1]   // U
                    d[col * 2 + 1] = s[col * 2]       // V
                }
            }
        }
        return buf
    }
}

/// H.264 解码占位：真实现需在 macOS 上用 VideoToolbox 写，不要在 Windows 上"猜"出来
private final class H264Decoder {
    private let log: (String) -> Void
    private var warned = false

    init(log: @escaping (String) -> Void) { self.log = log }

    func feed(payload: Data, width: Int, height: Int) -> CVPixelBuffer? {
        if !warned {
            warned = true
            log("iOS: H.264 解码尚未实现（需在 Mac 上补 VTDecompressionSession），当前只支持 MJPEG")
        }
        return nil
    }

    func invalidate() {}
}
