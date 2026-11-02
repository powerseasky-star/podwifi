import Foundation

/// 自然语言 → S3 命令帧（逐条对齐安卓 `Nlu.kt`，顺序不能改）
///
/// 设计原则（与安卓一致）：
///  - 指令集固定（开灯/关灯/扬声器/补光/静音/自检/摔倒…），关键词顺序匹配即可，
///    **不经过大模型**：离线可用、延迟低，断网也能用。
///  - 导航/天气/位置/时间 这类才交给大模型或高德处理。
enum PodCommand {

    // MARK: - 设备位掩码（与安卓 S3Protocol.kt 逐位一致）
    static let LED_G: UInt8 = 0x01    // 外接绿灯
    static let LED_R: UInt8 = 0x02    // 外接红灯
    static let SPK_EN: UInt8 = 0x04   // 扬声器使能
    static let VIBE_EN: UInt8 = 0x10  // 震动使能
    static let NEO: UInt8 = 0x20      // 板载 RGB

    /// 一条待下发的命令
    struct Action {
        let type: UInt8        // 0x03 = CMD，0x06 = DEVICE_CTL
        let payload: [UInt8]
        let desc: String       // 中文说明，用于日志与播报
        let isDeviceCtl: Bool

        static func cmd(_ code: UInt8, _ arg: UInt8? = nil, desc: String) -> Action {
            var pl: [UInt8] = [code]
            if let a = arg { pl.append(a) }
            return Action(type: 0x03, payload: pl, desc: desc, isDeviceCtl: false)
        }

        static func deviceCtl(_ mask: UInt8, _ value: UInt8, desc: String) -> Action {
            return Action(type: 0x06, payload: [mask, value], desc: desc, isDeviceCtl: true)
        }
    }

    private static func norm(_ s: String) -> String {
        var t = s
        for ch in [" ", "，", ",", "。", "."] {
            t = t.replacingOccurrences(of: ch, with: "")
        }
        return t
    }

    private static func has(_ t: String, _ keys: [String]) -> Bool {
        for k in keys where t.contains(k) { return true }
        return false
    }

    /// 本地命令匹配。返回 nil 表示"本 App 不处理，交给大模型/高德"。
    static func map(_ text: String) -> Action? {
        let t = norm(text)

        // ---- 顺序敏感：更具体的说法必须排在短词前面 ----
        // 板载 RGB 要先于"开灯/关灯"
        if has(t, ["关灯带", "关彩灯", "关状态灯", "关氛围灯"]) {
            return .deviceCtl(NEO, 0, desc: "关板载RGB")
        }
        if has(t, ["开灯带", "开彩灯", "开状态灯", "开氛围灯"]) {
            return .deviceCtl(NEO, NEO, desc: "开板载RGB")
        }

        // 外接红/绿灯
        if has(t, ["开灯", "亮灯", "开照明", "打开灯"]) {
            return .deviceCtl(LED_G | LED_R, LED_G | LED_R, desc: "开外接灯")
        }
        if has(t, ["关灯", "灭灯", "关闭灯"]) {
            return .deviceCtl(LED_G | LED_R, 0, desc: "关外接灯")
        }

        // 扬声器
        if has(t, ["打开扬声器", "开声音", "开喇叭", "开外放", "打开声音"]) {
            return .deviceCtl(SPK_EN, SPK_EN, desc: "扬声器开")
        }
        if has(t, ["关闭扬声器", "关声音", "关喇叭", "关外放", "关闭声音"]) {
            return .deviceCtl(SPK_EN, 0, desc: "扬声器关")
        }

        // 震动使能
        if has(t, ["关震动", "停止震动", "关闭震动"]) {
            return .deviceCtl(VIBE_EN, 0, desc: "震动关")
        }
        if has(t, ["开震动", "恢复震动", "打开震动"]) {
            return .deviceCtl(VIBE_EN, VIBE_EN, desc: "震动开")
        }

        // IR 补光（固件 CMD=4）
        if has(t, ["开补光", "开红外", "开夜视", "打开补光"]) {
            return .cmd(4, 1, desc: "补光开")
        }
        if has(t, ["关补光", "关红外", "关夜视", "关闭补光"]) {
            return .cmd(4, 0, desc: "补光关")
        }

        // 其它
        if has(t, ["静音", "别出声"]) { return .cmd(1, nil, desc: "静音切换") }
        if has(t, ["自检", "自我检测"]) { return .cmd(3, nil, desc: "自检") }
        if has(t, ["摔倒", "我摔了", "测试摔倒", "模拟摔倒"]) { return .cmd(5, 4, desc: "模拟摔倒") }
        if has(t, ["恢复自动", "自动模式", "恢复默认", "取消接管"]) {
            return .deviceCtl(0, 0, desc: "全部恢复自动")
        }

        // 导航/天气/位置/时间 → 不拦截
        return nil
    }

    /// 是否是"应该交给大模型"的导航/信息类问题
    static func isNavOrInfo(_ text: String) -> Bool {
        let t = norm(text)
        return has(t, ["导航", "怎么走", "去哪", "路线", "带我去", "我要去",
                       "天气", "温度", "下雨", "位置", "我在哪", "几点", "时间"])
    }

    /// 导航指令 action（0x10 帧用，与固件 nav_cmd_dispatch 一致）
    enum NavAction: UInt8 {
        case left = 1
        case right = 2
        case straight = 3
        case arrived = 4
        case offRoute = 5
        case caution = 6
    }
}
