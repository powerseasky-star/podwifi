import Foundation
import CoreLocation

/// 语音/导航助手：本地命令优先 → 导航（高德）→ 大模型兜底
///
/// 分层理由（与安卓一致）：固定指令必须**离线秒回**，不能等网络；
/// 只有"导航/位置/闲聊"这类才走网络，且失败要能优雅降级成一句人话。
@MainActor
final class AssistantEngine: ObservableObject {

    @Published var logs: [String] = []
    @Published var busy = false
    @Published var lastReply: String = ""

    private let link = PodLink.shared
    private let st = AppSettings.shared

    func log(_ s: String) {
        let t = String(format: "%@ %@", Self.timeString(), s)
        logs.append(t)
        if logs.count > 300 { logs.removeFirst(logs.count - 300) }
    }

    private static func timeString() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }

    /// 快捷按钮：直接下发固定命令（不经过任何网络）
    func quick(_ desc: String) {
        guard let a = PodCommand.map(desc) else {
            log("未识别快捷命令：\(desc)")
            return
        }
        link.send(a)
        log("→ 下发：\(a.desc)（\(a.type == 0x06 ? "DEVICE_CTL" : "CMD")）")
        Announcer.shared.say(a.desc)
    }

    /// 主入口
    func submit(_ raw: String) async {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        busy = true
        defer { busy = false }

        log("你说：\(text)")

        // 1) 本地固定命令（离线、秒回）
        if let a = PodCommand.map(text) {
            link.send(a)
            log("→ 下发：\(a.desc)")
            Announcer.shared.say(a.desc)
            return
        }

        // 2) 导航/位置/时间类
        if PodCommand.isNavOrInfo(text) {
            await handleNav(text)
            return
        }

        // 3) 大模型兜底
        await askLlm(text)
    }

    // MARK: - 导航

    private func handleNav(_ text: String) async {
        guard st.hasAmap else {
            log("⚠️ 未配置高德 Key，导航跳过")
            Announcer.shared.say("还没设置高德地图的钥匙")
            return
        }

        var place = text
        for p in ["导航去", "带我去", "我要去", "怎么去", "怎么走", "导航到", "去", "导航"] {
            place = place.replacingOccurrences(of: p, with: "")
        }
        place = place.trimmingCharacters(in: .whitespacesAndNewlines)

        // 纯"导航/怎么走"没有目的地 → 交给大模型或提示
        if place.isEmpty {
            Announcer.shared.say("你要去哪里")
            log("未识别目的地")
            return
        }

        do {
            let pois = try await AmapClient.searchPOI(key: st.amapKey, keywords: place)
            guard let poi = pois.first else {
                log("高德没搜到「\(place)」")
                Announcer.shared.say("没找到这个地方")
                return
            }
            log("POI：\(poi.name) \(poi.address) (\(poi.lng),\(poi.lat))")

            let loc = await LocationProvider.shared.current()
            guard let me = loc else {
                Announcer.shared.say("拿到定位再说，找到\(poi.name)")
                log("⚠️ 无定位（检查定位权限）")
                return
            }

            let route = try await AmapClient.walking(key: st.amapKey,
                                                     fromLng: me.coordinate.longitude,
                                                     fromLat: me.coordinate.latitude,
                                                     toLng: poi.lng, toLat: poi.lat)
            let minutes = max(1, route.durationS / 60)
            let first = route.steps.first?.instruction ?? "沿当前方向前进"
            let dm = Double(route.steps.first?.distanceM ?? 0) / 10.0

            let line = String(format: "%@，全程%d米约%d分钟", poi.name, route.distanceM, minutes)
            lastReply = line
            Announcer.shared.say(line)
            log("路线：\(line)；首步：\(first)")

            // 首步下发（固件自己播预录音，转弯提示不能等手机 TTS）
            link.sendNavCmd(action: PodCommand.NavAction.straight.rawValue, distMeters: dm / 10.0)
            log("→ 下发 NAVCMD straight")
        } catch {
            log("导航失败：\(error.localizedDescription)")
            Announcer.shared.say("导航没成功，再说一次")
        }
    }

    // MARK: - 大模型

    private func askLlm(_ text: String) async {
        guard st.hasLlm else {
            log("⚠️ 未配置大模型 Key")
            Announcer.shared.say("还没设置大模型的钥匙")
            return
        }
        do {
            let reply = try await LlmClient.chat(
                base: st.llmBase, key: st.llmKey, model: st.llmModel,
                messages: [LlmClient.systemPrompt(sensor: PodLink.lastSensorText),
                           LlmClient.Message(role: "user", content: text)]
            )
            lastReply = reply
            log("LLM：\(reply)")
            Announcer.shared.say(reply)
        } catch {
            log("LLM 失败：\(error.localizedDescription)")
            Announcer.shared.say("我这边没听懂，再说一遍")
        }
    }
}
