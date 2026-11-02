//
//  ObstacleAlerter.swift
//  PodWifi
//
//  YOLO 检测 × 深度 → **避障语音播报**（v0.6.0 新增；0.5.0 只显示不播）。
//
//  ## 播报不是"看到什么念什么"
//  导盲场景下播报的带宽极窄：一句话 1.5~2.5 秒，说错一句就把真正危险的那句盖掉了。
//  所以这里的核心不是"识别"，而是**取舍**：
//
//   1) 只播行进走廊内的目标（|方位角| ≤ 25°）。侧后方的东西念出来只会让人停下来回头看。
//      例外：≤1.2m 且高置信的侧方目标也播，因为贴脸的人/车马上会进入走廊。
//   2) 只播**最近的、最危险的一个**。同一帧里 5 个目标也只念 1 个，
//      因为"念 5 个"等于"一个都没听清"。
//   3) 静物不重复。同一类别、距离变化 < 0.35m，6 秒内不再念（走过去要时间）。
//   4) 紧急（<1.0m 在走廊内）**打断**当前播报，且下发 0x10「注意车辆」让 Pod 震动。
//   5) ToF 兜底：ToF 说 0.55m 以内有东西、但视觉没框（细杆/玻璃/逆光）→ 也要播。
//      这是补视觉的盲区，恰恰是导盲最需要的"宁可虚报"。
//
//  ## 高度怎么来（与安卓 fusion_v25.h 同一公式）
//      H = h_norm × 图像高 × Z / fy，fy = A / tx ≈ 472.90（来自标定 npz：A=24.5906, tx=52mm）
//  只为"柱子/障碍/垃圾桶/树"这类**高度有区分意义**的目标附加，
//  行人/车辆的人均身高车高众所周知，念出来是噪音。
//

import Foundation

/// 一个已换算到"方位角 + 距离 + 高度"的视觉目标
struct VisionObstacle {
    let label: Int
    let name: String
    let prob: Float
    /// 方位角：负=左，正=右，单位度
    let azimuthDeg: Double
    /// 距离（米）——已优先用融合距离，无融合则用画面内比例估计
    let meters: Double
    /// 高度（米），0 = 未知/不适用
    let heightM: Double
    /// 是否在行进走廊内（|方位角| ≤ 25°）
    let inPath: Bool

    var azimuthWord: String {
        let a = abs(azimuthDeg)
        if a < 12 { return "正前方" }
        if a < 25 { return azimuthDeg < 0 ? "前方偏左" : "前方偏右" }
        if a < 50 { return azimuthDeg < 0 ? "左前方" : "右前方" }
        return azimuthDeg < 0 ? "左侧" : "右侧"
    }

    var text: String {
        var s = String(format: "%@ %.1f 米 %@", azimuthWord, meters, name)
        if heightM >= 0.2 && heightM <= 2.2 {
            s += String(format: " 高约 %.1f 米", heightM)
        }
        if azimuthDeg.isFinite && abs(azimuthDeg) >= 12 {
            s += String(format: " %d 度", Int(abs(azimuthDeg).rounded()))
        }
        return s
    }
}

/// 避障播报引擎
///
/// ⚠️ 线程约定：**所有调用必须来自主线程**（VisionHub 在 DispatchQueue.main.async 里调）。
/// 刻意不加 `@MainActor`：VisionHub 是普通类、在视觉队列里跑，给它加隔离会在
/// "后台队列调用 → 主队列投递"这条链上引入一堆 Sendable 报错。
/// 用约定代替标注：入口只有 consider()，且只有一个调用方。
final class ObstacleAlerter: ObservableObject {

    static let shared = ObstacleAlerter()

    // MARK: - 对外状态（界面直接绑）

    @Published var enabled: Bool = true
    @Published var line: String = "—"
    @Published var lastSpoken: String = ""
    /// 0=无 1=提示 2=警告 3=紧急（界面用颜色标）
    @Published var level: Int = 0
    @Published var spokenCount: Int = 0

    // MARK: - 阈值（集中在这里，现场可直接讲）

    /// 走廊半宽（度）
    static let corridorDeg: Double = 25
    /// 只关心这么远以内的东西
    static let maxRange: Double = 3.2
    /// 三档距离
    static let urgentM: Double = 1.0
    static let warnM: Double = 2.0
    /// 置信度下限（比 YOLO 阈值 0.20 稍高，避免把误检念出来）
    static let minProb: Float = 0.28

    /// 全局最小间隔（秒）
    private let gapNormal: TimeInterval = 2.2
    private let gapUrgent: TimeInterval = 1.2
    /// 同类别冷却（秒）
    private let cooldownSameLabel: TimeInterval = 6.0
    /// 同类别"距离没怎么变"就不重复念（米）
    private let sameDistEps: Double = 0.35

    // MARK: - 状态

    private var lastAt: Date = .distantPast
    private var lastLabelAt: [String: Date] = [:]
    private var lastLabelDist: [String: Double] = [:]
    private var lastTofAlertAt: Date = .distantPast
    private var lastPodCmdAt: Date = .distantPast

    private init() {}

    // MARK: - 主入口（VisionHub 在后台算完后回主线程调用）

    /// - Parameters:
    ///   - obstacles: 本帧已换算的目标（可为空）
    ///   - tofMeters: 当前 ToF（米），0/nil = 无
    func consider(obstacles: [VisionObstacle], tofMeters: Double?) {
        guard enabled else { return }

        // 1) 粗筛：走廊内 + 够近 + 置信够
        let cand = obstacles.filter { o in
            guard o.prob >= Self.minProb, o.meters > 0.05, o.meters <= Self.maxRange else { return false }
            if o.inPath { return true }
            // 走廊外：只有贴脸才管
            return o.meters <= 1.2 && abs(o.azimuthDeg) <= 50
        }

        // 2) 排序：先按距离分档（近的一定优先），档内再按 类别×置信×方位×距离
        let ranked = cand.sorted { risk($0) > risk($1) }
        let top = ranked.first

        // 3) 界面永远显示最近 3 个（不节流，方便现场核对识别对不对）
        updateLine(ranked: Array(ranked.prefix(3)))

        // 4) ToF 兜底：视觉没看到但 ToF 说很近
        if let t = tofMeters, t > 0.05, t < 0.55 {
            let visualClose = top.map { $0.inPath && $0.meters < 0.85 } ?? false
            if !visualClose, Date().timeIntervalSince(lastTofAlertAt) > 3.0 {
                lastTofAlertAt = Date()
                speak("正前方很近有障碍", urgent: true, dist: t)
                return
            }
        }

        guard let o = top else {
            level = 0
            return
        }
        level = levelFor(o)

        // 5) 节流 + 冷却
        let key = o.name
        let now = Date()
        let urgent = level >= 3
        let gap = urgent ? gapUrgent : gapNormal
        if now.timeIntervalSince(lastAt) < gap { return }
        if let la = lastLabelAt[key], now.timeIntervalSince(la) < cooldownSameLabel {
            // 同类静物没靠近多少 → 不重复
            if let ld = lastLabelDist[key], abs(ld - o.meters) < sameDistEps { return }
        }

        lastAt = now
        lastLabelAt[key] = now
        lastLabelDist[key] = o.meters
        speak(o.text, urgent: urgent, dist: o.meters)
    }

    // MARK: - 播报

    private func speak(_ text: String, urgent: Bool, dist: Double) {
        lastSpoken = text
        spokenCount += 1
        if urgent {
            Announcer.shared.say(text, force: true)      // 打断：近距离必须先说
            sendPodCaution(dist: dist)
        } else {
            // 非紧急：等当前播报说完再讲，避免把导航指令切成两半
            if Announcer.shared.isSpeaking {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                    Announcer.shared.say(text, force: false)
                }
            } else {
                Announcer.shared.say(text, force: false)
            }
        }
    }

    /// 紧急时让 Pod 也动起来（0x10 action=6 注意车辆；固件侧会蜂鸣/震动）
    private func sendPodCaution(dist: Double) {
        let now = Date()
        guard now.timeIntervalSince(lastPodCmdAt) > (level >= 3 ? 1.5 : 3.0) else { return }
        lastPodCmdAt = now
        PodLink.shared.sendNavCmd(action: PodCommand.NavAction.caution.rawValue, distMeters: dist)
    }

    // MARK: - 危险度

    /// 类别权重：越大越"要命"。
    /// 用名字前缀匹配而不是下标，这样将来模型从 10 类扩到 29 类（安卓已是 29 类）时，
    /// 新类别即使不在表里也只是落到默认权重，**不会因为下标错位而把"车辆"当成"门"**。
    private static let classWeight: [(String, Double)] = [
        ("车辆", 1.70), ("汽车", 1.70), ("卡车", 1.75), ("摩托", 1.60),
        ("坑", 1.60), ("台阶", 1.50),
        ("自行车", 1.35), ("电动车", 1.45),
        ("路缘", 1.30), ("柱子", 1.20), ("行人", 1.15), ("障碍", 1.10),
        ("门", 1.00), ("垃圾桶", 0.95), ("树", 0.85), ("坡道", 0.70)
    ]

    private func risk(_ o: VisionObstacle) -> Double {
        // 🔴 距离分档**先于**类别权重（v0.6.0 第一版这里是纯乘积，实测排序反了：
        //    2.0m 的车辆(1.70) 压过了 1.0m 的行人(1.15)，因为 1.70/1.15=1.48 >
        //    距离项的 2.35/1.35=1.74 差得不多，再乘上方位衰减就翻了。
        //    导盲第一条铁律：**近的就是急的**。所以先分档，同档内再比类别/方位。）
        let tier: Double
        if o.meters < Self.urgentM { tier = 3.0 }        // <1.0m
        else if o.meters < Self.warnM { tier = 2.0 }     // <2.0m
        else { tier = 1.0 }                              // <3.2m
        let w = weight(of: o.name)
        // 方位衰减：正前方 1.0，50° 处 0.6
        let az = 1.0 - min(abs(o.azimuthDeg) / 75.0, 0.6)
        let near = 1.0 / (o.meters + 0.35)
        // tier × 10 保证跨档不可逾越；档内由 类别×置信×方位×距离 决定
        return tier * 10.0 + w * Double(o.prob) * az * near
    }

    /// 类别权重：越大越"要命"。
    /// 用名字前缀匹配而不是下标，这样将来模型从 10 类扩到 29 类（安卓已是 29 类）时，
    /// 新类别即使不在表里也只是落到默认权重 1.0，**不会因为下标错位把"车辆"当成"门"**。
    private func weight(of name: String) -> Double {
        for (k, v) in Self.classWeight where name.contains(k) { return v }
        return 1.0
    }

    private func levelFor(_ o: VisionObstacle) -> Int {
        if o.meters < Self.urgentM && o.inPath { return 3 }
        if o.meters < Self.warnM { return 2 }
        return 1
    }

    private func updateLine(ranked: [VisionObstacle]) {
        if ranked.isEmpty {
            line = "走廊内无目标"
            return
        }
        line = ranked.map { $0.text }.joined(separator: " ｜ ")
    }

    // MARK: - 现场开关

    func reset() {
        lastAt = .distantPast
        lastLabelAt.removeAll()
        lastLabelDist.removeAll()
        spokenCount = 0
        level = 0
        line = "—"
        lastSpoken = ""
    }
}
