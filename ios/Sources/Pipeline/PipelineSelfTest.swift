import Foundation

/// Plain-Swift checks for the Pipeline module (no XCTest). They cover the pure parts: the
/// memory gate, stamp freshness, the state reducer, the progress throttle, the dependency
/// planner, the crash-loop decision, the idle-timer rule, the job queue and the cancel flag,
/// plus the executor's file work on a temporary package. The runner itself is async and
/// main-actor, so it is covered by the device smoke test. `run()` returns one line per
/// failing check; empty means all passed. Deterministic, no ARKit, camera or network.
enum PipelineSelfTest {
    /// Collects failures.
    final class Recorder {
        /// Failing checks as "name: detail".
        private(set) var failures: [String] = []
        /// Number of checks made.
        private(set) var count = 0

        /// Records a failure when `condition` is false.
        func check(_ name: String, _ condition: Bool, _ detail: String = "") {
            count += 1
            if !condition { failures.append(detail.isEmpty ? name : "\(name): \(detail)") }
        }
    }

    /// Fixed identifiers (no randomness in the checks).
    static let roomA = UUID(uuidString: "00000000-0000-0000-0000-00000000000A") ?? UUID()
    /// Second fixed room.
    static let roomB = UUID(uuidString: "00000000-0000-0000-0000-00000000000B") ?? UUID()
    /// Fixed project identifiers for the queue checks.
    static let projectA = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1") ?? UUID()
    /// Second fixed project.
    static let projectB = UUID(uuidString: "00000000-0000-0000-0000-0000000000B1") ?? UUID()
    /// Third fixed project.
    static let projectC = UUID(uuidString: "00000000-0000-0000-0000-0000000000C1") ?? UUID()
    /// A fixed date with whole seconds (ISO 8601 round trips exactly).
    static let fixedDate = Date(timeIntervalSince1970: 1_790_000_000)

    /// Runs every check. Failing checks as "name: detail".
    static func run() -> [String] {
        let r = Recorder()
        checkVariant(r)
        checkStamps(r)
        checkReduce(r)
        checkThrottleAndIdle(r)
        checkPlanner(r)
        checkAttempt(r)
        checkQueue(r)
        checkFlagAndLedger(r)
        checkFiles(r)
        return r.failures
    }

    // MARK: - Memory gate

    /// `ProcessingGuards.variant` boundaries and the reduced cap.
    static func checkVariant(_ r: Recorder) {
        let budget: UInt64 = 700_000_000
        let reduced: UInt64 = 350_000_000
        r.check("variant.fullAtBoundary", ProcessingGuards.variant(available: 1_000_000_000, budget: budget, reduced: reduced) == .full)
        r.check("variant.reducedJustBelowFull", ProcessingGuards.variant(available: 999_999_999, budget: budget, reduced: reduced) == .reduced)
        r.check("variant.reducedAtBoundary", ProcessingGuards.variant(available: 650_000_000, budget: budget, reduced: reduced) == .reduced)
        r.check("variant.refuseBelowReduced", ProcessingGuards.variant(available: 649_999_999, budget: budget, reduced: reduced) == .refuse)
        r.check("variant.noReducedRefuses", ProcessingGuards.variant(available: 999_999_999, budget: budget, reduced: nil) == .refuse)
        r.check("variant.noReducedFull", ProcessingGuards.variant(available: 1_000_000_000, budget: budget, reduced: nil) == .full)
        r.check("variant.hugeBudgetNoOverflow", ProcessingGuards.variant(available: 5, budget: UInt64.max, reduced: nil) == .refuse)
        r.check("variant.capBelowBudget", ProcessingGuards.reducedMemoryCap(available: 2_000_000_000, budget: budget) == budget - 1)
        r.check("variant.capKeepsLowerAvailable", ProcessingGuards.reducedMemoryCap(available: 500_000_000, budget: budget) == 500_000_000)
        r.check("variant.capZeroBudget", ProcessingGuards.reducedMemoryCap(available: 500_000_000, budget: 0) == 0)
        r.check("variant.saturatingAdd", ProcessingGuards.saturatingAdd(UInt64.max - 1, 5) == UInt64.max)
    }

    // MARK: - Stamps

    /// `shouldSkip` and `DerivedIndex.record`.
    static func checkStamps(_ r: Recorder) {
        let version = ProjectManifest.currentPipelineVersion
        var index = DerivedIndex()
        index.record(DerivedStamp(step: .consolidateMesh, subject: roomA, pipelineVersion: version, inputHash: "abc", createdAt: fixedDate))
        r.check("skip.sameHashAndSubject", ProcessingGuards.shouldSkip(index: index, step: .consolidateMesh, subject: roomA, inputHash: "abc"))
        r.check("skip.otherHash", !ProcessingGuards.shouldSkip(index: index, step: .consolidateMesh, subject: roomA, inputHash: "abd"))
        r.check("skip.otherSubject", !ProcessingGuards.shouldSkip(index: index, step: .consolidateMesh, subject: roomB, inputHash: "abc"))
        r.check("skip.nilSubject", !ProcessingGuards.shouldSkip(index: index, step: .consolidateMesh, subject: nil, inputHash: "abc"))
        r.check("skip.otherStep", !ProcessingGuards.shouldSkip(index: index, step: .quality, subject: roomA, inputHash: "abc"))
        var stale = DerivedIndex()
        stale.record(DerivedStamp(step: .cleanModel, subject: nil, pipelineVersion: version + 1, inputHash: "abc", createdAt: fixedDate))
        r.check("skip.otherVersion", !ProcessingGuards.shouldSkip(index: stale, step: .cleanModel, subject: nil, inputHash: "abc"))

        var replacing = DerivedIndex()
        replacing.record(DerivedStamp(step: .cleanModel, subject: nil, pipelineVersion: version, inputHash: "one", createdAt: fixedDate))
        replacing.record(DerivedStamp(step: .cleanModel, subject: nil, pipelineVersion: version, inputHash: "two", createdAt: fixedDate))
        let clean = replacing.stamps.filter { $0.step == .cleanModel }
        r.check("index.recordReplaces", clean.count == 1 && clean.first?.inputHash == "two", "\(clean.count) stamps")
        replacing.record(DerivedStamp(step: .quality, subject: roomA, pipelineVersion: version, inputHash: "q", createdAt: fixedDate))
        replacing.record(DerivedStamp(step: .quality, subject: roomB, pipelineVersion: version, inputHash: "q", createdAt: fixedDate))
        r.check("index.recordKeepsOtherSubjects", replacing.stamps.count == 3, "\(replacing.stamps.count) stamps")
    }

    // MARK: - Reducer

    /// `ProcessingGuards.reduce` for every event.
    static func checkReduce(_ r: Recorder) {
        let idle = ProjectProcessingState()
        let queued = ProcessingGuards.reduce(idle, .queued)
        r.check("reduce.queued", queued.isQueued && !queued.isRunning)
        let started = ProcessingGuards.reduce(queued, .started(.consolidateMesh))
        let startedOK = started.isRunning && !started.isQueued && started.currentStep == .consolidateMesh
        r.check("reduce.started", startedOK && started.fraction == 0)
        let progressed = ProcessingGuards.reduce(started, .progress(0.4))
        r.check("reduce.progress", progressed.fraction == 0.4)
        r.check("reduce.progressClamped", ProcessingGuards.reduce(started, .progress(1.7)).fraction == 1)
        r.check("reduce.progressIgnoredWhenIdle", ProcessingGuards.reduce(idle, .progress(0.5)) == idle)
        let completed = ProcessingGuards.reduce(progressed, .stepCompleted(.consolidateMesh))
        let completedOK = completed.completed.contains(.consolidateMesh) && completed.currentStep == nil
        r.check("reduce.stepCompleted", completedOK && completed.isRunning && completed.fraction == 0)
        let skipped = ProcessingGuards.reduce(completed, .stepSkipped(.buildRoom))
        r.check("reduce.stepSkipped", skipped.completed.contains(.buildRoom) && skipped.isRunning)

        let texturing = ProcessingGuards.reduce(skipped, .started(.textureLow))
        let optionalFailed = ProcessingGuards.reduce(texturing, .stepFailed(.textureLow, reason: "bake", optional: true))
        let optionalOK = optionalFailed.failed[.textureLow] == "bake" && optionalFailed.currentStep == nil
        r.check("reduce.stepFailedOptionalContinues", optionalOK && optionalFailed.isRunning)
        let planning = ProcessingGuards.reduce(optionalFailed, .started(.floorPlan))
        let requiredFailed = ProcessingGuards.reduce(planning, .stepFailed(.floorPlan, reason: "plan", optional: false))
        let requiredOK = requiredFailed.failed[.floorPlan] == "plan" && !requiredFailed.completed.contains(.floorPlan)
        r.check("reduce.stepFailedRequired", requiredOK && requiredFailed.isRunning && requiredFailed.failed.count == 2)
        let recovered = ProcessingGuards.reduce(requiredFailed, .stepCompleted(.floorPlan))
        r.check("reduce.completedClearsFailure", recovered.failed[.floorPlan] == nil && recovered.completed.contains(.floorPlan))

        let hot = ProcessingGuards.reduce(started, .pausedForHeat(true))
        r.check("reduce.pausedForHeat", hot.isPausedForHeat && hot.currentStep == .consolidateMesh)
        r.check("reduce.heatCleared", !ProcessingGuards.reduce(hot, .pausedForHeat(false)).isPausedForHeat)
        let finished = ProcessingGuards.reduce(ProcessingGuards.reduce(requiredFailed, .pausedForHeat(true)), .finished)
        let finishedIdle = !finished.isRunning && !finished.isQueued && !finished.isPausedForHeat && finished.currentStep == nil
        r.check("reduce.finished", finishedIdle && finished.failed.count == 2 && finished.completed.contains(.consolidateMesh))
    }

    // MARK: - Throttle and idle timer

    /// `shouldPublish` and `IdleTimerGuard.shouldDisable`.
    static func checkThrottleAndIdle(_ r: Recorder) {
        r.check("publish.first", ProcessingGuards.shouldPublish(now: 10, last: nil))
        r.check("publish.drops50ms", !ProcessingGuards.shouldPublish(now: 10.05, last: 10))
        r.check("publish.passes200ms", ProcessingGuards.shouldPublish(now: 10.2, last: 10))
        r.check("idle.zeroHolders", !IdleTimerGuard.shouldDisable(holders: 0))
        r.check("idle.twoHolders", IdleTimerGuard.shouldDisable(holders: 2))
        r.check("thermal.hot", ProcessingGuards.isHot(.serious) && ProcessingGuards.isHot(.critical))
        r.check("thermal.cool", !ProcessingGuards.isHot(.nominal) && !ProcessingGuards.isHot(.fair))
    }

    // MARK: - Planner

    /// `runnable`, `failedDependency` and `ordered`.
    static func checkPlanner(_ r: Recorder) {
        let build = ScheduledStep(PipelineSelfTestStep(.buildRoom), subject: roomA, isOptional: false)
        let consolidate = ScheduledStep(PipelineSelfTestStep(.consolidateMesh), subject: roomA, isOptional: true)
        let clean = ScheduledStep(PipelineSelfTestStep(.cleanModel), dependsOn: [build.key])
        let plan = ScheduledStep(PipelineSelfTestStep(.floorPlan), dependsOn: [clean.key])
        let steps = [build, consolidate, clean, plan]
        r.check("planner.allRunnable", ProcessingGuards.runnable(steps, failed: []) == steps.map { $0.key })
        let afterFailure = ProcessingGuards.runnable(steps, failed: [build.key])
        r.check("planner.independentKeepsRunning", afterFailure.contains(consolidate.key))
        r.check("planner.dropsDependent", !afterFailure.contains(clean.key))
        r.check("planner.dropsTransitive", !afterFailure.contains(plan.key) && afterFailure.count == 1, "\(afterFailure.map { $0.logName })")
        let blocker = ProcessingGuards.failedDependency(of: plan, in: steps, failed: [build.key])
        r.check("planner.failedDependency", blocker == clean.key)
        let reordered = ProcessingGuards.ordered([plan, clean, build, consolidate]).map { $0.key }
        r.check("planner.orderedPutsDependenciesFirst", reordered == [build.key, clean.key, plan.key, consolidate.key],
                "\(reordered.map { $0.logName })")
        let duplicate = ProcessingGuards.ordered([build, build, consolidate])
        r.check("planner.orderedDropsDuplicates", duplicate.count == 2)
        let loopA = ScheduledStep(PipelineSelfTestStep(.mergeStructure), dependsOn: [ScheduledStepKey(step: .alignRooms)])
        let loopB = ScheduledStep(PipelineSelfTestStep(.alignRooms), dependsOn: [ScheduledStepKey(step: .mergeStructure)])
        let cycle = ProcessingGuards.ordered([loopA, loopB]).map { $0.key }
        r.check("planner.cycleKeepsOrder", cycle == [loopA.key, loopB.key])
        let external = ScheduledStep(PipelineSelfTestStep(.thumbnail), dependsOn: [ScheduledStepKey(step: .reconstructObject)])
        r.check("planner.externalDependencySatisfied", ProcessingGuards.runnable([external], failed: []) == [external.key])
    }

    // MARK: - Crash-loop guard

    /// `PipelineAttempt.decision` and `next`.
    static func checkAttempt(_ r: Recorder) {
        let once = PipelineAttempt(step: .consolidateMesh, subject: roomA, variant: PipelineAttempt.fullVariant, count: 1, startedAt: fixedDate)
        let twice = PipelineAttempt(step: .consolidateMesh, subject: roomA, variant: PipelineAttempt.reducedVariant, count: 2, startedAt: fixedDate)
        r.check("attempt.noMarkerRuns", PipelineAttempt.decision(previous: nil, hasReducedVariant: true) == .run)
        r.check("attempt.onceRunsReduced", PipelineAttempt.decision(previous: once, hasReducedVariant: true) == .runReduced)
        r.check("attempt.onceWithoutReducedGivesUp", PipelineAttempt.decision(previous: once, hasReducedVariant: false) == .giveUp)
        r.check("attempt.twiceGivesUp", PipelineAttempt.decision(previous: twice, hasReducedVariant: true) == .giveUp)
        let next = PipelineAttempt.next(after: once, step: .consolidateMesh, subject: roomA, variant: .reduced, now: fixedDate)
        r.check("attempt.nextCounts", next.count == 2 && next.variant == PipelineAttempt.reducedVariant)
        let other = PipelineAttempt.next(after: once, step: .consolidateMesh, subject: roomB, variant: .full, now: fixedDate)
        r.check("attempt.nextOtherSubjectStartsAtOne", other.count == 1 && other.variant == PipelineAttempt.fullVariant)
        do {
            let data = try ProjectStore.encoder.encode(twice)
            let decoded = try ProjectStore.decoder.decode(PipelineAttempt.self, from: data)
            r.check("attempt.jsonRoundTrip", decoded == twice)
        } catch {
            r.check("attempt.jsonRoundTrip", false, "\(error)")
        }
    }

    // MARK: - Queue

    /// Suspend and resume keep the job queued; replacement and front insertion.
    static func checkQueue(_ r: Recorder) {
        var queue = PipelineJobQueue<String>()
        queue.enqueue("A", projectID: projectA, atFront: false)
        queue.enqueue("B", projectID: projectB, atFront: false)
        r.check("queue.startsFirst", queue.startNext()?.entry == "A")
        r.check("queue.oneAtATime", queue.startNext() == nil)
        queue.suspend()
        r.check("queue.suspendRequeues", queue.finishRunning(requeue: true) == nil && queue.waitingProjectIDs == [projectA, projectB])
        r.check("queue.nothingStartsSuspended", queue.startNext() == nil && queue.running == nil)
        queue.resume()
        r.check("queue.resumeRestartsInterrupted", queue.startNext()?.entry == "A")
        var index = DerivedIndex()
        index.record(DerivedStamp(step: .buildRoom, subject: roomA, pipelineVersion: ProjectManifest.currentPipelineVersion,
                                  inputHash: "h1", createdAt: fixedDate))
        let stampedSkips = ProcessingGuards.shouldSkip(index: index, step: .buildRoom, subject: roomA, inputHash: "h1")
        let unstampedRuns = !ProcessingGuards.shouldSkip(index: index, step: .consolidateMesh, subject: roomA, inputHash: "h2")
        r.check("queue.resumedStampedStepsSkip", stampedSkips && unstampedRuns)

        r.check("queue.replaceWaiting", queue.enqueue("B2", projectID: projectB, atFront: false) == "B")
        queue.enqueue("C", projectID: projectC, atFront: true)
        r.check("queue.atFront", queue.waitingProjectIDs == [projectC, projectB])
        queue.enqueue("A2", projectID: projectA, atFront: true)
        queue.suspend()
        r.check("queue.supersededNotRequeued", queue.finishRunning(requeue: true) == "A")
        r.check("queue.newerJobKept", queue.waitingProjectIDs == [projectA, projectC, projectB])
        r.check("queue.removeWaiting", queue.removeWaiting(projectID: projectC) == "C" && !queue.hasWaiting(projectC))
        r.check("queue.suspendedKeepsWaiting", queue.startNext() == nil && !queue.isEmpty)
    }

    // MARK: - Flag and ledger

    /// Cancel wins over suspend; the ledger's outcome.
    static func checkFlagAndLedger(_ r: Recorder) {
        let flag = PipelineCancelFlag()
        r.check("flag.startsClear", !flag.isSet)
        flag.set(.suspended)
        flag.set(.cancelled)
        r.check("flag.cancelWins", flag.reason == .cancelled)
        let cancelled = PipelineCancelFlag()
        cancelled.set(.cancelled)
        cancelled.set(.suspended)
        r.check("flag.suspendNeverDowngrades", cancelled.reason == .cancelled)

        let texture = ScheduledStep(PipelineSelfTestStep(.textureLow), subject: roomA, isOptional: true)
        let plan = ScheduledStep(PipelineSelfTestStep(.floorPlan))
        let clean = ScheduledStep(PipelineSelfTestStep(.cleanModel))
        var ledger = PipelineJobLedger()
        r.check("ledger.emptyCompletes", ledger.outcome(cancelled: false) == .completed(skippedOptional: []))
        ledger.recordFailure(texture, error: .processingFailed(step: .textureLow, reason: "x"))
        r.check("ledger.optionalCompletes", ledger.outcome(cancelled: false) == .completed(skippedOptional: [.textureLow]))
        ledger.recordFailure(plan, error: .outOfMemory(step: .floorPlan))
        ledger.recordFailure(clean, error: .cancelled)
        r.check("ledger.firstRequiredFails", ledger.outcome(cancelled: false) == .failed(step: .floorPlan, error: .outOfMemory(step: .floorPlan)))
        r.check("ledger.cancelled", ledger.outcome(cancelled: true) == .cancelled)
        r.check("ledger.failedKeys", ledger.failedKeys == [texture.key, plan.key, clean.key])
    }
}

/// A do-nothing step with a fixed hash and budgets, for the self-test.
final class PipelineSelfTestStep: ProcessingStep {
    /// Which step it pretends to be.
    let id: PipelineStepID
    /// Full budget, bytes.
    let memoryBudgetBytes: UInt64
    /// Reduced budget, bytes.
    let reducedMemoryBudgetBytes: UInt64?
    /// The input hash it reports.
    let hash: String

    /// Creates a fake step.
    init(_ id: PipelineStepID, budget: UInt64 = 50_000_000, reduced: UInt64? = nil, hash: String = "h") {
        self.id = id
        self.memoryBudgetBytes = budget
        self.reducedMemoryBudgetBytes = reduced
        self.hash = hash
    }

    /// Returns the fixed hash.
    func inputHash(_ ctx: StepContext) throws -> String {
        hash
    }

    /// Does nothing.
    func run(_ ctx: StepContext) async throws {
        try ctx.checkCancelled()
    }
}
