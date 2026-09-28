import Foundation

/// Reads and writes `derived/rooms/<r>/quality.json` (docs/MODULES.md 3.1) and mirrors the
/// summary into `RoomRecord.quality`. Stateless and safe on any thread.
enum QualityStore {
    /// File name inside the room's derived folder.
    static let fileName = "quality.json"
    /// quality.json larger than this is refused as damaged, bytes.
    static let maxBytes: Int64 = 16 * 1024 * 1024

    /// Thrown inside the manifest update to leave the manifest untouched when the room is not
    /// listed (for example a room DemoProjectFactory writes before appending its record).
    private enum SaveOutcome: Error {
        /// The evaluated room is not in `manifest.rooms`.
        case roomNotInManifest
    }

    /// derived/rooms/<r>/quality.json
    static func url(_ package: ProjectPackage, room: UUID) -> URL {
        package.derivedRoomURL(room).appendingPathComponent(fileName, isDirectory: false)
    }

    /// The stored evaluation, or nil when the file is absent, too large or unreadable (the last
    /// two are logged).
    static func load(_ package: ProjectPackage, room: UUID) -> QualityEvaluation? {
        let file = url(package, room: room)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        do {
            return try ProjectStore.readJSON(QualityEvaluation.self, from: file, maxBytes: maxBytes)
        } catch {
            LogStore.shared.write("room \(room): quality.json unreadable (\(error))", category: QualityEvaluator.logCategory)
            return nil
        }
    }

    /// Writes quality.json and sets RoomRecord.quality through ManifestWriter.
    ///
    /// Both happen inside one `ManifestWriter.update`, so a concurrent `discardRoom` either sees
    /// the finished write or removes the room first. The derived room folder is created only
    /// while the package exists (CR-6). When the room is not listed in the manifest, quality.json
    /// is still written, the manifest is left unchanged and the case is logged. Throws when the
    /// manifest cannot be read (for example the project was deleted) or a write fails.
    static func save(_ evaluation: QualityEvaluation, package: ProjectPackage) throws {
        let stored = evaluation.sanitizedForStorage()
        let data = try ProjectStore.encoder.encode(stored)
        let roomID = stored.roomID
        do {
            try ManifestWriter.update(package) { manifest in
                try ProjectStore.ensureDirectory(package.derivedRoomURL(roomID), inside: package.root)
                try ProjectStore.writeData(data, to: url(package, room: roomID), createParents: false)
                guard let index = manifest.rooms.firstIndex(where: { $0.id == roomID }) else {
                    throw SaveOutcome.roomNotInManifest
                }
                manifest.rooms[index].quality = stored.summary
            }
        } catch SaveOutcome.roomNotInManifest {
            LogStore.shared.write("room \(roomID): not in the manifest; quality.json written, RoomRecord not updated",
                                  category: QualityEvaluator.logCategory)
        }
    }
}
