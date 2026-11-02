//
//  DepthSelfTest.swift
//  PodWifi
//
//  合成双目对自检：**不用真机、不用真场景**，就能证明"参数 → 视差 → 距离"这条链路是自洽的。
//
//  ## 为什么要它
//  在 0.5.0 里，深度错的时候你无法判断是「算法错」「参数错」还是「标定错」——
//  三者表现都是一句"深度无效"。装到手机上对着墙试，一次只能看到一个结果。
//
//  这里反过来做：**先构造已知答案**。
//    左图 = 确定性伪随机纹理
//    右图 = 左图左移 d 像素（这正是右相机看同一场景的样子：x_R = x_L − d）
//    真值 = d，期望距离 = A / (d640 − C)
//  然后跑真正的 PodDepth（同一个 .mm，同一套参数），看能不能把 d 还原出来。
//
//  三种结果对应三种病因，一目了然：
//    - 合成也测不准      → 算法/参数/端口类型错（和标定无关）
//    - 合成准、实机不准  → 场景问题（弱纹理/过曝）或标定 A,C,tx 不对
//    - 合成准、实机偏大  → 典型"匹配到背景"，收紧 uniqueness / 打开纹理门限
//
//  ## 用 640×360 而不是小图
//  代码里 d640 = halfD × 2 × (640/w)，只有 w=640 时"全分辨率位移 = d640"，
//  对照关系最直接、最不容易在读数时搞错。
//

import Foundation

enum DepthSelfTest {

    struct Row {
        let trueHalfD: Int
        let gotHalfD: Int
        let validRatio: Float
        let d640: Double
        let z: Double
        let zExpect: Double
        var ok: Bool {
            abs(gotHalfD - trueHalfD) <= 1 && validRatio >= 0.45
        }
        var errPct: Double {
            zExpect > 0 ? abs(z - zExpect) / zExpect * 100 : 0
        }
        var text: String {
            String(format: "%@ 真值%2d 实测%2d 有效%.0f%%  Z=%.2fm 期望%.2fm 差%.0f%%",
                   ok ? "✅" : "❌", trueHalfD, gotHalfD, validRatio * 100, z, zExpect, errPct)
        }
    }

    struct Report {
        let rows: [Row]
        let flatRatio: Float        // 纯色平面的有效比例（应接近 0）
        let ms: Double
        let params: DepthParams

        var passed: Int { rows.filter { $0.ok }.count }
        var total: Int { rows.count }
        var allOK: Bool { passed == total && flatRatio < 0.05 }

        var text: String {
            var lines = rows.map { $0.text }
            lines.append(String(format: "%@ 纯色平面有效比例 %.1f%%（应 <5%%，证明唯一性/纹理门限在生效）",
                                flatRatio < 0.05 ? "✅" : "❌", flatRatio * 100))
            lines.append(String(format: "参数：%@   总耗时 %.0f ms", params.summary, ms))
            lines.append(String(format: "%@ %d/%d 通过", allOK ? "全部通过" : "存在问题", passed, total))
            return lines.joined(separator: "\n")
        }
    }

    static let testWidth = 640
    static let testHeight = 360

    /// 跑一遍（同步，约 0.3~0.8 秒，请在后台队列调用）
    static func run(params: DepthParams) -> Report {
        let t0 = Date()
        var rows: [Row] = []

        // 只测当前 maxDisparity 能覆盖的档位。
        // （否则用户把 maxD 调到 16 时，24/32/40 三档必然"失败"——那是量程不够，不是算法错，
        //   会把人误导成"参数坏了"，反而不敢调。）
        var targets = [10, 16, 24, 32, 40].filter { $0 <= params.maxDisparity }
        if targets.isEmpty { targets = [max(4, params.maxDisparity / 2)] }

        for halfD in targets {
            let shift = halfD * 2                    // 全分辨率位移
            let (l, r) = synthPair(shift: shift)
            var got: Int32 = -1
            var ratio: Float = 0
            l.withUnsafeBufferPointer { lp in
                r.withUnsafeBufferPointer { rp in
                    guard let lb = lp.baseAddress, let rb = rp.baseAddress else { return }
                    if let res = PodDepth.computeLeft(lb, right: rb,
                                                      width: Int32(testWidth),
                                                      height: Int32(testHeight),
                                                      maxDisparity: Int32(params.maxDisparity),
                                                      windowRadius: Int32(params.winRadius),
                                                      uniquenessPct: Float(params.uniquenessPct),
                                                      uniquenessMargin: Int32(params.uniquenessMargin),
                                                      lrcTol: Int32(params.lrcTol),
                                                      textureGate: Int32(params.textureGate)) {
                        // 取中间 60% 区域的中位数，避开左右边缘（那里本来就没有匹配）
                        let hw = Int32(res.width), hh = Int32(res.height)
                        got = res.median(inX0: hw / 5, y0: hh / 5, x1: hw * 4 / 5, y1: hh * 4 / 5,
                                         stride: 1)
                        ratio = res.validRatio()
                    }
                }
            }
            let d640 = Double(halfD) * 2.0 * (640.0 / Double(testWidth))
            // 期望值用同一套参数算，这样本自检只衡量 SAD 准确性；
            // calScale 的影响单独在报告末行显示（否则 ToF 校准之后这里会全线"失败"，误导）
            let zExpect = VisionHub.metersFromD640(d640, params: params) ?? 0
            let zGot = VisionHub.metersFromD640(Double(got), params: params) ?? 0
            rows.append(Row(trueHalfD: halfD,
                            gotHalfD: Int(got),
                            validRatio: ratio,
                            d640: d640,
                            z: zGot,
                            zExpect: zExpect))
        }

        // 纯色平面：唯一性判定应该把整幅图判为无效
        let flat = [UInt8](repeating: 128, count: testWidth * testHeight)
        var flatRatio: Float = 0
        flat.withUnsafeBufferPointer { p in
            guard let b = p.baseAddress else { return }
            if let res = PodDepth.computeLeft(b, right: b,
                                              width: Int32(testWidth), height: Int32(testHeight),
                                              maxDisparity: Int32(params.maxDisparity),
                                              windowRadius: Int32(params.winRadius),
                                              uniquenessPct: Float(params.uniquenessPct),
                                              uniquenessMargin: Int32(params.uniquenessMargin),
                                              lrcTol: Int32(params.lrcTol),
                                              textureGate: Int32(params.textureGate)) {
                flatRatio = res.validRatio()
            }
        }

        return Report(rows: rows, flatRatio: flatRatio,
                      ms: Date().timeIntervalSince(t0) * 1000, params: params)
    }

    // MARK: - 合成双目对

    /// 确定性伪随机纹理（同 seed 每次一致，才能比较不同参数的结果）
    /// 右图 = 左图左移 shift 像素：R[x] = L[x + shift]
    private static func synthPair(shift: Int) -> ([UInt8], [UInt8]) {
        let w = testWidth, h = testHeight
        // 先造一张比图宽 shift 的底图，避免移位后右侧没内容
        let wideW = w + shift + 8
        var base = [UInt8](repeating: 0, count: wideW * h)

        var seed: UInt32 = 0x9E3779B9
        func rnd() -> UInt32 {
            seed = seed &* 1664525 &+ 1013904223
            return seed >> 16
        }

        for y in 0..<h {
            for x in 0..<wideW {
                // 噪声 + 低频条纹：既有唯一性（满足唯一性判定），又不是逐像素白噪（更接近真实纹理）
                let noise = Int(rnd() % 120)
                let stripe = Int(60.0 + 55.0 * sin(Double(x) * 0.11 + Double(y) * 0.07))
                let v = max(0, min(255, 70 + noise + stripe / 2))
                base[y * wideW + x] = UInt8(v)
            }
        }

        var l = [UInt8](repeating: 0, count: w * h)
        var r = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                l[y * w + x] = base[y * wideW + x]
                // 右图取同一场景 + shift 处的内容 → 对应视差 = shift
                r[y * w + x] = base[y * wideW + x + shift]
            }
        }
        return (l, r)
    }
}
