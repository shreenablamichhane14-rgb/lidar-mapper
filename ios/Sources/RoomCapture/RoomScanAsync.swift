import Foundation
import UIKit

// Small concurrency helpers of the room engine's finish sequence: a callback wait with a
// timeout (RoomBuilder, the world map and recorders must never hang the seal), and the
// background task that lets the sequence finish when the user leaves the app
// (`UIApplication.beginBackgroundTask(withName:expirationHandler:)`, not in RESEARCH, iOS 4,
// main; docs/MODULES.md 3.21).

/// Resumes a continuation at most once; later values are ignored. Thread-safe.
final class RoomResumeOnce<Value: Sendable>: @unchecked Sendable {
    /// Guards `continuation`.
    private let lock = NSLock()
    /// The pending continuation, nil once resumed.
    private var continuation: CheckedContinuation<Value, Never>?

    /// Wraps a continuation.
    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    /// Resumes with `value` the first time; does nothing afterwards. Returns true when this call
    /// resumed the continuation.
    @discardableResult
    func resume(_ value: Value) -> Bool {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        guard let pending else { return false }
        pending.resume(returning: value)
        return true
    }
}

/// Callback waits with a deadline.
enum RoomAsync {
    /// Calls `start` with a completion callback and returns the first value delivered, or
    /// `fallback` after `seconds`. Work started by `start` keeps running after a timeout; its
    /// late value is ignored.
    static func withTimeout<Value: Sendable>(seconds: TimeInterval, fallback: Value,
                                             _ start: (@escaping @Sendable (Value) -> Void) -> Void) async -> Value {
        await withCheckedContinuation { (continuation: CheckedContinuation<Value, Never>) in
            let once = RoomResumeOnce(continuation)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(0, seconds)) {
                once.resume(fallback)
            }
            start { value in
                once.resume(value)
            }
        }
    }
}

/// One `beginBackgroundTask` around the finish sequence: ended by `end()` at the last step or
/// by iOS through the expiration handler, whichever comes first. Thread-safe. UIKit values are
/// only touched on the main actor; the identifier is kept as its raw value.
final class RoomBackgroundTask: @unchecked Sendable {
    /// Guards the two properties below.
    private let lock = NSLock()
    /// Raw value of the task identifier; nil until begun, or when iOS refused the task.
    private var identifierRaw: Int?
    /// True once ended (by `end()` or on expiry).
    private var ended = false

    /// Begins a background task on the main actor and returns its handle.
    static func begin(name: String) async -> RoomBackgroundTask {
        let task = RoomBackgroundTask()
        await MainActor.run {
            let identifier = UIApplication.shared.beginBackgroundTask(withName: name, expirationHandler: {
                task.expire()
            })
            task.adopt(identifier == .invalid ? nil : identifier.rawValue)
        }
        return task
    }

    /// Main thread. Stores the identifier, or ends it at once when `end()` already ran.
    private func adopt(_ raw: Int?) {
        lock.lock()
        let alreadyEnded = ended
        if !alreadyEnded { identifierRaw = raw }
        lock.unlock()
        guard alreadyEnded, let raw else { return }
        MainActor.assumeIsolated {
            UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: raw))
        }
    }

    /// Main thread (iOS calls the expiration handler on main): ends the task.
    private func expire() {
        guard let raw = take() else { return }
        RoomScanLog.write("background time expired during the room finish sequence")
        MainActor.assumeIsolated {
            UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: raw))
        }
    }

    /// Ends the task (idempotent).
    func end() async {
        guard let raw = take() else { return }
        await MainActor.run {
            UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: raw))
        }
    }

    /// Marks the task ended and returns its raw identifier the first time, when there is one.
    private func take() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard !ended else { return nil }
        ended = true
        return identifierRaw
    }
}
