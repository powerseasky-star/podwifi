//
//  DepthFusion.swift
//  PodWifi
//
//  双目深度 × ToF 融合。
//
//  ## 为什么必须融合（不是"二选一"）
//  两台传感器的失效区间**互补**：
//    - 双目：0.5~3m 最准；<0.4m 视差超出搜索范围（超量程）；>4m 视差只剩 3~4 像素，
//            亚像素误差就能让距离翻倍；纯色/逆光/玻璃面直接无有效视差。
//    - ToF(VL53L7CX)：0.05~4m 单点稳；但**只有一个点**（8x8 区的最近值），
//            窄小目标（电线杆、栏杆）容易漏，强日照 3m 以上噪声大。
//  所以：近处信 ToF、中距离信双目、两者矛盾时**取近值**（安全优先，宁可多报不要漏报）。
//
//  ## 权重从哪来（不是拍的）
//    wToF 随距离单调下降：1m 处 1.00 → 4m 处 0.25
//      依据：ToF 相对误差随距离上升（datasheet 4m 内约 ±5%，但强光下更差），
//            而双目相对误差 ∝ Z²，3m 内反而优于 ToF。
//    wStereo = 有效像素比例 × 距离可信度(0.5~3m 为 1，向两侧衰减到 0.3)
//      依据：validRatio 低 = 弱纹理，此时双目的中位数本身就不可信。
//
//  ## 一致性判定（rel = |Zstereo − Ztof| / Ztof）
//    rel ≤ 15%       → 融合（加权平均），agree = true
//    15% < rel ≤ 40% → 取近者，agree = false，标注差值（多半是 ToF 打到了近处的细杆）
//    rel > 40%       → 信 ToF，agree = false，标注"双目疑似误匹配"
//      依据：>40% 已超出任何一方单次误差的合理范围，属于"匹配到了背景/重复纹理"，
//            这种错误是**系统性偏大**（匹配到远处同类纹理），必须用 ToF 拉回来。
//

import Foundation

enum DepthFusion {

    enum Source: String {
        case stereo = "双目"
        case tof    = "ToF"
        case fused  = "融合"
        // 刻意不叫 none：`Source?` 里的 .none 会和 Optional.none 撞，读代码的人也会误解
        case unknown = "无"
    }

    struct Input {
        /// 双目中心区距离（米），nil = 本轮没算出来
        var stereo: Double?
        /// 双目有效像素比例 0..1
        var stereoRatio: Float = 0
        /// ToF 距离（米），nil = 无新鲜读数
        var tof: Double?
    }

    struct Output {
        let meters: Double
        let source: Source
        /// 两路是否一致（只有两路都有意义时才为 true）
        let agree: Bool
        /// 融合用的权重（调试显示）
        let wStereo: Double
        let wTof: Double
        /// 一行说明（含差值百分比）
        let note: String

        var text: String {
            String(format: "%.2f m（%@）", meters, source.rawValue)
        }
    }

    /// ToF 可用窗口（VL53L7CX：0.05~4.0m；两端都留点余量，贴脸 4cm 以内基本是撞上了）
    static let tofMin = 0.04
    static let tofMax = 4.0
    /// 双目可信窗口
    static let stereoMin = 0.40
    static let stereoMax = 6.0
    /// 有效比例低于这个值，双目中位数就当"仅供参考"
    static let minRatio: Float = 0.06

    // MARK: - 主入口

    static func fuse(_ i: Input) -> Output? {
        let zs = sanitizeStereo(i.stereo, ratio: i.stereoRatio)
        let zt = sanitizeTof(i.tof)

        switch (zs, zt) {
        case (nil, nil):
            return nil

        case let (s?, nil):
            return Output(meters: s, source: .stereo, agree: false,
                          wStereo: 1, wTof: 0,
                          note: String(format: "仅双目（有效 %.0f%%）", i.stereoRatio * 100))

        case let (nil, t?):
            return Output(meters: t, source: .tof, agree: false,
                          wStereo: 0, wTof: 1,
                          note: "仅 ToF（双目无有效视差）")

        case let (s?, t?):
            let rel = abs(s - t) / max(t, 1e-3)
            let ws = stereoWeight(stereo: s, ratio: i.stereoRatio)
            let wt = tofWeight(tof: t)

            if rel <= 0.15 {
                let z = (ws * s + wt * t) / (ws + wt)
                return Output(meters: z, source: .fused, agree: true,
                              wStereo: ws, wTof: wt,
                              note: String(format: "一致(差%.0f%%) 权重 S%.2f/T%.2f", rel * 100, ws, wt))
            }
            if rel <= 0.40 {
                let z = min(s, t)
                return Output(meters: z, source: .fused, agree: false,
                              wStereo: ws, wTof: wt,
                              note: String(format: "偏差%.0f%%，取近值 %.2f/%.2f", rel * 100, s, t))
            }
            return Output(meters: t, source: .tof, agree: false,
                          wStereo: ws, wTof: wt,
                          note: String(format: "双目疑似误匹配(%.2f vs ToF %.2f)，信 ToF", s, t))
        }
    }

    // MARK: - 有效性清洗

    static func sanitizeStereo(_ z: Double?, ratio: Float) -> Double? {
        guard let z = z, z.isFinite, z >= stereoMin, z <= stereoMax else { return nil }
        guard ratio >= minRatio else { return nil }
        return z
    }

    static func sanitizeTof(_ z: Double?) -> Double? {
        guard let z = z, z.isFinite, z >= tofMin, z <= tofMax else { return nil }
        return z
    }

    // MARK: - 权重

    /// ToF 权重：1m 处 1.00，线性降到 4m 处 0.25
    static func tofWeight(tof z: Double) -> Double {
        let t = clamp((z - 1.0) / 3.0, 0, 1)
        return 1.0 - 0.75 * t
    }

    /// 双目权重：有效比例 × 距离可信度
    static func stereoWeight(stereo z: Double, ratio: Float) -> Double {
        let r = clamp(Double(ratio), 0, 1)
        var d = 1.0
        if z < 0.5 { d = 0.35 }                     // 太近：视差超量程边缘
        else if z < 1.0 { d = 0.35 + (z - 0.5) * 1.3 }   // 0.5→0.35, 1.0→1.0
        else if z <= 3.0 { d = 1.0 }
        else if z <= 6.0 { d = max(0.30, 1.0 - (z - 3.0) / 3.0 * 0.7) }
        return max(0.15, r) * d
    }

    // MARK: - 时域平滑

    /// 指数平滑 + 跳变直通。
    ///
    /// 为什么不纯 EMA：导盲最怕"人已经贴上来，播报还停在 3 米"。
    /// 所以新值若**明显更近**（> 0.8m）就立刻采纳，把真实逼近透传出去；
    /// 只有拉远或小抖动才走 EMA（α 默认 0.4，约 3 帧收敛）。
    static func smooth(new: Double, old: Double?, alpha: Double) -> Double {
        guard let o = old else { return new }
        if new < o - 0.8 { return new }
        let a = clamp(alpha, 0.05, 1.0)
        return o + (new - o) * a
    }

    static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        return v < lo ? lo : (v > hi ? hi : v)
    }
}
