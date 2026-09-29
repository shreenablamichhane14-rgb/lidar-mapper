import Foundation
import Combine
import UIKit

/// The app lifecycle side of `ProcessingRunner` (the crash-loop guard's foreground state) and
/// its log helpers. Main actor, like the runner.
extension ProcessingRunner {
    /// The step whose attempt marker is (or is about to be) on disk.
    struct ActiveAttempt {
        /// The job's package.
        let package: ProjectPackage
        /// The step.
        let stepID: PipelineStepID
        /// Its subject.
        let subject: UUID?
    }

    // MARK: - App lifecycle

    /// willResignActive and didEnterBackground mark the app as out of the foreground;
    /// didBecomeActive marks it back (UIKit posts them on main).
    func observeLifecycle() {
        let center = NotificationCenter.default
        center.publisher(for: UIApplication.willResignActiveNotification)
            .merge(with: center.publisher(for: UIApplication.didEnterBackgroundNotification))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let runner = self else { return }
                    runner.appLeftForeground()
                }
            }
            .store(in: &lifecycleObservers)
        center.publisher(for: UIApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let runner = self else { return }
                    runner.appReturnedToForeground()
                }
            }
            .store(in: &lifecycleObservers)
    }

    /// The app became inactive or went to the background: the running step's marker records
    /// it, so an end of the app from here is not counted as a death.
    func appLeftForeground() {
        guard PipelineForeground.shared.leave(at: Date()) else { return }
        if activeAttempt != nil { log("app left the foreground during a step; its attempt marker is marked") }
        syncActiveAttempt()
    }

    /// The app is active again: the running step's marker counts deaths again.
    func appReturnedToForeground() {
        guard PipelineForeground.shared.enter() else { return }
        syncActiveAttempt()
    }

    /// Copies the foreground state into the running step's marker, off main. The executor reads
    /// the state when it runs, so the last of several quick changes wins.
    func syncActiveAttempt() {
        guard let attempt = activeAttempt else { return }
        let package = attempt.package
        let stepID = attempt.stepID
        let subject = attempt.subject
        Task.detached(priority: .userInitiated) {
            PipelineStepExecutor.syncForeground(package: package, stepID: stepID, subject: subject)
        }
    }

    // MARK: - Log

    /// Writes a line to the log (category "pipeline").
    func log(_ message: String) {
        LogStore.shared.write(message, category: "pipeline")
    }

    /// First 8 characters of an id for the log.
    func short(_ id: UUID) -> String {
        String(id.uuidString.prefix(8))
    }

    /// Seconds with one decimal for the log.
    func secondsText(_ value: Double) -> String {
        guard value.isFinite, value >= 0, value < 1_000_000 else { return "? s" }
        return String(Double(Int(value * 10)) / 10) + " s"
    }

    /// Outcome text for the log.
    func describe(_ outcome: ProcessingOutcome) -> String {
        switch outcome {
        case .completed(let skipped):
            return skipped.isEmpty ? "completed" : "completed without " + skipped.map { $0.rawValue }.joined(separator: ", ")
        case .failed(let step, let error):
            return "failed at \(step.rawValue) (\(error.copyKey))"
        case .cancelled:
            return "cancelled"
        }
    }
}
