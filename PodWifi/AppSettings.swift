import Foundation

/// 运行期设置（Key 不写进代码、不进仓库，与安卓端 `navPrefs.getString("amap_key")` 同思路）
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let d = UserDefaults.standard

    // 无线视频地址
    @Published var wifiHost: String { didSet { d.set(wifiHost, forKey: "wifiHost") } }
    @Published var wifiPort: String { didSet { d.set(wifiPort, forKey: "wifiPort") } }

    // 高德开放平台「Web 服务」Key（restapi.amap.com 用这个）
    @Published var amapKey: String { didSet { d.set(amapKey, forKey: "amapKey") } }

    // OpenAI 兼容大模型
    @Published var llmBase: String { didSet { d.set(llmBase, forKey: "llmBase") } }
    @Published var llmKey: String { didSet { d.set(llmKey, forKey: "llmKey") } }
    @Published var llmModel: String { didSet { d.set(llmModel, forKey: "llmModel") } }

    /// whisper 模型下载地址（默认 hf-mirror 镜像，可改）
    @Published var whisperURL: String { didSet { d.set(whisperURL, forKey: "whisperURL") } }

    private init() {
        wifiHost = d.string(forKey: "wifiHost") ?? "192.168.1.23"
        wifiPort = d.string(forKey: "wifiPort") ?? "5000"
        amapKey = d.string(forKey: "amapKey") ?? ""
        llmBase = d.string(forKey: "llmBase") ?? "https://api.deepseek.com/v1"
        llmKey = d.string(forKey: "llmKey") ?? ""
        llmModel = d.string(forKey: "llmModel") ?? "deepseek-chat"
        whisperURL = d.string(forKey: "whisperURL") ?? WhisperModel.defaultURL
    }

    var hasAmap: Bool { !amapKey.trimmingCharacters(in: .whitespaces).isEmpty }
    var hasLlm: Bool { !llmKey.trimmingCharacters(in: .whitespaces).isEmpty }
}
