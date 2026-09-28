import Foundation

/// Identifies one scheduled step within a job (step plus subject).
struct ScheduledStepKey: Hashable, Sendable {
    /// Which step.
    var step: PipelineStepID
    /// Room or object the step works on; nil for project-wide steps.
    var subject: UUID?

    /// Creates a key.
    init(step: PipelineStepID, subject: UUID? = nil) {
        self.step = step
        self.subject = subject
    }

    /// Short text for the log, for example "consolidateMesh/1A2B3C4D".
    var logName: String {
        guard let subject else { return step.rawValue }
        return step.rawValue + "/" + String(subject.uuidString.prefix(8))
    }
}

/// One step of a job: a Core `ProcessingStep`, its subject, whether a failure may be
/// tolerated, and the steps of the same job whose output it reads.
struct ScheduledStep {
    /// The step object. The runner touches it only off the main thread after creation.
    let step: ProcessingStep
    /// Room or object the step works on; nil for project-wide steps.
    let subject: UUID?
    /// True when the job completes even if this step fails (D20).
    let isOptional: Bool
    /// Steps of the same job whose output this one reads. When one of them failed or was skipped
    /// for failure, this step is not run and is recorded as failed ("dependency failed");
    /// independent steps still run.
    let dependsOn: Set<ScheduledStepKey>
    /// `step.id`, read once at creation so the main actor never touches the step again.
    let stepID: PipelineStepID

    /// The key of this step within its job.
    var key: ScheduledStepKey { ScheduledStepKey(step: stepID, subject: subject) }

    /// Creates a scheduled step.
    init(_ step: ProcessingStep, subject: UUID? = nil, isOptional: Bool = false, dependsOn: Set<ScheduledStepKey> = []) {
        self.step = step
        self.subject = subject
        self.isOptional = isOptional
        self.dependsOn = dependsOn
        self.stepID = step.id
    }
}

/// A project plus its ordered steps (built by AppShell's `ProcessingPlans`).
struct ProcessingJob {
    /// The project being processed.
    let projectID: UUID
    /// Its package on disk.
    let package: ProjectPackage
    /// The steps, each after the steps it reads (the runner also sorts by `dependsOn`).
    let steps: [ScheduledStep]

    /// Creates a job.
    init(projectID: UUID, package: ProjectPackage, steps: [ScheduledStep]) {
        self.projectID = projectID
        self.package = package
        self.steps = steps
    }
}

/// How a job ended. `.failed` names the first required step that failed; it is reported after
/// every step that did not depend on it has run. `.cancelled` covers user cancel and a job
/// replaced by a newer one for the same project; `suspendAll` is never reported (a suspended
/// job keeps its place and reruns later).
enum ProcessingOutcome: Equatable, Sendable {
    /// Every required step succeeded; the optional steps listed produced no output.
    case completed(skippedOptional: [PipelineStepID])
    /// The first required step that failed (or could not run because a dependency failed).
    case failed(step: PipelineStepID, error: MapperError)
    /// Cancelled by the user or replaced by a newer job for the project.
    case cancelled
}

/// Per-project processing state published by `ProcessingRunner` for progressive results
/// (D20). `completed` and `failed` are keyed by step (all subjects of a step share a key).
struct ProjectProcessingState: Equatable, Sendable {
    /// A job for the project waits in the queue.
    var isQueued = false
    /// A job for the project is running.
    var isRunning = false
    /// The running job waits for the phone to cool down.
    var isPausedForHeat = false
    /// The step running now.
    var currentStep: PipelineStepID? = nil
    /// Progress of the current step, 0...1.
    var fraction: Double = 0
    /// Steps whose output is current (run or fresh) in this job.
    var completed: Set<PipelineStepID> = []
    /// Steps that failed in this job, with a reason for the log.
    var failed: [PipelineStepID: String] = [:]

    /// An idle state.
    init() {}
}

/// The memory variant a step may run in (D17).
enum StepVariant: Equatable, Sendable {
    /// The full budget plus headroom fits.
    case full
    /// Only the reduced budget plus headroom fits.
    case reduced
    /// Neither fits: the step is recorded as `MapperError.outOfMemory(step:)`.
    case refuse
}

/// Events the runner feeds into `ProcessingGuards.reduce`.
enum ProcessingEvent: Equatable, Sendable {
    /// A job for the project was queued.
    case queued
    /// A step started.
    case started(PipelineStepID)
    /// Progress of the current step, 0...1.
    case progress(Double)
    /// A step finished and its stamp was recorded.
    case stepCompleted(PipelineStepID)
    /// A step was skipped because its stamp is fresh.
    case stepSkipped(PipelineStepID)
    /// A step failed or could not run; `optional` tells whether the job may still complete.
    case stepFailed(PipelineStepID, reason: String, optional: Bool)
    /// The job started or stopped waiting for the phone to cool down.
    case pausedForHeat(Bool)
    /// The job ended (completed, failed, cancelled or interrupted).
    case finished
}

/// Failure bookkeeping for one job run (pure; the runner derives the outcome from it).
struct PipelineJobLedger: Equatable, Sendable {
    /// Keys of steps that failed or could not run.
    private(set) var failedKeys: Set<ScheduledStepKey> = []
    /// The first required step that failed, with its error.
    private(set) var firstRequiredStep: PipelineStepID? = nil
    /// The error of `firstRequiredStep`.
    private(set) var firstRequiredError: MapperError? = nil
    /// Optional steps that produced no output, in failure order, without duplicates.
    private(set) var skippedOptional: [PipelineStepID] = []

    /// An empty ledger.
    init() {}

    /// Records that `scheduled` failed with `error`.
    mutating func recordFailure(_ scheduled: ScheduledStep, error: MapperError) {
        failedKeys.insert(scheduled.key)
        if scheduled.isOptional {
            if !skippedOptional.contains(scheduled.stepID) { skippedOptional.append(scheduled.stepID) }
        } else if firstRequiredStep == nil {
            firstRequiredStep = scheduled.stepID
            firstRequiredError = error
        }
    }

    /// The outcome of the job once nothing runnable is left.
    func outcome(cancelled: Bool) -> ProcessingOutcome {
        if cancelled { return .cancelled }
        if let step = firstRequiredStep {
            let error = firstRequiredError ?? MapperError.processingFailed(step: step, reason: "failed")
            return .failed(step: step, error: error)
        }
        return .completed(skippedOptional: skippedOptional)
    }
}
