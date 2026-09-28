import Foundation

/// What the runner does with a step when it finds a crash-loop marker for it.
enum AttemptDecision: Equatable, Sendable {
    /// No earlier death: run normally.
    case run
    /// One earlier death: run forcing the reduced variant.
    case runReduced
    /// Two earlier deaths, or one with no reduced variant: record
    /// `MapperError.outOfMemory(step:)` without running.
    case giveUp
}

/// Crash-loop guard (`derived/pipeline_attempt.json`, `ProjectPackage.pipelineAttemptURL`),
/// written atomically before `step.run` and deleted after its stamp or failure is recorded.
/// A marker still present when a job reaches the same step means the app died inside it.
/// Only `ProcessingRunner` (through `PipelineStepExecutor`) reads and writes it.
struct PipelineAttempt: Codable, Equatable, Sendable {
    /// Variant name written for a full run.
    static let fullVariant = "full"
    /// Variant name written for a reduced run.
    static let reducedVariant = "reduced"

    /// The step that was running.
    var step: PipelineStepID
    /// Its subject (room or object), nil for project-wide steps.
    var subject: UUID?
    /// `fullVariant` or `reducedVariant`.
    var variant: String
    /// How many times this step was started without its stamp or failure being recorded.
    var count: Int
    /// When the latest attempt started.
    var startedAt: Date

    /// Creates a marker (same shape as the memberwise initializer, `subject` defaults to nil).
    init(step: PipelineStepID, subject: UUID? = nil, variant: String, count: Int, startedAt: Date) {
        self.step = step
        self.subject = subject
        self.variant = variant
        self.count = count
        self.startedAt = startedAt
    }

    /// True when the marker names this step and subject.
    func matches(step: PipelineStepID, subject: UUID?) -> Bool {
        self.step == step && self.subject == subject
    }

    /// Pure: what to do when a job starts and a marker for this step exists (the app died in it).
    /// count 0 (no marker): run normally; count 1: run forcing the reduced variant (refuse when there
    /// is none); count 2 or more: do not run, record `MapperError.outOfMemory(step:)`.
    static func decision(previous: PipelineAttempt?, hasReducedVariant: Bool) -> AttemptDecision {
        let count = previous?.count ?? 0
        if count <= 0 { return .run }
        if count == 1 { return hasReducedVariant ? .runReduced : .giveUp }
        return .giveUp
    }

    /// The marker to write before the next attempt of a step, counting the earlier attempt
    /// when `previous` names the same step and subject.
    static func next(after previous: PipelineAttempt?, step: PipelineStepID, subject: UUID?,
                     variant: StepVariant, now: Date) -> PipelineAttempt {
        let earlier = (previous?.matches(step: step, subject: subject) ?? false) ? (previous?.count ?? 0) : 0
        let name = variant == .reduced ? reducedVariant : fullVariant
        return PipelineAttempt(step: step, subject: subject, variant: name, count: earlier + 1, startedAt: now)
    }

    // MARK: - File (runner only)

    /// The marker of a package, or nil when there is none. An unreadable marker is logged,
    /// removed and treated as absent.
    static func load(from package: ProjectPackage) -> PipelineAttempt? {
        let url = package.pipelineAttemptURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try ProjectStore.readJSON(PipelineAttempt.self, from: url, maxBytes: 64 * 1024)
        } catch {
            LogStore.shared.write("attempt marker unreadable, removed: \(error)", category: "pipeline")
            remove(from: package)
            return nil
        }
    }

    /// Writes the marker atomically into `derived/`, creating `derived/` only while the
    /// package exists (a deleted project is never recreated, CR-6).
    static func save(_ attempt: PipelineAttempt, to package: ProjectPackage) throws {
        try ProjectStore.ensureDirectory(package.derivedURL, inside: package.root)
        try ProjectStore.writeJSON(attempt, to: package.pipelineAttemptURL, createParents: false)
    }

    /// Deletes the marker when present; a failure is logged.
    static func remove(from package: ProjectPackage) {
        let url = package.pipelineAttemptURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            LogStore.shared.write("attempt marker not removed: \(error)", category: "pipeline")
        }
    }
}
