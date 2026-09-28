import Foundation
import RoomPlan

/// Reads and writes `derived/clean.json` (docs/MODULES.md 3.1). Thread-safe (stateless).
enum CleanModelStore {
    /// Size cap of `edits/editlog.json`, bytes (ARCHITECTURE 11.3).
    static let maxEditLogBytes: Int64 = 16 * 1024 * 1024

    /// derived/clean.json. Missing: `CoreError.missingFile`; undecodable: `CoreError.corruptFile`.
    static func loadBase(_ package: ProjectPackage) throws -> CleanModel {
        try decodeProjectJSON(CleanModel.self, from: package.cleanModelURL)
    }

    /// Applies `EditLog` from `package.editLogURL` (missing file = empty log), recomputes metrics.
    /// The last active scale correction of each room is re-applied after the recompute.
    static func loadEdited(_ package: ProjectPackage) throws -> (model: CleanModel, orphaned: [EditOperation]) {
        let base = try loadBase(package)
        let log = try loadEditLog(package)
        return base.applyingEdits(log)
    }

    /// Writes derived/clean.json atomically. The derived folder is created only while the
    /// package exists and the write never recreates a missing parent (CR-6).
    static func save(_ model: CleanModel, to package: ProjectPackage) throws {
        try ProjectStore.ensureDirectory(package.derivedURL, inside: package.root)
        try ProjectStore.writeJSON(model, to: package.cleanModelURL, createParents: false)
    }

    /// The package's edit log, or an empty log when the file does not exist.
    static func loadEditLog(_ package: ProjectPackage) throws -> EditLog {
        guard FileManager.default.fileExists(atPath: package.editLogURL.path) else { return EditLog() }
        return try decodeProjectJSON(EditLog.self, from: package.editLogURL, maxBytes: maxEditLogBytes)
    }

    /// `ProjectStore.readJSON` with decoding failures mapped to `CoreError.corruptFile`.
    static func decodeProjectJSON<T: Decodable>(_ type: T.Type, from url: URL,
                                                maxBytes: Int64 = ProjectStore.defaultMaxJSONBytes) throws -> T {
        do {
            return try ProjectStore.readJSON(type, from: url, maxBytes: maxBytes)
        } catch is DecodingError {
            throw CoreError.corruptFile(url.lastPathComponent)
        }
    }
}

/// Locates and decodes RoomPlan's `CapturedRoom` for a room (raw, rebuilt or provisional).
/// RoomPlan JSON is read with a plain `JSONDecoder()` (docs/MODULES.md 3.1). Thread-safe.
enum CapturedRoomStore {
    /// Size cap of a `capturedroom.json` file, bytes (ARCHITECTURE 11.3).
    static let maxCapturedRoomBytes: Int64 = 64 * 1024 * 1024
    /// Size cap of a `capturedroomdata.json` file, bytes.
    static let maxCapturedRoomDataBytes: Int64 = 256 * 1024 * 1024

    /// Where a loaded room came from.
    enum Source: String, Sendable {
        /// Raw `capturedroom.json` written at capture time.
        case raw
        /// `derived/rooms/<id>/capturedroom.json` rebuilt by `BuildRoomStep`.
        case rebuilt
        /// Raw `capturedroom-live.json` of a killed capture (provisional).
        case live
    }

    /// The sealed raw folder of a room.
    static func rawFolder(_ package: ProjectPackage, room: RoomRecord) -> RawScanFolder {
        RawScanFolder(url: package.rawRoomURL(session: room.sessionID, room: room.id))
    }

    /// derived/rooms/<id>/capturedroom.json
    static func rebuiltURL(_ package: ProjectPackage, roomID: UUID) -> URL {
        package.derivedRoomURL(roomID).appendingPathComponent("capturedroom.json", isDirectory: false)
    }

    /// Raw capturedroom.json first, then the rebuilt derived one, then raw capturedroom-live.json.
    /// A file that exists but cannot be decoded is logged and the next one is tried; when none
    /// loads, the first error is thrown (`CoreError.missingFile` when no file exists).
    static func loadCapturedRoom(_ package: ProjectPackage, room: RoomRecord) throws -> CapturedRoom {
        try loadWithSource(package, room: room).room
    }

    /// As `loadCapturedRoom`; `isProvisional` is true when the live file was used.
    static func loadInput(_ package: ProjectPackage, room: RoomRecord) throws -> RoomInput {
        let loaded = try loadWithSource(package, room: room)
        var input = RoomInput(loaded.room)
        input.isProvisional = loaded.source == .live
        return input
    }

    /// The first loadable room in the order raw, rebuilt, live, with its source.
    static func loadWithSource(_ package: ProjectPackage, room: RoomRecord) throws -> (room: CapturedRoom, source: Source) {
        let folder = rawFolder(package, room: room)
        let candidates: [(url: URL, source: Source)] = [
            (folder.capturedRoomURL, .raw),
            (rebuiltURL(package, roomID: room.id), .rebuilt),
            (folder.liveCapturedRoomURL, .live)
        ]
        var firstError: Error?
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.url.path) {
            do {
                let decoded = try decodeRoomPlanJSON(CapturedRoom.self, from: candidate.url, maxBytes: maxCapturedRoomBytes)
                return (decoded, candidate.source)
            } catch {
                LogStore.shared.write("room \(room.id): \(candidate.source.rawValue) capturedroom unreadable: \(error)",
                                      category: RoomOutline.logCategory)
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
        throw CoreError.missingFile("capturedroom.json")
    }

    /// True when a raw or rebuilt (final) CapturedRoom file exists for the room.
    static func hasFinalRoom(_ package: ProjectPackage, room: RoomRecord) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: rawFolder(package, room: room).capturedRoomURL.path)
            || fm.fileExists(atPath: rebuiltURL(package, roomID: room.id).path)
    }

    /// Size-capped read and plain `JSONDecoder()` decode of a RoomPlan JSON file. Missing:
    /// `CoreError.missingFile`; too large: `CoreError.fileTooLarge`; undecodable:
    /// `CoreError.corruptFile`.
    static func decodeRoomPlanJSON<T: Decodable>(_ type: T.Type, from url: URL, maxBytes: Int64) throws -> T {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { throw CoreError.missingFile(url.lastPathComponent) }
        let attributes = try fm.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard size <= maxBytes else { throw CoreError.fileTooLarge(name: url.lastPathComponent, bytes: size) }
        let data = try Data(contentsOf: url)
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw CoreError.corruptFile(url.lastPathComponent)
        }
    }
}
