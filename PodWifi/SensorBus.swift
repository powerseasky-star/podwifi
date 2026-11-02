//
//  SensorBus.swift
//  PodWifi
//
//  ToF / 超声的统一数据总线。
//
//  🔴 为什么需要它（v0.5.0 之前没有）：
//    ToF 有**两条**到达手机的路径，各自算各自的界面文本，互不知情——
//      ① BLE：BlePodClient 解析 0x07 帧 → BleModel.onSensor → 显示在「蓝牙」页
//      ② Wi-Fi：WifiStereoReceiver.onSensorJson（JSON 里 tof 是**米**）→ 「无线」页
//    深度融合和避障必须看到**同一个最新 ToF**，否则同一秒里两路数据打架，
//    融合结果会在两个值之间来回跳（实机表现就是播报距离抖 ±40%）。
//    所以这里做单一真相源：谁收到谁就写，读的一方只看时间戳最新的那条。
//
//  单位统一：内部一律用**米**。BLE 来的是毫米，在这里就除 1000，绝不留到下游。
//

import Foundation

final class SensorBus {

    static let shared = SensorBus()

    struct Reading {
        let meters: Double
        let at: Date
        let source: String          // "ble" / "wifi"
        var age: TimeInterval { Date().timeIntervalSince(at) }
    }

    /// ToF（VL53L7CX）最近一次有效读数
    private var _tof: Reading?
    /// 超声（A02）最近一次有效读数
    private var _ultra: Reading?

    /// 写发生在主线程（BLE/Wi-Fi 回调），读发生在视觉队列（5fps 融合）→ 必须加锁。
    /// 虽然 arm64 上指针赋值本身是原子的，但靠"碰巧原子"过日子迟早出问题。
    private let lock = NSLock()

    var tof: Reading? {
        lock.lock(); defer { lock.unlock() }; return _tof
    }
    var ultra: Reading? {
        lock.lock(); defer { lock.unlock() }; return _ultra
    }

    /// BLE 0x07 大约 2Hz，Wi-Fi sensor JSON 约 1~2Hz；给 1.5s 宽限，
    /// 太短会让融合频繁掉回"只有双目"，太长会把上一秒的旧值当成现在（危险）。
    static let freshWindow: TimeInterval = 1.5

    private init() {}

    // MARK: - 写入

    /// BLE 侧：毫米
    func updateToF(binaryMm mm: Int, source: String = "ble") {
        guard mm > 0 else { return }
        let r = Reading(meters: Double(mm) / 1000.0, at: Date(), source: source)
        lock.lock(); _tof = r; lock.unlock()
    }

    /// Wi-Fi 侧：已经是米（JSON 里 tof 字段单位为 m，见 WifiStereoReceiver 的 fake pod）
    func updateToF(meters: Double, source: String = "wifi") {
        guard meters > 0, meters.isFinite else { return }
        let r = Reading(meters: meters, at: Date(), source: source)
        lock.lock(); _tof = r; lock.unlock()
    }

    func updateUltra(binaryMm mm: Int, source: String = "ble") {
        guard mm > 0 else { return }
        let r = Reading(meters: Double(mm) / 1000.0, at: Date(), source: source)
        lock.lock(); _ultra = r; lock.unlock()
    }

    func updateUltra(meters: Double, source: String = "wifi") {
        guard meters > 0, meters.isFinite else { return }
        let r = Reading(meters: meters, at: Date(), source: source)
        lock.lock(); _ultra = r; lock.unlock()
    }

    // MARK: - 读取

    func freshToF(maxAge: TimeInterval = SensorBus.freshWindow) -> Reading? {
        guard let r = tof, r.age <= maxAge else { return nil }
        return r
    }

    func freshUltra(maxAge: TimeInterval = SensorBus.freshWindow) -> Reading? {
        guard let r = ultra, r.age <= maxAge else { return nil }
        return r
    }

    /// 给界面用的一行摘要
    var summary: String {
        var p: [String] = []
        if let r = freshToF() {
            p.append(String(format: "ToF %.2fm(%@)", r.meters, r.source))
        } else if let r = tof {
            p.append(String(format: "ToF %.2fm(%@,旧%.0fs)", r.meters, r.source, r.age))
        } else {
            p.append("ToF 无")
        }
        if let u = freshUltra() { p.append(String(format: "超声 %.2fm", u.meters)) }
        return p.joined(separator: "  ")
    }
}
