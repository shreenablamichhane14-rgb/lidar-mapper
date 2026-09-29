import Foundation

/// Why a running job was asked to stop. Lock-protected: steps read it from their own threads
/// through `StepContext.isCancelled`.
final class PipelineCancelFlag: @unchecked Sendable {
    /// The stop request.
    enum Reason: Equatable, Sendable {
        /// No stop requested: keep going.
        case proceed
        /// The user cancelled (or the project is gone): the job ends as `.cancelled`.
        case cancelled
        /// `suspendAll`: the job stops and stays queued.
        case suspended
    }

    /// Guards `value`.
    private let lock = NSLock()
    /// The current request.
    private var value: Reason = .proceed

    /// A flag with no request.
    init() {}

    /// The current request.
    var reason: Reason {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    /// True when the job should stop.
    var isSet: Bool { reason != .proceed }

    /// Requests a stop. A user cancel wins over a suspension; a suspension never downgrades
    /// a cancel.
    func set(_ reason: Reason) {
        lock.lock()
        defer { lock.unlock() }
        switch reason {
        case .proceed:
            return
        case .cancelled:
            value = .cancelled
        case .suspended:
            if value == .proceed { value = .suspended }
        }
    }
}

/// Throttled progress relay for one step run: delivers at most one update per 0.1 s
/// (`ProcessingGuards.shouldPublish`). `report` may be called from any thread.
final class PipelineProgressSink: @unchecked Sendable {
    /// Guards `last`.
    private let lock = NSLock()
    /// Uptime of the last delivered update.
    private var last: Double?
    /// Identifies the step run, so late updates of an earlier step are dropped.
    private let token: UUID
    /// Hands an update to the runner (hops to main itself).
    private let deliver: @Sendable (UUID, Double) -> Void

    /// Creates a sink for one step run.
    init(token: UUID, deliver: @escaping @Sendable (UUID, Double) -> Void) {
        self.token = token
        self.deliver = deliver
    }

    /// Offers a progress value 0...1; drops it when the previous one is under 0.1 s old.
    func report(_ fraction: Double) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let publish = ProcessingGuards.shouldPublish(now: now, last: last)
        if publish { last = now }
        lock.unlock()
        if publish { deliver(token, fraction) }
    }
}

/// Holds a step object so it can cross into a detached task. The runner uses the step on one
/// task at a time (never concurrently), which is what makes the unchecked conformance safe.
final class PipelineStepBox: @unchecked Sendable {
    /// The step.
    let step: ProcessingStep

    /// Wraps a step.
    init(_ step: ProcessingStep) {
        self.step = step
    }
}

/// The file and step work of one step run, called by `ProcessingRunner` inside
/// `Task.detached` so the main thread never blocks. The runner is the only caller, which
/// makes it the only reader and writer of `derived/index.json` and the attempt marker.
enum PipelineStepExecutor {
    /// Everything read before a step runs.
    struct Plan: Sendable {
        /// The manifest at the time.
        var manifest: ProjectManifest
        /// The step's input hash with the real available memory.
        var inputHash: String
        /// The crash-loop decision.
        var decision: AttemptDecision
        /// The marker of an earlier interrupted attempt of this step, if any.
        var previous: PipelineAttempt?
        /// `memoryBudgetBytes`.
        var budget: UInt64
        /// `reducedMemoryBudgetBytes`.
        var reducedBudget: UInt64?
        /// A marker left by a death in another step or subject. There is one marker file, so
        /// this step's own marker replaces it while it runs; it is put back afterwards so the
        /// death still counts when that other step runs.
        var foreign: PipelineAttempt?
    }

    /// Result of `prepare`.
    enum Preparation: Sendable {
        /// The package folder no longer exists (the project was deleted).
        case projectMissing
        /// The stamp is fresh; the step is skipped.
        case fresh
        /// The step died `count` times already: record `outOfMemory` without running.
        case giveUp(count: Int)
        /// The manifest or the input hash could not be read.
        case failed(MapperError)
        /// The step must run.
        case needsRun(Plan)
    }

    /// How a step is launched.
    struct Launch: Sendable {
        /// Full or reduced.
        var variant: StepVariant
        /// The `StepContext.availableMemory` passed to the step (capped for reduced).
        var passedMemory: UInt64
        /// `os_proc_available_memory()` before the start.
        var measuredMemory: UInt64
        /// The hash to stamp on success (computed with the passed memory).
        var inputHash: String
        /// Thermal state name at the start.
        var thermal: String
        /// Attempt number written to the marker.
        var attempt: Int
    }

    /// Result of `gate`.
    enum Gate: Sendable {
        /// The package folder no longer exists.
        case projectMissing
        /// Neither variant fits in the available memory.
        case refused(available: UInt64)
        /// Run with these settings (the marker is written).
        case go(Launch)
    }

    /// Result of `run`.
    enum RunResult: Sendable {
        /// The step returned normally.
        case success(seconds: Double, memoryAfter: UInt64)
        /// The step threw; `detail` is the original error text for the log.
        case failure(MapperError, detail: String, seconds: Double, memoryAfter: UInt64)
    }

    /// Suffix added to the stamped input hash of a reduced run chosen for memory or heat, so
    /// that result is never fresh: the next job for the project (Retry, a resume) runs the step
    /// again, full when memory allows, and the steps that hash this stamp follow.
    static let reducedStampSuffix = "+reduced"

    /// The hash to stamp for a run of `variant`: the input hash, plus `reducedStampSuffix` for
    /// a reduced run. `afterDeath` (the run followed a death in this step, attempt 2 or more)
    /// keeps the plain hash: the full variant already killed the app once, so a Retry must not
    /// try it again.
    static func stampHash(_ inputHash: String, variant: StepVariant, afterDeath: Bool = false) -> String {
        variant == .reduced && !afterDeath ? inputHash + reducedStampSuffix : inputHash
    }

    /// Reads the manifest, computes the input hash, checks the stamp and the crash-loop marker.
    /// A marker that ended outside the foreground (`PipelineAttempt.endedOutsideForeground`)
    /// is removed and not counted as a death.
    static func prepare(box: PipelineStepBox, stepID: PipelineStepID, subject: UUID?,
                        package: ProjectPackage, flag: PipelineCancelFlag) -> Preparation {
        guard packageExists(package) else { return .projectMissing }
        let manifest: ProjectManifest
        do {
            manifest = try ProjectStore.readManifest(package)
        } catch {
            return .failed(MapperError.corruptProject("manifest unreadable: \(error)"))
        }
        let ctx = context(package: package, manifest: manifest, availableMemory: ProcessingGuards.availableMemory(),
                          flag: flag, progress: { _ in })
        let hash: String
        do {
            hash = try box.step.inputHash(ctx)
        } catch {
            return .failed(mapped(error, step: stepID))
        }
        var marker = PipelineAttempt.load(from: package)
        if let left = marker, left.endedOutsideForeground {
            LogStore.shared.write("attempt marker of \(left.step.rawValue) ended outside the foreground; not counted as a death",
                                  category: "pipeline")
            PipelineAttempt.remove(from: package)
            marker = nil
        }
        let markerMatches = marker?.matches(step: stepID, subject: subject) ?? false
        let index = readIndex(package)
        if ProcessingGuards.shouldSkip(index: index, step: stepID, subject: subject, inputHash: hash) {
            if markerMatches { PipelineAttempt.remove(from: package) }
            return .fresh
        }
        let previous: PipelineAttempt? = markerMatches ? marker : nil
        let foreign: PipelineAttempt? = markerMatches ? nil : marker
        let reduced = box.step.reducedMemoryBudgetBytes
        let decision = PipelineAttempt.decision(previous: previous, hasReducedVariant: reduced != nil)
        if decision == .giveUp {
            PipelineAttempt.remove(from: package)
            return .giveUp(count: previous?.count ?? 0)
        }
        let plan = Plan(manifest: manifest, inputHash: hash, decision: decision, previous: previous,
                        budget: box.step.memoryBudgetBytes, reducedBudget: reduced, foreign: foreign)
        return .needsRun(plan)
    }

    /// Applies the memory gate (D17), forces the reduced variant after a death or at thermal
    /// `.serious`, and writes the attempt marker (count + 1, with the current foreground state)
    /// right before the run.
    static func gate(box: PipelineStepBox, stepID: PipelineStepID, subject: UUID?, package: ProjectPackage,
                     plan: Plan, flag: PipelineCancelFlag) -> Gate {
        guard packageExists(package) else { return .projectMissing }
        let available = ProcessingGuards.availableMemory()
        let thermal = ProcessInfo.processInfo.thermalState
        var variant = ProcessingGuards.variant(available: available, budget: plan.budget, reduced: plan.reducedBudget)
        if variant == .refuse { return .refused(available: available) }
        let hotAndReducible = ProcessingGuards.isHot(thermal) && plan.reducedBudget != nil
        if plan.decision == .runReduced || hotAndReducible { variant = .reduced }
        let passed = variant == .reduced
            ? ProcessingGuards.reducedMemoryCap(available: available, budget: plan.budget)
            : available
        var runHash = plan.inputHash
        if passed != available {
            let capped = context(package: package, manifest: plan.manifest, availableMemory: passed,
                                 flag: flag, progress: { _ in })
            if let hash = try? box.step.inputHash(capped) { runHash = hash }
        }
        let attempt = PipelineAttempt.next(after: plan.previous, step: stepID, subject: subject,
                                           variant: variant, now: Date())
        do {
            try PipelineAttempt.begin(attempt, in: package)
        } catch {
            guard packageExists(package) else { return .projectMissing }
            LogStore.shared.write("attempt marker not written for \(stepID.rawValue): \(error)", category: "pipeline")
        }
        let launch = Launch(variant: variant, passedMemory: passed, measuredMemory: available, inputHash: runHash,
                            thermal: ProcessingGuards.thermalName(thermal), attempt: attempt.count)
        return .go(launch)
    }

    /// Runs the step with its context; never throws (errors become `RunResult.failure`).
    static func run(box: PipelineStepBox, stepID: PipelineStepID, package: ProjectPackage, manifest: ProjectManifest,
                    availableMemory: UInt64, flag: PipelineCancelFlag, sink: PipelineProgressSink) async -> RunResult {
        let start = ProcessInfo.processInfo.systemUptime
        let ctx = context(package: package, manifest: manifest, availableMemory: availableMemory,
                          flag: flag, progress: { fraction in sink.report(fraction) })
        do {
            try await box.step.run(ctx)
            let seconds = ProcessInfo.processInfo.systemUptime - start
            return .success(seconds: seconds, memoryAfter: ProcessingGuards.availableMemory())
        } catch {
            let seconds = ProcessInfo.processInfo.systemUptime - start
            return .failure(mapped(error, step: stepID), detail: "\(error)", seconds: seconds,
                            memoryAfter: ProcessingGuards.availableMemory())
        }
    }

    /// Records the step's stamp in `derived/index.json` (atomic) and ends the attempt (see
    /// `endAttempt`). Returns false when the index could not be written (the step then reruns
    /// next time).
    static func recordSuccess(stepID: PipelineStepID, subject: UUID?, inputHash: String,
                              package: ProjectPackage, now: Date, restoring foreign: PipelineAttempt? = nil) -> Bool {
        guard packageExists(package) else { return false }
        var index = readIndex(package)
        index.record(DerivedStamp(step: stepID, subject: subject, pipelineVersion: ProjectManifest.currentPipelineVersion,
                                  inputHash: inputHash, createdAt: now))
        var written = true
        do {
            try writeIndex(index, to: package)
        } catch {
            written = false
            LogStore.shared.write("index not written after \(stepID.rawValue): \(error)", category: "pipeline")
        }
        endAttempt(package: package, restoring: foreign)
        return written
    }

    /// After a failure or an interruption: ends the attempt (the app did not die).
    static func recordFailure(package: ProjectPackage, restoring foreign: PipelineAttempt? = nil) {
        endAttempt(package: package, restoring: foreign)
    }

    /// The app left or re-entered the foreground while `stepID` of `subject` runs: its marker
    /// takes the current `PipelineForeground` state (`PipelineAttempt.syncForeground`).
    static func syncForeground(package: ProjectPackage, stepID: PipelineStepID, subject: UUID?) {
        guard packageExists(package) else { return }
        PipelineAttempt.syncForeground(package: package, step: stepID, subject: subject)
    }

    /// Deletes the marker of the step that just ended, or puts back `foreign` (the marker of
    /// another step that died earlier, `Plan.foreign`) so the crash-loop guard still sees it.
    static func endAttempt(package: ProjectPackage, restoring foreign: PipelineAttempt?) {
        guard let foreign else {
            PipelineAttempt.remove(from: package)
            return
        }
        guard packageExists(package) else { return }
        do {
            try PipelineAttempt.save(foreign, to: package)
        } catch {
            LogStore.shared.write("attempt marker of \(foreign.step.rawValue) not restored: \(error)", category: "pipeline")
        }
    }

    // MARK: - Helpers

    /// A step context whose cancel check reads `flag`.
    static func context(package: ProjectPackage, manifest: ProjectManifest, availableMemory: UInt64,
                        flag: PipelineCancelFlag, progress: @escaping (Double) -> Void) -> StepContext {
        StepContext(package: package, manifest: manifest, availableMemory: availableMemory,
                    isCancelled: { flag.isSet }, progress: progress)
    }

    /// `derived/index.json`, or an empty index when it is missing or unreadable (logged; the
    /// steps then rerun and rewrite it).
    static func readIndex(_ package: ProjectPackage) -> DerivedIndex {
        let url = package.derivedIndexURL
        guard FileManager.default.fileExists(atPath: url.path) else { return DerivedIndex() }
        do {
            return try ProjectStore.readJSON(DerivedIndex.self, from: url)
        } catch {
            LogStore.shared.write("index unreadable, starting empty: \(error)", category: "pipeline")
            return DerivedIndex()
        }
    }

    /// Writes `derived/index.json` atomically; `derived/` is created only while the package exists.
    static func writeIndex(_ index: DerivedIndex, to package: ProjectPackage) throws {
        try ProjectStore.ensureDirectory(package.derivedURL, inside: package.root)
        try ProjectStore.writeJSON(index, to: package.derivedIndexURL, createParents: false)
    }

    /// True when the package folder exists.
    static func packageExists(_ package: ProjectPackage) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: package.root.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    /// Maps any error a step throws to `MapperError`.
    static func mapped(_ error: Error, step: PipelineStepID) -> MapperError {
        if let mapper = error as? MapperError { return mapper }
        if error is CancellationError { return .cancelled }
        return .processingFailed(step: step, reason: "\(error)")
    }
}
