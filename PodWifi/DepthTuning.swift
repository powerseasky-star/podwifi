//
//  DepthTuning.swift
//  PodWifi
//
//  双目 SAD 参数（可在界面里改、可持久化、可用 ToF 真值反推修正）。
//
//  ## 为什么参数要暴露出来
//  SAD 的四个参数没有"普适最优值"，它们是场景的函数：
//     - 走廊/夜间 → 纹理弱 → 需要大窗口 + 宽阈值，否则一片无效
//     - 户外/逆光 → 噪声大 → 需要收紧阈值，否则匹配到背景（系统性偏大）
//     - 远近混合场景 → 视差搜索范围不够会"全图无效"（远处目标挤在同一档）
//  0.5.0 里这些是写死的常量，实测不准只能回来改代码重发版；
//  0.6.0 改成运行期参数：**你在现场按一下按钮，让 ToF 当真值自动给出修正量**。
//
//  ## 单位约定
//    maxDisparity 以**半分辨率**计（SAD 在 320×180 上跑），所以 48 ≈ 640 宽上的 96 像素视差，
//    对应 Z = A/(96−C) ≈ 24.59/79.3 ≈ 0.31m —— 也就是说 0.3m 以内本来就测不到，这是设计如此。
//

import Foundation

struct DepthParams: Codable, Equatable {

    /// 视差搜索上限（半分辨率像素）。46/48/64 三档常用；调大＝能测更近，但慢且更易误匹配
    var maxDisparity: Int = 48
    /// SAD 窗口半径：2=5×5（默认，快）、3=7×7（弱纹理更稳，慢 1.4 倍）
    var winRadius: Int = 2
    /// 唯一性比例阈值：次优代价必须 > 最优 × 这个系数，否则判为歧义
    ///   1.08 = 默认；弱纹理想提高有效比例就降到 1.04（但误匹配变多）
    var uniquenessPct: Double = 1.08
    /// 唯一性绝对裕度（灰度 SAD 代价单位）：防止"最优/次优都接近 0"时系数判定失效
    var uniquenessMargin: Double = 12
    /// 左右一致性容差（半分辨率像素）：1=严格、2=宽松
    var lrcTol: Int = 1
    /// 纹理门限：5×5 窗口内 max−min 灰度差小于它就跳过（0 = 关闭）
    ///   默认 0 关闭：v0.5.0 无条件接受，实测发现夜空/白墙会给出成片假视差时才需要打开
    var textureGate: Int = 0
    /// A 的修正系数（ToF 校准产物）。Z = (A × calScale) / (d640 − C)
    var calScale: Double = 1.0
    /// 时域平滑 α（0.4 ≈ 3 帧收敛；越小越稳但越迟钝）
    var emaAlpha: Double = 0.4

    static let `default` = DepthParams()

    // MARK: - 持久化

    private static let key = "pod.depth.params.v1"

    static func load() -> DepthParams {
        guard let d = UserDefaults.standard.data(forKey: key),
              let p = try? JSONDecoder().decode(DepthParams.self, from: d) else {
            return .default
        }
        return p
    }

    func save() {
        guard let d = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(d, forKey: DepthParams.key)
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: DepthParams.key)
    }

    var summary: String {
        String(format: "maxD%d win%d uniq%.2f/%.0f lrc%d tex%d A×%.3f α%.2f",
               maxDisparity, winRadius * 2 + 1, uniquenessPct, uniquenessMargin,
               lrcTol, textureGate, calScale, emaAlpha)
    }
}

// MARK: - 现场诊断 + 自动建议

/// 一帧深度诊断数据（VisionHub 每帧填，界面与自动调参用）
struct DepthDiag {
    var validRatio: Float = 0
    /// 中心区中位视差（640 宽基准）
    var disparity640: Double = 0
    /// 双目距离（米）
    var stereoM: Double = 0
    /// 当帧 ToF（米），0 = 无
    var tofM: Double = 0
    /// 处理耗时（毫秒）
    var ms: Double = 0
    /// 图像尺寸
    var width: Int = 0
    var height: Int = 0

    var relError: Double {
        guard tofM > 0, stereoM > 0 else { return 0 }
        return abs(stereoM - tofM) / tofM
    }

    var text: String {
        var s = String(format: "有效 %.0f%%  视差 %.1f  双目 %.2f",
                       validRatio * 100, disparity640, stereoM)
        if tofM > 0 {
            s += String(format: "  ToF %.2f  差 %.0f%%", tofM, relError * 100)
        } else {
            s += "  ToF 无"
        }
        s += String(format: "  %.1fms %d×%d", ms, width, height)
        return s
    }
}

/// 自动调参建议：把"现象"翻译成"该动哪个旋钮"
enum DepthAdvisor {

    struct Advice {
        let params: DepthParams
        let reason: String
        let changed: Bool
    }

    /// 根据最近若干帧的统计给出建议参数
    /// - Parameters:
    ///   - cur: 当前参数
    ///   - avgRatio: 有效比例均值（0..1）
    ///   - avgRelErr: 与 ToF 的相对误差均值（0..1，无 ToF 传 0）
    ///   - samples: 参与统计帧数（< 8 帧不给建议，样本太少）
    ///   - tofAvailable: 统计期间是否有 ToF
    static func advise(cur: DepthParams,
                       avgRatio: Double,
                       avgRelErr: Double,
                       samples: Int,
                       tofAvailable: Bool) -> Advice {
        guard samples >= 8 else {
            return Advice(params: cur, reason: "样本不足（\(samples)/8 帧），多对着场景站一会儿", changed: false)
        }

        var p = cur
        var why: [String] = []

        // 1) 几乎没有有效视差 → 先把搜索范围与阈值放宽，再考虑大窗口
        if avgRatio < 0.10 {
            if p.uniquenessPct > 1.045 {
                p.uniquenessPct = 1.045
                why.append("有效比例过低(\(pct(avgRatio)))，唯一性阈值 1.08→1.045")
            }
            if p.textureGate > 0 {
                p.textureGate = 0
                why.append("关闭纹理门限")
            }
            if p.winRadius < 3 {
                p.winRadius = 3
                why.append("SAD 窗口 5×5→7×7（弱纹理更稳，耗时约 +40%）")
            }
            if p.maxDisparity < 64 {
                p.maxDisparity = 64
                why.append("视差上限 48→64（能测到 0.24m 以内）")
            }
        }
        // 2) 有效比例虚高 + 和 ToF 差很多 → 是误匹配，收紧
        else if avgRatio > 0.75, tofAvailable, avgRelErr > 0.20 {
            if p.uniquenessPct < 1.15 {
                p.uniquenessPct = 1.15
                why.append("与 ToF 差 \(pct(avgRelErr))，唯一性阈值收紧到 1.15")
            }
            if p.lrcTol < 2 {
                p.lrcTol = 2
                why.append("左右一致性容差 1→2")
            }
            if p.textureGate < 8 {
                p.textureGate = 8
                why.append("打开纹理门限 8")
            }
        }
        // 3) 有效比例正常但和 ToF 有系统性偏差 → 这是标定/基线问题，SAD 参数救不了
        //    必须用**带符号**的比值去修 A（abs 误差判不出方向，硬猜会越修越偏）。
        //    这里只提示，真正修正走 calibrate(cur:stereoAvg:tofAvg:)。
        else if tofAvailable, avgRelErr > 0.12, avgRatio >= 0.10 {
            why.append(String(format: "与 ToF 有 %.0f%% 系统偏差：SAD 参数已合适，请点「用 ToF 校准」修 A",
                              avgRelErr * 100))
        }

        if why.isEmpty {
            return Advice(params: cur,
                          reason: String(format: "参数合适（有效 %@，误差 %@）", pct(avgRatio), pct(avgRelErr)),
                          changed: false)
        }
        return Advice(params: p, reason: why.joined(separator: "；"), changed: true)
    }

    /// 带符号的精确修正：stereoAvg 与 tofAvg 都是米
    static func calibrate(cur: DepthParams, stereoAvg: Double, tofAvg: Double) -> Advice {
        guard stereoAvg > 0.3, tofAvg > 0.05 else {
            return Advice(params: cur, reason: "标定样本无效（双目 \(stereoAvg) / ToF \(tofAvg)）", changed: false)
        }
        let k = tofAvg / stereoAvg
        guard k.isFinite, k > 0.5, k < 2.0 else {
            return Advice(params: cur, reason: String(format: "比值 %.2f 异常，拒绝修正（可能已误匹配）", k), changed: false)
        }
        var p = cur
        let old = p.calScale
        p.calScale = DepthFusion.clamp(old * k, 0.70, 1.40)
        return Advice(params: p,
                      reason: String(format: "ToF %.2fm / 双目 %.2fm ⇒ A×%.3f → ×%.3f（A=%.3f）",
                                     tofAvg, stereoAvg, old, p.calScale,
                                     VisionHub.calA * p.calScale),
                      changed: abs(p.calScale - old) > 0.005)
    }

    private static func pct(_ v: Double) -> String {
        String(format: "%.0f%%", v * 100)
    }
}
