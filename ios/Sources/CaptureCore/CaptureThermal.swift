import Foundation

/// Thermal ladder (ship-first 3.1, RESEARCH 3.8, ARCHITECTURE 12.2): what capture does at
/// each device thermal level.
struct ThermalPolicy: Equatable, Sendable {
    /// Multiplier of the keyframe gate interval: 1 nominal and fair, 2 serious and critical.
    var keyframeIntervalScale: Double
    /// Live coverage integration rate, Hz: 3, 3, 1, 0.
    var coverageHz: Double
    /// Whether the live coverage overlay keeps updating: false from serious.
    var overlayEnabled: Bool
    /// True at critical: the engine finishes the room itself and pauses the session.
    var mustStop: Bool

    /// The policy for a thermal level.
    static func forLevel(_ level: ThermalLevel) -> ThermalPolicy {
        switch level {
        case .nominal, .fair:
            return ThermalPolicy(keyframeIntervalScale: 1, coverageHz: 3, overlayEnabled: true, mustStop: false)
        case .serious:
            return ThermalPolicy(keyframeIntervalScale: 2, coverageHz: 1, overlayEnabled: false, mustStop: false)
        case .critical:
            return ThermalPolicy(keyframeIntervalScale: 2, coverageHz: 0, overlayEnabled: false, mustStop: true)
        }
    }
}

/// Observes `ProcessInfo.thermalStateDidChangeNotification` and keeps the current
/// `ThermalLevel`. Thread-safe: `level` and `policy` may be read from any thread.
final class ThermalGovernor {
    /// Notification center observed (injectable for the self-test).
    private let center: NotificationCenter
    /// Reads the current system thermal state (injectable for the self-test).
    private let readState: () -> ProcessInfo.ThermalState
    /// Guards every mutable property below.
    private let lock = NSLock()
    /// Last level read.
    private var currentLevel: ThermalLevel
    /// Notification observer token while started.
    private var observer: NSObjectProtocol?
    /// Where change callbacks go while started.
    private var callbackQueue: DispatchQueue?
    /// Change callback while started.
    private var onChange: ((ThermalLevel) -> Void)?

    /// Observes the given center (the default center in the app) and reads
    /// `ProcessInfo.processInfo.thermalState`.
    convenience init(notificationCenter: NotificationCenter = .default) {
        self.init(notificationCenter: notificationCenter, stateReader: { ProcessInfo.processInfo.thermalState })
    }

    /// Observes the given center and reads the thermal state through `stateReader` (tests).
    init(notificationCenter: NotificationCenter, stateReader: @escaping () -> ProcessInfo.ThermalState) {
        center = notificationCenter
        readState = stateReader
        currentLevel = ThermalLevel(stateReader())
    }

    /// Removes the notification observer if the owner never called `stop()`.
    deinit {
        if let token = observer { center.removeObserver(token) }
    }

    /// The current thermal level.
    var level: ThermalLevel {
        lock.lock()
        defer { lock.unlock() }
        return currentLevel
    }

    /// The capture policy for the current level.
    var policy: ThermalPolicy { ThermalPolicy.forLevel(level) }

    /// Starts observing. `onChange` is called on `queue` after every change of level (not for
    /// the initial read). Calling it again replaces the queue and callback.
    func start(on queue: DispatchQueue, onChange: @escaping (ThermalLevel) -> Void) {
        lock.lock()
        callbackQueue = queue
        self.onChange = onChange
        let needsObserver = observer == nil
        lock.unlock()
        refresh(notify: false)
        guard needsObserver else { return }
        let token = center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification,
                                       object: nil, queue: nil) { [weak self] _ in
            self?.refresh(notify: true)
        }
        lock.lock()
        if observer == nil {
            observer = token
            lock.unlock()
        } else {
            lock.unlock()
            center.removeObserver(token)
        }
    }

    /// Stops observing and drops the callback. Idempotent.
    func stop() {
        lock.lock()
        let token = observer
        observer = nil
        callbackQueue = nil
        onChange = nil
        lock.unlock()
        if let token { center.removeObserver(token) }
    }

    /// Re-reads the thermal state; when the level changed and `notify` is true, calls the
    /// change callback on its queue.
    func refresh(notify: Bool) {
        let newLevel = ThermalLevel(readState())
        lock.lock()
        let changed = newLevel != currentLevel
        currentLevel = newLevel
        let targetQueue = callbackQueue
        let targetCallback = onChange
        lock.unlock()
        guard changed, notify, let queue = targetQueue, let callback = targetCallback else { return }
        queue.async { callback(newLevel) }
    }
}
