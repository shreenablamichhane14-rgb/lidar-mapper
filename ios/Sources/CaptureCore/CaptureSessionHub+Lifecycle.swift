import ARKit
import UIKit

/// Lifecycle of `ARSessionHub`: install, run, pause, re-apply, recorders, profile, scan start,
/// memory warnings and the housekeeping timer.
extension ARSessionHub {
    // MARK: - Session (main thread)

    /// Call on the main thread (not actor-isolated, so nonisolated engine methods may call it).
    /// Sets `session.delegate = self` and `session.delegateQueue = queue`. Call before any
    /// RoomPlan object is created (RESEARCH 3.2 recommended step 2). Drops an installed relay.
    func install() {
        session.delegateQueue = queue
        session.delegate = self
        setRelay(nil)
        let delegateIsHub = session.delegate === self
        let queueIsHub = session.delegateQueue === queue
        CaptureCoreLog.write("install: delegate === hub \(delegateIsHub), delegateQueue === queue \(queueIsHub)")
    }

    /// Call on the main thread. `session.run(ScanConfigurationFactory.make(profile), options: options)`.
    /// Also starts the thermal, storage and identity-check monitors and logs the configuration.
    func run(options: ARSession.RunOptions = []) {
        let configuration = ScanConfigurationFactory.make(locked { configurationProfile })
        session.run(configuration, options: options)
        locked { running = true }
        registerMemoryWarningObserver()
        thermal.start(on: queue) { [weak self] level in self?.handleThermalChange(level) }
        storage.start(on: queue) { [weak self] state in self?.handleStorageChange(state) }
        startChecks()
        let effective = session.configuration
        let optionsText = ScanConfigurationFactory.runOptionsText(options)
        queue.async { [weak self] in
            guard let self else { return }
            self.diagnostics.logConfiguration(effective, label: "run")
            self.emit(.config, "session run, options \(optionsText)")
            self.emit(.thermal, "thermal at run \(self.thermal.level.rawValue)")
            self.requestStatusPublish()
        }
    }

    /// Call on the main thread. `session.pause()`; also stops the memory warning observer,
    /// the thermal and storage monitors and the identity check. Idempotent.
    func pause() {
        session.pause()
        let wasRunning = locked { () -> Bool in
            let was = running
            running = false
            return was
        }
        unregisterMemoryWarningObserver()
        thermal.stop()
        storage.stop()
        stopChecks()
        guard wasRunning else { return }
        CaptureCoreLog.write("hub paused")
        queue.async { [weak self] in self?.emit(.note, "session paused") }
    }

    /// Any thread. Re-runs the configuration with options [] (never reset options). Logs the
    /// reason and the configuration before and after (D22). Called by the watchdog when depth
    /// or mesh is missing, never unconditionally: on the RoomCaptureView path RoomPlan
    /// preserves the session's settings, so Mapper reconfigures only when the watchdog sees
    /// depth or mesh missing (RESEARCH ruling 1). The run itself happens on the main thread,
    /// as in Apple's samples; it is skipped while the session is paused.
    func reapplyConfiguration(reason: String) {
        guard isRunning else {
            CaptureCoreLog.write("reapply skipped, session not running: \(reason)")
            return
        }
        let configuration = ScanConfigurationFactory.make(locked { configurationProfile })
        let work: () -> Void = { [weak self] in
            guard let self else { return }
            let before = self.session.configuration
            self.session.run(configuration, options: [])
            let after = self.session.configuration
            self.queue.async { [weak self] in
                guard let self else { return }
                self.diagnostics.logConfiguration(before, label: "before reapply")
                self.diagnostics.logConfiguration(after, label: "after reapply")
                self.emit(.config, "configuration re-applied: \(reason)")
            }
            self.queue.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self else { return }
                self.diagnostics.logConfiguration(self.session.configuration, label: "1 s after reapply")
            }
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    /// True between `run` and `pause` (any thread).
    var isRunning: Bool { locked { running } }

    // MARK: - Recorders, profile, scan start (any thread, work on the hub queue)

    /// Any thread (hops to queue). Attaching the same recorder twice has no effect.
    func attach(_ recorder: ScanRecorder) {
        performOnQueue { [weak self] in
            guard let self else { return }
            guard !self.recorders.contains(where: { $0 === recorder }) else { return }
            self.recorders.append(recorder)
            CaptureCoreLog.write("recorder attached: \(String(describing: type(of: recorder)))")
        }
    }

    /// Any thread (hops to queue; runs at once when called on the queue, so no callback
    /// reaches the recorder after this returns there).
    func detach(_ recorder: ScanRecorder) {
        performOnQueue { [weak self] in
            guard let self else { return }
            let before = self.recorders.count
            self.recorders.removeAll { $0 === recorder }
            if self.recorders.count != before {
                CaptureCoreLog.write("recorder detached: \(String(describing: type(of: recorder)))")
            }
        }
    }

    /// Any thread (hops to queue). A change of plane detection re-applies the configuration.
    func updateProfile(_ profile: ScanProfile) {
        let old = locked { () -> ScanProfile in
            let previous = configurationProfile
            configurationProfile = profile
            return previous
        }
        performOnQueue { [weak self] in self?.profileValue = profile }
        if old.wantsPlaneDetection != profile.wantsPlaneDetection {
            reapplyConfiguration(reason: "profile changed to \(profile.mode.rawValue)")
        }
    }

    /// Hub queue (hops there when called elsewhere). Resets elapsed time, tracking history,
    /// the degraded mode and the watchdogs for a new room or pass; the depth and mesh
    /// watchdog runs only after this call.
    func markScanStart(timestamp: TimeInterval) {
        performOnQueue { [weak self] in
            guard let self else { return }
            self.scanStartTimestamp = timestamp
            self.watchdog.reset()
            self.tracking.reset()
            self.lastPose = nil
            self.degradedValue = .allGood
            self.statusValue.elapsed = 0
            self.emit(.note, "scan start")
            self.requestStatusPublish()
        }
    }

    // MARK: - Relay and foreign-queue bookkeeping (any thread)

    /// The installed relay, if any.
    var currentRelay: ARDelegateRelay? { locked { relayStorage } }

    /// Replaces the installed relay.
    func setRelay(_ relay: ARDelegateRelay?) { locked { relayStorage = relay } }

    /// Counts a delegate callback that arrived off the hub queue; logs the first and every
    /// 600th occurrence.
    func noteForeignQueue(_ what: String) {
        let count = locked { () -> Int in
            foreignCallbacks += 1
            return foreignCallbacks
        }
        if count == 1 || count % 600 == 0 {
            CaptureCoreLog.write("callback \(what) arrived off the hub queue (\(count) so far); "
                                 + "values copied, frame not forwarded to recorders")
        }
    }

    // MARK: - Memory warnings

    /// Observes `UIApplication.didReceiveMemoryWarningNotification` (idempotent).
    func registerMemoryWarningObserver() {
        guard locked({ memoryObserver == nil }) else { return }
        let center = NotificationCenter.default
        let token = center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                                       object: nil, queue: nil) { [weak self] _ in
            self?.handleMemoryWarning()
        }
        let duplicate = locked { () -> Bool in
            guard memoryObserver == nil else { return true }
            memoryObserver = token
            return false
        }
        if duplicate { center.removeObserver(token) }
    }

    /// Stops observing memory warnings (idempotent).
    func unregisterMemoryWarningObserver() {
        let token = locked { () -> NSObjectProtocol? in
            let current = memoryObserver
            memoryObserver = nil
            return current
        }
        if let token { NotificationCenter.default.removeObserver(token) }
    }

    /// Any thread: hops to the queue, logs a `.memory` event, forwards `onMemoryPressure` once
    /// and marks the next status tick `.critical`.
    func handleMemoryWarning() {
        queue.async { [weak self] in
            guard let self else { return }
            self.memoryWarningPending = true
            self.emit(.memory, "memory warning, available \(MemoryProbe.availableBytes() / 1_000_000) MB")
            self.onMemoryPressure?()
            self.requestStatusPublish()
        }
    }

    // MARK: - Housekeeping timer

    /// Starts the 1 s identity check and housekeeping timer on `queue` (idempotent).
    func startChecks() {
        let timer = locked { () -> DispatchSourceTimer? in
            guard checkTimer == nil else { return nil }
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now() + ARSessionHub.checkInterval,
                            repeating: ARSessionHub.checkInterval, leeway: .milliseconds(100))
            source.setEventHandler { [weak self] in self?.runChecks() }
            checkTimer = source
            return source
        }
        timer?.resume()
    }

    /// Cancels the timer (idempotent).
    func stopChecks() {
        let timer = locked { () -> DispatchSourceTimer? in
            let current = checkTimer
            checkTimer = nil
            return current
        }
        timer?.cancel()
    }
}
