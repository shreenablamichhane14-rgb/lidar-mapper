import Foundation

/// Appends every snapshot as JSON Lines to Documents/Diagnostics/recording-<timestamp>.jsonl when enabled.
///
/// Diagnostics > Record Scan Snapshots (`SettingsKey.recordSnapshots`): a real room scan is
/// saved in the format `SnapshotRecording.decodeJSONLines` reads, so it can be replayed with
/// `FakeScanEngine` for UI work without ARKit. Snapshots hold counts, states and device
/// readings only (no images, no positions of people, no identifiers).
///
/// Threading: call from one thread (the scan flow calls it on main); encoding and file writes
/// run on a private serial queue. The file is capped at `maxBytes`; later snapshots are
/// dropped (logged once).
final class SnapshotRecorder {
    /// Largest recording file, bytes.
    static let maxBytes: Int64 = 64 * 1024 * 1024
    /// Folder name under Documents.
    static let folderName = "Diagnostics"

    /// The recording file.
    let url: URL
    /// Serial queue of the encoding and writes.
    private let queue = DispatchQueue(label: "mapper.scanui.snapshots", qos: .utility)
    /// The open file (touched only on `queue`).
    private var handle: FileHandle?
    /// Bytes written so far (touched only on `queue`).
    private var written: Int64 = 0
    /// True once the cap was reached (touched only on `queue`).
    private var capped = false
    /// Encoder with sorted keys, like `SnapshotRecording.encodeJSONLines`.
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    /// Nil when `enabled` is false or the file cannot be created (logged). Otherwise creates
    /// Documents/Diagnostics/recording-<yyyyMMdd-HHmmss>.jsonl.
    init?(enabled: Bool) {
        guard enabled else { return nil }
        do {
            let docs = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil,
                                                   create: true)
            let folder = docs.appendingPathComponent(SnapshotRecorder.folderName, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("recording-" + SnapshotRecorder.stamp(Date()) + ".jsonl",
                                                     isDirectory: false)
            guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
                LogStore.shared.write("snapshot recording could not be created", category: "scanui")
                return nil
            }
            url = file
            handle = try FileHandle(forWritingTo: file)
        } catch {
            LogStore.shared.write("snapshot recording not started: \(error)", category: "scanui")
            return nil
        }
        LogStore.shared.write("snapshot recording started: \(url.lastPathComponent)", category: "scanui")
    }

    /// Appends one snapshot as a JSON line (asynchronously, in call order).
    func record(_ snapshot: LiveScanSnapshot) {
        queue.async { [self] in
            guard let file = handle, !capped else { return }
            do {
                var line = try encoder.encode(snapshot)
                line.append(10)
                guard written + Int64(line.count) <= SnapshotRecorder.maxBytes else {
                    capped = true
                    LogStore.shared.write("snapshot recording reached \(SnapshotRecorder.maxBytes / 1_048_576) MB; "
                                          + "later snapshots dropped", category: "scanui")
                    return
                }
                try file.write(contentsOf: line)
                written += Int64(line.count)
            } catch {
                capped = true
                LogStore.shared.write("snapshot recording stopped: \(error)", category: "scanui")
            }
        }
    }

    /// Closes the file after the queued lines are written. Idempotent.
    func close() {
        queue.async { [self] in
            guard let file = handle else { return }
            handle = nil
            do {
                try file.close()
            } catch {
                LogStore.shared.write("snapshot recording close failed: \(error)", category: "scanui")
            }
            LogStore.shared.write("snapshot recording closed: \(written) bytes", category: "scanui")
        }
    }

    /// Closes the file if `close()` was never called.
    deinit {
        if let file = handle {
            try? file.close()
        }
    }

    /// File name time stamp, "yyyyMMdd-HHmmss" in the device time zone (POSIX digits).
    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}
