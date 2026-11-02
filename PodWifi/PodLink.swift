import Foundation

/// 全局唯一的 BLE 链路。
///
/// 为什么必须是单例：iOS 允许创建多个 CBCentralManager，但对**同一个外设**只能保持一条连接。
/// 如果「蓝牙」页和「语音/导航」页各建一个 client，两边会互相抢连接（表现就是连上又掉）。
/// 所以所有页面共用这一个实例。
enum PodLink {
    static let shared = BlePodClient()

    /// 最近一次传感器数据（供语音助手做上下文）
    static var lastSensorText: String = "无数据"
}
