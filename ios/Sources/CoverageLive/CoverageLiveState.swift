import Foundation
import simd

// Internal state of CoverageLiveRecorder, split by owner (docs/MODULES.md 3.31):
// - lock-protected values (inputs from any thread, the pending seed, what readers and hooks
//   copy, the frame-callback timing): `CoverageLiveInputs`, `CoverageLiveSeed`,
//   `CoverageLivePublished`, `CoverageLiveCallbackTiming`;
// - work-queue state (the grid, the anchors, the evaluation results): `CoverageLiveWorkState`,
//   touched only inside blocks running on the recorder's "mapper.coverage.live" queue.

/// What the expected surfaces come from.
enum CoverageLiveExpected {
    /// No expected room.
    case none
    /// The live RoomPlan room (live-room mode: nearby missing areas and completeness for guidance).
    case liveRoom(RoomInput)
    /// A boundary built elsewhere plus its exclusion boxes.
    case boundary(CoverageRoomBoundary, [OrientedBox])
}

/// Expected-surface inputs set from any thread, applied at the next pass. Lock-protected.
struct CoverageLiveInputs {
    /// Expected room or boundary.
    var expected: CoverageLiveExpected = .none
    /// Watched point sets by caller key.
    var watched: [Int: [SIMD3<Float>]] = [:]
    /// Bumped on every change; a pass applies the inputs when it differs from what it applied.
    var version = 0
    /// True when the inputs were set while no recording ran: the next `beginRecording` keeps
    /// them (MissingAreas sets its watched points before its pass starts). Inputs of a finished
    /// recording are cleared by the next `beginRecording`.
    var setWhileIdle = false

    /// Clears the room, boundary and watched sets.
    mutating func clear() {
        expected = .none
        watched = [:]
        version += 1
    }
}

/// Earlier observations to integrate before live passes (`CoverageLiveRecorder.seed`).
struct CoverageLiveSeed {
    /// Observations in the order given.
    var observations: [CoverageObservation]
    /// Faces the observations are tested against.
    var faces: [CoverageFace]
    /// Work-queue seconds allowed.
    var deadlineSeconds: Double
}

/// Values readers and hooks copy. Lock-protected; written once per pass.
struct CoverageLivePublished {
    /// Summary of the last pass (skippedBusy and effectiveHz are filled from the lock group on read).
    var summary = CoverageLiveSummary.zero
    /// Anchors with their states, and their first-seen order.
    var anchors: [UUID: CoverageAnchorFaces] = [:]
    var order: [UUID] = []
    /// Newest anchor revision handed out.
    var revision: UInt64 = 0
    /// Missing areas after the D19 filter, largest first, and the ones handed to guidance.
    var missing: [MissingArea] = []
    var nearby: [MissingArea] = []
    /// Live-room completeness and whether live-room mode is on.
    var overallComplete = false
    var liveRoomMode = false
    /// Last minimap, with the camera marker of the last pass.
    var minimap: MinimapSnapshot?
    /// Well-observed fraction per watched set.
    var watched: [Int: Float] = [:]
    /// Camera to world of the last integrated observation.
    var camera: simd_float4x4?
    /// Observations the last seed integrated.
    var seeded = 0
}

/// Frame-callback timing, logged once per recording (acceptance: under 0.5 ms when not due,
/// under 2 ms when due). Lock-protected.
struct CoverageLiveCallbackTiming {
    /// Frames seen, the slowest not-due callback and the first due one, nanoseconds.
    var frames = 0
    var maxNotDueNanos: UInt64 = 0
    var firstDueNanos: UInt64?
    /// True once the line was written.
    var logged = false
    /// Frames observed before the line is written.
    static let framesBeforeLog = 180
}

/// One tracked anchor on the work queue: the published form plus its voxel keys.
struct CoverageLiveAnchorState {
    /// The anchor as published (states and revision current).
    var value: CoverageAnchorFaces
    /// Voxel key per face.
    var perFaceKey: [SIMD3<Int32>]
    /// Unique voxel keys of the positive-area faces.
    var uniqueKeys: [SIMD3<Int32>]
}

/// Work-queue state. Only touched on the recorder's work queue.
final class CoverageLiveWorkState {
    /// Recording generation this state belongs to; passes of another generation are dropped.
    var generation = 0
    /// Voxel edge used for new grids.
    let voxelSize: Float
    /// The coverage grid of the current recording.
    var grid: CoverageGrid
    /// Scan start in the ARFrame timebase (nil until the first observation when the engine gave 0).
    var startTimestamp: Double?

    /// Tracked anchors, their first-seen order and their face total.
    var anchors: [UUID: CoverageLiveAnchorState] = [:]
    var order: [UUID] = []
    var trackedFaces = 0
    /// The face cap was logged in this recording.
    var faceCapLogged = false
    /// Observation times of the last anchor refresh, evaluation and periodic log line.
    var lastAnchorRefresh: Double?
    var lastEvaluation: Double?
    var lastLogTimestamp: Double?
    /// Recorder-wide revision counter; never reset, so a reader's revision stays meaningful.
    var revisionCounter: UInt64 = 0

    /// `CoverageLiveInputs.version` applied last (-1 forces the next pass to apply).
    var appliedInputsVersion = -1
    /// Live-room mode, the expected boundary, its exclusions and samples, the watched sets.
    var liveRoomMode = false
    var boundary: CoverageRoomBoundary?
    var exclusions: [OrientedBox] = []
    var watched: [Int: [SIMD3<Float>]] = [:]
    /// Voxel keys currently marked expected.
    var expectedKeys = Set<SIMD3<Int32>>()
    /// The boundary samples as faces (D16 shell fallback) and their voxel keys.
    var shellFaces: [CoverageFace] = []
    var shellKeys: [SIMD3<Int32>] = []
    /// The shell samples stand in for mesh faces now.
    var usesShellFallback = false

    /// Evaluation results.
    var coverageFraction: Float = 0
    var missing: [MissingArea] = []
    var nearby: [MissingArea] = []
    var overallComplete = false
    var ages = CoverageLiveMissingAges()
    var minimap: MinimapSnapshot?
    /// Last pass results.
    var viewCoverage: Float?
    var watchedFractions: [Int: Float] = [:]
    var lastCamera: simd_float4x4?

    /// Counters: live integrations, faces handed to the last integration, seeded observations.
    var integrations = 0
    var lastIntegratedFaces = 0
    var seeded = 0
    /// After a seed: recompute every anchor's states and evaluate at the next pass.
    var forceAllStates = false
    var forceEvaluation = false
    /// Pass durations since the last periodic log line, and the last one, milliseconds.
    var passTimes: [Double] = []
    var lastPassMilliseconds: Double = 0

    /// An empty state with a grid of `voxelSize`.
    init(voxelSize: Float) {
        self.voxelSize = voxelSize
        grid = CoverageGrid(voxelSize: voxelSize)
    }

    /// A fresh state for a new recording; keeps only the revision counter.
    func reset(generation: Int, startTimestamp: Double) {
        self.generation = generation
        self.startTimestamp = startTimestamp > 0 && startTimestamp.isFinite ? startTimestamp : nil
        grid = CoverageGrid(voxelSize: voxelSize)
        dropAnchors()
        faceCapLogged = false
        lastAnchorRefresh = nil
        lastEvaluation = nil
        lastLogTimestamp = nil
        appliedInputsVersion = -1
        liveRoomMode = false
        boundary = nil
        exclusions = []
        watched = [:]
        expectedKeys = []
        coverageFraction = 0
        missing = []
        nearby = []
        overallComplete = false
        ages = CoverageLiveMissingAges()
        minimap = nil
        viewCoverage = nil
        watchedFractions = [:]
        lastCamera = nil
        integrations = 0
        lastIntegratedFaces = 0
        seeded = 0
        forceAllStates = false
        forceEvaluation = false
        passTimes = []
        lastPassMilliseconds = 0
    }

    /// Drops every per-anchor array and the shell faces (D17: MeshStore.evict then really frees
    /// the chunk memory these arrays share).
    func dropAnchors() {
        anchors = [:]
        order = []
        trackedFaces = 0
        shellFaces = []
        shellKeys = []
        usesShellFallback = false
    }

    /// End of a recording: drops the anchors and replaces the grid with an empty one; the
    /// evaluation results stay (they are already published).
    func finish() {
        dropAnchors()
        grid = CoverageGrid(voxelSize: voxelSize)
        expectedKeys = []
        appliedInputsVersion = -1
        generation = -1
    }

    /// The next anchor revision.
    func nextRevision() -> UInt64 {
        revisionCounter = revisionCounter == UInt64.max ? revisionCounter : revisionCounter + 1
        return revisionCounter
    }

    /// Seconds since the scan started at `timestamp` (0 before the start is known).
    func elapsed(at timestamp: Double) -> Double {
        if startTimestamp == nil { startTimestamp = timestamp }
        let start = startTimestamp ?? timestamp
        let value = timestamp - start
        return value.isFinite ? max(value, 0) : 0
    }
}
