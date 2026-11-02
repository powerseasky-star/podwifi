//
//  BlePodClient.swift
//  PodWifi — 蓝牙（BLE NUS）客户端
//
//  为什么要它：iPhone 不能插 UVC 相机，但**蓝牙是通的**。S3 那边 Ble NUS 把手机发来的
//  字节直接喂 comms_parse_byte（与串口同一套状态机），所以手机只要按 0xAA 帧协议收发，
//  就能在不接相机、不插 USB 的情况下把「传感器上报 / 姿态 / 命令下发」全部测通。
//
//  🔴 三条从固件源码抄来的硬约束（改代码前先看这里）：
//   1) 服务 = Nordic UART Service
//        Service 6E400001-B5A3-F393-E0A9-E50E24DCCA9E
//        RX（手机→Pod，Write）       6E400002-...
//        TX（Pod→手机，Notify）      6E400003-...
//   2) 帧格式 [0xAA][TYPE][LEN][PL...][XOR]，XOR = TYPE ^ LEN ^ 所有 PL（**不含 0xAA**）
//   3) 0x07 SENSOR 的 payload **必须 11 字节 / 整帧 15 字节**：BLE MTU 23 时 ATT Notify
//      单包上限 20 字节，超长会被 NimBLE 静默丢弃（历史故障：控制能用但数据收不到）。
//
//  接收缓冲一律用 [UInt8] 而不是 Data —— Data 是切片语义，removeFirst 后 startIndex 会偏移，
//  再用绝对下标就崩（2026-11-02 iOS v0.1.0 实机崩溃的根因）。
//

import Foundation
import CoreBluetooth

/// 0x07 SENSOR 帧解析结果（payload 11 字节，大端）
struct PodSensor {
    var seq: UInt8 = 0
    var tofMm: Int = -1          // -1 = 无效（0xFFFF）
    var ultraMm: Int = -1
    var lux: Int = -1
    var tiltDeg: Int = -1
    var battPct: Int = -1        // -1 = 无效（0xFF）
    var level: Int = 0
    var flags: UInt8 = 0

    var fall: Bool { flags & 0x01 != 0 }
    var stationary: Bool { flags & 0x02 != 0 }
    var irOn: Bool { flags & 0x04 != 0 }
    var muted: Bool { flags & 0x08 != 0 }
    var tofOk: Bool { flags & 0x10 != 0 }
    var ultraOk: Bool { flags & 0x20 != 0 }
    var battOk: Bool { flags & 0x40 != 0 }
    var poseOk: Bool { flags & 0x80 != 0 }
}

/// 0x11 SENSOR_EXT 姿态帧（payload 6 字节，yaw/mag 为**小端** u16 ×10）
struct PodPose {
    var seq: UInt8 = 0
    var yawDeg: Double = -1
    var flags: UInt8 = 0
    var mag: Double = -1

    var yawValid: Bool { flags & 0x01 != 0 }
    var magDisturbed: Bool { flags & 0x02 != 0 }
}

final class BlePodClient: NSObject {

    // MARK: - NUS UUID

    static let serviceUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    static let rxUUID      = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
    static let txUUID      = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")

    // MARK: - 回调（全部在主线程投递）

    var onState: ((String) -> Void)?                       // 蓝牙状态文本
    var onDiscover: ((String, UUID, Int, Bool) -> Void)?   // name, id, rssi, 是否已连
    var onConnected: ((String) -> Void)?
    var onDisconnected: (() -> Void)?
    var onSensor: ((PodSensor) -> Void)?
    var onPose: ((PodPose) -> Void)?
    var onFrameLog: ((String) -> Void)?                    // 每帧摘要（调试用）
    var onPodRequest: ((String, String) -> Void)?          // kind, text（Pod 请求类帧）

    // MARK: - 内部状态

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var rxChar: CBCharacteristic?
    private var txChar: CBCharacteristic?
    private var buf: [UInt8] = []
    private var frameCount = 0
    private var badChecksum = 0

    private(set) var connectedName: String = ""
    private(set) var isConnected: Bool = false
    private(set) var bluetoothState: String = "未初始化"

    override init() {
        super.init()
        // 队列固定 main：回调与 UI 状态同线程，省掉一堆 hop 与数据竞争
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: - 对外操作

    func startScan() {
        guard central.state == .poweredOn else {
            onState?("蓝牙不可用：\(bluetoothState)")
            return
        }
        buf.removeAll()
        // 不按服务过滤：有些固件广播包里不带 128 位 UUID，过滤会直接扫不到
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        onState?("扫描中…")
    }

    func stopScan() {
        central.stopScan()
    }

    func connect(_ id: UUID) {
        guard let p = central.retrievePeripherals(withIdentifiers: [id]).first else {
            onState?("找不到该设备（可能已离开范围）")
            return
        }
        central.stopScan()
        peripheral = p
        p.delegate = self
        central.connect(p, options: nil)
        onState?("连接中：\(p.name ?? "未命名")")
    }

    func disconnect() {
        if let p = peripheral {
            central.cancelPeripheralConnection(p)
        }
    }

    /// 0x0E 校时：pl = [0x01, h, m, s]
    func sendTimeSync() {
        let c = Calendar.current.dateComponents([.hour, .minute, .second], from: Date())
        let pl: [UInt8] = [0x01,
                           UInt8(c.hour ?? 0), UInt8(c.minute ?? 0), UInt8(c.second ?? 0)]
        write(type: 0x0E, pl: pl)
    }

    /// 0x10 导航指令：pl = [action, dist_dm]
    /// action 1=左转 2=右转 3=直行 4=到达 5=偏航 6=注意车辆；dist_dm 0xFF = 距离未知
    func sendNavCmd(action: UInt8, distMeters: Double?) {
        let dm: UInt8
        if let d = distMeters, d > 0, d < 25.4 {
            dm = UInt8((d * 10).rounded())
        } else {
            dm = 0xFF
        }
        write(type: 0x10, pl: [action, dm])
    }

    // MARK: - 发送 / 组帧

    private func write(type: UInt8, pl: [UInt8]) {
        guard let ch = rxChar, let p = peripheral, p.state == .connected else {
            onState?("未连接，命令未发送")
            return
        }
        var f: [UInt8] = [0xAA, type, UInt8(pl.count)]
        f.append(contentsOf: pl)
        var x: UInt8 = type ^ UInt8(pl.count)
        for b in pl { x ^= b }
        f.append(x)
        let data = Data(f)
        // 带响应更可靠：命令类帧很短，不怕慢
        p.writeValue(data, for: ch, type: .withResponse)
        onFrameLog?(String(format: "TX type=0x%02X len=%d %@", type, pl.count,
                           f.map { String(format: "%02X", $0) }.joined(separator: " ")))
    }

    // MARK: - 收帧（[UInt8] 缓冲，0xAA 重同步）

    private func feed(_ data: Data) {
        buf.append(contentsOf: data)
        while true {
            // 找帧头；找不到就丢掉整段垃圾
            guard let startIdx = buf.firstIndex(of: 0xAA) else {
                if !buf.isEmpty {
                    onFrameLog?("丢弃 \(buf.count) 字节（无 0xAA 帧头）")
                    buf.removeAll()
                }
                return
            }
            if startIdx > 0 {
                onFrameLog?("丢弃 \(startIdx) 字节前缀（重同步）")
                buf.removeFirst(startIdx)
            }
            guard buf.count >= 3 else { return }
            let type = buf[1]
            let len = Int(buf[2])
            let total = 3 + len + 1
            guard buf.count >= total else { return }   // 半包：等下一包

            var x: UInt8 = type ^ UInt8(truncatingIfNeeded: len)
            for k in 0..<len { x ^= buf[3 + k] }
            let sum = buf[3 + len]
            let pl = Array(buf[3..<(3 + len)])
            buf.removeFirst(total)

            if x != sum {
                badChecksum += 1
                onFrameLog?(String(format: "校验失败 type=0x%02X len=%d 期望%02X 收到%02X（累计错 %d）",
                                   type, len, x, sum, badChecksum))
                continue
            }
            frameCount += 1
            handle(type: type, pl: pl)
        }
    }

    private func handle(type: UInt8, pl: [UInt8]) {
        switch type {
        case 0x07:   // SENSOR（payload 必须 11 字节，大端）
            guard pl.count == 11 else {
                onFrameLog?("0x07 长度异常 \(pl.count)（应为 11）")
                return
            }
            var s = PodSensor()
            s.seq = pl[0]
            s.tofMm   = u16be(pl, 1)
            s.ultraMm = u16be(pl, 3)
            s.lux     = u16be(pl, 5)
            s.tiltDeg = Int(pl[7])
            s.battPct = pl[8] == 0xFF ? -1 : Int(pl[8])
            s.level   = Int(pl[9])
            s.flags   = pl[10]
            if s.tofMm == 0xFFFF { s.tofMm = -1 }
            if s.ultraMm == 0xFFFF { s.ultraMm = -1 }
            if s.lux == 0xFFFF { s.lux = -1 }
            onSensor?(s)
            onFrameLog?(String(format: "RX SENSOR seq=%d tof=%dmm ultra=%dmm lux=%d tilt=%d° batt=%d%% flags=0x%02X",
                               s.seq, s.tofMm, s.ultraMm, s.lux, s.tiltDeg, s.battPct, s.flags))

        case 0x11:   // SENSOR_EXT 姿态（payload 6 字节，yaw/mag 小端 ×10）
            guard pl.count == 6 else {
                onFrameLog?("0x11 长度异常 \(pl.count)（应为 6）")
                return
            }
            var p = PodPose()
            p.seq = pl[0]
            p.yawDeg = Double(u16le(pl, 1)) / 10.0
            p.flags = pl[3]
            p.mag = Double(u16le(pl, 4)) / 10.0
            onPose?(p)
            onFrameLog?(String(format: "RX POSE seq=%d yaw=%.1f° mag=%.1f flags=0x%02X",
                               p.seq, p.yawDeg, p.mag, p.flags))

        case 0x0C:   // REQUEST_SPEAK：Pod 请求手机朗读
            let t = String(bytes: pl, encoding: .utf8) ?? ""
            onPodRequest?("朗读请求", t)
        case 0x0D:   // ASK_ENV：pl[0] 1=天气 2=位置
            let what = pl.first == 2 ? "位置" : "天气"
            onPodRequest?("环境查询", "Pod 请求查询\(what)")
        case 0x0F:   // ASK_NAV：pl[0] 1问路 2预设 3取消 4重听
            let sub = pl.first ?? 0
            let m = [1: "问路", 2: "预设目的地", 3: "取消导航", 4: "重听"][Int(sub)] ?? "sub=\(sub)"
            onPodRequest?("导航请求", m)
        default:
            onFrameLog?(String(format: "RX 其他帧 type=0x%02X len=%d", type, pl.count))
        }
    }

    private func u16be(_ a: [UInt8], _ i: Int) -> Int {
        (Int(a[i]) << 8) | Int(a[i + 1])
    }

    private func u16le(_ a: [UInt8], _ i: Int) -> Int {
        Int(a[i]) | (Int(a[i + 1]) << 8)
    }
}

// MARK: - CBCentralManagerDelegate

extension BlePodClient: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:      bluetoothState = "已就绪"
        case .poweredOff:     bluetoothState = "蓝牙已关闭"
        case .unauthorized:   bluetoothState = "未授权（设置→隐私与安全性→蓝牙）"
        case .unsupported:    bluetoothState = "本机不支持蓝牙"
        case .resetting:      bluetoothState = "正在重置"
        default:              bluetoothState = "未知状态"
        }
        onState?(bluetoothState)
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        let name = peripheral.name
            ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? "未命名"
        let hasSvc = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?
            .contains(BlePodClient.serviceUUID) ?? false
        onDiscover?(name, peripheral.identifier, RSSI.intValue, hasSvc)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        isConnected = true
        connectedName = peripheral.name ?? "Pod"
        onConnected?(connectedName)
        peripheral.discoverServices([BlePodClient.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral, error: Error?) {
        isConnected = false
        onState?("连接失败：\(error?.localizedDescription ?? "未知")")
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        isConnected = false
        rxChar = nil
        txChar = nil
        buf.removeAll()
        onDisconnected?()
        onState?("已断开：\(error?.localizedDescription ?? "主动断开")")
    }
}

// MARK: - CBPeripheralDelegate

extension BlePodClient: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let e = error {
            onState?("发现服务失败：\(e.localizedDescription)")
            return
        }
        guard let svc = peripheral.services?.first(where: { $0.uuid == BlePodClient.serviceUUID }) else {
            onState?("该设备没有 NUS 服务（不是我们的 Pod？）")
            return
        }
        peripheral.discoverCharacteristics([BlePodClient.rxUUID, BlePodClient.txUUID], for: svc)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let e = error {
            onState?("发现特征失败：\(e.localizedDescription)")
            return
        }
        for ch in service.characteristics ?? [] {
            if ch.uuid == BlePodClient.rxUUID { rxChar = ch }
            if ch.uuid == BlePodClient.txUUID {
                txChar = ch
                peripheral.setNotifyValue(true, for: ch)   // 打开 TX 通知
            }
        }
        if rxChar != nil && txChar != nil {
            onState?("NUS 就绪（可按 0xAA 帧收发了）")
        } else {
            onState?("NUS 特征不全：rx=\(rxChar != nil) tx=\(txChar != nil)")
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let e = error {
            onState?("开通知失败：\(e.localizedDescription)")
        } else if characteristic.isNotifying {
            onState?("已订阅 TX 通知，等待传感器数据…")
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let e = error {
            onFrameLog?("收包错误：\(e.localizedDescription)")
            return
        }
        if let d = characteristic.value, !d.isEmpty {
            feed(d)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let e = error {
            onFrameLog?("写入失败：\(e.localizedDescription)")
        }
    }
}
