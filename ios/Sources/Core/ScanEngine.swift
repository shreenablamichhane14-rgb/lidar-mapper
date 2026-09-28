import Foundation

/// Tracking state summary for the UI. Raw values are persisted in recordings.
enum TrackingSummary: String, Codable, CaseIterable, Sendable {
    case normal, initializing, excessiveMotion, insufficientFeatures, relocalizing, limited, notAvailable
}

/// Device thermal level. Raw values are persisted in recordings.
enum ThermalLevel: String, Codable, CaseIterable, Sendable {
    case nominal, fair, serious, critical

    /// Maps the system thermal state; unknown future states count as `.serious`.
    init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .serious
        }
    }
}

/// Coverage codes of `MinimapSnapshot.cells`.
enum MinimapCell: UInt8, Codable, CaseIterable, Sendable {
    /// Not observed and not expected.
    case empty = 0
    /// Expected surface never observed (red).
    case missing = 1
    /// Observed once or twice (yellow).
    case partial = 2
    /// Observed three or more times (green).
    case covered = 3
}

/// Top-down coverage map for the live minimap (plan coordinates, `PlanAxes`).
struct MinimapSnapshot: Codable, Equatable, Sendable {
    /// Cell edge length, meters.
    var cellSize: Float
    /// Plan position of the corner of cell (0, 0), meters.
    var origin: Vec2
    /// Cells per row.
    var width: Int
    /// Rows.
    var height: Int
    /// Row-major `MinimapCell` raw values, `width * height` entries.
    var cells: [UInt8]
    /// Wall polylines detected so far, plan meters.
    var walls: [[Vec2]]

    /// Cell state at column x, row y; `.empty` outside the grid or for unknown codes.
    func cell(x: Int, y: Int) -> MinimapCell {
        guard x >= 0, y >= 0, x < width, y < height, y * width + x < cells.count else { return .empty }
        return MinimapCell(rawValue: cells[y * width + x]) ?? .empty
    }
}

/// Everything the live scan UI shows, produced by a `ScanEngine` a few times per second.
struct LiveScanSnapshot: Codable, Equatable, Sendable {
    /// `ARFrame.timestamp` (or replay time), seconds.
    var timestamp: Double = 0
    /// Seconds since the scan started.
    var elapsed: Double = 0
    /// Tracking state.
    var tracking: TrackingSummary = .initializing
    /// Which streams are working (D16).
    var degraded: DegradedMode = .allGood
    /// `GuidanceKind.rawValue` of the guidance to show, if any (stored as a string so this
    /// type stays Sendable and decodable across builds).
    var guidanceRawValue: String?
    /// Walls found so far.
    var wallCount: Int = 0
    /// Doors found so far.
    var doorCount: Int = 0
    /// Windows found so far.
    var windowCount: Int = 0
    /// Openings found so far.
    var openingCount: Int = 0
    /// Objects found so far.
    var objectCount: Int = 0
    /// Mesh faces recorded so far.
    var meshFaceCount: Int = 0
    /// Keyframes accepted so far.
    var keyframeCount: Int = 0
    /// Photos taken so far.
    var photoCount: Int = 0
    /// Covered fraction of expected surfaces, 0...1.
    var coverageFraction: Float = 0
    /// Device thermal level.
    var thermal: ThermalLevel = .nominal
    /// Free storage, bytes.
    var freeBytes: Int64 = 0
    /// `os_proc_available_memory()`, bytes.
    var availableMemory: UInt64 = 0
    /// Minimap, when the engine produces one.
    var minimap: MinimapSnapshot?

    /// The guidance to show, decoded from `guidanceRawValue`.
    var guidance: GuidanceKind? {
        guard let raw = guidanceRawValue else { return nil }
        return GuidanceKind(rawValue: raw)
    }
}

/// Engine lifecycle state. Raw values are persisted in recordings.
enum ScanEngineState: String, Codable, CaseIterable, Sendable {
    case idle, starting, scanning, paused, stopping, finished, failed
}

/// Events an engine delivers to its owner.
enum ScanEngineEvent: Equatable, Sendable {
    /// A new live snapshot.
    case snapshot(LiveScanSnapshot)
    /// A room (or scan pass) finished and its raw folder was sealed.
    case roomFinished(roomID: UUID)
    /// The engine failed; state becomes `.failed`.
    case failed(MapperError)
    /// The lifecycle state changed.
    case stateChanged(ScanEngineState)
}

/// A capture driver (D1): Room (RoomPlan), mesh-only, Object Capture or a fake.
///
/// Threading rules:
/// - The protocol is not actor-isolated. Call every method from the main thread.
/// - Engines do their work on their own serial queue; ARKit and RoomPlan delegates are
///   plain NSObject subclasses on that queue, never `@MainActor`.
/// - `onEvent` is always called on the main queue (`DispatchQueue.main.async`), carrying
///   only value types. UI wraps an engine in a `@MainActor final class ScanFlowModel:
///   ObservableObject` and never retains ARFrames or ARKit buffers.
protocol ScanEngine: AnyObject {
    /// Current lifecycle state (read on main).
    var state: ScanEngineState { get }
    /// Event callback, always invoked on the main queue.
    var onEvent: ((ScanEngineEvent) -> Void)? { get set }
    /// Starts capture. Throws a `MapperError` when capture cannot start (storage, device).
    func start() throws
    /// Pauses capture (keeps what was captured).
    func pause()
    /// Resumes after `pause()`.
    func resume()
    /// Finishes the current room or scan and seals its raw folder.
    func finish()
    /// Stops without finishing; captured raw data stays in InProgress for recovery.
    func cancel()
}

/// A recorded or synthetic sequence of snapshots, stored as JSON or JSON Lines (one
/// snapshot per line) for Demo Mode and UI development without ARKit.
struct SnapshotRecording: Codable, Equatable, Sendable {
    /// Snapshots in replay order.
    var snapshots: [LiveScanSnapshot]

    /// Parses JSON Lines; blank lines are skipped.
    static func decodeJSONLines(_ data: Data) throws -> SnapshotRecording {
        let decoder = JSONDecoder()
        var snapshots: [LiveScanSnapshot] = []
        for line in data.split(separator: 10) where !line.isEmpty {
            snapshots.append(try decoder.decode(LiveScanSnapshot.self, from: Data(line)))
        }
        return SnapshotRecording(snapshots: snapshots)
    }

    /// Serializes as JSON Lines.
    func encodeJSONLines() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var out = Data()
        for snapshot in snapshots {
            out.append(try encoder.encode(snapshot))
            out.append(10)
        }
        return out
    }

    /// A deterministic scripted room scan of `count` snapshots `interval` seconds apart:
    /// counts and coverage grow, then tracking briefly limits and recovers.
    static func synthetic(count: Int = 120, interval: Double = 0.25) -> SnapshotRecording {
        var snapshots: [LiveScanSnapshot] = []
        let total = Swift.max(1, count)
        for i in 0..<total {
            let progress = Float(i + 1) / Float(total)
            var s = LiveScanSnapshot()
            s.timestamp = Double(i) * interval
            s.elapsed = Double(i) * interval
            s.tracking = i < 4 ? .initializing : (i % 50 >= 45 ? .excessiveMotion : .normal)
            s.guidanceRawValue = s.tracking == .excessiveMotion ? GuidanceKind.moveSlower.rawValue : nil
            s.wallCount = Int(progress * 4)
            s.doorCount = progress > 0.5 ? 1 : 0
            s.windowCount = progress > 0.7 ? 2 : 0
            s.objectCount = Int(progress * 6)
            s.meshFaceCount = Int(progress * 120_000)
            s.keyframeCount = i / 3
            s.coverageFraction = progress * 0.95
            s.freeBytes = 20_000_000_000
            s.availableMemory = 2_000_000_000
            snapshots.append(s)
        }
        return SnapshotRecording(snapshots: snapshots)
    }
}

/// Replays a `SnapshotRecording` on the main queue at a fixed interval (Demo Mode, UI
/// development). Deterministic, needs no ARKit. When the recording ends the engine
/// finishes by itself unless `loops` is true.
final class FakeScanEngine: ScanEngine {
    /// Current lifecycle state.
    private(set) var state: ScanEngineState = .idle
    /// Event callback, invoked on the main queue.
    var onEvent: ((ScanEngineEvent) -> Void)?
    /// The recording being replayed.
    let recording: SnapshotRecording
    /// Seconds between snapshots.
    let interval: TimeInterval
    /// Restart from the first snapshot at the end instead of finishing.
    let loops: Bool
    /// Room identifier reported in `.roomFinished`.
    let roomID: UUID
    /// Index of the next snapshot to deliver.
    private var nextIndex = 0
    /// The running timer, nil while not scanning.
    private var timer: DispatchSourceTimer?

    /// Creates a fake engine.
    init(recording: SnapshotRecording = .synthetic(), interval: TimeInterval = 0.25,
         loops: Bool = false, roomID: UUID = UUID()) {
        self.recording = recording
        self.interval = Swift.max(0.01, interval)
        self.loops = loops
        self.roomID = roomID
    }

    /// Starts replay from the first snapshot. Does nothing unless idle.
    func start() throws {
        guard state == .idle || state == .finished else { return }
        nextIndex = 0
        setState(.starting)
        setState(.scanning)
        startTimer()
    }

    /// Stops the timer, keeping the replay position.
    func pause() {
        guard state == .scanning else { return }
        stopTimer()
        setState(.paused)
    }

    /// Continues from the replay position.
    func resume() {
        guard state == .paused else { return }
        setState(.scanning)
        startTimer()
    }

    /// Ends the replay and reports the room as finished.
    func finish() {
        guard state == .scanning || state == .paused else { return }
        stopTimer()
        setState(.stopping)
        emit(.roomFinished(roomID: roomID))
        setState(.finished)
    }

    /// Ends the replay without finishing the room.
    func cancel() {
        stopTimer()
        setState(.idle)
    }

    /// Delivers the next snapshot, finishing or looping at the end.
    private func tick() {
        guard state == .scanning else { return }
        if nextIndex >= recording.snapshots.count {
            if loops && !recording.snapshots.isEmpty {
                nextIndex = 0
            } else {
                finish()
                return
            }
        }
        emit(.snapshot(recording.snapshots[nextIndex]))
        nextIndex += 1
    }

    /// Creates and starts the main-queue timer.
    private func startTimer() {
        stopTimer()
        let source = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        source.schedule(deadline: .now() + interval, repeating: interval)
        source.setEventHandler { [weak self] in self?.tick() }
        source.resume()
        timer = source
    }

    /// Cancels the timer (never left suspended, so it can be released safely).
    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    /// Updates the state and reports it.
    private func setState(_ newState: ScanEngineState) {
        state = newState
        emit(.stateChanged(newState))
    }

    /// Calls `onEvent` on the main queue (directly when already on main).
    private func emit(_ event: ScanEngineEvent) {
        if Thread.isMainThread {
            onEvent?(event)
        } else {
            DispatchQueue.main.async { [weak self] in self?.onEvent?(event) }
        }
    }

    /// Stops the timer on release.
    deinit {
        timer?.cancel()
    }
}
