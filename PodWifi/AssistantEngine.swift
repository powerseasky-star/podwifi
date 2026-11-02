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
    @Published var navActive = false
    @Published var navStatus = ""
    /// 连续导航会话（开启后持续播报拐点）
    let nav = NavSession()

    init() {
        // 跨对象直接观察另一个 ObservableObject 的 @Published 不可靠，
        // 所以让 NavSession 主动回推状态，本对象再触发界面刷新。
        nav.onChange = { [weak self] active, status in
            guard let self = self else { return }
            self.navActive = active
            self.navStatus = status
        }
    }

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

            let line = String(format: "%@，全程%d米约%d分钟", poi.name, route.distanceM, minutes)
            lastReply = line
            Announcer.shared.say(line)
            log("路线：\(line)；共 \(route.steps.count) 段")

            // 启动连续导航：到拐点前 25 米自动播报 + 下发马达/预录音
            nav.start(route: route, placeName: poi.name)
            if let first = route.steps.first {
                log("首段：\(first.instruction)")
                PodLink.shared.sendNavCmd(action: PodCommand.NavAction.straight.rawValue,
                                          distMeters: Double(first.distanceM) / 10.0)
            }
        } catch {
            log("导航失败：\(error.localizedDescription)")
            Announcer.shared.say("导航没成功，再说一次")
        }
    }

    /// 停止导航（界面上有按钮，语音"停止导航"也会走到这里）
    func stopNav() {
        nav.stop(reason: "已手动结束")
        log("导航已结束")
        Announcer.shared.say("导航已结束")
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
