import CoreLocation
import Foundation

/// 连续语音导航会话：滚动判定"离下一拐点还有多远"，到点提前播报并下发马达指令。
///
/// 与安卓 NavFlowController 的思路一致，但**刻意做小**：
///  - 只做步行；不做车道级
///  - 拐点判定用"距该段折线终点 < 25m"，偏航判定用"离当前段折线 > 45m"
///  - 偏航不自动重算（重算要再打一次高德、多一次等待），先播报让用户停下
@MainActor
final class NavSession: ObservableObject {

    @Published var active = false
    @Published var status = ""

    /// 状态变化回调（AssistantEngine 用它把状态转发给界面，跨对象观察 @Published 不可靠）
    var onChange: ((Bool, String) -> Void)?

    private var steps: [AmapClient.RouteStep] = []
    private var dest: (lng: Double, lat: Double)?
    private var idx = 0
    private var lastAnnounceAt: Date = .distantPast
    private let announceGap: TimeInterval = 6      // 同一句至少隔 6 秒，避免绕圈刷屏

    private var announcedTurn = Set<Int>()

    func start(route: AmapClient.Route, placeName: String) {
        steps = route.steps
        dest = route.destination
        idx = 0
        announcedTurn.removeAll()
        active = true
        status = "导航中：\(placeName)"
        onChange?(true, status)

        LocationProvider.shared.startUpdates { [weak self] loc in
            Task { @MainActor in self?.onLocation(loc) }
        }
    }

    func stop(reason: String = "已结束") {
        guard active else { return }
        active = false
        status = reason
        LocationProvider.shared.stopUpdates()
        onChange?(false, status)
    }

    // MARK: - 核心判定

    private func onLocation(_ loc: CLLocation) {
        guard active else { return }
        let me = (loc.coordinate.longitude, loc.coordinate.latitude)

        // 1) 到终点？
        if let d = dest {
            let toDest = Self.meters(me, (d.lng, d.lat))
            if toDest < 20 {
                Announcer.shared.say("已到达目的地附近")
                PodLink.shared.sendNavCmd(action: PodCommand.NavAction.arrived.rawValue,
                                          distMeters: nil)
                stop(reason: "已到达")
                return
            }
        }

        guard idx < steps.count else {
            stop(reason: "路线走完")
            return
        }
        let step = steps[idx]

        // 2) 偏航？离当前段折线太远
        if !step.points.isEmpty {
            let minD = step.points.map { Self.meters(me, ($0.lng, $0.lat)) }.min() ?? 0
            if minD > 45 {
                say("已偏离路线，请停下重新导航", force: true)
                stop(reason: "偏航")
                return
            }
        }

        // 3) 离本段终点还有多远
        let target = step.points.last.map { ($0.lng, $0.lat) }
            ?? (dest ?? me)
        let toTurn = Self.meters(me, target)

        if toTurn < 25 && !announcedTurn.contains(idx) {
            announcedTurn.insert(idx)
            // 该段走完 → 播下一段的指令（当前段指令是"走这条路"，下一段才是拐点）
            let nextIns = (idx + 1 < steps.count) ? steps[idx + 1].instruction : "到达目的地"
            say(nextIns, force: true)
            let action = Self.actionFor(nextIns)
            PodLink.shared.sendNavCmd(action: action.rawValue, distMeters: max(0, toTurn))
            idx += 1
            return
        }

        // 4) 长距离段的提前提示（每 60 米最多一次）
        if toTurn < 60 && toTurn > 25 {
            say(String(format: "前方 %.0f 米，%@", toTurn, Self.shortHint(step.instruction)))
        }
    }

    private func say(_ text: String, force: Bool = false) {
        let now = Date()
        if !force && now.timeIntervalSince(lastAnnounceAt) < announceGap { return }
        lastAnnounceAt = now
        status = text
        onChange?(active, text)
        Announcer.shared.say(text)
    }

    // MARK: - 工具

    /// 球面距离（米）
    static func meters(_ a: (lng: Double, lat: Double),
                       _ b: (lng: Double, lat: Double)) -> Double {
        let R = 6371000.0
        let dLat = (b.lat - a.lat) * .pi / 180
        let dLng = (b.lng - a.lng) * .pi / 180
        let la1 = a.lat * .pi / 180
        let la2 = b.lat * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(la1) * cos(la2) * sin(dLng / 2) * sin(dLng / 2)
        return 2 * R * asin(min(1, sqrt(h)))
    }

    /// 从高德指令文本推断方向（高德中文指令里一定带"左/右"）
    static func actionFor(_ ins: String) -> PodCommand.NavAction {
        if ins.contains("左") { return .left }
        if ins.contains("右") { return .right }
        if ins.contains("到达") { return .arrived }
        return .straight
    }

    /// 播报用的短提示：去掉高德冗长的路口描述
    static func shortHint(_ ins: String) -> String {
        var t = ins
        for junk in ["沿", "步行", "米后", "后"] {
            t = t.replacingOccurrences(of: junk, with: "")
        }
        if t.count > 18 { t = String(t.prefix(18)) }
        return t
    }
}
