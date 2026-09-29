import Foundation
import RoomPlan
import os

// The merge and alignment steps of a House project (docs/MODULES.md 3.30, ARCHITECTURE 5.9).
// MergeStructureStep hands only rooms of the confirmed shared frame (D9) to
// `StructureBuilder(options: [.beautifyObjects])` behind the attempt.json crash guard;
// AlignRoomsStep solves each merged room's placement from the kept surface identifiers and
// writes the placement plan. Neither step fails the job for a merge, solve or placement failure.

/// RoomPlan surfaces of a merged structure by identifier: walls, doors, windows and openings
/// of `structure.rooms` first, then the structure-level lists for identifiers not seen yet,
/// each converted with RoomModel's `SurfaceInput.init(_:)` (StructureSteps.swift, RoomPlan).
enum StructureSurfaces {
    /// Every wall, door, window and opening of the structure by RoomPlan identifier.
    static func index(_ structure: CapturedStructure) -> [UUID: SurfaceInput] {
        var result: [UUID: SurfaceInput] = [:]
        /// Adds surfaces whose identifier is not indexed yet.
        func add(_ surfaces: [CapturedRoom.Surface]) {
            for surface in surfaces where result[surface.identifier] == nil {
                result[surface.identifier] = SurfaceInput(surface)
            }
        }
        for room in structure.rooms {
            add(room.walls)
            add(room.doors)
            add(room.windows)
            add(room.openings)
        }
        add(structure.walls)
        add(structure.doors)
        add(structure.windows)
        add(structure.openings)
        return result
    }
}

/// id .mergeStructure; optional in the House plan; budget 400 MB, reduced 60 MB (the reduced
/// variant never calls StructureBuilder). Reads `ctx.manifest`, so it takes no arguments (rooms
/// can change between enqueue and run).
final class MergeStructureStep: ProcessingStep {
    /// Which step this is.
    let id: PipelineStepID = .mergeStructure
    /// Peak memory of the builder run, bytes (400 MB).
    let memoryBudgetBytes: UInt64 = 400 * 1024 * 1024
    /// The reduced variant only records `skippedReducedMemory`, bytes (60 MB).
    let reducedMemoryBudgetBytes: UInt64? = 60 * 1024 * 1024
    /// Version of the merge rules, part of the input hash.
    static let rulesVersion = "mergeStructure-rules=1"

    /// A step for the project in `ctx`.
    init() {}

    /// Seals of the mergeable rooms, their `buildRoom` stamp hashes ("-" when absent), every
    /// session's `linkKey`, "attempt=present" or "attempt=absent", and the rules version.
    func inputHash(_ ctx: StepContext) throws -> String {
        let package = ctx.package
        let active = StructureEligibility.activeRooms(ctx.manifest)
        let split = StructureEligibility.mergeable(active, sessions: ctx.manifest.sessions,
                                                   isFinal: { CapturedRoomStore.hasFinalRoom(package, room: $0) })
        let index = try? ProjectStore.readJSON(DerivedIndex.self, from: package.derivedIndexURL)
        var seals: [SealFile] = []
        var extra = [MergeStructureStep.rulesVersion]
        for room in split.merge {
            if let seal = try? ProjectStore.readJSON(SealFile.self, from: CapturedRoomStore.rawFolder(package, room: room).sealURL) {
                seals.append(seal)
            } else {
                extra.append("seal-missing=\(room.id.uuidString)")
            }
            let built = index?.stamp(step: .buildRoom, subject: room.id)?.inputHash ?? "-"
            extra.append("room=\(room.id.uuidString)|buildRoom=\(built)")
        }
        for session in ctx.manifest.sessions {
            extra.append("session=\(session.id.uuidString)|\(StructureEligibility.linkKey(session.frameLink))")
        }
        extra.append(StructureStore.hasCrashedAttempt(package) ? "attempt=present" : "attempt=absent")
        return InputHasher.hash(seals: seals, editRevision: nil, extra: extra)
    }

    /// The merge decision before any RoomPlan call, in order: `unsupported`,
    /// `skippedReducedMemory` (available memory below the full budget), `crashedBefore` (an
    /// attempt.json exists, whatever input hash it records: the builder died last time and only
    /// `StructureStore.clearCrashedAttempt` re-enables it), `tooFewRooms` (fewer than 2
    /// mergeable rooms); nil means "call the builder". `currentHash` is deliberately not compared
    /// with the attempt's hash (3.30). Pure.
    static func decision(isSupported: Bool, availableMemory: UInt64, budget: UInt64, attempt: StructureAttempt?,
                         attemptFileExists: Bool, currentHash: String, mergeableCount: Int) -> StructureMergeOutcome? {
        if !isSupported { return .unsupported }
        if availableMemory < budget { return .skippedReducedMemory }
        if attemptFileExists || attempt != nil { return .crashedBefore }
        if mergeableCount < 2 { return .tooFewRooms }
        return nil
    }

    /// Anchor-group rooms that would be merged but have only the provisional live room.
    static func provisionalRooms(_ active: [RoomRecord], sessions: [CaptureSessionRef], package: ProjectPackage) -> [UUID] {
        let candidates = StructureEligibility.mergeable(active, sessions: sessions, isFinal: { _ in true }).merge
        return candidates.filter { room in
            let live = CapturedRoomStore.rawFolder(package, room: room).liveCapturedRoomURL
            return !CapturedRoomStore.hasFinalRoom(package, room: room) && FileManager.default.fileExists(atPath: live.path)
        }.map { $0.id }
    }

    /// Runs the merge (3.30 order). merge.json is written in every case; only `merged` keeps a
    /// structure.json. Only cancellation and failed derived writes throw.
    func run(_ ctx: StepContext) async throws {
        let started = Date()
        let package = ctx.package
        let active = StructureEligibility.activeRooms(ctx.manifest)
        let sessions = ctx.manifest.sessions
        let split = StructureEligibility.mergeable(active, sessions: sessions,
                                                   isFinal: { CapturedRoomStore.hasFinalRoom(package, room: $0) })
        var provisional = MergeStructureStep.provisionalRooms(active, sessions: sessions, package: package)
        let hash = (try? inputHash(ctx)) ?? "-"
        let leftover = StructureStore.loadAttempt(package)
        let supported = await MainActor.run { RoomCaptureSession.isSupported }
        let early = MergeStructureStep.decision(isSupported: supported, availableMemory: ctx.availableMemory,
                                                budget: memoryBudgetBytes, attempt: leftover,
                                                attemptFileExists: StructureStore.hasCrashedAttempt(package),
                                                currentHash: hash, mergeableCount: split.merge.count)
        if let early {
            if early == .crashedBefore {
                let stored = leftover?.inputHash ?? "unreadable"
                log("attempt.json from an earlier run (hash \(stored), current \(hash)); builder not called again")
            }
            try finish(ctx, outcome: early, merged: [], active: active, provisional: provisional, detail: nil,
                       hash: hash, started: started, structure: nil)
            return
        }
        try ctx.checkCancelled()
        let attempt = StructureAttempt(startedAt: Date(), roomIDs: split.merge.map { $0.id }, inputHash: hash)
        try StructureStore.writeAttempt(attempt, to: package)
        var outcome = StructureMergeOutcome.tooFewRooms
        var detail: String?
        var structure: CapturedStructure?
        var mergedIDs: [UUID] = []
        do {
            defer { StructureStore.removeAttempt(package) }
            var rooms: [CapturedRoom] = []
            for record in split.merge {
                do {
                    let loaded = try CapturedRoomStore.loadWithSource(package, room: record)
                    if loaded.source == .live {
                        log("room \(record.id): only the provisional live room loads; left out")
                        provisional.append(record.id)
                        continue
                    }
                    rooms.append(loaded.room)
                    mergedIDs.append(record.id)
                } catch {
                    log("room \(record.id): capturedroom not loadable (\(error)); left out")
                }
            }
            ctx.progress(0.2)
            try ctx.checkCancelled()
            if rooms.count >= 2 {
                log("calling StructureBuilder with \(rooms.count) rooms, memory \(ctx.availableMemory / 1_000_000) MB")
                do {
                    let builder = StructureBuilder(options: [.beautifyObjects])
                    structure = try await builder.capturedStructure(from: rooms)
                    outcome = .merged
                } catch {
                    outcome = .builderFailed
                    detail = "\(error)"
                }
            }
        }
        ctx.progress(0.9)
        try finish(ctx, outcome: outcome, merged: outcome == .merged ? mergedIDs : [], active: active,
                   provisional: provisional, detail: detail, hash: hash, started: started, structure: structure)
    }

    /// Writes (or removes) structure.json and writes merge.json, then logs the run.
    private func finish(_ ctx: StepContext, outcome: StructureMergeOutcome, merged: [UUID], active: [RoomRecord],
                        provisional: [UUID], detail: String?, hash: String, started: Date,
                        structure: CapturedStructure?) throws {
        let package = ctx.package
        var finalOutcome = outcome
        var finalDetail = detail
        var finalMerged = merged
        if outcome == .merged, let structure {
            do {
                try StructureStore.saveStructure(structure, to: package)
            } catch {
                StructureStore.removeStructure(package)
                finalOutcome = .builderFailed
                finalDetail = "structure.json not written: \(error)"
                finalMerged = []
                _ = try? saveResult(ctx, outcome: finalOutcome, merged: finalMerged, active: active, provisional: provisional,
                                    detail: finalDetail, hash: hash, started: started)
                throw error
            }
        } else {
            StructureStore.removeStructure(package)
        }
        try saveResult(ctx, outcome: finalOutcome, merged: finalMerged, active: active, provisional: provisional,
                       detail: finalDetail, hash: hash, started: started)
        ctx.progress(1)
        let seconds = Date().timeIntervalSince(started)
        let after = UInt64(clamping: os_proc_available_memory())
        let secondsText: String = String(format: "%.1f", seconds)
        let beforeMB: UInt64 = ctx.availableMemory / 1_000_000
        let afterMB: UInt64 = after / 1_000_000
        var parts: [String] = []
        parts.append("merge \(finalOutcome.rawValue): \(finalMerged.count) of \(active.count) active rooms merged")
        parts.append("\(provisional.count) provisional")
        parts.append("\(secondsText) s")
        parts.append("memory before \(beforeMB) MB, after \(afterMB) MB")
        if finalOutcome == .merged, let structure {
            parts.append("surfaces: \(structure.rooms.count) rooms, \(structure.walls.count) walls")
            parts.append("\(structure.doors.count) doors, \(structure.windows.count) windows")
            parts.append("\(structure.openings.count) openings, \(structure.objects.count) objects")
        }
        if let finalDetail { parts.append("detail: \(finalDetail)") }
        log(parts.joined(separator: ", "))
    }

    /// Writes merge.json for this run.
    private func saveResult(_ ctx: StepContext, outcome: StructureMergeOutcome, merged: [UUID], active: [RoomRecord],
                            provisional: [UUID], detail: String?, hash: String, started: Date) throws {
        let mergedSet = Set(merged)
        let provisionalSet = Set(provisional)
        let separate = active.map { $0.id }.filter { !mergedSet.contains($0) && !provisionalSet.contains($0) }
        let result = StructureMergeResult(outcome: outcome, mergedRooms: merged, separateRooms: separate,
                                          provisionalRooms: provisional, detail: detail,
                                          seconds: Date().timeIntervalSince(started), inputHash: hash, finishedAt: Date())
        try StructureStore.saveMerge(result, to: ctx.package)
    }

    /// Writes a log line (category "structure").
    private func log(_ message: String) {
        LogStore.shared.write("mergeStructure: " + message, category: StructureStore.logCategory)
    }
}

/// id .alignRooms; optional; budget 150 MB.
final class AlignRoomsStep: ProcessingStep {
    /// Which step this is.
    let id: PipelineStepID = .alignRooms
    /// Peak memory budget, bytes (150 MB, no reduced variant).
    let memoryBudgetBytes: UInt64 = 150 * 1024 * 1024
    /// Version of the alignment rules, part of the input hash.
    static let rulesVersion = "alignRooms-rules=1"

    /// A step for the project in `ctx`.
    init() {}

    /// Seals of the active rooms, their ids, frame links and `buildRoom` stamps, the
    /// `mergeStructure` stamp, session `linkKey`s and the rules version (no edit revision: user
    /// alignments are applied by consumers).
    func inputHash(_ ctx: StepContext) throws -> String {
        let package = ctx.package
        let index = try? ProjectStore.readJSON(DerivedIndex.self, from: package.derivedIndexURL)
        var seals: [SealFile] = []
        var extra = [AlignRoomsStep.rulesVersion]
        for room in StructureEligibility.activeRooms(ctx.manifest) {
            if let seal = try? ProjectStore.readJSON(SealFile.self, from: CapturedRoomStore.rawFolder(package, room: room).sealURL) {
                seals.append(seal)
            } else {
                extra.append("seal-missing=\(room.id.uuidString)")
            }
            let built = index?.stamp(step: .buildRoom, subject: room.id)?.inputHash ?? "-"
            extra.append("room=\(room.id.uuidString)|link=\(StructureEligibility.linkKey(room.frameLink))|buildRoom=\(built)")
        }
        let merged = index?.stamp(step: .mergeStructure, subject: nil)?.inputHash ?? "-"
        extra.append("mergeStructure=\(merged)")
        for session in ctx.manifest.sessions {
            extra.append("session=\(session.id.uuidString)|\(StructureEligibility.linkKey(session.frameLink))")
        }
        return InputHasher.hash(seals: seals, editRevision: nil, extra: extra)
    }

    /// Loads every active room, solves the merged ones, writes alignment.json and
    /// placements.json. A room it cannot load or place is logged, never fatal.
    func run(_ ctx: StepContext) async throws {
        let package = ctx.package
        let active = StructureEligibility.activeRooms(ctx.manifest)
        var inputs: [UUID: RoomInput] = [:]
        var footprints: [UUID: RoomFootprint] = [:]
        for (i, record) in active.enumerated() {
            try ctx.checkCancelled()
            do {
                let input = try CapturedRoomStore.loadInput(package, room: record)
                inputs[record.id] = input
                if let footprint = RoomFootprint.from(input, roomID: record.id) {
                    footprints[record.id] = footprint
                } else {
                    log("room \(record.id): no outline; it gets no footprint")
                }
            } catch {
                log("room \(record.id): no CapturedRoom (\(error)); it gets no footprint")
            }
            ctx.progress(0.5 * Double(i + 1) / Double(Swift.max(1, active.count)))
        }
        let solutions = solve(package, inputs: inputs)
        try ctx.checkCancelled()
        let plan = StructureLayout.plan(rooms: active, sessions: ctx.manifest.sessions, footprints: footprints,
                                        solutions: solutions)
        let hash = (try? inputHash(ctx)) ?? "-"
        try StructureStore.saveAlignments(plan.records, to: package)
        let placements = StructurePlacements(rooms: plan.reports, unplaced: plan.unplaced, inputHash: hash, finishedAt: Date())
        try StructureStore.savePlacements(placements, to: package)
        ctx.progress(1)
        for report in plan.reports {
            let rms = report.rms.map { String(format: "%.3f m", $0) } ?? "-"
            let stacked = report.stackedWith.map { ", stacked on \($0)" } ?? ""
            log("room \(report.roomID): \(report.method.rawValue), matches \(report.matches), rms \(rms)\(stacked)")
        }
        for id in plan.unplaced { log("room \(id): unplaced (another frame and no outline)") }
    }

    /// Solutions for the rooms of a successful merge (merge.json `merged` and a loadable
    /// structure.json); untrusted solves are kept for the report and logged with their rms.
    private func solve(_ package: ProjectPackage, inputs: [UUID: RoomInput]) -> [UUID: AlignmentSolution] {
        guard let merge = StructureStore.loadMerge(package), merge.outcome == .merged else {
            log("no merged structure; rooms of the structure frame keep their capture placement")
            return [:]
        }
        let structure: CapturedStructure
        do {
            guard let loaded = try StructureStore.loadStructure(package) else {
                log("merge.json says merged but structure.json is missing")
                return [:]
            }
            structure = loaded
        } catch {
            log("structure.json unreadable (\(error))")
            return [:]
        }
        let surfaces = StructureSurfaces.index(structure)
        var solutions: [UUID: AlignmentSolution] = [:]
        for id in merge.mergedRooms {
            guard let input = inputs[id] else { continue }
            let pairs = StructureAlignment.pairs(room: input, structure: surfaces)
            guard let solution = StructureAlignment.solve(pairs) else {
                log("room \(id): no solve from \(pairs.count) kept surfaces")
                continue
            }
            solutions[id] = solution
            if !solution.isTrusted {
                log("room \(id): solve not trusted (matches \(solution.matches), rms \(String(format: "%.3f", solution.rms)) m)")
            }
        }
        return solutions
    }

    /// Writes a log line (category "structure").
    private func log(_ message: String) {
        LogStore.shared.write("alignRooms: " + message, category: StructureStore.logCategory)
    }
}
