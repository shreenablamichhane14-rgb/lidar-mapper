import Foundation
import Combine

/// Runs processing jobs one project at a time and one step at a time (D11, D17, D20). The
/// main-actor facade owns the queue and the published state; every file read, hash and step
/// runs in `Task.detached` through `PipelineStepExecutor`, so the main thread never blocks.
///
/// Per step: a step whose dependency failed is recorded as failed without running; otherwise
/// the manifest is read, the input hash computed and a fresh stamp skips the step; the
/// crash-loop marker decides run, run reduced or give up; the phone must not be `.critical`,
/// and at `.serious` reduced variants are forced and heavy steps wait 30 s; the memory gate
/// refuses with `MapperError.outOfMemory(step:)` when nothing fits; the marker is written, the
/// step runs, and on success the stamp is recorded (the runner is the only writer of the
/// index and the marker). While a job runs the runner holds an `IdleTimerGuard` token.
@MainActor final class ProcessingRunner: ObservableObject {
    /// The app's runner.
    static let shared = ProcessingRunner()

    /// Processing state per project, kept after a job ends so screens can show failures.
    @Published private(set) var states: [UUID: ProjectProcessingState] = [:]
    /// True between `suspendAll` and `resumeAll`.
    @Published private(set) var isSuspended: Bool = false

    /// A queued job with its completion.
    private struct PendingJob {
        /// The job.
        let job: ProcessingJob
        /// Called on main once with the outcome.
        let onFinish: (ProcessingOutcome) -> Void
    }

    /// What one step run ended with.
    private enum StepResult {
        /// The step ran and its stamp was recorded.
        case completed
        /// The stamp was fresh.
        case skipped
        /// The step failed or could not run; `reason` is for the log and the state.
        case failed(MapperError, reason: String)
        /// The job was cancelled or suspended during the step (not a failure).
        case interrupted
        /// The package folder no longer exists.
        case projectMissing
    }

    /// Waiting and running jobs.
    private var queue = PipelineJobQueue<PendingJob>()
    /// Stop flag of the running job; non-nil exactly while a job loop is active.
    private var activeFlag: PipelineCancelFlag?
    /// The detached task running the current step, cancelled with the job.
    private var activeStepTask: Task<PipelineStepExecutor.RunResult, Never>?
    /// Token of the current step run; progress of other runs is dropped.
    private var progressToken: UUID?
    /// The runner's idle-timer hold while a job runs.
    private var idleToken: UUID?

    /// Creates a runner. The app uses `shared`.
    init() {}

    // MARK: - Public API

    /// True while a job runs or waits.
    var isBusy: Bool { !queue.isEmpty }

    /// The state of a project (idle when it has none).
    func state(for projectID: UUID) -> ProjectProcessingState {
        states[projectID] ?? ProjectProcessingState()
    }

    /// Queues a job; `onFinish` is called on main once. A job for a project already queued replaces
    /// it (the replaced job reports `.cancelled`). `atFront` puts it before the waiting jobs (a
    /// scan the user just finished).
    func enqueue(_ job: ProcessingJob, atFront: Bool = false, onFinish: @escaping (ProcessingOutcome) -> Void) {
        let projectID = job.projectID
        let isRunningNow = queue.running?.projectID == projectID
        let replaced = queue.enqueue(PendingJob(job: job, onFinish: onFinish), projectID: projectID, atFront: atFront)
        let base = isRunningNow ? state(for: projectID) : ProjectProcessingState()
        publish(ProcessingGuards.reduce(base, .queued), for: projectID)
        log("job queued: project \(short(projectID)), \(job.steps.count) steps\(atFront ? ", at front" : "")\(isSuspended ? ", suspended" : "")")
        if let replaced {
            log("job replaced: project \(short(projectID))")
            replaced.onFinish(.cancelled)
        }
        pump()
    }

    /// Cancels the project's job: a waiting job ends now, a running job stops at its next
    /// cancellation check. Both report `.cancelled`.
    func cancel(projectID: UUID) {
        let removed = queue.removeWaiting(projectID: projectID)
        let isRunningNow = queue.running?.projectID == projectID
        if isRunningNow, let flag = activeFlag {
            flag.set(.cancelled)
            activeStepTask?.cancel()
            publish(state(for: projectID), for: projectID)
        } else if removed != nil {
            apply(.finished, to: projectID)
        }
        if removed != nil || isRunningNow {
            log("job cancel: project \(short(projectID))\(isRunningNow ? " (running)" : "")")
        }
        removed?.onFinish(.cancelled)
    }

    /// Before a capture starts: sets the running job's cancel flag, keeps every job queued (the
    /// interrupted step reruns later; stamped steps skip), does not call `onFinish`, publishes
    /// `isSuspended`. Nothing starts until `resumeAll`.
    func suspendAll(reason: String) {
        queue.suspend()
        if !isSuspended { isSuspended = true }
        if let flag = activeFlag {
            flag.set(.suspended)
            activeStepTask?.cancel()
        }
        log("suspend: \(reason)\(activeFlag != nil ? ", interrupting the running job" : "")")
    }

    /// After the capture cover closes: restarts the queue.
    func resumeAll() {
        guard isSuspended else { return }
        queue.resume()
        isSuspended = false
        log("resume: \(queue.waitingProjectIDs.count) jobs waiting")
        pump()
    }

    // MARK: - Queue

    /// Starts the next job when none runs and the queue is not suspended.
    private func pump() {
        guard activeFlag == nil else { return }
        guard let item = queue.startNext() else {
            updateIdleTimer()
            return
        }
        let flag = PipelineCancelFlag()
        activeFlag = flag
        updateIdleTimer()
        let pending = item.entry
        Task { await self.runJob(pending, flag: flag) }
    }

    /// Holds the idle timer while a job loop is active, releases it otherwise.
    private func updateIdleTimer() {
        if activeFlag != nil {
            if idleToken == nil { idleToken = IdleTimerGuard.acquire("processing") }
        } else if let token = idleToken {
            IdleTimerGuard.release(token)
            idleToken = nil
        }
    }

    /// Runs every step of a job in dependency order, then reports.
    private func runJob(_ pending: PendingJob, flag: PipelineCancelFlag) async {
        let job = pending.job
        let projectID = job.projectID
        let steps = ProcessingGuards.ordered(job.steps)
        let started = ProcessInfo.processInfo.systemUptime
        log("job start: project \(short(projectID)), \(steps.count) steps, available \(ProcessingGuards.megabytes(ProcessingGuards.availableMemory()))")
        if steps.map({ $0.key }) != job.steps.map({ $0.key }) {
            log("job steps reordered by dependencies: \(steps.map { $0.key.logName }.joined(separator: ", "))")
        }
        var ledger = PipelineJobLedger()
        for scheduled in steps {
            if flag.isSet { break }
            let runnable = ProcessingGuards.runnable(steps, failed: ledger.failedKeys)
            guard runnable.contains(scheduled.key) else {
                let blocker = ProcessingGuards.failedDependency(of: scheduled, in: steps, failed: ledger.failedKeys)
                let reason = "dependency failed" + (blocker.map { ": " + $0.logName } ?? "")
                let error = MapperError.processingFailed(step: scheduled.stepID, reason: reason)
                recordFailure(scheduled, error: error, reason: reason, ledger: &ledger, projectID: projectID)
                continue
            }
            let result = await runStep(scheduled, job: job, flag: flag)
            switch result {
            case .completed, .skipped, .interrupted:
                break
            case .failed(let error, let reason):
                recordFailure(scheduled, error: error, reason: reason, ledger: &ledger, projectID: projectID)
            case .projectMissing:
                log("job stop: project \(short(projectID)) package is gone")
                flag.set(.cancelled)
            }
        }
        finishJob(pending, flag: flag, ledger: ledger, started: started)
    }

    /// Records a failed step in the ledger and the published state, and logs it.
    private func recordFailure(_ scheduled: ScheduledStep, error: MapperError, reason: String,
                               ledger: inout PipelineJobLedger, projectID: UUID) {
        ledger.recordFailure(scheduled, error: error)
        apply(.stepFailed(scheduled.stepID, reason: reason, optional: scheduled.isOptional), to: projectID)
        let kind = scheduled.isOptional ? "optional" : "required"
        log("step failed: \(scheduled.key.logName) (\(kind)): \(reason); \(error.copyKey), available \(ProcessingGuards.megabytes(ProcessingGuards.availableMemory()))")
    }

    /// Ends the running job: requeues it after a suspension, otherwise reports its outcome.
    private func finishJob(_ pending: PendingJob, flag: PipelineCancelFlag, ledger: PipelineJobLedger, started: Double) {
        let projectID = pending.job.projectID
        let duration = ProcessInfo.processInfo.systemUptime - started
        activeFlag = nil
        activeStepTask = nil
        progressToken = nil
        var outcome: ProcessingOutcome? = nil
        switch flag.reason {
        case .suspended:
            if queue.finishRunning(requeue: true) != nil {
                outcome = .cancelled
                log("job interrupted and replaced by a newer job: project \(short(projectID))")
            } else {
                log("job interrupted, kept queued: project \(short(projectID)) after \(secondsText(duration))")
            }
        case .cancelled:
            _ = queue.finishRunning(requeue: false)
            outcome = .cancelled
        case .proceed:
            _ = queue.finishRunning(requeue: false)
            outcome = ledger.outcome(cancelled: false)
        }
        apply(.finished, to: projectID)
        updateIdleTimer()
        if let outcome {
            log("job end: project \(short(projectID)) \(describe(outcome)) in \(secondsText(duration)), available \(ProcessingGuards.megabytes(ProcessingGuards.availableMemory()))")
            pending.onFinish(outcome)
        }
        pump()
    }

    // MARK: - One step

    /// Prepares, gates and runs one step; every file access happens in detached tasks.
    private func runStep(_ scheduled: ScheduledStep, job: ProcessingJob, flag: PipelineCancelFlag) async -> StepResult {
        let box = PipelineStepBox(scheduled.step)
        let stepID = scheduled.stepID
        let subject = scheduled.subject
        let package = job.package
        let projectID = job.projectID
        let name = scheduled.key.logName
        let checkStart = ProcessInfo.processInfo.systemUptime

        let preparation = await Task.detached(priority: .userInitiated) {
            PipelineStepExecutor.prepare(box: box, stepID: stepID, subject: subject, package: package, flag: flag)
        }.value
        let plan: PipelineStepExecutor.Plan
        switch preparation {
        case .projectMissing:
            return .projectMissing
        case .fresh:
            apply(.stepSkipped(stepID), to: projectID)
            let elapsed = ProcessInfo.processInfo.systemUptime - checkStart
            log("step skip (fresh): \(name) in \(secondsText(elapsed)), available \(ProcessingGuards.megabytes(ProcessingGuards.availableMemory()))")
            return .skipped
        case .failed(let error):
            if flag.isSet { return .interrupted }
            return .failed(error, reason: "not started: \(error)")
        case .giveUp(let count):
            log("step give-up: \(name) after \(count) interrupted attempts")
            return .failed(.outOfMemory(step: stepID), reason: "gave up after \(count) interrupted attempts")
        case .needsRun(let value):
            plan = value
        }
        if flag.isSet { return .interrupted }
        apply(.started(stepID), to: projectID)

        await waitForHeat(budget: plan.budget, projectID: projectID, name: name, flag: flag)
        if flag.isSet { return .interrupted }

        let gateResult = await Task.detached(priority: .userInitiated) {
            PipelineStepExecutor.gate(box: box, stepID: stepID, subject: subject, package: package, plan: plan, flag: flag)
        }.value
        let launch: PipelineStepExecutor.Launch
        switch gateResult {
        case .projectMissing:
            return .projectMissing
        case .refused(let available):
            let reason = "not enough memory: \(ProcessingGuards.megabytes(available)) available, budget \(ProcessingGuards.megabytes(plan.budget))"
            return .failed(.outOfMemory(step: stepID), reason: reason)
        case .go(let value):
            launch = value
        }
        if flag.isSet {
            await Task.detached(priority: .userInitiated) {
                PipelineStepExecutor.recordFailure(package: package)
            }.value
            return .interrupted
        }
        let variantName = launch.variant == .reduced ? PipelineAttempt.reducedVariant : PipelineAttempt.fullVariant
        log("step start: \(name) variant \(variantName), attempt \(launch.attempt), available \(ProcessingGuards.megabytes(launch.measuredMemory)), passed \(ProcessingGuards.megabytes(launch.passedMemory)), thermal \(launch.thermal)")

        let result = await execute(box: box, stepID: stepID, package: package, manifest: plan.manifest,
                                   memory: launch.passedMemory, flag: flag)
        switch result {
        case .success(let elapsed, let memoryAfter):
            let hash = launch.inputHash
            let now = Date()
            let written = await Task.detached(priority: .userInitiated) {
                PipelineStepExecutor.recordSuccess(stepID: stepID, subject: subject, inputHash: hash, package: package, now: now)
            }.value
            apply(.stepCompleted(stepID), to: projectID)
            log("step done: \(name) in \(secondsText(elapsed)), available \(ProcessingGuards.megabytes(launch.measuredMemory)) -> \(ProcessingGuards.megabytes(memoryAfter))\(written ? "" : ", stamp not written")")
            return .completed
        case .failure(let error, let detail, let elapsed, let memoryAfter):
            await Task.detached(priority: .userInitiated) {
                PipelineStepExecutor.recordFailure(package: package)
            }.value
            if flag.isSet {
                log("step interrupted: \(name) after \(secondsText(elapsed)), available \(ProcessingGuards.megabytes(memoryAfter))")
                return .interrupted
            }
            log("step error: \(name) after \(secondsText(elapsed)): \(detail), available \(ProcessingGuards.megabytes(memoryAfter))")
            return .failed(error, reason: detail)
        }
    }

    /// Waits while the phone is `.critical`, then 30 s before a heavy step at `.serious`,
    /// publishing `isPausedForHeat` while waiting.
    private func waitForHeat(budget: UInt64, projectID: UUID, name: String, flag: PipelineCancelFlag) async {
        let cancelCheck: @Sendable () -> Bool = { flag.isSet }
        if ProcessInfo.processInfo.thermalState == .critical {
            apply(.pausedForHeat(true), to: projectID)
            log("step waits for the phone to cool down (critical): \(name)")
            await ProcessingGuards.waitWhileCritical(isCancelled: cancelCheck)
            apply(.pausedForHeat(false), to: projectID)
        }
        if flag.isSet { return }
        let hot = ProcessingGuards.isHot(ProcessInfo.processInfo.thermalState)
        if hot && budget > ProcessingGuards.heavyStepBytes {
            apply(.pausedForHeat(true), to: projectID)
            log("step waits \(Int(ProcessingGuards.heatWaitSeconds)) s (serious heat): \(name)")
            await ProcessingGuards.waitSeconds(ProcessingGuards.heatWaitSeconds, isCancelled: cancelCheck)
            apply(.pausedForHeat(false), to: projectID)
        }
    }

    /// Runs the step in a detached task whose handle is kept for cancellation.
    private func execute(box: PipelineStepBox, stepID: PipelineStepID, package: ProjectPackage,
                         manifest: ProjectManifest, memory: UInt64, flag: PipelineCancelFlag) async -> PipelineStepExecutor.RunResult {
        let token = UUID()
        progressToken = token
        let runner = self
        let sink = PipelineProgressSink(token: token) { stepToken, fraction in
            _ = Task { @MainActor in runner.receiveProgress(token: stepToken, fraction: fraction) }
        }
        let task = Task.detached(priority: .userInitiated) {
            await PipelineStepExecutor.run(box: box, stepID: stepID, package: package, manifest: manifest,
                                           availableMemory: memory, flag: flag, sink: sink)
        }
        activeStepTask = task
        if flag.isSet { task.cancel() }
        let result = await task.value
        activeStepTask = nil
        progressToken = nil
        return result
    }

    /// Publishes a throttled progress update of the current step run.
    private func receiveProgress(token: UUID, fraction: Double) {
        guard token == progressToken, let projectID = queue.running?.projectID else { return }
        apply(.progress(fraction), to: projectID)
    }

    // MARK: - State and log

    /// Applies an event to a project's state and publishes it.
    private func apply(_ event: ProcessingEvent, to projectID: UUID) {
        publish(ProcessingGuards.reduce(state(for: projectID), event), for: projectID)
    }

    /// Publishes a state with `isQueued` taken from the queue; skips unchanged values.
    private func publish(_ state: ProjectProcessingState, for projectID: UUID) {
        var next = state
        next.isQueued = queue.hasWaiting(projectID)
        if states[projectID] != next { states[projectID] = next }
    }

    /// Writes a line to the log (category "pipeline").
    private func log(_ message: String) {
        LogStore.shared.write(message, category: "pipeline")
    }

    /// First 8 characters of an id for the log.
    private func short(_ id: UUID) -> String {
        String(id.uuidString.prefix(8))
    }

    /// Seconds with one decimal for the log.
    private func secondsText(_ value: Double) -> String {
        guard value.isFinite, value >= 0, value < 1_000_000 else { return "? s" }
        return String(Double(Int(value * 10)) / 10) + " s"
    }

    /// Outcome text for the log.
    private func describe(_ outcome: ProcessingOutcome) -> String {
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
