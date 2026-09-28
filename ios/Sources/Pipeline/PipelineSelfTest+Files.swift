import Foundation

extension PipelineSelfTest {
    /// The executor's file work on a temporary package under `temporaryDirectory` (removed
    /// afterwards): the index, the attempt marker and the decisions of `prepare`.
    static func checkFiles(_ r: Recorder) {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("mapper-pipeline-selftest", isDirectory: true)
        try? fm.removeItem(at: folder)
        defer { try? fm.removeItem(at: folder) }
        let package = ProjectPackage(root: folder.appendingPathComponent("SelfTest.mapperproj", isDirectory: true))
        do {
            try ProjectStore.writeManifest(ProjectManifest.new(kind: .room, name: "Self Test", now: fixedDate), to: package)
        } catch {
            r.check("files.manifest", false, "\(error)")
            return
        }
        let flag = PipelineCancelFlag()
        r.check("files.missingIndexIsEmpty", PipelineStepExecutor.readIndex(package).stamps.isEmpty)
        checkStampFlow(r, package: package, flag: flag)
        checkMarkerFlow(r, package: package, flag: flag)
        checkMissingPackage(r, folder: folder, flag: flag)
    }

    /// needsRun, stamp, fresh, changed hash.
    static func checkStampFlow(_ r: Recorder, package: ProjectPackage, flag: PipelineCancelFlag) {
        let cleanBox = PipelineStepBox(PipelineSelfTestStep(.cleanModel, budget: 200_000_000, hash: "clean-1"))
        let first = PipelineStepExecutor.prepare(box: cleanBox, stepID: .cleanModel, subject: nil, package: package, flag: flag)
        let firstHash: String = plan(of: first)?.inputHash ?? ""
        let firstDecision: AttemptDecision? = plan(of: first)?.decision
        let firstBudget: UInt64 = plan(of: first)?.budget ?? 0
        let firstOK: Bool = firstHash == "clean-1" && firstDecision == AttemptDecision.run && firstBudget == 200_000_000
        r.check("files.prepareNeedsRun", firstOK, describe(first))

        let written = PipelineStepExecutor.recordSuccess(stepID: .cleanModel, subject: nil, inputHash: "clean-1",
                                                         package: package, now: fixedDate)
        let index = PipelineStepExecutor.readIndex(package)
        r.check("files.stampWritten", written && index.stamp(step: .cleanModel)?.inputHash == "clean-1")
        let again = PipelineStepExecutor.prepare(box: cleanBox, stepID: .cleanModel, subject: nil, package: package, flag: flag)
        r.check("files.freshSkips", isFresh(again), describe(again))

        let changedBox = PipelineStepBox(PipelineSelfTestStep(.cleanModel, budget: 200_000_000, hash: "clean-2"))
        let changed = PipelineStepExecutor.prepare(box: changedBox, stepID: .cleanModel, subject: nil, package: package, flag: flag)
        r.check("files.changedHashRuns", plan(of: changed)?.inputHash == "clean-2", describe(changed))
    }

    /// Crash-loop marker: reduced after one death, give up after two or without a reduced
    /// variant, other subjects unaffected, cleared by a fresh stamp or a recorded success.
    static func checkMarkerFlow(_ r: Recorder, package: ProjectPackage, flag: PipelineCancelFlag) {
        let meshBox = PipelineStepBox(PipelineSelfTestStep(.consolidateMesh, budget: 700_000_000, reduced: 350_000_000, hash: "mesh"))
        let died = PipelineAttempt(step: .consolidateMesh, subject: roomA, variant: PipelineAttempt.fullVariant,
                                   count: 1, startedAt: fixedDate)
        save(died, package, r)
        r.check("files.markerLoads", PipelineAttempt.load(from: package) == died)
        let afterDeath = PipelineStepExecutor.prepare(box: meshBox, stepID: .consolidateMesh, subject: roomA, package: package, flag: flag)
        let reducedDecision: AttemptDecision? = plan(of: afterDeath)?.decision
        let reducedPrevious: PipelineAttempt? = plan(of: afterDeath)?.previous
        let reducedOK: Bool = reducedDecision == AttemptDecision.runReduced && reducedPrevious == died
        r.check("files.oneDeathRunsReduced", reducedOK, describe(afterDeath))
        let otherRoom = PipelineStepExecutor.prepare(box: meshBox, stepID: .consolidateMesh, subject: roomB, package: package, flag: flag)
        let otherDecision: AttemptDecision? = plan(of: otherRoom)?.decision
        r.check("files.otherSubjectRunsNormally", otherDecision == AttemptDecision.run, describe(otherRoom))

        var twice = died
        twice.count = 2
        save(twice, package, r)
        let afterTwo = PipelineStepExecutor.prepare(box: meshBox, stepID: .consolidateMesh, subject: roomA, package: package, flag: flag)
        r.check("files.twoDeathsGiveUp", isGiveUp(afterTwo, count: 2), describe(afterTwo))
        r.check("files.giveUpRemovesMarker", PipelineAttempt.load(from: package) == nil)

        let planBox = PipelineStepBox(PipelineSelfTestStep(.floorPlan, hash: "plan"))
        save(PipelineAttempt(step: .floorPlan, subject: nil, variant: PipelineAttempt.fullVariant, count: 1, startedAt: fixedDate), package, r)
        let noReduced = PipelineStepExecutor.prepare(box: planBox, stepID: .floorPlan, subject: nil, package: package, flag: flag)
        r.check("files.oneDeathWithoutReducedGivesUp", isGiveUp(noReduced, count: 1), describe(noReduced))

        let cleanBox = PipelineStepBox(PipelineSelfTestStep(.cleanModel, budget: 200_000_000, hash: "clean-1"))
        save(PipelineAttempt(step: .cleanModel, subject: nil, variant: PipelineAttempt.fullVariant, count: 1, startedAt: fixedDate), package, r)
        let fresh = PipelineStepExecutor.prepare(box: cleanBox, stepID: .cleanModel, subject: nil, package: package, flag: flag)
        r.check("files.freshClearsOwnMarker", isFresh(fresh) && PipelineAttempt.load(from: package) == nil, describe(fresh))

        save(died, package, r)
        let recorded = PipelineStepExecutor.recordSuccess(stepID: .consolidateMesh, subject: roomA, inputHash: "mesh",
                                                          package: package, now: fixedDate)
        let stamps = PipelineStepExecutor.readIndex(package).stamps.count
        r.check("files.successClearsMarker", recorded && PipelineAttempt.load(from: package) == nil && stamps == 2, "\(stamps) stamps")

        do {
            try Data("not json".utf8).write(to: package.pipelineAttemptURL)
            let corrupt = PipelineAttempt.load(from: package)
            let removed = !FileManager.default.fileExists(atPath: package.pipelineAttemptURL.path)
            r.check("files.corruptMarkerIgnored", corrupt == nil && removed)
        } catch {
            r.check("files.corruptMarkerIgnored", false, "\(error)")
        }
    }

    /// A deleted package is reported and never recreated.
    static func checkMissingPackage(_ r: Recorder, folder: URL, flag: PipelineCancelFlag) {
        let gone = ProjectPackage(root: folder.appendingPathComponent("Gone.mapperproj", isDirectory: true))
        let box = PipelineStepBox(PipelineSelfTestStep(.thumbnail))
        let missing = PipelineStepExecutor.prepare(box: box, stepID: .thumbnail, subject: nil, package: gone, flag: flag)
        r.check("files.missingPackageReported", describe(missing) == "projectMissing", describe(missing))
        let stamped = PipelineStepExecutor.recordSuccess(stepID: .thumbnail, subject: nil, inputHash: "t", package: gone, now: fixedDate)
        var threw = false
        do {
            try PipelineStepExecutor.writeIndex(DerivedIndex(), to: gone)
        } catch {
            threw = true
        }
        let recreated = FileManager.default.fileExists(atPath: gone.root.path)
        r.check("files.missingPackageNotRecreated", !stamped && threw && !recreated)
    }

    // MARK: - Helpers

    /// Saves a marker, recording a failure when the write throws.
    static func save(_ attempt: PipelineAttempt, _ package: ProjectPackage, _ r: Recorder) {
        do {
            try PipelineAttempt.save(attempt, to: package)
        } catch {
            r.check("files.markerSaved", false, "\(error)")
        }
    }

    /// The plan of a `.needsRun` preparation.
    static func plan(of preparation: PipelineStepExecutor.Preparation) -> PipelineStepExecutor.Plan? {
        if case .needsRun(let plan) = preparation { return plan }
        return nil
    }

    /// True for `.fresh`.
    static func isFresh(_ preparation: PipelineStepExecutor.Preparation) -> Bool {
        if case .fresh = preparation { return true }
        return false
    }

    /// True for `.giveUp` with this count.
    static func isGiveUp(_ preparation: PipelineStepExecutor.Preparation, count: Int) -> Bool {
        if case .giveUp(let actual) = preparation { return actual == count }
        return false
    }

    /// Case name of a preparation for failure messages.
    static func describe(_ preparation: PipelineStepExecutor.Preparation) -> String {
        switch preparation {
        case .projectMissing: return "projectMissing"
        case .fresh: return "fresh"
        case .giveUp(let count): return "giveUp(\(count))"
        case .failed(let error): return "failed(\(error.copyKey))"
        case .needsRun(let plan): return "needsRun(\(plan.decision), \(plan.inputHash))"
        }
    }
}
