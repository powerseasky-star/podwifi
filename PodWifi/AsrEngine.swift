import AVFoundation
import Foundation

/// 语音识别：麦克风采集 → 端点检测（说话结束）→ whisper.cpp 识别
///
/// 为什么不做常驻唤醒词：whisper 是"整段音频重解码"，常驻监听在手机上耗电与发热都不可接受
/// （官方示例也只在按键录音后用）。所以这里用**按住/点一次说一句**：说完自动结束并识别。
@MainActor
final class AsrEngine: ObservableObject {

    @Published var state: String = "未就绪"
    @Published var listening = false
    @Published var decoding = false
    @Published var lastText: String = ""
    @Published var level: Float = 0

    /// 识别完成回调（在主线程）
    var onResult: ((String) -> Void)?

    private let whisper = PodWhisper()
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private var silenceSince: Date?
    private var speechStarted = false
    private var startedAt: Date?
    private let lock = NSLock()

    // 参数（实测可调）
    private let targetRate: Double = 16000
    private let maxSeconds: Double = 8.0
    private let silenceStop: Double = 0.9
    private let rmsThreshold: Float = 0.012

    var isReady: Bool { whisper.isLoaded }

    // MARK: - 模型

    func loadModelIfNeeded() {
        guard !whisper.isLoaded else { state = "模型就绪"; return }
        guard WhisperModel.exists else {
            state = "缺模型（点『下载模型』）"
            return
        }
        state = "加载模型…"
        let path = WhisperModel.fileURL.path
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let ok = self.whisper.loadModel(atPath: path)
            DispatchQueue.main.async {
                self.state = ok ? "模型就绪" : "模型加载失败"
            }
        }
    }

    func downloadModel(urlString: String) async {
        state = "下载模型…"
        do {
            _ = try await WhisperModel.ensureDownloaded(urlString: urlString) { p in
                Task { @MainActor in self.state = String(format: "下载模型 %.0f%%", p * 100) }
            }
            loadModelIfNeeded()
        } catch {
            state = "下载失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 采集

    func start() {
        guard !listening else { return }
        guard whisper.isLoaded else { state = "模型未加载"; return }

        let session = AVAudioSession.sharedInstance()
        session.requestRecordPermission { granted in
            guard granted else {
                Task { @MainActor in self.state = "无麦克风权限（设置→PodWifi→麦克风）" }
                return
            }
            Task { @MainActor in self.beginCapture() }
        }
    }

    private func beginCapture() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement,
                                    options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)

            let input = engine.inputNode
            let inFmt = input.inputFormat(forBus: 0)
            guard let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: targetRate,
                                             channels: 1,
                                             interleaved: false),
                  let conv = AVAudioConverter(from: inFmt, to: outFmt) else {
                state = "音频格式转换失败"
                return
            }
            converter = conv

            lock.lock(); samples.removeAll(keepingCapacity: true); lock.unlock()
            silenceSince = nil
            speechStarted = false
            startedAt = Date()
            listening = true
            state = "正在听…"

            input.installTap(onBus: 0, bufferSize: 1024, format: inFmt) { [weak self] buf, _ in
                self?.handle(buf: buf, outFmt: outFmt)
            }
            engine.prepare()
            try engine.start()
        } catch {
            listening = false
            state = "启动录音失败：\(error.localizedDescription)"
        }
    }

    private func handle(buf: AVAudioPCMBuffer, outFmt: AVAudioFormat) {
        guard let conv = converter else { return }
        let ratio = outFmt.sampleRate / buf.format.sampleRate
        let cap = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: cap) else { return }

        var err: NSError?
        var fed = false
        conv.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buf
        }
        guard err == nil, out.frameLength > 0, let ch = out.floatChannelData?[0] else { return }

        let n = Int(out.frameLength)
        var sum: Float = 0
        var tmp = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let v = ch[i]
            tmp[i] = v
            sum += v * v
        }
        let rms = sqrtf(sum / Float(max(1, n)))

        lock.lock()
        samples.append(contentsOf: tmp)
        let total = samples.count
        lock.unlock()

        let elapsed = Date().timeIntervalSince(startedAt ?? Date())

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.level = rms
            if rms > self.rmsThreshold {
                self.speechStarted = true
                self.silenceSince = nil
            } else if self.speechStarted {
                if self.silenceSince == nil { self.silenceSince = Date() }
                if let s = self.silenceSince, Date().timeIntervalSince(s) > self.silenceStop {
                    self.finishCapture()
                    return
                }
            }
            if elapsed > self.maxSeconds && self.speechStarted {
                self.finishCapture()
            }
        }
    }

    /// 手动结束（用户再点一次）
    func stopAndDecode() {
        if listening { finishCapture() }
    }

    private func finishCapture() {
        guard listening else { return }
        listening = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        lock.lock()
        let pcm = samples
        samples.removeAll(keepingCapacity: false)
        lock.unlock()

        // 太短（<0.4s）直接丢弃，避免把咳嗽/关门当命令
        guard pcm.count > Int(targetRate * 0.4) else {
            state = "太短，没听清"
            return
        }

        decoding = true
        state = "识别中…"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            var text = ""
            pcm.withUnsafeBufferPointer { bp in
                if let base = bp.baseAddress {
                    text = self.whisper.transcribeSamples(base, count: Int32(bp.count))
                }
            }
            let cleaned = Self.clean(text)
            DispatchQueue.main.async {
                self.decoding = false
                self.lastText = cleaned
                self.state = cleaned.isEmpty ? "没识别出内容" : "识别完成"
                if !cleaned.isEmpty { self.onResult?(cleaned) }
            }
        }
    }

    /// whisper 中文输出常带空格与标点噪音，去掉便于关键词匹配
    private static func clean(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        t = t.replacingOccurrences(of: " ", with: "")
        // 去掉首尾标点（保留中文与字母数字）
        let junk = CharacterSet(charactersIn: "，。,.!！?？、:：;；\"'“”‘’")
        while let f = t.unicodeScalars.first, junk.contains(f) {
            t.removeFirst()
        }
        while let l = t.unicodeScalars.last, junk.contains(l) {
            t.removeLast()
        }
        return t
    }
}
