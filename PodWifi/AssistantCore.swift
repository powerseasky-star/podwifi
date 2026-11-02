import AVFoundation
import CoreLocation
import Foundation

/// 播报器：新播报立刻打断旧播报（导盲场景不能排队积压）
final class Announcer {
    static let shared = Announcer()
    private let synth = AVSpeechSynthesizer()
    private init() {
        // 让静音键也不影响播报（导盲必需），与安卓走同一路由思路
        try? AVAudioSession.sharedInstance().setCategory(.playback,
                                                        mode: .spokenAudio,
                                                        options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    func say(_ text: String, force: Bool = true) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if force, synth.isSpeaking {
            synth.stopSpeaking(at: .immediate)
        }
        let u = AVSpeechUtterance(string: t)
        u.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        u.rate = 0.52
        synth.speak(u)
    }

    var isSpeaking: Bool { synth.isSpeaking }
}

/// 定位（点对点导航用）。只在前台取一次位置，不上传、不常驻。
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    static let shared = LocationProvider()

    private let m = CLLocationManager()
    private(set) var last: CLLocation?
    private var waiters: [CheckedContinuation<CLLocation?, Never>] = []
    private var onUpdate: ((CLLocation) -> Void)?

    private override init() {
        super.init()
        m.delegate = self
        m.desiredAccuracy = kCLLocationAccuracyBest
    }

    func prepare() {
        if m.authorizationStatus == .notDetermined {
            m.requestWhenInUseAuthorization()
        }
    }

    /// 取当前位置：最多等 4 秒，拿不到就返回 nil（不阻塞语音流程）
    func current() async -> CLLocation? {
        if let l = last, l.timestamp.timeIntervalSinceNow > -10 { return l }
        prepare()
        m.requestLocation()
        let loc: CLLocation? = await withCheckedContinuation { c in
            waiters.append(c)
            // 兜底超时：到点还没回调就放弃（finish 内部会去重，不会重复 resume）
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                self?.finish(nil)
            }
        }
        return loc ?? last
    }

    private func finish(_ loc: CLLocation?) {
        if let l = loc { last = l }
        let ws = waiters
        waiters.removeAll()
        ws.forEach { $0.resume(returning: loc) }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let l = locations.last {
            last = l
            onUpdate?(l)
        }
        finish(locations.last)
    }

    // MARK: - 连续定位（导航会话用）

    /// 开始持续上报位置（约 1 次/秒，精度最好）
    func startUpdates(_ handler: @escaping (CLLocation) -> Void) {
        prepare()
        onUpdate = handler
        m.desiredAccuracy = kCLLocationAccuracyBest
        m.distanceFilter = 3          // 走 3 米才回调，省电且够用
        m.startUpdatingLocation()
    }

    func stopUpdates() {
        onUpdate = nil
        m.stopUpdatingLocation()
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(nil)
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedWhenInUse
            || manager.authorizationStatus == .authorizedAlways {
            manager.requestLocation()
        }
    }
}
