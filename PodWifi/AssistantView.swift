import SwiftUI

/// 语音/导航页：输入指令 → 下发 / 导航 / 大模型 → 语音播报
struct AssistantView: View {
    @StateObject private var eng = AssistantEngine()
    @ObservedObject private var st = AppSettings.shared
    @State private var text = ""
    @State private var showSettings = false

    private let quickItems = [
        "开灯", "关灯", "开灯带", "关灯带",
        "打开扬声器", "关闭扬声器", "静音", "自检",
        "开补光", "关补光", "测试摔倒", "恢复自动"
    ]

    var body: some View {
        VStack(spacing: 8) {
            // 状态行
            HStack(spacing: 12) {
                Text(PodLink.shared.isConnected ? "蓝牙：已连接" : "蓝牙：未连接")
                    .foregroundColor(PodLink.shared.isConnected ? .green : .orange)
                Text(st.hasAmap ? "高德：已配" : "高德：未配")
                    .foregroundColor(st.hasAmap ? .green : .gray)
                Text(st.hasLlm ? "大模型：已配" : "大模型：未配")
                    .foregroundColor(st.hasLlm ? .green : .gray)
                Spacer()
                Button("设置") { showSettings = true }
                    .font(.caption)
            }
            .font(.caption)
            .padding(.horizontal)

            // 输入
            HStack {
                TextField("说点什么，比如：导航去最近的地铁站", text: $text)
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
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.blue.opacity(0.12))
                            .cornerRadius(14)
                    }
                }
                .padding(.horizontal)
            }

            // 最近一次回复
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
        .onAppear { LocationProvider.shared.prepare() }
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
                Section {
                    Button("完成") { presentation.wrappedValue.dismiss() }
                }
            }
            .navigationTitle("设置")
        }
    }
}
