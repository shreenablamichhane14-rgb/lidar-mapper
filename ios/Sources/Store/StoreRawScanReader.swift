import Foundation

/// Read-only access to a sealed or in-progress raw scan folder. Safe on any thread.
///
/// Every file is size-capped before it is read (untrusted input, ARCHITECTURE 11.3). Missing
/// optional files read as empty (a scan without photos has no photos.jsonl); only oversized
/// or unreadable files throw.
struct RawScanReader {
    /// Longest accepted JSON Lines line, bytes (ARCHITECTURE 11.3: 64 KB).
    static let maxLineBytes = 64 * 1024
    /// Read cap of one JSON Lines file, bytes.
    static let maxJSONLinesBytes: Int64 = 64 * 1024 * 1024
    /// Read cap of `poses.ptrk`, bytes.
    static let maxPoseTrackBytes: Int64 = 64 * 1024 * 1024
    /// Read cap of one `.mchk` file, bytes (ARCHITECTURE 11.3: 256 MB).
    static let maxMeshChunkBytes: Int64 = 256 * 1024 * 1024
    /// Read cap of `roomlog.json`, bytes.
    static let maxRoomLogBytes: Int64 = 1024 * 1024

    /// The folder being read.
    let folder: RawScanFolder

    /// Creates a reader.
    init(folder: RawScanFolder) {
        self.folder = folder
    }

    /// `scan.json`, or nil when absent or unreadable (unreadable is logged).
    func info() -> InProgressScanInfo? {
        let url = folder.url.appendingPathComponent(InProgressScanInfo.fileName, isDirectory: false)
        guard StoreFiles.exists(url) else { return nil }
        do {
            return try ProjectStore.readJSON(InProgressScanInfo.self, from: url, maxBytes: InProgressScanInfo.maxBytes)
        } catch {
            LogStore.shared.write("scan \(folderName): unreadable scan.json (\(StoreFiles.describe(error)))", category: "store")
            return nil
        }
    }

    /// JSON Lines readers skip every line that does not decode (a torn last line after a crash,
    /// or a middle line after a failed append), count the skipped lines and log the count once.
    /// Records whose file paths fail `PackageCheck.isSafeRecordPath` are dropped and logged.
    func keyframes() throws -> [KeyframeRecord] {
        let read = try RawScanReader.jsonLines(KeyframeRecord.self, at: folder.keyframesLogURL)
        let safe = read.records.filter { RawScanReader.hasSafePaths($0) }
        logDropped(read.records.count - safe.count, file: "keyframes.jsonl")
        return safe
    }

    /// Photo pins of `photos.jsonl` (unsafe image paths dropped and logged).
    func photos() throws -> [PhotoPin] {
        let read = try RawScanReader.jsonLines(PhotoPin.self, at: folder.photosLogURL)
        let safe = read.records.filter { PackageCheck.isSafeRecordPath($0.imageFile) }
        logDropped(read.records.count - safe.count, file: "photos.jsonl")
        return safe
    }

    /// Capture events of `events.jsonl`.
    func events() throws -> [CaptureEvent] {
        try RawScanReader.jsonLines(CaptureEvent.self, at: folder.eventsLogURL).records
    }

    /// Samples of `poses.ptrk`: empty when the file is missing or holds less than a header
    /// (a crash before the header was written); a partial last record is ignored by Core.
    func poseSamples() throws -> [PoseSample] {
        let url = folder.poseTrackURL
        guard StoreFiles.exists(url) else { return [] }
        let data = try StoreFiles.readCapped(url, maxBytes: RawScanReader.maxPoseTrackBytes)
        guard data.count >= PoseTrackFile.headerSize else {
            if !data.isEmpty {
                LogStore.shared.write("scan \(folderName): pose track shorter than its header", category: "store")
            }
            return []
        }
        return try PoseTrackFile.decode(data)
    }

    /// `roomlog.json`, or nil when absent (a recovered scan) or unreadable (logged).
    func roomLog() -> RoomCaptureLog? {
        let url = folder.roomLogURL
        guard StoreFiles.exists(url) else { return nil }
        do {
            return try ProjectStore.readJSON(RoomCaptureLog.self, from: url, maxBytes: RawScanReader.maxRoomLogBytes)
        } catch {
            LogStore.shared.write("scan \(folderName): unreadable roomlog.json (\(StoreFiles.describe(error)))", category: "store")
            return nil
        }
    }

    /// The `mesh/*.mchk` files, sorted by name (temporary files of atomic writes excluded).
    func meshChunkURLs() -> [URL] {
        guard let children = try? FileManager.default.contentsOfDirectory(at: folder.meshURL, includingPropertiesForKeys: nil)
        else { return [] }
        return children
            .filter { $0.pathExtension == "mchk" && !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Decodes every mesh/*.mchk; corrupt files are skipped and logged when `skipCorrupt`.
    /// With `skipCorrupt` false one corrupt file makes the result empty (all or nothing).
    func meshChunks(skipCorrupt: Bool = true) -> [MeshChunk] {
        var chunks: [MeshChunk] = []
        var corrupt = 0
        for url in meshChunkURLs() {
            do {
                let data = try StoreFiles.readCapped(url, maxBytes: RawScanReader.maxMeshChunkBytes)
                chunks.append(try MeshChunkFile.decode(data))
            } catch {
                corrupt += 1
                if corrupt <= 5 {
                    LogStore.shared.write("scan \(folderName): bad chunk \(url.lastPathComponent) (\(StoreFiles.describe(error)))",
                                          category: "store")
                }
                if !skipCorrupt { return [] }
            }
        }
        if corrupt > 0 {
            LogStore.shared.write("scan \(folderName): skipped \(corrupt) corrupt mesh chunks", category: "store")
        }
        return chunks
    }

    /// True when `capturedroom.json` exists.
    var hasCapturedRoom: Bool { StoreFiles.exists(folder.capturedRoomURL) }
    /// True when `capturedroomdata.json` exists.
    var hasCapturedRoomData: Bool { StoreFiles.exists(folder.capturedRoomDataURL) }
    /// True when `capturedroom-live.json` exists.
    var hasLiveCapturedRoom: Bool { StoreFiles.exists(folder.liveCapturedRoomURL) }

    /// The image file of a keyframe, or nil when its path is unsafe (`RawScanFolder.resolve`).
    func imageURL(for record: KeyframeRecord) -> URL? {
        folder.resolve(record.imageFile)
    }

    /// The depth file of a keyframe, or nil when there is none or its path is unsafe.
    func depthURL(for record: KeyframeRecord) -> URL? {
        guard let path = record.depthFile else { return nil }
        return folder.resolve(path)
    }

    /// The image file of a photo pin, or nil when its path is unsafe.
    func imageURL(for pin: PhotoPin) -> URL? {
        folder.resolve(pin.imageFile)
    }

    /// Reads a JSON Lines file. Lines skipped by this read are returned in `skipped`: every
    /// non-empty line that is longer than `maxLineBytes` or does not decode with
    /// `ProjectStore.decoder` is skipped and counted (the count is logged once per read). A
    /// missing file reads as empty; a file over `maxJSONLinesBytes` throws
    /// `CoreError.fileTooLarge`.
    static func jsonLines<T: Decodable>(_ type: T.Type, at url: URL) throws -> (records: [T], skipped: Int) {
        guard StoreFiles.exists(url) else { return (records: [], skipped: 0) }
        let data = try StoreFiles.readCapped(url, maxBytes: maxJSONLinesBytes)
        var records: [T] = []
        var skipped = 0
        for line in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            guard line.count <= maxLineBytes else {
                skipped += 1
                continue
            }
            do {
                records.append(try ProjectStore.decoder.decode(T.self, from: Data(line)))
            } catch {
                skipped += 1
            }
        }
        if skipped > 0 {
            LogStore.shared.write("\(url.lastPathComponent): skipped \(skipped) undecodable lines", category: "store")
        }
        return (records: records, skipped: skipped)
    }

    /// True when a keyframe's image path and depth path (if any) pass `isSafeRecordPath`.
    static func hasSafePaths(_ record: KeyframeRecord) -> Bool {
        guard PackageCheck.isSafeRecordPath(record.imageFile) else { return false }
        guard let depth = record.depthFile else { return true }
        return PackageCheck.isSafeRecordPath(depth)
    }

    /// The scan folder name (its UUID) for logs.
    private var folderName: String { folder.url.lastPathComponent }

    /// Logs records dropped for unsafe paths.
    private func logDropped(_ count: Int, file: String) {
        guard count > 0 else { return }
        LogStore.shared.write("scan \(folderName): dropped \(count) records with unsafe paths in \(file)", category: "store")
    }
}
