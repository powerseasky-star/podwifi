import Foundation

/// OpenAI 兼容大模型客户端（默认 DeepSeek，与安卓 NavAgent 一致：Bearer + /chat/completions）
enum LlmClient {

    struct Message {
        let role: String     // system / user / assistant
        let content: String
    }

    private static func enc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
    }

    /// 单轮补全。失败抛错，调用方负责降级成"我这边没听懂，请再说一遍"。
    static func chat(base: String, key: String, model: String,
                     messages: [Message],
                     timeout: TimeInterval = 20) async throws -> String {
        let b = base.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let url = URL(string: b + "/chat/completions") else {
            throw NSError(domain: "LLM", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "base URL 非法"])
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "model": model,
            "temperature": 0.3,
            "max_tokens": 220,
            "messages": messages.map { ["role": $0.role, "content": $0.content] }
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            let txt = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "LLM", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode) \(txt.prefix(120))"])
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first,
              let msg = first["message"] as? [String: Any],
              let content = msg["content"] as? String else {
            throw NSError(domain: "LLM", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "返回格式异常"])
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 导盲场景的系统提示：简短、口语、一次一句（长句在实走时会听不懂/记不住）
    static func systemPrompt(sensor: String) -> Message {
        return Message(role: "system", content: """
        你是盲人导盲助手的语音播报员。规则：
        1. 只用中文口语，一次最多一句话，不超过 25 个字。
        2. 不寒暄、不解释过程、不用 Markdown、不列点。
        3. 涉及方向时用"左前方/正前方/右前方"，涉及距离用"米"，一次给一个数。
        4. 拿不准就说"我不确定"，绝不编造地点或距离。
        当前传感器：\(sensor)
        """)
    }
}
