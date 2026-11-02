//
//  CameraProfile.swift
//  PodWifi
//
//  相机档案 + 自动识别（协议 v3 的 `codec=0x13 CAMINFO`）。
//
//  ## 为什么必须有这一层
//  现在有两个相机版本，**内参差一倍**：
//    AR0144 双目：HFOV 68.1°，fy(640宽) = 472.90 px，有基线 52 mm，能算深度
//    OV5640 单目：HFOV 108°（120° 标称镜头），fy(640宽) = 232.50 px，**无基线、无深度**
//  拿 AR0144 的 fy 去算 OV5640，方位角与高度都会**偏大一倍**——
//  而这两个数正是避障播报要说出口的东西。所以"先认型号，再算数"。
//
//  ## 识别优先级（不可跳级，见协议 v3 §4）
//    ① CAMINFO 声明  → ② 帧头 flags bit0 → ③ 尺寸推断
//  并做**交叉校验**：声明说双目但整帧不是双倍宽 → 判定协议自相矛盾 → **降级成单目**。
//  宁可降级，也不要假装有深度：假装有深度会播错距离，比不播更危险。
//
//  ## 焦距基准约定
//  `fPxAt640` 一律是**单眼宽 = 640 px** 时的等效焦距。
//  实际使用时按眼宽缩放：`fy = fPxAt640 × eyeW / 640`。
//  这样 640×480 与 1280×960 同一支镜头算出来的角度一致（视场角是镜头属性，不是分辨率属性）。
//

import Foundation

enum PodLens: String {
    case stereo = "stereo"
    case mono = "mono"
}

/// 识别来源（界面要显示出来，让人一眼知道是"真认出来了"还是"猜的"）
enum IdentitySource: String {
    case declared = "声明"
    case flagsBit = "协议位"
    case inferred = "推断"
    case fallback = "默认"
}

// MARK: - CAMINFO 帧解析结果

/// `codec=0x13` 的负载。字段全部可选（除 model/lens），缺就用档案兜底。
struct PodCamInfo {
    var model: String?
    var lens: PodLens?
    var frameW: Int?
    var frameH: Int?
    var baselineMm: Double?
    var hfovDeg: Double?
    var vfovDeg: Double?
    var fx: Double?
    var fy: Double?
    var cx: Double?
    var cy: Double?
    var calVer: String?
    var depth: Bool?
    var fps: Int?
    var fw: String?

    /// 手写解析而不用 Codable：现场 JSON 由固件拼，字段缺失/类型不符（int vs double）
    /// 是常态，Codable 遇到就整体抛错——那样一个 `fps:15` 写错就把整条身份信息丢了。
    static func parse(_ json: String) -> PodCamInfo? {
        guard let d = json.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            return nil
        }
        var i = PodCamInfo()
        func num(_ k: String) -> Double? {
            if let v = o[k] as? Double { return v }
            if let v = o[k] as? Int { return Double(v) }
            if let v = o[k] as? NSNumber { return v.doubleValue }
            if let v = o[k] as? String { return Double(v) }
            return nil
        }
        func str(_ k: String) -> String? {
            (o[k] as? String)?.trimmingCharacters(in: .whitespaces)
        }
        i.model = str("model")
        if let l = str("lens") { i.lens = PodLens(rawValue: l.lowercased()) }
        i.frameW = num("w").map { Int($0) }
        i.frameH = num("h").map { Int($0) }
        i.baselineMm = num("baseline_mm")
        i.hfovDeg = num("hfov")
        i.vfovDeg = num("vfov")
        i.fx = num("fx")
        i.fy = num("fy")
        i.cx = num("cx")
        i.cy = num("cy")
        i.calVer = str("cal_ver")
        i.depth = o["depth"] as? Bool
        i.fps = num("fps").map { Int($0) }
        i.fw = str("fw")
        // model 与 lens 至少要有一个，否则认为是垃圾帧
        if i.model == nil && i.lens == nil { return nil }
        return i
    }
}

// MARK: - 相机档案

struct CameraProfile: Equatable {

    let model: String
    let lens: PodLens
    /// 整帧尺寸（并排双目时是 1280×480，不是 640×480）
    let frameW: Int
    let frameH: Int
    /// 双目基线（米）；单目为 0
    let baselineM: Double
    /// 单眼宽 640 时的等效焦距（像素）
    let fPxAt640: Double
    let hfovDeg: Double
    /// 仅双目有效：Z = (A × calScale) / (d640 − C)
    let stereoA: Double
    let stereoC: Double
    let calVer: String
    /// 固件自评能否出深度
    let firmwareSaysDepth: Bool

    // MARK: 派生

    var isStereo: Bool { lens == .stereo }
    /// 单眼宽（切图后）
    var eyeW: Int { isStereo ? frameW / 2 : frameW }
    var eyeH: Int { frameH }
    /// 能不能真的出深度：必须双目 + 有基线 + 固件没说不能
    var depthCapable: Bool { isStereo && baselineM > 0.001 && firmwareSaysDepth }
    /// 单眼宽 640 时的视场角（已由 fPx 保证自洽）
    var vfovAt640: Double { 2 * atan(180.0 / fPxAt640) * 180 / .pi }
    /// 标准视频流下按眼宽缩放后的实际焦距（像素）
    func fy(eyeW actual: Int) -> Double {
        guard actual > 0 else { return fPxAt640 }
        return fPxAt640 * Double(actual) / 640.0
    }

    var summary: String {
        String(format: "%@ %@ %d×%d fy%.0f HFOV%.0f°",
               model, isStereo ? "双目" : "单目", frameW, frameH, fPxAt640, hfovDeg)
    }

    // MARK: 档案库

    /// AR0144 双目（现役）：标定来源 `pair_model_ar0144_v3_20260923_111327.npz`
    /// A=24.5906, C=16.6897, tx=52mm ⇒ fy = A/tx = 472.90（640 宽）
    static let ar0144Stereo = CameraProfile(
        model: "AR0144", lens: .stereo,
        frameW: 1280, frameH: 480,
        baselineM: 0.052,
        fPxAt640: 24.59061297352434 / 0.052,     // 472.896
        hfovDeg: 68.1,
        stereoA: 24.59061297352434,
        stereoC: 16.68971837761396,
        calVer: "20260923",
        firmwareSaysDepth: true)

    /// OV5640 单目（新增，ESP32-S3 DVP 直连）
    /// HFOV ≈ 108°（120° 标称镜头，实测水平）⇒ fy = (640/2)/tan(54°) = 232.50
    /// ⚠️ 出厂对焦 2.3 m：0.5~1.5 m 近处虚焦，**近距离识别反而更差**，靠 ToF 补
    static let ov5640Mono = CameraProfile(
        model: "OV5640", lens: .mono,
        frameW: 640, frameH: 480,
        baselineM: 0,
        fPxAt640: 320.0 / tan(54.0 * Double.pi / 180.0),   // 232.499
        hfovDeg: 108.0,
        stereoA: 0, stereoC: 0,
        calVer: "factory-108",
        firmwareSaysDepth: false)

    /// 未知单目时的保守默认（按 OV5640 内参，因为新硬件就是它）
    static let unknownMono = ov5640Mono

    /// 按型号名找档案
    static func byModel(_ name: String?) -> CameraProfile? {
        guard let n = name?.uppercased() else { return nil }
        if n.contains("AR0144") || n.contains("AR1044") { return .ar0144Stereo }
        if n.contains("OV5640") { return .ov5640Mono }
        return nil
    }
}

// MARK: - 识别结果

struct ResolvedCamera {
    let profile: CameraProfile
    let source: IdentitySource
    /// 一行给界面看
    let note: String
    /// 需要提醒用户的问题（矛盾、降级等）
    let warnings: [String]

    var text: String {
        "\(profile.model) \(profile.isStereo ? "双目" : "单目")（\(source.rawValue)）"
    }
}

// MARK: - 识别器

enum CameraIdentity {

    /// 主入口。`info` 为 nil 表示这一连接内还没收到 CAMINFO。
    ///
    /// - Parameters:
    ///   - info: 最近一次 CAMINFO
    ///   - flags: 视频帧头的 flags（bit0=1 并排双目）
    ///   - frameW/frameH: 实际到达的**整帧**尺寸
    static func resolve(info: PodCamInfo?,
                        flags: UInt8?,
                        frameW: Int,
                        frameH: Int) -> ResolvedCamera {
        var warns: [String] = []

        // ---------- ① 声明优先 ----------
        if let i = info, let lens = i.lens {
            var p = CameraProfile.byModel(i.model) ?? CameraProfile.unknownMono
            // 用 CAMINFO 的实测字段覆盖档案（固件报的比档案新）
            let fw = i.frameW ?? frameW
            let fh = i.frameH ?? frameH
            let hfov = i.hfovDeg ?? p.hfovDeg
            let baseline = (i.baselineMm ?? (p.baselineM * 1000)) / 1000.0
            // 焦距：fx/fy 优先，其次 hfov，最后档案
            var f = p.fPxAt640
            if let fy = i.fy, fy > 20, fw > 0 {
                // 固件报的 fy 是相对它自己的帧宽；换算到"单眼宽 640"基准
                let eyeW = (lens == .stereo) ? fw / 2 : fw
                f = fy * 640.0 / Double(max(eyeW, 1))
            } else if i.hfovDeg != nil {
                let eyeW = (lens == .stereo) ? Double(fw) / 2.0 : Double(fw)
                f = (eyeW / 2.0) / tan(hfov * Double.pi / 360.0) * 640.0 / eyeW
            }

            p = CameraProfile(
                model: i.model ?? p.model,
                lens: lens,
                frameW: fw, frameH: fh,
                baselineM: (lens == .stereo) ? baseline : 0,
                fPxAt640: f,
                hfovDeg: hfov,
                // A/C 只在双目有意义；CAMINFO 目前不报 A/C（那是标定产物，不在帧里）
                stereoA: (lens == .stereo) ? p.stereoA : 0,
                stereoC: (lens == .stereo) ? p.stereoC : 0,
                calVer: i.calVer ?? p.calVer,
                firmwareSaysDepth: i.depth ?? (lens == .stereo))

            // 交叉校验：声明双目但整帧不是双倍宽
            if lens == .stereo, fh > 0, Double(fw) / Double(fh) < 2.0 {
                warns.append(String(format: "声明双目但整帧 %d×%d 不是双倍宽 → 按单目处理", fw, fh))
                let mono = CameraProfile.ov5640Mono
                let fixed = CameraProfile(
                    model: (i.model ?? mono.model) + "(降级)", lens: .mono,
                    frameW: fw, frameH: fh, baselineM: 0,
                    fPxAt640: f, hfovDeg: hfov,
                    stereoA: 0, stereoC: 0,
                    calVer: i.calVer ?? mono.calVer,
                    firmwareSaysDepth: false)
                return ResolvedCamera(profile: fixed,
                                      source: .declared,
                                      note: "\(fixed.model) 单目（声明矛盾已降级）",
                                      warnings: warns)
            }
            // 声明单目却给了基线
            if lens == .mono, baseline > 0.001 {
                warns.append("声明单目但给了基线，已忽略基线")
            }
            return ResolvedCamera(profile: p, source: .declared,
                                  note: "\(p.model) \(p.isStereo ? "双目" : "单目")（声明）",
                                  warnings: warns)
        }

        // ---------- ② 协议位 ----------
        let stereoByFlags = (flags ?? 0) & 0x01 != 0
        if let f = flags, frameW > 0, frameH > 0 {
            if stereoByFlags, Double(frameW) / Double(frameH) < 2.0 {
                warns.append(String(format: "flags 说并排双目，但整帧 %d×%d 不是双倍宽 → 按单目处理", frameW, frameH))
                return ResolvedCamera(profile: branded(.ov5640Mono, frameW: frameW, frameH: frameH),
                                      source: .flagsBit,
                                      note: "单目（协议位矛盾已降级）",
                                      warnings: warns)
            }
            let base = stereoByFlags ? CameraProfile.ar0144Stereo : CameraProfile.ov5640Mono
            let p = branded(base, frameW: frameW, frameH: frameH)
            warns.append("固件未上报 CAMINFO，按协议位识别（建议升级固件以支持型号自动识别）")
            return ResolvedCamera(profile: p, source: .flagsBit,
                                  note: "\(p.model) \(p.isStereo ? "双目" : "单目")（协议位）",
                                  warnings: warns)
        }

        // ---------- ③ 尺寸推断 ----------
        // 并排双目整帧宽高比约 8:3=2.67；单目 4:3=1.33 / 16:9=1.78
        let ratio = frameH > 0 ? Double(frameW) / Double(frameH) : 0
        let guessStereo = ratio >= 2.2
        let base = guessStereo ? CameraProfile.ar0144Stereo : CameraProfile.ov5640Mono
        let p = branded(base, frameW: frameW, frameH: frameH)
        warns.append(String(format: "无 CAMINFO 也无 flags，按宽高比 %.2f 推断", ratio))
        return ResolvedCamera(profile: p, source: .inferred,
                              note: "\(p.model) \(p.isStereo ? "双目" : "单目")（推断）",
                              warnings: warns)
    }

    /// 把档案的帧尺寸替换成实测尺寸（内参按眼宽等比缩放，角度不变）
    private static func branded(_ base: CameraProfile, frameW: Int, frameH: Int) -> CameraProfile {
        guard frameW > 0, frameH > 0 else { return base }
        return CameraProfile(model: base.model, lens: base.lens,
                             frameW: frameW, frameH: frameH,
                             baselineM: base.baselineM,
                             fPxAt640: base.fPxAt640,
                             hfovDeg: base.hfovDeg,
                             stereoA: base.stereoA, stereoC: base.stereoC,
                             calVer: base.calVer,
                             firmwareSaysDepth: base.firmwareSaysDepth)
    }
}

// MARK: - 单目兜底测距

/// 单目没有视差，ToF 失效时只能用「框高 × 类别标称高度」反推。
///
/// ⚠️ 精度 ±40%，所以：
///   1. 只有**高度稳定**的类别才允许反推（台阶/坑/路缘/树 反推必然错，直接不给）
///   2. 播报必须带「约」字，分级阈值放宽
///   3. 结果必须标记来源，UI 上可与 ToF 区分
enum MonoRange {

    /// 类别标称高度（米）。键用名字子串匹配，与 ObstacleAlerter 同一套习惯，
    /// 这样将来模型扩到 29 类也不会因为下标错位把"车辆"当成"门"。
    static let nominalHeight: [(String, Double)] = [
        ("行人", 1.70), ("车辆", 1.50), ("汽车", 1.50), ("卡车", 1.60),
        ("电动车", 1.10), ("摩托", 1.10), ("自行车", 1.00),
        ("门", 2.00), ("垃圾桶", 0.90), ("柱子", 3.00), ("障碍", 1.00)
    ]

    /// 这些类别高度太小或太不确定，**不允许**用框高反推距离
    static let denied: [String] = ["台阶", "坑", "路缘", "坡道", "树"]

    static func height(of name: String) -> Double? {
        for d in denied where name.contains(d) { return nil }
        for (k, v) in nominalHeight where name.contains(k) { return v }
        return nil
    }

    /// `Z = H_real × fy / (h_norm × frameH)`
    /// - Parameters:
    ///   - hNorm: 检测框归一化高度（0..1）
    ///   - fy: 当前帧的等效焦距（像素）
    ///   - frameH: 帧高（像素）
    static func meters(name: String, hNorm: Float, fy: Double, frameH: Int) -> Double? {
        guard let hReal = height(of: name) else { return nil }
        let hPx = Double(hNorm) * Double(frameH)
        guard hPx > 4, fy > 20 else { return nil }
        let z = hReal * fy / hPx
        // 单目反推的合理区间：太近说明框异常大，太远误差已不可用
        guard z.isFinite, z > 0.25, z < 8.0 else { return nil }
        return z
    }
}
