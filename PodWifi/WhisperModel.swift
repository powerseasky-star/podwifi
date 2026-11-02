import Foundation

/// whisper.cpp 的 ggml 模型管理：首次使用下载到 App 沙盒，之后复用。
///
/// 为什么运行时下载而不是打进包里：模型 57~181 MB，塞进 ipa 会让每次装机都多传几十 MB，
/// 而调试期经常重装。下载地址可在设置里改（默认用 hf-mirror 镜像，国内可达性好于 huggingface）。
enum WhisperModel {

    static let fileName = "ggml-base-q5_1.bin"

    /// 默认下载源（hf-mirror 是 HuggingFace 的国内镜像）
    static let defaultURL = "https://hf-mirror.com/ggerganov/whisper.cpp/resolve/main/ggml-base-q5_1.bin"

    static var dir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory,
                                         in: .userDomainMask)[0]
        let sub = d.appendingPathComponent("whisper", isDirectory: true)
        if !FileManager.default.fileExists(atPath: sub.path) {
            try? FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        }
        return sub
    }

    static var fileURL: URL { dir.appendingPathComponent(fileName) }

    static var exists: Bool {
        let p = fileURL.path
        guard FileManager.default.fileExists(atPath: p) else { return false }
        let sz = (try? FileManager.default.attributesOfItem(atPath: p)[.size] as? Int) ?? 0
        // 小于 10MB 视为没下完（base-q5_1 约 57MB）
        return (sz ?? 0) > 10 * 1024 * 1024
    }

    /// 下载模型（带进度回调）。已存在则直接返回。
    static func ensureDownloaded(urlString: String,
                                 progress: @escaping (Double) -> Void) async throws -> URL {
        if exists { return fileURL }
        guard let u = URL(string: urlString), !urlString.isEmpty else {
            throw NSError(domain: "WhisperModel", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "模型地址为空"])
        }
        let (tmp, resp) = try await URLSession.shared.download(from: u)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw NSError(domain: "WhisperModel", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "下载失败 HTTP \(http.statusCode)"])
        }
        let sz = (try? FileManager.default.attributesOfItem(atPath: tmp.path)[.size] as? Int) ?? 0
        guard (sz ?? 0) > 10 * 1024 * 1024 else {
            throw NSError(domain: "WhisperModel", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "下载内容过小，可能不是模型文件"])
        }
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try? FileManager.default.removeItem(at: fileURL)
        }
        try FileManager.default.moveItem(at: tmp, to: fileURL)
        progress(1.0)
        return fileURL
    }
}
