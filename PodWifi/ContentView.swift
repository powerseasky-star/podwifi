import SwiftUI
import CoreImage
import UIKit
import AVFoundation
import CoreBluetooth

// MARK: - 根视图：无线 / 蓝牙 两个模式

struct ContentView: View {
    var body: some View {
        TabView {
            WifiView()
                .tabItem { Label("无线", systemImage: "wifi") }
            BleView()
                .tabItem { Label("蓝牙", systemImage: "dot.radiowaves.left.and.right") }
        }
    }
}

// =====================================================================
// MARK: - 无线（Wi-Fi TCP 收流）
// =====================================================================

struct WifiView: View {
    @StateObject private var model = ReceiverModel()

    var body: some View {
        VStack(spacing: 8) {
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
                .foregroundStyle(model.statusIsError ? Color.red : Color.secondary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)

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
    @Published var statusIsError = false
    @Published var image: UIImage?
    @Published var running = false
    @Published var sensorLine = "无数据"
    @Published var videoStat = ""
    @Published var lastSpoken = ""
    @Published var speakEnabled = true

    private var rx: WifiStereoReceiver?
    // nonisolated：解码在后台队列，CIContext 线程安全，但不能从后台碰 MainActor 隔离属性
    nonisolated private let ci = CIContext()
    private let speaker = AVSpeechSynthesizer()
    private var lastPaint = Date.distantPast

    private static let hostKey = "pod.wifi.host"
    private static let portKey = "pod.wifi.port"

    init() {
        // v0.2.0：记住上次填的地址，重装 App 后不用再手输
        let d = UserDefaults.standard
        if let h = d.string(forKey: ReceiverModel.hostKey), !h.isEmpty { host = h }
        if let p = d.string(forKey: ReceiverModel.portKey), !p.isEmpty { portText = p }
    }

    func toggle() { running ? stop() : start() }

    private func start() {
        guard let port = UInt16(portText) else {
            status = "端口不合法：\(portText)"
            statusIsError = true
            return
        }
        let cleanHost = host.trimmingCharacters(in: .whitespaces)
        guard !cleanHost.isEmpty else {
            status = "请先填 Pod 的 IP"
            statusIsError = true
            return
        }
        UserDefaults.standard.set(cleanHost, forKey: ReceiverModel.hostKey)
        UserDefaults.standard.set(portText, forKey: ReceiverModel.portKey)
        configureAudio()

        let r = WifiStereoReceiver(host: cleanHost, port: port)
        r.onState = { [weak self] ok, msg in
            Task { @MainActor in
                guard let self = self else { return }
                self.statusIsError = !ok
                if ok {
                    self.status = "已连接：\(msg)"
                } else {
                    self.status = "问题：\(msg)\n排查：①手机 Wi-Fi 与 Pod 是否同网段 ②设置→隐私与安全性→本地网络 是否允许本 App"
                }
            }
        }
        r.onStereoFrame = { [weak self] left, _, ts in
            guard let self = self else { return }
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
            Task { @MainActor in self?.status = "事件：\(text)" }
        }

        rx = r
        r.start()
        running = true
        statusIsError = false
        status = "连接中… \(cleanHost):\(port)"
    }

    private func stop() {
        rx?.stop()
        rx = nil
        running = false
        statusIsError = false
        status = "已停止"
        image = nil
        speaker.stopSpeaking(at: .immediate)
    }

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

    private func configureAudio() {
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

// =====================================================================
// MARK: - 蓝牙（BLE NUS：0xAA 帧；不接相机也能测传感器 / 姿态 / 命令）
// =====================================================================

struct BleDeviceRow: Identifiable {
    let id: UUID
    let name: String
    let rssi: Int
    let hasService: Bool
}

struct BleView: View {
    @StateObject private var model = BleModel()

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("蓝牙").font(.headline)
                Spacer()
                Text(model.btState)
                    .font(.footnote)
                    .foregroundStyle(model.connected ? Color.green : Color.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal)

            HStack(spacing: 8) {
                Button(model.scanning ? "停止扫描" : "扫描") { model.toggleScan() }
                    .buttonStyle(.borderedProminent)
                Button("断开") { model.disconnect() }
                    .buttonStyle(.bordered)
                    .disabled(!model.connected)
                Spacer()
                Text(model.connected ? "已连：\(model.connectedName)" : "未连接")
                    .font(.footnote)
                    .lineLimit(1)
            }
            .padding(.horizontal)

            if !model.connected {
                List(model.devices) { d in
                    Button {
                        model.connect(d.id)
                    } label: {
                        HStack {
                            Text(d.name).font(.body)
                            if d.hasService {
                                Text("NUS")
                                    .font(.caption2)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Color.blue.opacity(0.2))
                                    .clipShape(Capsule())
                            }
                            Spacer()
                            Text("\(d.rssi) dBm").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxHeight: 190)

                Text("提示：Pod 连上后会停止广播，此时扫不到是正常的")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("传感器（0x07）").font(.headline)
                    Text(model.sensorLine).font(.footnote.monospaced())
                    Text("姿态（0x11）").font(.headline).padding(.top, 4)
                    Text(model.poseLine).font(.footnote.monospaced())
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)

                // 下行命令：校时 + 导航指令（会驱动马达，可用来验证下行通路）
                HStack(spacing: 6) {
                    Button("校时") { model.timeSync() }
                    Button("左转") { model.navCmd(1, 2.0) }
                    Button("右转") { model.navCmd(2, 2.0) }
                    Button("直行") { model.navCmd(3, nil) }
                    Button("注意车") { model.navCmd(6, nil) }
                }
                .buttonStyle(.bordered)
                .font(.footnote)
                .padding(.horizontal)
            }

            Text(model.podRequest.isEmpty ? " " : "Pod 请求：" + model.podRequest)
                .font(.footnote)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)

            // 原始帧日志：排查协议问题全靠它
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(model.logs.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 10, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(6)
                }
                .background(Color.black.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal)
                .padding(.bottom, 8)
                .onChange(of: model.logs.count) { _ in
                    // 注意：双参数版 onChange 是 iOS 17+，本工程最低 15.0，只能用单参数版
                    if let last = model.logs.indices.last {
                        withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
            }
        }
    }
}

@MainActor
final class BleModel: ObservableObject {
    @Published var btState = "未初始化"
    @Published var devices: [BleDeviceRow] = []
    @Published var connected = false
    @Published var connectedName = ""
    @Published var scanning = false
    @Published var sensorLine = "无数据"
    @Published var poseLine = "无数据"
    @Published var podRequest = ""
    @Published var logs: [String] = []

    private let cli = BlePodClient()
    private let speaker = AVSpeechSynthesizer()
    private var known: Set<UUID> = []

    init() {
        cli.onState = { [weak self] s in
            guard let self = self else { return }
            self.btState = s
            self.log(s)
            if s.contains("扫描中") { self.scanning = true }
            if s.contains("已断开") { self.connected = false; self.scanning = false }
        }
        cli.onDiscover = { [weak self] name, id, rssi, hasSvc in
            guard let self = self else { return }
            if self.known.contains(id) {
                if let i = self.devices.firstIndex(where: { $0.id == id }) {
                    self.devices[i] = BleDeviceRow(id: id, name: name, rssi: rssi, hasService: hasSvc)
                }
                return
            }
            self.known.insert(id)
            self.devices.append(BleDeviceRow(id: id, name: name, rssi: rssi, hasService: hasSvc))
        }
        cli.onConnected = { [weak self] name in
            guard let self = self else { return }
            self.connected = true
            self.connectedName = name
            self.scanning = false
        }
        cli.onDisconnected = { [weak self] in
            self?.connected = false
        }
        cli.onSensor = { [weak self] s in
            guard let self = self else { return }
            var parts: [String] = []
            parts.append(s.tofMm >= 0 ? String(format: "ToF %.2fm", Double(s.tofMm) / 1000.0) : "ToF 无效")
            parts.append(s.ultraMm >= 0 ? String(format: "超声 %.2fm", Double(s.ultraMm) / 1000.0) : "超声 无效")
            parts.append(s.lux >= 0 ? "光 \(s.lux)lx" : "光 无效")
            parts.append("倾角 \(s.tiltDeg)°")
            parts.append(s.battPct >= 0 ? "电 \(s.battPct)%" : "电 无效")
            parts.append("level \(s.level)")
            var st: [String] = []
            if s.fall { st.append("摔倒") }
            if s.stationary { st.append("静止") }
            if s.irOn { st.append("IR") }
            if s.muted { st.append("静音") }
            if !st.isEmpty { parts.append("[" + st.joined(separator: ",") + "]") }
            self.sensorLine = parts.joined(separator: "  ")
        }
        cli.onPose = { [weak self] p in
            guard let self = self else { return }
            var s = String(format: "航向 %.1f°  磁力 %.1f", p.yawDeg, p.mag)
            if !p.yawValid { s += "  (yaw 无效)" }
            if p.magDisturbed { s += "  (磁干扰可疑)" }
            self.poseLine = s
        }
        cli.onFrameLog = { [weak self] line in
            self?.log(line)
        }
        cli.onPodRequest = { [weak self] kind, text in
            guard let self = self else { return }
            self.podRequest = "\(kind)：\(text)"
            if kind == "朗读请求", !text.isEmpty {
                let u = AVSpeechUtterance(string: text)
                u.voice = AVSpeechSynthesisVoice(language: "zh-CN")
                self.speaker.stopSpeaking(at: .immediate)
                self.speaker.speak(u)
            }
        }
    }

    func log(_ s: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        logs.append(f.string(from: Date()) + "  " + s)
        if logs.count > 120 { logs.removeFirst(logs.count - 120) }
    }

    func toggleScan() {
        if scanning {
            cli.stopScan()
            scanning = false
        } else {
            devices.removeAll()
            known.removeAll()
            cli.startScan()
        }
    }

    func connect(_ id: UUID) { cli.connect(id) }
    func disconnect() { cli.disconnect() }
    func timeSync() { cli.sendTimeSync() }
    func navCmd(_ action: UInt8, _ dist: Double?) { cli.sendNavCmd(action: action, distMeters: dist) }
}
