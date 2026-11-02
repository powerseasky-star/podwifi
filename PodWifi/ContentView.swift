import SwiftUI
import CoreImage
import UIKit
import AVFoundation

/// iOS 端 v2：**单目画面 + 传感器面板 + 语音导航**
///
/// 为什么是单目：iPhone 拿不到 UVC，双目只能靠 Pod 推流；先用单目把「看得到 + 听得到 + 传感器到位」
/// 这条最小可用链路跑通，双目/深度后续再上（那需要 CoreML 模型 + 更宽带宽）。
struct ContentView: View {
    @StateObject private var model = ReceiverModel()

    var body: some View {
        VStack(spacing: 8) {
            // ---- 连接栏 ----
            HStack(spacing: 8) {
                TextField("192.168.4.1", text: $model.host)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.numbersAndPunctuation)
                    .autocorrectionDisabled()
                TextField("5000", text: $model.portText)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.numberPad)
                    .frame(width: 68)
                Button(model.running ? "停止" : "连接") { model.toggle() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal)

            Text(model.status)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)

            // ---- 单目画面 ----
            ZStack {
                Color.black
                if let img = model.image {
                    Image(uiImage: img).resizable().scaledToFit()
                } else {
                    Text("无画面").foregroundStyle(.white.opacity(0.6))
                }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(4.0 / 3.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal)

            // ---- 传感器 ----
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("传感器").font(.headline)
                    Spacer()
                    Text(model.videoStat).font(.footnote.monospaced())
                }
                Text(model.sensorLine)
                    .font(.footnote.monospaced())
                    .foregroundStyle(model.sensorLine == "无数据" ? .secondary : .primary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)

            // ---- 语音 ----
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("语音导航").font(.headline)
                    Spacer()
                    Toggle("播报", isOn: $model.speakEnabled).labelsHidden()
                }
                Text(model.lastSpoken.isEmpty ? "（暂无播报）" : model.lastSpoken)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.bottom, 10)
        }
    }
}

@MainActor
final class ReceiverModel: ObservableObject {
    @Published var host = "192.168.4.1"
    @Published var portText = "5000"
    @Published var status = "未连接"
    @Published var image: UIImage?
    @Published var running = false
    @Published var sensorLine = "无数据"
    @Published var videoStat = ""
    @Published var lastSpoken = ""
    @Published var speakEnabled = true

    private var rx: WifiStereoReceiver?
    // nonisolated：视频解码在后台队列，CIContext 本身线程安全，但不能从后台碰 MainActor 隔离的属性
    nonisolated private let ci = CIContext()
    private let speaker = AVSpeechSynthesizer()
    private var lastPaint = Date.distantPast

    func toggle() { running ? stop() : start() }

    private func start() {
        guard let port = UInt16(portText) else { status = "端口不合法"; return }
        configureAudio()

        let r = WifiStereoReceiver(host: host.trimmingCharacters(in: .whitespaces), port: port)
        r.onState = { [weak self] ok, msg in
            Task { @MainActor in self?.status = (ok ? "已连接：" : "异常：") + msg }
        }
        // 单目：收到整帧就用（并排时 receiver 会切成左眼）
        r.onStereoFrame = { [weak self] left, _, ts in
            guard let self = self else { return }
            // 重活（解码）留在后台队列；**凡是 MainActor 隔离的状态一律在主线程改**。
            // 旧版在后台线程读写 @MainActor 的 lastPaint，是数据竞争（不是 2026-11-02 那次崩溃的主因，
            // 但确实是错的，顺手修掉）。节流也移到主线程做，语义更清楚。
            let ciImg = CIImage(cvPixelBuffer: left)
            guard let cg = self.ci.createCGImage(ciImg, from: ciImg.extent) else { return }
            let img = UIImage(cgImage: cg)
            let fps = r.fps
            let drops = r.dropFrames
            Task { @MainActor in
                let now = Date()
                if now.timeIntervalSince(self.lastPaint) < 0.1 { return }   // UI 限 10fps
                self.lastPaint = now
                self.image = img
                self.videoStat = String(format: "%.1f fps 丢%u ts=%u", fps, drops, ts)
            }
        }
        r.onSensorJson = { [weak self] json in
            Task { @MainActor in self?.applySensor(json) }
        }
        r.onNavText = { [weak self] text in
            Task { @MainActor in self?.speak(text) }
        }
        r.onEvent = { [weak self] text in
            Task { @MainActor in self?.status = "事件：" + text }
        }

        rx = r
        r.start()
        running = true
        status = "连接中…"
    }

    private func stop() {
        rx?.stop()
        rx = nil
        running = false
        status = "已停止"
        image = nil
        speaker.stopSpeaking(at: .immediate)
    }

    // MARK: - 传感器（JSON 字段全部可选）

    private func applySensor(_ json: String) {
        guard let data = json.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            sensorLine = "解析失败：" + json
            return
        }
        var parts: [String] = []
        if let v = o["tof"] as? Double { parts.append(String(format: "ToF %.2fm", v)) }
        if let v = o["ultra"] as? Double { parts.append(String(format: "超声 %.2fm", v)) }
        if let v = o["lux"] as? Int { parts.append("光 \(v)lx") }
        if let v = o["tilt"] as? Int { parts.append("倾角 \(v)°") }
        if let v = o["batt"] as? Int { parts.append("电 \(v)%") }
        if (o["still"] as? Bool) == true { parts.append("静止") }
        if (o["fall"] as? Bool) == true { parts.append("摔倒") }
        sensorLine = parts.isEmpty ? json : parts.joined(separator: "  ")
    }

    // MARK: - 语音

    private func configureAudio() {
        // 让播报在静音键打开时也能出声（导航场景必须）
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers, .mixWithOthers])
        try? session.setActive(true)
    }

    private func speak(_ text: String) {
        lastSpoken = text
        guard speakEnabled else { return }
        speaker.stopSpeaking(at: .immediate)     // 新播报优先，避免排队过时信息
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        speaker.speak(u)
    }
}
