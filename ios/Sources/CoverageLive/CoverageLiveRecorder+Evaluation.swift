import Foundation
import simd

// Evaluation, seed and logging of CoverageLiveRecorder (docs/MODULES.md 3.31), all on the work
// queue. The evaluation compares the expected room with the grid (Coverage's ExpectedSurfaces),
// drops windows, doors and openings (D19), ages the missing areas so guidance only hears about
// ones that stayed missing, and builds the minimap. Live values are display state only: the
// sealed scan is scored again by Quality (RESEARCH 3.8 gotcha 15, live rooms are provisional).

extension CoverageLiveRecorder {
    // MARK: Evaluation (work queue)

    /// Step 5: fraction, missing areas, ages, nearby list, completeness and minimap. With a
    /// boundary the fraction is the observed share of the expected area outside the exclusions;
    /// without one it is the green share of the tracked face area and the minimap has no missing cells.
    func evaluate(observation: CoverageObservation, elapsed: Double) {
        let s = state
        let m = observation.cameraToWorld
        let camera = SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        guard let boundary = s.boundary else {
            s.coverageFraction = greenShareOfTrackedFaces()
            s.missing = []
            s.nearby = []
            s.overallComplete = false
            s.ages = CoverageLiveMissingAges()
            s.minimap = CoverageLiveMinimap.make(voxels: minimapColumns(), voxelSize: s.grid.voxelSize, boundary: nil,
                                                 unobservedExpected: [], camera: m, cellSize: options.minimapCellSize,
                                                 maxCells: options.maxMinimapCells)
            return
        }
        let result = ExpectedSurfaces.evaluate(room: boundary, grid: s.grid)
        var expectedArea: Float = 0
        var observedArea: Float = 0
        var unobserved: [SIMD3<Float>] = []
        let count = min(result.samples.count, result.observed.count)
        for i in 0..<count {
            let sample = result.samples[i]
            if CoverageLiveBoundary.isExcluded(sample.position, exclusions: s.exclusions) { continue }
            expectedArea += sample.area
            if result.observed[i] {
                observedArea += sample.area
            } else {
                unobserved.append(sample.position)
            }
        }
        var fraction: Float = 0
        if expectedArea > 0, expectedArea.isFinite { fraction = min(max(observedArea / expectedArea, 0), 1) }
        s.coverageFraction = fraction
        let missing = CoverageLiveMissing.filtered(result.missing, exclusions: s.exclusions)
        s.missing = missing
        let ages = s.ages.update(missing, now: observation.timestamp)
        if s.liveRoomMode {
            s.nearby = CoverageLiveMissing.nearby(missing, ages: ages, camera: camera, elapsed: elapsed, options: options)
        } else {
            s.nearby = []
        }
        s.overallComplete = CoverageLiveMissing.isComplete(observedFraction: fraction, missingCount: missing.count)
        s.minimap = CoverageLiveMinimap.make(voxels: minimapColumns(), voxelSize: s.grid.voxelSize, boundary: boundary,
                                             unobservedExpected: unobserved, camera: m, cellSize: options.minimapCellSize,
                                             maxCells: options.maxMinimapCells)
    }

    /// One entry per voxel column (x, z) of the tracked anchors (and of the shell samples in the
    /// fallback), carrying the best state in that column; y is 0 because the minimap ignores it.
    func minimapColumns() -> [(key: SIMD3<Int32>, state: CoverageState)] {
        let s = state
        let grid = s.grid
        var columns: [SIMD2<Int32>: CoverageState] = [:]
        for id in s.order {
            guard let anchor = s.anchors[id] else { continue }
            for key in anchor.uniqueKeys {
                let column = SIMD2<Int32>(key.x, key.z)
                let value = grid.state(atVoxel: key)
                if let old = columns[column], old.rawValue >= value.rawValue { continue }
                columns[column] = value
            }
        }
        if s.usesShellFallback {
            for key in s.shellKeys {
                let column = SIMD2<Int32>(key.x, key.z)
                let value = grid.state(atVoxel: key)
                if let old = columns[column], old.rawValue >= value.rawValue { continue }
                columns[column] = value
            }
        }
        var out: [(key: SIMD3<Int32>, state: CoverageState)] = []
        out.reserveCapacity(columns.count)
        for (column, value) in columns {
            out.append((key: SIMD3<Int32>(column.x, 0, column.y), state: value))
        }
        return out
    }

    /// Area-weighted green share of every tracked face, 0 without faces.
    func greenShareOfTrackedFaces() -> Float {
        let s = state
        var total: Float = 0
        var green: Float = 0
        for id in s.order {
            guard let anchor = s.anchors[id] else { continue }
            let faces = anchor.value.faces
            let states = anchor.value.states
            let count = min(faces.count, states.count)
            for t in 0..<count where faces[t].area > 0 {
                total += faces[t].area
                if states[t] == .green { green += faces[t].area }
            }
        }
        return CoverageLiveMissing.fraction(green: green, total: total, minimumTotal: 0) ?? 0
    }

    // MARK: Seed (work queue)

    /// Integrates a seed's observations in order until its deadline, then marks every anchor's
    /// states and the evaluation for the next pass and publishes the watched fractions.
    func runSeed(_ seed: CoverageLiveSeed, generation gen: Int) {
        let s = state
        guard s.generation == gen else {
            CoverageLiveRecorder.log("seed dropped: its recording ended")
            return
        }
        let started = DispatchTime.now().uptimeNanoseconds
        let deadline = seed.deadlineSeconds.isFinite ? max(seed.deadlineSeconds, 0) : 0
        var used = 0
        for observation in seed.observations {
            let spent = Double(DispatchTime.now().uptimeNanoseconds &- started) / 1_000_000_000
            if spent >= deadline { break }
            s.grid.integrate(observation: observation, faces: seed.faces)
            used += 1
        }
        _ = applyInputsIfChanged()
        s.seeded = used
        s.forceAllStates = true
        s.forceEvaluation = true
        let fractions = watchedFractionsNow()
        s.watchedFractions = fractions
        locked { () -> Void in
            guard generation == gen else { return }
            published.seeded = used
            published.watched = fractions
        }
        let milliseconds = CoverageLiveRecorder.formatted(Double(DispatchTime.now().uptimeNanoseconds &- started) / 1_000_000)
        CoverageLiveRecorder.log("seed: \(used) of \(seed.observations.count) observations against \(seed.faces.count) faces "
                                 + "in \(milliseconds) ms (deadline \(CoverageLiveRecorder.formatted(deadline)) s)")
    }

    // MARK: Logging and small helpers

    /// One line every `logIntervalSeconds` of observation time: passes, skipped passes, anchors,
    /// faces, fraction, missing count and the median pass time since the previous line.
    func logPeriodically(timestamp: Double) {
        let s = state
        guard let last = s.lastLogTimestamp, timestamp >= last else {
            s.lastLogTimestamp = timestamp
            return
        }
        guard timestamp - last >= CoverageLiveRecorder.logIntervalSeconds else { return }
        s.lastLogTimestamp = timestamp
        let median = CoverageLiveRecorder.median(s.passTimes)
        s.passTimes.removeAll(keepingCapacity: true)
        let skipped = locked { skippedBusy }
        let fraction = CoverageLiveRecorder.formatted(Double(s.coverageFraction))
        CoverageLiveRecorder.log("passes \(s.integrations), skipped \(skipped), anchors \(s.anchors.count), "
                                 + "faces \(s.trackedFaces), fraction \(fraction), missing \(s.missing.count), "
                                 + "median pass \(CoverageLiveRecorder.formatted(median)) ms")
    }

    /// True when `interval` seconds passed since `last` (always when `last` is nil or later than `now`).
    static func intervalDue(last: Double?, now: Double, interval: Double) -> Bool {
        guard let last, now >= last else { return true }
        return now - last >= interval
    }

    /// Median of `values`, 0 when empty.
    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count % 2 == 1 { return sorted[middle] }
        return (sorted[middle - 1] + sorted[middle]) * 0.5
    }

    /// `value` rounded to `digits` decimals for log lines ("-" when not finite).
    static func formatted(_ value: Double, digits: Int = 2) -> String {
        guard value.isFinite else { return "-" }
        let scale = pow(10.0, Double(max(0, min(digits, 6))))
        return String((value * scale).rounded() / scale)
    }
}
