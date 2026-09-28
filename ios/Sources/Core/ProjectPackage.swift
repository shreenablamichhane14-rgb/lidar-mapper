import Foundation

/// Paths inside a project package (pure path helper, no IO). Layout (ship-first 2.1 as
/// amended by D3, D5, D8, D9, D11):
///
///     <id>.mapperproj/
///       project.json  thumbnail.jpg
///       raw/sessions/<session>/session.json, worldmap.arworldmap
///           rooms/<room>/        one sealed scan folder (RawScanFolder)
///           mesh-pass/<pass>/    patch and mesh-only passes (RawScanFolder)
///       raw/objects/<object>/    Images/, Checkpoint/, objectlog.json, SEAL.json
///       raw/measure/quick.json
///       derived/index.json  clean.json  plan.json
///       derived/rooms/<room>/  derived/objects/<object>/
///       derived/structure/structure.json, alignment.json
///       edits/editlog.json  edits/measurements.json
///       exports/
struct ProjectPackage: Equatable, Sendable {
    /// Package folder extension.
    static let fileExtension = "mapperproj"

    /// The package folder.
    let root: URL

    /// Creates a helper for a package folder.
    init(root: URL) {
        self.root = root
    }

    /// Joins path components under `base`; the last one is a directory when `isDirectory`.
    private func url(_ base: URL, _ parts: [String], isDirectory: Bool) -> URL {
        var result = base
        for (i, part) in parts.enumerated() {
            result = result.appendingPathComponent(part, isDirectory: i < parts.count - 1 || isDirectory)
        }
        return result
    }

    /// `project.json`.
    var manifestURL: URL { url(root, ["project.json"], isDirectory: false) }
    /// `thumbnail.jpg`.
    var thumbnailURL: URL { url(root, ["thumbnail.jpg"], isDirectory: false) }
    /// `raw/`, excluded from backup and never modified after sealing (D5).
    var rawURL: URL { url(root, ["raw"], isDirectory: true) }
    /// `raw/sessions/<id>/`.
    func sessionURL(_ id: UUID) -> URL { url(rawURL, ["sessions", id.uuidString], isDirectory: true) }
    /// `raw/sessions/<id>/session.json` (CaptureSessionRecord).
    func sessionRecordURL(_ id: UUID) -> URL { url(sessionURL(id), ["session.json"], isDirectory: false) }
    /// `raw/sessions/<id>/worldmap.arworldmap`.
    func worldMapURL(session id: UUID) -> URL { url(sessionURL(id), ["worldmap.arworldmap"], isDirectory: false) }
    /// `raw/sessions/<session>/rooms/<room>/`.
    func rawRoomURL(session: UUID, room: UUID) -> URL {
        url(sessionURL(session), ["rooms", room.uuidString], isDirectory: true)
    }
    /// `raw/sessions/<session>/mesh-pass/<pass>/`.
    func rawMeshPassURL(session: UUID, pass: UUID) -> URL {
        url(sessionURL(session), ["mesh-pass", pass.uuidString], isDirectory: true)
    }
    /// `raw/objects/<id>/`.
    func rawObjectURL(_ id: UUID) -> URL { url(rawURL, ["objects", id.uuidString], isDirectory: true) }
    /// `raw/measure/quick.json` ([MeasurementRecord] from Quick Measure).
    var quickMeasureURL: URL { url(rawURL, ["measure", "quick.json"], isDirectory: false) }

    /// `derived/`, regenerable.
    var derivedURL: URL { url(root, ["derived"], isDirectory: true) }
    /// `derived/index.json` (DerivedIndex, D11).
    var derivedIndexURL: URL { url(derivedURL, ["index.json"], isDirectory: false) }
    /// `derived/rooms/<id>/`.
    func derivedRoomURL(_ id: UUID) -> URL { url(derivedURL, ["rooms", id.uuidString], isDirectory: true) }
    /// `derived/objects/<id>/`.
    func derivedObjectURL(_ id: UUID) -> URL { url(derivedURL, ["objects", id.uuidString], isDirectory: true) }
    /// `derived/clean.json` (CleanModel before edits).
    var cleanModelURL: URL { url(derivedURL, ["clean.json"], isDirectory: false) }
    /// `derived/plan.json` (PlanModel before edits).
    var planModelURL: URL { url(derivedURL, ["plan.json"], isDirectory: false) }
    /// `derived/structure/`.
    var structureURL: URL { url(derivedURL, ["structure"], isDirectory: true) }
    /// `derived/structure/structure.json` (CapturedStructure).
    var capturedStructureURL: URL { url(structureURL, ["structure.json"], isDirectory: false) }
    /// `derived/structure/alignment.json` ([RoomAlignmentRecord], D9).
    var alignmentURL: URL { url(structureURL, ["alignment.json"], isDirectory: false) }

    /// `edits/`, user work (backed up, never touches raw).
    var editsURL: URL { url(root, ["edits"], isDirectory: true) }
    /// `edits/editlog.json` (EditLog, D3).
    var editLogURL: URL { url(editsURL, ["editlog.json"], isDirectory: false) }
    /// `edits/measurements.json` ([MeasurementRecord]).
    var measurementsURL: URL { url(editsURL, ["measurements.json"], isDirectory: false) }

    /// `exports/`, cleared on demand.
    var exportsURL: URL { url(root, ["exports"], isDirectory: true) }

    /// `SEAL.json` inside a sealed raw folder (D5).
    func sealURL(in folder: URL) -> URL { folder.appendingPathComponent(SealFile.fileName, isDirectory: false) }
}

/// File names inside one raw scan folder (a room, a mesh pass, or its InProgress folder
/// before sealing, D5, D8). Keyframe and depth files are numbered by keyframe index.
struct RawScanFolder: Equatable, Sendable {
    /// The scan folder.
    let url: URL

    /// Creates a helper for a scan folder.
    init(url: URL) {
        self.url = url
    }

    /// Child file URL.
    private func file(_ name: String) -> URL { url.appendingPathComponent(name, isDirectory: false) }

    /// `SEAL.json`.
    var sealURL: URL { file(SealFile.fileName) }
    /// `capturedroomdata.json` (RoomPlan CapturedRoomData).
    var capturedRoomDataURL: URL { file("capturedroomdata.json") }
    /// `capturedroom.json` (RoomPlan CapturedRoom at capture time).
    var capturedRoomURL: URL { file("capturedroom.json") }
    /// `roomlog.json` (RoomCaptureLog).
    var roomLogURL: URL { file("roomlog.json") }
    /// `poses.ptrk` (PoseTrackFile).
    var poseTrackURL: URL { file("poses.ptrk") }
    /// `keyframes.jsonl` (KeyframeRecord per line).
    var keyframesLogURL: URL { file("keyframes.jsonl") }
    /// `events.jsonl` (CaptureEvent per line).
    var eventsLogURL: URL { file("events.jsonl") }
    /// `photos.jsonl` (PhotoPin per line).
    var photosLogURL: URL { file("photos.jsonl") }
    /// `mesh/`.
    var meshURL: URL { url.appendingPathComponent("mesh", isDirectory: true) }
    /// `mesh/<anchor>.mchk` (MeshChunkFile).
    func meshChunkURL(anchor: UUID) -> URL {
        meshURL.appendingPathComponent(anchor.uuidString + ".mchk", isDirectory: false)
    }
    /// Relative image path of keyframe `index`: `keyframes/00012.jpg`.
    static func keyframeImagePath(_ index: Int) -> String { "keyframes/" + padded(index) + ".jpg" }
    /// Relative depth path of keyframe `index`: `depth/00012.dpth`.
    static func depthPath(_ index: Int) -> String { "depth/" + padded(index) + ".dpth" }
    /// Relative photo path: `photos/<id>.jpg`.
    static func photoPath(_ id: UUID) -> String { "photos/" + id.uuidString + ".jpg" }
    /// URL of a relative path stored in a record (for example `KeyframeRecord.imageFile`).
    func resolve(_ relativePath: String) -> URL { url.appendingPathComponent(relativePath, isDirectory: false) }

    /// Index zero-padded to 5 digits.
    private static func padded(_ index: Int) -> String {
        let digits = String(Swift.max(0, index))
        return String(repeating: "0", count: Swift.max(0, 5 - digits.count)) + digits
    }
}

/// Reads and writes project packages. All writes are atomic (temporary file in the same
/// folder, then rename). Functions are safe to call from any thread.
enum ProjectStore {
    /// Refuse to start a scan below this much free storage, bytes (D18).
    static let refuseScanBelowBytes: Int64 = 1_500_000_000
    /// Warn before a scan below this much free storage, bytes (D18).
    static let warnScanBelowBytes: Int64 = 3_000_000_000
    /// During capture, stop taking keyframes below this, bytes (D18).
    static let stopKeyframesBelowBytes: Int64 = 1_000_000_000
    /// During capture, pause below this, bytes (D18).
    static let pauseCaptureBelowBytes: Int64 = 300_000_000
    /// Object Capture preflight minimum, bytes (D18).
    static let objectCapturePreflightBytes: Int64 = 3_000_000_000

    /// Shared encoder: ISO 8601 dates, sorted keys.
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    /// Shared decoder: ISO 8601 dates.
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// `Documents/Projects/`, created when missing.
    static func projectsRoot() throws -> URL {
        let docs = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        return try ensureDirectory(docs.appendingPathComponent("Projects", isDirectory: true))
    }

    /// `Library/Application Support/InProgress/`, created when missing (D5).
    static func inProgressRoot() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        return try ensureDirectory(support.appendingPathComponent("InProgress", isDirectory: true))
    }

    /// Creates `url` (and parents) when missing; returns it.
    @discardableResult
    static func ensureDirectory(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The package of a project identifier inside `projectsRoot()`.
    static func package(for id: UUID) throws -> ProjectPackage {
        let folder = id.uuidString + "." + ProjectPackage.fileExtension
        return ProjectPackage(root: try projectsRoot().appendingPathComponent(folder, isDirectory: true))
    }

    /// Creates a new project package with its folders and manifest.
    static func create(kind: ScanMode, name: String, now: Date = Date()) throws -> (ProjectPackage, ProjectManifest) {
        let manifest = ProjectManifest.new(kind: kind, name: name, now: now)
        let created = try ProjectStore.package(for: manifest.id)
        for folder in [created.rawURL, created.derivedURL, created.editsURL, created.exportsURL] {
            try ensureDirectory(folder)
        }
        try excludeFromBackup(created.rawURL)
        try writeManifest(manifest, to: created)
        return (created, manifest)
    }

    /// Reads `project.json`. Throws `CoreError.unsupportedSchema` for a newer schema.
    static func readManifest(_ package: ProjectPackage) throws -> ProjectManifest {
        let manifest = try readJSON(ProjectManifest.self, from: package.manifestURL)
        guard manifest.schemaVersion <= ProjectManifest.currentSchema else {
            throw CoreError.unsupportedSchema(manifest.schemaVersion)
        }
        return manifest
    }

    /// Writes `project.json` atomically.
    static func writeManifest(_ manifest: ProjectManifest, to package: ProjectPackage) throws {
        try writeJSON(manifest, to: package.manifestURL)
    }

    /// All readable projects, newest change first. Unreadable packages are skipped and logged.
    static func listProjects() -> [ProjectManifest] {
        guard let root = try? projectsRoot(),
              let children = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        else { return [] }
        var manifests: [ProjectManifest] = []
        for child in children where child.pathExtension == ProjectPackage.fileExtension {
            do {
                manifests.append(try readManifest(ProjectPackage(root: child)))
            } catch {
                LogStore.shared.write("skipping project \(child.lastPathComponent): \(error)", category: "store")
            }
        }
        return manifests.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    /// Encodes `value` with `encoder` and writes it atomically, creating the folder.
    static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        try writeData(try encoder.encode(value), to: url)
    }

    /// Reads and decodes a JSON file. Throws `CoreError.missingFile` when absent.
    static func readJSON<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CoreError.missingFile(url.lastPathComponent)
        }
        return try decoder.decode(type, from: try Data(contentsOf: url))
    }

    /// Writes bytes atomically (`Data.WritingOptions.atomic` writes a temporary file in the
    /// same folder and renames it over the target), creating the folder when missing.
    static func writeData(_ data: Data, to url: URL) throws {
        try ensureDirectory(url.deletingLastPathComponent())
        try data.write(to: url, options: [.atomic])
    }

    /// Free space for important data, bytes (`volumeAvailableCapacityForImportantUsage`),
    /// falling back to plain available capacity; 0 when neither can be read.
    static func freeBytes() -> Int64 {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
        guard let values = try? home.resourceValues(forKeys: keys) else { return 0 }
        if let important = values.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        if let plain = values.volumeAvailableCapacity { return Int64(plain) }
        return 0
    }

    /// Marks a file or folder as excluded from iCloud and device backups (applied to raw/).
    static func excludeFromBackup(_ url: URL) throws {
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try target.setResourceValues(values)
    }

    /// Seals a finished raw scan folder (D5): lists its files and sizes in `SEAL.json`.
    @discardableResult
    static func sealRawFolder(_ folder: URL, now: Date = Date()) throws -> SealFile {
        let seal = try SealFile.make(folder: folder, now: now)
        try writeJSON(seal, to: folder.appendingPathComponent(SealFile.fileName, isDirectory: false))
        return seal
    }

    /// Verifies a sealed folder against its `SEAL.json`; returns mismatch lines (also logged).
    static func verifyRawFolder(_ folder: URL) -> [String] {
        let sealURL = folder.appendingPathComponent(SealFile.fileName, isDirectory: false)
        let problems: [String]
        do {
            problems = try readJSON(SealFile.self, from: sealURL).verify(folder: folder)
        } catch {
            problems = ["unreadable seal: \(error)"]
        }
        for line in problems {
            LogStore.shared.write("seal \(folder.lastPathComponent): \(line)", category: "store")
        }
        return problems
    }
}
