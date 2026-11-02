//
//  DepthTuningView.swift
//  PodWifi
//
//  深度调参页（v0.6.0 新增）。
//
//  设计目标：**不用回来找我改代码发版**，你在现场就能
//    ① 看实时诊断（有效比例/视差/双目距离/ToF/误差/耗时）
//    ② 拖滑块改 SAD 参数，立刻生效
//    ③ 点「合成自检」先排除算法问题
//    ④ 点「用 ToF 校准」让真值去修标定系数 A
//    ⑤ 点「重新建议」让它按当前读数给出该动哪个旋钮
//

import SwiftUI

struct DepthTuningView: View {
    @ObservedObject private var vision = VisionHub.shared
    @Environment(\.presentationMode) var presentation

    @State private var p = VisionHub.shared.params
    @State private var advice = ""
    @State private var selfTest = ""
    @State private var testing = false
    @State private var timer: Timer?

    var body: some View {
        Form {
                // MARK: 实时诊断
                Section(header: Text("实时诊断（对着目标站着看这几行）"),
                        footer: Text("「有效」低于 10% 说明这个场景纹理不足或参数太严；「差」是与 ToF 的相对误差。")) {
                    LabeledRow(k: "识别", v: vision.ready ? vision.detsText : "模型未加载")
                    LabeledRow(k: "融合", v: vision.depthText)
                    LabeledRow(k: "一致性", v: vision.fuseText)
                    LabeledRow(k: "诊断", v: vision.diagText)
                    LabeledRow(k: "传感器", v: vision.tofText)
                    LabeledRow(k: "避障", v: vision.obsText)
                }

                // MARK: 一键动作
                Section(header: Text("一键动作")) {
                    Button {
                        runSelfTest()
                    } label: {
                        HStack {
                            Text(testing ? "自检运行中…" : "跑合成自检（不用真机）")
                            Spacer()
                            if testing { ProgressView() }
                        }
                    }
                    .disabled(testing)

                    Button("用 ToF 校准 A（需 ToF 有数）") { calibrate() }
                    Button("按当前读数重新建议参数") { advise() }
                    Button("恢复默认参数") {
                        DepthParams.reset()
                        p = .default
                        vision.params = .default
                        advice = "已恢复默认（maxD48 / 5×5 / 1.08 / lrc1 / 纹理门限关 / A×1.000）"
                    }
                }

                if !selfTest.isEmpty {
                    Section(header: Text("自检结果")) {
                        Text(selfTest).font(.system(size: 11, design: .monospaced))
                    }
                }
                if !advice.isEmpty {
                    Section(header: Text("建议")) {
                        Text(advice).font(.footnote)
                    }
                }

                // MARK: 参数
                Section(header: Text("SAD 参数（改了立刻生效）"),
                        footer: Text("现在：\(p.summary)")) {
                    Stepper("视差上限 maxD = \(p.maxDisparity)（半分辨率）",
                            value: $p.maxDisparity, in: 16...96, step: 4)
                    Stepper("SAD 窗口 = \(p.winRadius * 2 + 1)×\(p.winRadius * 2 + 1)",
                            value: $p.winRadius, in: 1...4)

                    VStack(alignment: .leading) {
                        Text(String(format: "唯一性阈值 %.3f（越大越严，有效像素越少）", p.uniquenessPct))
                            .font(.footnote)
                        Slider(value: $p.uniquenessPct, in: 1.00...1.30, step: 0.005)
                    }
                    VStack(alignment: .leading) {
                        Text(String(format: "唯一性裕度 %.0f（防止两边代价都接近 0 时误判）", p.uniquenessMargin))
                            .font(.footnote)
                        Slider(value: $p.uniquenessMargin, in: 0...40, step: 1)
                    }
                    Stepper("左右一致性容差 lrc = \(p.lrcTol) 像素",
                            value: $p.lrcTol, in: 1...3)
                    VStack(alignment: .leading) {
                        Text("纹理门限 \(p.textureGate)（0=关；纯色/夜空设 8~16 可大幅减少假视差）")
                            .font(.footnote)
                        Slider(value: Binding(
                            get: { Double(p.textureGate) },
                            set: { p.textureGate = Int($0) }
                        ), in: 0...40, step: 1)
                    }
                }

                Section(header: Text("标定与平滑"),
                        footer: Text(String(format: "当前等效 A = %.3f（标定值 %.3f × %.3f），基线 tx = 52 mm。",
                                            VisionHub.calA * p.calScale, VisionHub.calA, p.calScale))) {
                    VStack(alignment: .leading) {
                        Text(String(format: "A 修正系数 %.3f", p.calScale)).font(.footnote)
                        Slider(value: $p.calScale, in: 0.70...1.40, step: 0.005)
                    }
                    VStack(alignment: .leading) {
                        Text(String(format: "时域平滑 α %.2f（越小越稳、越迟钝）", p.emaAlpha)).font(.footnote)
                        Slider(value: $p.emaAlpha, in: 0.10...0.90, step: 0.02)
                    }
                }

                Section {
                    Button("完成") { presentation.wrappedValue.dismiss() }
                }
            }
            .navigationTitle("深度调参")
            .onAppear {
                p = VisionHub.shared.params
                // 诊断数据是收流时刷新的；这里每秒催一次重绘，让读数在页面上是活的
                timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                    VisionHub.shared.objectWillChange.send()
                }
            }
            .onDisappear { timer?.invalidate(); timer = nil }
            .onChange(of: p) { newValue in
                // 任一参数变化 → 立刻写回 VisionHub（会清 EMA，避免新旧参数混合出怪值）
                vision.params = newValue
            }
    }

    // MARK: - 动作

    private func runSelfTest() {
        testing = true
        selfTest = ""
        let cur = p
        DispatchQueue.global(qos: .userInitiated).async {
            let r = DepthSelfTest.run(params: cur)
            DispatchQueue.main.async {
                self.selfTest = r.text
                self.testing = false
            }
        }
    }

    private func calibrate() {
        let s = VisionHub.shared.stats()
        guard s.tofAvailable else {
            advice = "ToF 数据不足（需要至少 3 帧同时有双目距离和 ToF）。先接上蓝牙/Wi-Fi 收流，正对墙面站 5 秒。"
            return
        }
        let a = DepthAdvisor.calibrate(cur: p, stereoAvg: s.stereoAvg, tofAvg: s.tofAvg)
        advice = a.reason + (a.changed ? "\n（已应用，可随时点「恢复默认」撤销）" : "")
        if a.changed {
            p = a.params
            vision.params = a.params
        }
    }

    private func advise() {
        let s = VisionHub.shared.stats()
        let a = DepthAdvisor.advise(cur: p,
                                    avgRatio: s.ratio,
                                    avgRelErr: s.relErr,
                                    samples: s.samples,
                                    tofAvailable: s.tofAvailable)
        advice = a.reason
        if a.changed {
            p = a.params
            vision.params = a.params
            advice += "\n（已应用）"
        }
    }
}

private struct LabeledRow: View {
    let k: String
    let v: String
    var body: some View {
        HStack(alignment: .top) {
            Text(k).font(.caption).foregroundColor(.secondary).frame(width: 56, alignment: .leading)
            Text(v).font(.system(size: 11, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
