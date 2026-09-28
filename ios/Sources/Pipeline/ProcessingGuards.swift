import Foundation
import os

/// Pure rules and small system reads used by `ProcessingRunner`: the memory gate (D17), the
/// thermal waits, stamp freshness (D11), the state reducer, the progress throttle and the
/// dependency planner. Everything here is nonisolated and safe to call from any thread.
enum ProcessingGuards {
    /// Memory kept free on top of a step's budget, bytes (D17).
    static let headroomBytes: UInt64 = 300_000_000
    /// Steps with a budget above this wait 30 s at thermal `.serious`, bytes.
    static let heavyStepBytes: UInt64 = 300_000_000
    /// Wait before a heavy step at thermal `.serious`, seconds (RESEARCH 3.1 recommended 10).
    static let heatWaitSeconds: Double = 30
    /// Poll interval while the phone is at thermal `.critical`, seconds.
    static let criticalPollSeconds: Double = 5
    /// Minimum interval between two published progress updates, seconds (10 Hz).
    static let progressInterval: Double = 0.1

    // MARK: - Memory

    /// `os_proc_available_memory()` in bytes (0 when the process is already over its limit).
    static func availableMemory() -> UInt64 {
        let value = os_proc_available_memory()
        return value > 0 ? UInt64(value) : 0
    }

    /// .full when available >= budget + headroom, .reduced when a reduced budget exists and
    /// available >= reduced + headroom, else .refuse (D17).
    static func variant(available: UInt64, budget: UInt64, reduced: UInt64?) -> StepVariant {
        if available >= saturatingAdd(budget, headroomBytes) { return .full }
        if let reduced, available >= saturatingAdd(reduced, headroomBytes) { return .reduced }
        return .refuse
    }

    /// The `StepContext.availableMemory` that makes a step pick its reduced variant: just
    /// below the full budget (Core `ProcessingStep.run` picks reduced below
    /// `memoryBudgetBytes`), never above what is really available.
    static func reducedMemoryCap(available: UInt64, budget: UInt64) -> UInt64 {
        guard budget > 0 else { return 0 }
        return Swift.min(available, budget - 1)
    }

    /// `a + b`, clamped at `UInt64.max`.
    static func saturatingAdd(_ a: UInt64, _ b: UInt64) -> UInt64 {
        let (sum, overflow) = a.addingReportingOverflow(b)
        return overflow ? UInt64.max : sum
    }

    /// Megabytes for the log.
    static func megabytes(_ bytes: UInt64) -> String {
        String(bytes / 1_000_000) + " MB"
    }

    // MARK: - Thermal

    /// True at `.serious` and `.critical`: reduced variants are forced and heavy steps wait.
    static func isHot(_ state: ProcessInfo.ThermalState) -> Bool {
        switch state {
        case .serious, .critical: return true
        case .nominal, .fair: return false
        @unknown default: return false
        }
    }

    /// Name of a thermal state for the log.
    static func thermalName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    /// Returns once the phone is no longer at `.critical` (polled every 5 s) or `isCancelled`
    /// becomes true.
    static func waitWhileCritical(isCancelled: () -> Bool) async {
        while ProcessInfo.processInfo.thermalState == .critical && !isCancelled() {
            if Task.isCancelled { return }
            await waitSeconds(criticalPollSeconds, isCancelled: isCancelled)
        }
    }

    /// Waits `seconds` in short slices, returning early when `isCancelled` becomes true.
    static func waitSeconds(_ seconds: Double, isCancelled: () -> Bool) async {
        var remaining = seconds
        while remaining > 0 && !isCancelled() {
            if Task.isCancelled { return }
            let slice = Swift.min(remaining, 0.25)
            try? await Task.sleep(nanoseconds: UInt64(slice * 1_000_000_000))
            remaining -= slice
        }
    }

    // MARK: - Stamps

    /// True when the index holds a stamp with the current pipeline version and this hash.
    static func shouldSkip(index: DerivedIndex, step: PipelineStepID, subject: UUID?, inputHash: String) -> Bool {
        index.isFresh(step: step, subject: subject, version: ProjectManifest.currentPipelineVersion, inputHash: inputHash)
    }

    // MARK: - State

    /// Pure state reducer used by the runner (and the self-test). The runner sets `isQueued`
    /// from its queue after each event, because a newer job for the same project can wait
    /// while one runs.
    static func reduce(_ state: ProjectProcessingState, _ event: ProcessingEvent) -> ProjectProcessingState {
        var next = state
        switch event {
        case .queued:
            next.isQueued = true
        case .started(let step):
            next.isQueued = false
            next.isRunning = true
            next.isPausedForHeat = false
            next.currentStep = step
            next.fraction = 0
        case .progress(let value):
            guard next.isRunning, next.currentStep != nil else { return next }
            next.fraction = value.isNaN ? 0 : Swift.min(Swift.max(value, 0), 1)
        case .stepCompleted(let step), .stepSkipped(let step):
            next.completed.insert(step)
            next.failed[step] = nil
            if next.currentStep == step {
                next.currentStep = nil
                next.fraction = 0
            }
        case .stepFailed(let step, let reason, _):
            next.failed[step] = reason
            next.completed.remove(step)
            if next.currentStep == step {
                next.currentStep = nil
                next.fraction = 0
            }
        case .pausedForHeat(let paused):
            next.isPausedForHeat = paused
        case .finished:
            next.isQueued = false
            next.isRunning = false
            next.isPausedForHeat = false
            next.currentStep = nil
            next.fraction = 0
        }
        return next
    }

    /// True when a progress update at `now` should be published after one at `last` (0.1 s throttle).
    static func shouldPublish(now: Double, last: Double?) -> Bool {
        guard let last else { return true }
        if now < last { return true }
        return now - last >= progressInterval
    }

    // MARK: - Dependencies

    /// Keys that cannot run: the failed keys plus every step that depends on one of them,
    /// directly or transitively.
    static func blocked(_ steps: [ScheduledStep], failed: Set<ScheduledStepKey>) -> Set<ScheduledStepKey> {
        var result = failed
        var changed = true
        while changed {
            changed = false
            for scheduled in steps where !result.contains(scheduled.key) {
                if !scheduled.dependsOn.isDisjoint(with: result) {
                    result.insert(scheduled.key)
                    changed = true
                }
            }
        }
        return result
    }

    /// Pure planner: the keys, in job order, of the steps that may still run given the failed
    /// keys (a step is dropped when it failed or depends on a failed step, transitively).
    /// Dependencies on keys that are not part of the job are treated as satisfied.
    static func runnable(_ steps: [ScheduledStep], failed: Set<ScheduledStepKey>) -> [ScheduledStepKey] {
        let stopped = blocked(steps, failed: failed)
        return steps.map { $0.key }.filter { !stopped.contains($0) }
    }

    /// The dependency of `scheduled` that stops it (failed or itself stopped), for the log.
    static func failedDependency(of scheduled: ScheduledStep, in steps: [ScheduledStep],
                                 failed: Set<ScheduledStepKey>) -> ScheduledStepKey? {
        let stopped = blocked(steps, failed: failed)
        let candidates = scheduled.dependsOn.filter { stopped.contains($0) }
        return candidates.sorted { $0.logName < $1.logName }.first
    }

    /// The steps in a runnable order: each step after the steps it depends on, otherwise in
    /// the given order (stable). A repeated key keeps its first occurrence. A dependency cycle
    /// leaves the remaining steps in the given order.
    static func ordered(_ steps: [ScheduledStep]) -> [ScheduledStep] {
        var seen = Set<ScheduledStepKey>()
        var remaining: [ScheduledStep] = []
        for scheduled in steps {
            if seen.insert(scheduled.key).inserted { remaining.append(scheduled) }
        }
        let keys = seen
        var placed = Set<ScheduledStepKey>()
        var result: [ScheduledStep] = []
        while !remaining.isEmpty {
            let ready = remaining.firstIndex { candidate in
                candidate.dependsOn.allSatisfy { dependency in
                    !keys.contains(dependency) || placed.contains(dependency)
                }
            }
            guard let index = ready else {
                result.append(contentsOf: remaining)
                break
            }
            let next = remaining.remove(at: index)
            placed.insert(next.key)
            result.append(next)
        }
        return result
    }
}
