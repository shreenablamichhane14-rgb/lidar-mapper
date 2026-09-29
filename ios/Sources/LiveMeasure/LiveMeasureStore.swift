import Foundation

// Quick Measure's raw file (MODULES 3.1 and 3.36): `raw/measure/quick.json` with the saved
// measurements, sealed with `SEAL.json` as soon as it is written (raw is never modified after
// sealing, D5). Results and ExportUI read it through `QuickMeasureStore.load`; renames and
// deletions go to `edits/measurements.json` (Store `EditStore`), never here.

/// `raw/measure/quick.json` (`ProjectPackage.quickMeasureURL`).
struct QuickMeasureFile: Codable, Equatable, Sendable {
    /// Format version written by this build.
    static let currentVersion = 1
    /// Format version of the file.
    var version: Int
    /// When the measurements were saved.
    var createdAt: Date
    /// The measurements, in the order they were made (kind `.distance`, source `.live`).
    var records: [MeasurementRecord]
}

/// Reads and writes `raw/measure/quick.json`. Any thread.
enum QuickMeasureStore {
    /// Largest quick.json read, bytes.
    static let maxBytes: Int64 = 4 * 1024 * 1024

    /// raw/measure/.
    static func folder(_ package: ProjectPackage) -> URL {
        package.quickMeasureURL.deletingLastPathComponent()
    }

    /// Makes raw/measure/ with `ProjectStore.ensureDirectory(_:inside: package.root)`, writes quick.json with
    /// `ProjectStore.writeJSON(_:to:createParents: false)`, then seals the folder (`ProjectStore.sealRawFolder`).
    /// Throws when the package is gone.
    static func save(_ records: [MeasurementRecord], to package: ProjectPackage, now: Date) throws {
        let measureFolder = folder(package)
        try ProjectStore.ensureDirectory(measureFolder, inside: package.root)
        let file = QuickMeasureFile(version: QuickMeasureFile.currentVersion, createdAt: now, records: records)
        try ProjectStore.writeJSON(file, to: package.quickMeasureURL, createParents: false)
        let seal = try ProjectStore.sealRawFolder(measureFolder, now: now)
        LogStore.shared.write("quick.json sealed: \(records.count) measurements, \(seal.totalBytes) bytes",
                              category: "livemeasure")
    }

    /// Nil when absent or unreadable (logged); reads with `maxBytes`.
    static func load(_ package: ProjectPackage) -> QuickMeasureFile? {
        let url = package.quickMeasureURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let file = try ProjectStore.readJSON(QuickMeasureFile.self, from: url, maxBytes: maxBytes)
            if file.version > QuickMeasureFile.currentVersion {
                LogStore.shared.write("quick.json version \(file.version) is newer than \(QuickMeasureFile.currentVersion); "
                                      + "reading the known fields", category: "livemeasure")
            }
            return file
        } catch {
            LogStore.shared.write("quick.json unreadable: \(error)", category: "livemeasure")
            return nil
        }
    }
}
