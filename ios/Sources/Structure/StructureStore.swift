import Foundation
import RoomPlan
import simd

// Every file under derived/structure/ (docs/MODULES.md 3.1 and 3.30) and the effective room
// placements that consumers use. RoomPlan types (CapturedStructure) are written with a plain
// JSONEncoder and read with a plain JSONDecoder; Mapper's own files use ProjectStore's encoder
// and decoder. Stateless and safe on any thread.

/// `derived/structure/attempt.json`: written right before StructureBuilder runs, removed right
/// after it returns or throws. Present at the next run: the app died inside the builder.
struct StructureAttempt: Codable, Equatable, Sendable {
    /// When the builder was called.
    var startedAt: Date
    /// Rooms passed to the builder.
    var roomIDs: [UUID]
    /// MergeStructureStep input hash at that time (logs only; never matched, 3.30).
    var inputHash: String
}

/// What MergeStructureStep did. Raw values are persisted in merge.json.
enum StructureMergeOutcome: String, Codable, CaseIterable, Sendable {
    /// StructureBuilder returned; structure.json holds the result.
    case merged
    /// Fewer than 2 mergeable rooms.
    case tooFewRooms
    /// StructureBuilder threw (`detail` has the error).
    case builderFailed
    /// attempt.json was left by a run that died inside the builder; not retried automatically.
    case crashedBefore
    /// The reduced variant ran (low memory, or forced after a crash); the builder was not called.
    case skippedReducedMemory
    /// `RoomCaptureSession.isSupported` is false.
    case unsupported
}

/// `derived/structure/merge.json` (MergeStructureStep).
struct StructureMergeResult: Codable, Equatable, Sendable {
    /// The outcome.
    var outcome: StructureMergeOutcome
    /// Rooms inside structure.json (empty unless `merged`).
    var mergedRooms: [UUID]
    /// Active rooms not passed to the builder (other frames, unaligned or manual rooms, rooms
    /// that could not be loaded) and, for every outcome but `merged`, the rooms that would have
    /// been merged.
    var separateRooms: [UUID]
    /// Anchor-group rooms left out because only the provisional live room exists.
    var provisionalRooms: [UUID]
    /// Builder error description (logs only, never shown).
    var detail: String?
    /// Wall time of the step, seconds.
    var seconds: Double
    /// Input hash of the run.
    var inputHash: String
    /// When the step finished.
    var finishedAt: Date
}

/// `derived/structure/placements.json` (AlignRoomsStep).
struct StructurePlacements: Codable, Equatable, Sendable {
    /// One report per placed or parked room, manifest order.
    var rooms: [RoomPlacementReport]
    /// Active rooms without a placement.
    var unplaced: [UUID]
    /// Input hash of the run.
    var inputHash: String
    /// When the step finished.
    var finishedAt: Date
}

/// A room's derived floor index (connections.json).
struct FloorAssignmentEntry: Codable, Equatable, Sendable { var roomID: UUID; var floorIndex: Int }

/// `derived/structure/connections.json` (HouseCleanModelStep).
struct StructureConnections: Codable, Equatable, Sendable {
    /// Shared walls with measured thickness.
    var sharedWalls: [SharedWallPair]
    /// Doorways drawn once.
    var doorways: [DoorwayLink]
    /// Derived floor index of every room in clean.json, model order.
    var floors: [FloorAssignmentEntry]
    /// Input hash of the run.
    var inputHash: String
    /// The effective placement each room of clean.json was built with (user edits included), so
    /// the next build can log rooms whose placement changed. Nil in files without the key.
    var appliedAlignments: [RoomAlignmentRecord]? = nil
}

/// Everything HouseUI and Results read about a house's structure, in one value.
struct StructureReport: Equatable, Sendable {
    /// merge.json, when present and readable.
    var merge: StructureMergeResult?
    /// placements.json, when present and readable.
    var placements: StructurePlacements?
    /// connections.json, when present and readable.
    var connections: StructureConnections?
    /// True while attempt.json exists (the builder died last time).
    var hasCrashedAttempt: Bool

    /// Nothing known yet.
    static let empty = StructureReport(merge: nil, placements: nil, connections: nil, hasCrashedAttempt: false)

    /// The placement report of one room, if any.
    func placement(for roomID: UUID) -> RoomPlacementReport? {
        placements?.rooms.first { $0.roomID == roomID }
    }
}

/// Reads and writes derived/structure/ and resolves effective room placements.
enum StructureStore {
    /// Size cap of structure.json, bytes.
    static let maxStructureBytes: Int64 = 128 * 1024 * 1024
    /// Size cap of Mapper's own structure files, bytes.
    static let maxReportBytes: Int64 = 16 * 1024 * 1024
    /// Log category.
    static let logCategory = "structure"

    /// derived/structure/attempt.json
    static func attemptURL(_ package: ProjectPackage) -> URL { file(package, "attempt.json") }
    /// derived/structure/merge.json
    static func mergeURL(_ package: ProjectPackage) -> URL { file(package, "merge.json") }
    /// derived/structure/placements.json
    static func placementsURL(_ package: ProjectPackage) -> URL { file(package, "placements.json") }
    /// derived/structure/connections.json
    static func connectionsURL(_ package: ProjectPackage) -> URL { file(package, "connections.json") }

    /// A file inside derived/structure/.
    private static func file(_ package: ProjectPackage, _ name: String) -> URL {
        let folder: URL = package.structureURL
        return folder.appendingPathComponent(name, isDirectory: false)
    }

    /// `ProjectStore.ensureDirectory(package.structureURL, inside: package.root)` (CR-6).
    @discardableResult static func ensureFolder(_ package: ProjectPackage) throws -> URL {
        try ProjectStore.ensureDirectory(package.structureURL, inside: package.root)
    }

    // MARK: structure.json

    /// `package.capturedStructureURL` with a plain `JSONDecoder()` through RoomModel's
    /// `CapturedRoomStore.decodeRoomPlanJSON(_:from:maxBytes:)`; nil when absent.
    static func loadStructure(_ package: ProjectPackage) throws -> CapturedStructure? {
        guard FileManager.default.fileExists(atPath: package.capturedStructureURL.path) else { return nil }
        return try CapturedRoomStore.decodeRoomPlanJSON(CapturedStructure.self, from: package.capturedStructureURL,
                                                        maxBytes: maxStructureBytes)
    }

    /// Plain `JSONEncoder()`, `ProjectStore.writeData(_:to:createParents: false)`.
    static func saveStructure(_ structure: CapturedStructure, to package: ProjectPackage) throws {
        let data = try JSONEncoder().encode(structure)
        try ensureFolder(package)
        try ProjectStore.writeData(data, to: package.capturedStructureURL, createParents: false)
    }

    /// Removes structure.json when present (a failure is logged).
    static func removeStructure(_ package: ProjectPackage) {
        remove(package.capturedStructureURL)
    }

    // MARK: Mapper's own files

    /// `package.alignmentURL` ([RoomAlignmentRecord], Core doc); empty when absent or unreadable.
    static func loadAlignments(_ package: ProjectPackage) -> [RoomAlignmentRecord] {
        loadAlignmentsIfPresent(package) ?? []
    }

    /// alignment.json, or nil when it is absent or unreadable (logged).
    static func loadAlignmentsIfPresent(_ package: ProjectPackage) -> [RoomAlignmentRecord]? {
        read([RoomAlignmentRecord].self, from: package.alignmentURL)
    }

    /// Writes alignment.json (derived records only; user alignments stay in the EditLog).
    static func saveAlignments(_ records: [RoomAlignmentRecord], to package: ProjectPackage) throws {
        try write(records, to: package.alignmentURL, in: package)
    }

    /// merge.json, or nil when absent or unreadable.
    static func loadMerge(_ package: ProjectPackage) -> StructureMergeResult? {
        read(StructureMergeResult.self, from: mergeURL(package))
    }

    /// Writes merge.json.
    static func saveMerge(_ result: StructureMergeResult, to package: ProjectPackage) throws {
        try write(result, to: mergeURL(package), in: package)
    }

    /// placements.json, or nil when absent or unreadable.
    static func loadPlacements(_ package: ProjectPackage) -> StructurePlacements? {
        read(StructurePlacements.self, from: placementsURL(package))
    }

    /// Writes placements.json.
    static func savePlacements(_ placements: StructurePlacements, to package: ProjectPackage) throws {
        try write(placements, to: placementsURL(package), in: package)
    }

    /// connections.json, or nil when absent or unreadable.
    static func loadConnections(_ package: ProjectPackage) -> StructureConnections? {
        read(StructureConnections.self, from: connectionsURL(package))
    }

    /// Writes connections.json.
    static func saveConnections(_ connections: StructureConnections, to package: ProjectPackage) throws {
        try write(connections, to: connectionsURL(package), in: package)
    }

    /// attempt.json, or nil when absent or unreadable.
    static func loadAttempt(_ package: ProjectPackage) -> StructureAttempt? {
        read(StructureAttempt.self, from: attemptURL(package))
    }

    /// Writes attempt.json (MergeStructureStep, right before the builder call).
    static func writeAttempt(_ attempt: StructureAttempt, to package: ProjectPackage) throws {
        try write(attempt, to: attemptURL(package), in: package)
    }

    /// Removes attempt.json after the builder returned or threw (a failure is logged).
    static func removeAttempt(_ package: ProjectPackage) {
        remove(attemptURL(package))
    }

    /// Everything known about the house's structure.
    static func loadReport(_ package: ProjectPackage) -> StructureReport {
        StructureReport(merge: loadMerge(package), placements: loadPlacements(package),
                        connections: loadConnections(package), hasCrashedAttempt: hasCrashedAttempt(package))
    }

    /// True while attempt.json exists.
    static func hasCrashedAttempt(_ package: ProjectPackage) -> Bool {
        FileManager.default.fileExists(atPath: attemptURL(package).path)
    }

    /// HouseUI "Join Rooms Again": removes attempt.json so the next job calls the builder again.
    static func clearCrashedAttempt(_ package: ProjectPackage) throws {
        let url = attemptURL(package)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
        LogStore.shared.write("crashed merge attempt cleared; the next job joins the rooms again", category: logCategory)
    }

    // MARK: Effective placements

    /// The last `setRoomAlignment` per room in `log.flattenedActive` (CR-1: a batch may hold one),
    /// source forced to `.user`.
    static func userAlignments(_ log: EditLog) -> [UUID: RoomAlignmentRecord] {
        var result: [UUID: RoomAlignmentRecord] = [:]
        for operation in log.flattenedActive {
            guard case .setRoomAlignment(let record) = operation else { continue }
            var user = record
            user.source = .user
            result[user.roomID] = user
        }
        return result
    }

    /// Derived records overridden by user edits (pure). The last derived record per room wins
    /// when `measured` repeats a room.
    static func effectiveAlignments(measured: [RoomAlignmentRecord], log: EditLog) -> [UUID: RoomAlignmentRecord] {
        var result: [UUID: RoomAlignmentRecord] = [:]
        for record in measured { result[record.roomID] = record }
        for (id, record) in userAlignments(log) { result[id] = record }
        return result
    }

    /// `loadAlignments` plus `EditStore.load(package)` (any thread). Results, ExportUI and the
    /// build 5 viewers place each room's mesh, keyframes and textures with
    /// `StructureAlignment.matrix` of this record.
    static func effectiveAlignments(_ package: ProjectPackage) -> [UUID: RoomAlignmentRecord] {
        effectiveAlignments(measured: loadAlignments(package), log: EditStore.load(package))
    }

    /// Pure. Where Results and ExportUI draw each active room (`StructureEligibility.activeRooms`):
    /// `StructureAlignment.matrix` of its record in `alignments`; without a record, identity for a
    /// room of the anchor frame group (it shares the structure frame, exactly as
    /// HouseCleanModelStep's fallback plan places it while alignment.json is missing) and no entry
    /// for a room of another group (it waits for AlignRoomsStep to park it). Every active room of a
    /// non-House project gets identity. Rooms without an entry are skipped by the caller.
    static func placementMatrices(manifest: ProjectManifest,
                                  alignments: [UUID: RoomAlignmentRecord]) -> [UUID: simd_float4x4] {
        let active = StructureEligibility.activeRooms(manifest)
        var result: [UUID: simd_float4x4] = [:]
        guard manifest.kind == .house else {
            for room in active { result[room.id] = matrix_identity_float4x4 }
            return result
        }
        let anchor = StructureEligibility.anchorRoomIDs(rooms: active, sessions: manifest.sessions)
        for room in active {
            if let record = alignments[room.id] {
                result[room.id] = StructureAlignment.matrix(record)
            } else if anchor.contains(room.id) {
                result[room.id] = matrix_identity_float4x4
            }
        }
        return result
    }

    /// Stable text of the user alignments for input hashes ("-" when none): one
    /// "room:yaw:x:y:z" entry per room with the exact float bit patterns, sorted by room id.
    static func alignmentEditDigest(_ log: EditLog) -> String {
        let user = userAlignments(log)
        guard !user.isEmpty else { return "-" }
        let entries = user.values.sorted { $0.roomID.uuidString < $1.roomID.uuidString }.map { record -> String in
            let parts = [record.yaw, record.translation.x, record.translation.y, record.translation.z]
                .map { String($0.bitPattern, radix: 16) }
            return record.roomID.uuidString + ":" + parts.joined(separator: ":")
        }
        return entries.joined(separator: ";")
    }

    // MARK: Helpers

    /// Decodes one of Mapper's own structure files; nil when absent, logged when unreadable.
    private static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try ProjectStore.readJSON(type, from: url, maxBytes: maxReportBytes)
        } catch {
            LogStore.shared.write("\(url.lastPathComponent) unreadable: \(error)", category: logCategory)
            return nil
        }
    }

    /// Writes one of Mapper's own structure files (folder created only inside an existing
    /// package, never recreating a missing parent, CR-6).
    private static func write<T: Encodable>(_ value: T, to url: URL, in package: ProjectPackage) throws {
        try ensureFolder(package)
        try ProjectStore.writeJSON(value, to: url, createParents: false)
    }

    /// Removes a file when present; a failure is logged.
    private static func remove(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            LogStore.shared.write("\(url.lastPathComponent) not removed: \(error)", category: logCategory)
        }
    }
}
