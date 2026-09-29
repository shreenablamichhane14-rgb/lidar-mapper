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
/// A marker still present when a job reaches the same step means the app died inside it,
/// unless it carries `backgroundedAt`: the app was then out of the foreground (inactive or in
/// the background) when it ended, which iOS or the user does to any app (a suspended app
/// reclaimed, a swipe from the app switcher, a new build installed), so it is not counted.
/// Only `ProcessingRunner` (through `PipelineStepExecutor`) reads and writes it; every file
/// access holds one lock, so a background mark never brings back a marker a step just ended.
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
    /// Set while the app is out of the foreground during this attempt (`PipelineForeground`);
    /// nil in the foreground. Older markers without the key decode as nil.
    var backgroundedAt: Date?

    /// Creates a marker (same shape as the memberwise initializer, `subject` and
    /// `backgroundedAt` default to nil).
    init(step: PipelineStepID, subject: UUID? = nil, variant: String, count: Int, startedAt: Date,
         backgroundedAt: Date? = nil) {
        self.step = step
        self.subject = subject
        self.variant = variant
        self.count = count
        self.startedAt = startedAt
        self.backgroundedAt = backgroundedAt
    }

    /// True when the attempt ended while the app was out of the foreground (not a death).
    var endedOutsideForeground: Bool { backgroundedAt != nil }

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

    /// Serializes every read and write of marker files (load, save, remove and the
    /// read-modify-write of `syncForeground`).
    private static let fileLock = NSLock()

    /// The marker of a package, or nil when there is none. An unreadable marker is logged,
    /// removed and treated as absent.
    static func load(from package: ProjectPackage) -> PipelineAttempt? {
        fileLock.lock()
        defer { fileLock.unlock() }
        return loadLocked(package)
    }

    /// Writes the marker atomically into `derived/`, creating `derived/` only while the
    /// package exists (a deleted project is never recreated, CR-6).
    static func save(_ attempt: PipelineAttempt, to package: ProjectPackage) throws {
        fileLock.lock()
        defer { fileLock.unlock() }
        try saveLocked(attempt, package)
    }

    /// Writes the marker of an attempt that starts now, with `backgroundedAt` taken from
    /// `PipelineForeground` under the file lock (so a foreground change is never missed).
    static func begin(_ attempt: PipelineAttempt, in package: ProjectPackage) throws {
        fileLock.lock()
        defer { fileLock.unlock() }
        var marked = attempt
        marked.backgroundedAt = PipelineForeground.shared.leftAt
        try saveLocked(marked, package)
    }

    /// Copies the current `PipelineForeground.leftAt` into the package's marker when it names
    /// `step` and `subject` (the step running now); any other marker, or none, is left alone.
    /// Returns true when the marker was rewritten.
    @discardableResult
    static func syncForeground(package: ProjectPackage, step: PipelineStepID, subject: UUID?) -> Bool {
        fileLock.lock()
        defer { fileLock.unlock() }
        guard var marker = loadLocked(package), marker.matches(step: step, subject: subject) else { return false }
        let leftAt = PipelineForeground.shared.leftAt
        guard marker.backgroundedAt != leftAt else { return false }
        marker.backgroundedAt = leftAt
        do {
            try saveLocked(marker, package)
            return true
        } catch {
            LogStore.shared.write("attempt marker foreground state not saved: \(error)", category: "pipeline")
            return false
        }
    }

    /// Deletes the marker when present; a failure is logged.
    static func remove(from package: ProjectPackage) {
        fileLock.lock()
        defer { fileLock.unlock() }
        removeLocked(package)
    }

    /// `load` with the lock held.
    private static func loadLocked(_ package: ProjectPackage) -> PipelineAttempt? {
        let url = package.pipelineAttemptURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try ProjectStore.readJSON(PipelineAttempt.self, from: url, maxBytes: 64 * 1024)
        } catch {
            LogStore.shared.write("attempt marker unreadable, removed: \(error)", category: "pipeline")
            removeLocked(package)
            return nil
        }
    }

    /// `save` with the lock held.
    private static func saveLocked(_ attempt: PipelineAttempt, _ package: ProjectPackage) throws {
        try ProjectStore.ensureDirectory(package.derivedURL, inside: package.root)
        try ProjectStore.writeJSON(attempt, to: package.pipelineAttemptURL, createParents: false)
    }

    /// `remove` with the lock held.
    private static func removeLocked(_ package: ProjectPackage) {
        let url = package.pipelineAttemptURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            LogStore.shared.write("attempt marker not removed: \(error)", category: "pipeline")
        }
    }
}

/// Whether the app is out of the foreground, for the crash-loop guard (`PipelineAttempt`).
/// `ProcessingRunner` sets it from the app lifecycle notifications on main; the executor reads
/// it from any thread. Lock-protected.
final class PipelineForeground: @unchecked Sendable {
    /// The app's state.
    static let shared = PipelineForeground()

    /// Guards `value`.
    private let lock = NSLock()
    /// When the app left the foreground; nil while it is in the foreground.
    private var value: Date?

    /// Starts in the foreground.
    init() {}

    /// When the app left the foreground, nil while it is in the foreground.
    var leftAt: Date? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    /// The app became inactive or went to the background. Returns true when this changed the
    /// state (the first of willResignActive and didEnterBackground).
    @discardableResult
    func leave(at date: Date) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard value == nil else { return false }
        value = date
        return true
    }

    /// The app is active again. Returns true when this changed the state.
    @discardableResult
    func enter() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard value != nil else { return false }
        value = nil
        return true
    }
}
