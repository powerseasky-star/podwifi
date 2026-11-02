import Foundation

/// 高德 Web 服务（restapi.amap.com）客户端。
///
/// 说明：安卓端用的是高德 **MCP Server**（`mcp.amap.com/mcp`，JSON-RPC + SSE 会话）。
/// iOS 侧直接调同样的 Web 服务 REST 接口 —— **同一个 Key、同样的数据**，
/// 但省掉「在 App 里实现 MCP 会话/SSE」这一层无用复杂度。
enum AmapClient {

    struct POI {
        let name: String
        let address: String
        let lng: Double
        let lat: Double
        let distanceM: Int
    }

    struct RouteStep {
        let instruction: String
        let distanceM: Int
    }

    struct Route {
        let distanceM: Int
        let durationS: Int
        let steps: [RouteStep]
        let destination: (lng: Double, lat: Double)?
    }

    private static func get(_ url: String) async throws -> [String: Any] {
        guard let u = URL(string: url) else {
            throw NSError(domain: "Amap", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "URL 非法"])
        }
        var req = URLRequest(url: u)
        req.timeoutInterval = 8
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "Amap", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "返回非 JSON"])
        }
        if let status = obj["status"] as? String, status != "1" {
            let info = obj["info"] as? String ?? "未知错误"
            throw NSError(domain: "Amap", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "高德返回：\(info)"])
        }
        return obj
    }

    private static func enc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
    }

    /// 逆地理编码：坐标 → 文字地址
    static func regeo(key: String, lng: Double, lat: Double) async throws -> String {
        let url = "https://restapi.amap.com/v3/geocode/regeo?key=\(enc(key))&location=\(lng),\(lat)&extensions=base"
        let obj = try await get(url)
        guard let re = obj["regeocode"] as? [String: Any] else { return "未知位置" }
        return (re["formatted_address"] as? String) ?? "未知位置"
    }

    /// POI 关键字搜索
    static func searchPOI(key: String, keywords: String, city: String = "") async throws -> [POI] {
        var url = "https://restapi.amap.com/v3/place/text?key=\(enc(key))&keywords=\(enc(keywords))&offset=5&page=1&extensions=base"
        if !city.isEmpty { url += "&city=\(enc(city))" }
        let obj = try await get(url)
        guard let pois = obj["pois"] as? [[String: Any]] else { return [] }
        return pois.compactMap { p in
            guard let name = p["name"] as? String,
                  let loc = p["location"] as? String else { return nil }
            let parts = loc.split(separator: ",")
            guard parts.count == 2,
                  let lng = Double(parts[0]), let lat = Double(parts[1]) else { return nil }
            let addr = (p["address"] as? String) ?? ""
            let dist = Int((p["distance"] as? String) ?? "0") ?? 0
            return POI(name: name, address: addr, lng: lng, lat: lat, distanceM: dist)
        }
    }

    /// 步行路径规划
    static func walking(key: String,
                        fromLng: Double, fromLat: Double,
                        toLng: Double, toLat: Double) async throws -> Route {
        let url = "https://restapi.amap.com/v3/direction/walking?key=\(enc(key))"
            + "&origin=\(fromLng),\(fromLat)&destination=\(toLng),\(toLat)"
        let obj = try await get(url)
        guard let route = obj["route"] as? [String: Any],
              let paths = route["paths"] as? [[String: Any]],
              let first = paths.first else {
            throw NSError(domain: "Amap", code: -4,
                          userInfo: [NSLocalizedDescriptionKey: "未找到步行路线"])
        }
        let dist = Int((first["distance"] as? String) ?? "0") ?? 0
        let dur = Int((first["duration"] as? String) ?? "0") ?? 0
        var steps: [RouteStep] = []
        if let raw = first["steps"] as? [[String: Any]] {
            for s in raw {
                let ins = (s["instruction"] as? String) ?? ""
                let d = Int((s["distance"] as? String) ?? "0") ?? 0
                if !ins.isEmpty { steps.append(RouteStep(instruction: ins, distanceM: d)) }
            }
        }
        return Route(distanceM: dist, durationS: dur, steps: steps,
                     destination: (toLng, toLat))
    }
}
