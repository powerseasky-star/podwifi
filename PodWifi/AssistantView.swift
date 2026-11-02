import SwiftUI

/// 语音/导航页：说话或打字 → 下发 / 导航 / 大模型 → 语音播报
struct AssistantView: View {
    @StateObject private var eng = AssistantEngine()
    @StateObject private var asr = AsrEngine()
    @ObservedObject private var st = AppSettings.shared
    @ObservedObject private var vision = VisionHub.shared
    @State private var text = ""
    @State private var showSettings = false

    private let quickItems = [
        "开灯", "关灯", "开灯带", "关灯带",
        "打开扬声器", "关闭扬声器", "静音", "自检",
        "开补光", "关补光", "测试摔倒", "恢复自动"
    ]

    /// 麦克风按钮标题由三态决定：缺模型 / 可说话 / 正在听
    private var micTitle: String {
        if !asr.isReady { return WhisperModel.exists ? "加载模型" : "下载模型" }
        return asr.listening ? "停止" : "说话"
    }

    var body: some View {
        VStack(spacing: 8) {
            // 状态行
            HStack(spacing: 10) {
                Text(PodLink.shared.isConnected ? "蓝牙：已连接" : "蓝牙：未连接")
                    .foregroundColor(PodLink.shared.isConnected ? .green : .orange)
                Text(st.hasAmap ? "高德✓" : "高德✗").foregroundColor(st.hasAmap ? .green : .gray)
                Text(st.hasLlm ? "模型✓" : "模型✗").foregroundColor(st.hasLlm ? .green : .gray)
                Spacer()
                Button("设置") { showSettings = true }.font(.caption)
            }
            .font(.caption)
            .padding(.horizontal)

            // 视觉：YOLO 检测 + 双目深度（来自「无线」页的收流）
            HStack(spacing: 8) {
                Text(vision.ready ? "识别：\(vision.detsText)" : "识别：未加载")
                    .lineLimit(1)
                Spacer()
                Text("深度：\(vision.depthText)").lineLimit(1)
            }
            .font(.caption2)
            .foregroundColor(.secondary)
            .padding(.horizontal)

            // 导航进行中：显示当前指令 + 停止
            if eng.navActive {
                HStack {
                    Text(eng.navStatus).font(.caption).foregroundColor(.blue).lineLimit(1)
                    Spacer()
                    Button("停止导航") { eng.stopNav() }.font(.caption)
                }
                .padding(.horizontal)
            }

            // 语音识别区
            HStack(spacing: 10) {
                Button {
                    if !asr.isReady {
                        if WhisperModel.exists {
                            asr.loadModelIfNeeded()
                        } else {
                            Task { await asr.downloadModel(urlString: st.whisperURL) }
                        }
                    } else if asr.listening {
                        asr.stopAndDecode()
                    } else {
                        asr.start()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: asr.listening ? "stop.circle.fill" : "mic.circle.fill")
                        Text(micTitle)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(asr.listening ? Color.red.opacity(0.85) : Color.green.opacity(0.18))
                    .foregroundColor(asr.listening ? .white : .primary)
                    .cornerRadius(16)
                }
                .disabled(asr.decoding)

                // 音量指示（录音时才有意义）
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.gray.opacity(0.2))
                        Capsule()
                            .fill(asr.level > 0.012 ? Color.green : Color.orange)
                            .frame(width: max(2, min(1, CGFloat(asr.level) * 12) * g.size.width))
                    }
                }
                .frame(height: 8)

                Text(asr.state).font(.caption2).foregroundColor(.secondary).lineLimit(1)
            }
            .padding(.horizontal)

            if !asr.lastText.isEmpty {
                Text("听到：\(asr.lastText)")
                    .font(.footnote).foregroundColor(.blue)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
            }

            // 文字输入（语音不好用时兜底）
            HStack {
                TextField("也可以直接打字，比如：导航去最近的地铁站", text: $text)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .disabled(eng.busy)
                Button(eng.busy ? "…" : "发送") {
                    let t = text
                    text = ""
                    Task { await eng.submit(t) }
                }
                .disabled(eng.busy || text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal)

            // 快捷命令
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(quickItems, id: \.self) { item in
                        Button(item) { eng.quick(item) }
                            .font(.caption)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Color.blue.opacity(0.12))
                            .cornerRadius(14)
                    }
                }
                .padding(.horizontal)
            }

            if !eng.lastReply.isEmpty {
                Text("回复：\(eng.lastReply)")
                    .font(.footnote)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
            }

            // 日志
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(eng.logs.enumerated()), id: \.offset) { i, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(i)
                        }
                    }
                    .padding(.horizontal, 8)
                }
                .background(Color.gray.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal)
                .padding(.bottom, 8)
                .onChange(of: eng.logs.count) { _ in
                    if let last = eng.logs.indices.last {
                        withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
            }
        }
        .padding(.top, 6)
        .sheet(isPresented: $showSettings) {
            SettingsView().environmentObject(st)
        }
        .onAppear {
            LocationProvider.shared.prepare()
            VisionHub.shared.warmUp()
            // 识别结果直接交给同一套调度：本地命令 → 导航 → 大模型
            asr.onResult = { spoken in
                Task { await eng.submit(spoken) }
            }
            asr.loadModelIfNeeded()
        }
    }
}

/// 设置页：Key 只存本机 UserDefaults，不进代码、不进仓库
struct SettingsView: View {
    @EnvironmentObject var st: AppSettings
    @Environment(\.presentationMode) var presentation

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("无线视频")) {
                    TextField("Pod IP", text: $st.wifiHost)
                    TextField("端口", text: $st.wifiPort)
                }
                Section(header: Text("高德（Web 服务 Key）"),
                        footer: Text("高德开放平台 → 应用管理 → Web服务。仅存本机。")) {
                    TextField("amap key", text: $st.amapKey)
                }
                Section(header: Text("大模型（OpenAI 兼容）"),
                        footer: Text("默认 DeepSeek：base=https://api.deepseek.com/v1，model=deepseek-chat")) {
                    TextField("base URL", text: $st.llmBase)
                    TextField("model", text: $st.llmModel)
                    TextField("api key", text: $st.llmKey)
                }
                Section(header: Text("语音识别（whisper.cpp）"),
                        footer: Text("默认 base-q5_1（约 57MB，中文可用）。下载源可改成自己的镜像或局域网地址。")) {
                    TextField("模型下载地址", text: $st.whisperURL)
                        .font(.system(size: 12))
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }
                Section {
                    Button("完成") { presentation.wrappedValue.dismiss() }
                }
            }
            .navigationTitle("设置")
        }
    }
}
