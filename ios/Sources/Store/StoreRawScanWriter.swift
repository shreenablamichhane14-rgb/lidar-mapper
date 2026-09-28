import Foundation

/// Serial IO for one raw scan folder. Every method returns at once; work runs in order on
/// `ioQueue`. Only this type writes raw files, and only before sealing (D5). Every write
/// uses `createParents: false` (CR-6), so nothing recreates a discarded folder.
///
/// A write call made while already running on `ioQueue` (for example `writeFile` inside a
/// `perform` block) runs at once as part of that block, so it keeps its place before any
/// later `flush` or `close`. The counters are lock-protected; the closed flag is confined to
/// `ioQueue`. Failures are counted and logged, never thrown to the caller.
final class RawScanWriter: @unchecked Sendable {
    /// Key marking `ioQueue`, so calls made on it run inline.
    private static let ioQueueKey = DispatchSpecificKey<UInt8>()

    /// Shared serial queue "mapper.io" (QoS utility).
    static let ioQueue: DispatchQueue = {
        let queue = DispatchQueue(label: "mapper.io", qos: .utility)
        queue.setSpecific(key: RawScanWriter.ioQueueKey, value: 1)
        return queue
    }()

    /// The folder this writer serves.
    let folder: RawScanFolder

    /// Protects the counters below.
    private let counterLock = NSLock()
    /// Failed writes.
    private var failures = 0
    /// Writes dropped after close.
    private var dropped = 0
    /// Bytes written.
    private var written: Int64 = 0
    /// True once the first dropped write was logged.
    private var loggedDrop = false
    /// True once the close block ran (ioQueue only).
    private var isClosed = false

    /// Creates a writer for a folder made by `InProgressScans.create`.
    init(folder: RawScanFolder) {
        self.folder = folder
    }

    /// Encodes with `ProjectStore.encoder`, appends one line plus "\n" (FileHandle, seekToEnd).
    /// On a failed or short write it truncates the file back to the offset before the append
    /// (`truncate(atOffset:)`) and increments `failureCount`, so a torn line never glues onto
    /// the next one. Lines longer than `RawScanReader.maxLineBytes` are refused (counted).
    func appendJSONLine<T: Encodable>(_ value: T, to url: URL) {
        submit { [self] in
            let encoded: Data
            do {
                encoded = try ProjectStore.encoder.encode(value)
            } catch {
                recordFailure("encode \(url.lastPathComponent)", error)
                return
            }
            guard encoded.count < RawScanReader.maxLineBytes else {
                recordFailure("line of \(encoded.count) bytes for \(url.lastPathComponent)", nil)
                return
            }
            var line = encoded
            line.append(UInt8(ascii: "\n"))
            append(line, to: url)
        }
    }

    /// Appends raw bytes (pose track).
    func appendBytes(_ data: Data, to url: URL) {
        submit { [self] in
            append(data, to: url)
        }
    }

    /// Writes a whole file atomically (temporary file, then rename). The parent folder must
    /// exist (`createParents: false`); a session file outside the scan folder needs its
    /// session folder made first with `ProjectStore.ensureDirectory(_:inside: package.root)`.
    func writeFile(_ data: Data, to url: URL) {
        submit { [self] in
            do {
                try ProjectStore.writeData(data, to: url, createParents: false)
                addWritten(data.count)
            } catch {
                recordFailure("write \(url.lastPathComponent)", error)
            }
        }
    }

    /// Runs arbitrary work on the io queue (JPEG encode then write); errors are counted and logged.
    func perform(_ work: @escaping () throws -> Void) {
        submit { [self] in
            do {
                try work()
            } catch {
                recordFailure("work", error)
            }
        }
    }

    /// Calls `completion` on the io queue after all work queued before it.
    func flush(completion: @escaping () -> Void) {
        RawScanWriter.ioQueue.async {
            completion()
        }
    }

    /// Returns after all work queued before it has run (async form of `flush(completion:)`).
    func flush() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            flush {
                continuation.resume()
            }
        }
    }

    /// Queued after all earlier work: from then on every write call is dropped and counted in
    /// `droppedAfterClose` (logged once). The engine closes the writer before sealing or
    /// discarding the folder.
    func close() {
        RawScanWriter.ioQueue.async { [self] in
            guard !isClosed else { return }
            isClosed = true
            LogStore.shared.write("writer \(folder.url.lastPathComponent) closed: \(bytesWritten) bytes, \(failureCount) failures",
                                  category: "store")
        }
    }

    /// Writes dropped because they arrived after `close()` (thread-safe).
    var droppedAfterClose: Int {
        counterLock.lock()
        defer { counterLock.unlock() }
        return dropped
    }

    /// Failed writes so far (thread-safe).
    var failureCount: Int {
        counterLock.lock()
        defer { counterLock.unlock() }
        return failures
    }

    /// Bytes written so far (thread-safe).
    var bytesWritten: Int64 {
        counterLock.lock()
        defer { counterLock.unlock() }
        return written
    }

    /// Runs `work` on the io queue unless the writer is closed by then: inline when already
    /// on the io queue, else queued.
    private func submit(_ work: @escaping () -> Void) {
        if DispatchQueue.getSpecific(key: RawScanWriter.ioQueueKey) != nil {
            runUnlessClosed(work)
        } else {
            RawScanWriter.ioQueue.async { [self] in
                runUnlessClosed(work)
            }
        }
    }

    /// Runs `work`, or counts a dropped write when the writer is closed (ioQueue only).
    private func runUnlessClosed(_ work: () -> Void) {
        guard !isClosed else {
            noteDropped()
            return
        }
        work()
    }

    /// Appends `bytes` at the end of `url` (created empty when missing; its folder must
    /// exist). A failed or short write is truncated back to the old end (ioQueue only).
    private func append(_ bytes: Data, to url: URL) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            guard fm.createFile(atPath: url.path, contents: nil) else {
                recordFailure("create \(url.lastPathComponent)", nil)
                return
            }
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: url)
        } catch {
            recordFailure("open \(url.lastPathComponent)", error)
            return
        }
        defer { try? handle.close() }
        let start: UInt64
        do {
            start = try handle.seekToEnd()
        } catch {
            recordFailure("seek \(url.lastPathComponent)", error)
            return
        }
        do {
            try handle.write(contentsOf: bytes)
            let end = try handle.offset()
            let expected = start + UInt64(bytes.count)
            guard end == expected else {
                throw MapperError.ioFailed("short write: end \(end), expected \(expected)")
            }
            addWritten(bytes.count)
        } catch {
            do {
                try handle.truncate(atOffset: start)
            } catch {
                LogStore.shared.write("writer \(folder.url.lastPathComponent): truncate of \(url.lastPathComponent) failed",
                                      category: "store")
            }
            recordFailure("append \(url.lastPathComponent)", error)
        }
    }

    /// Adds to the byte counter.
    private func addWritten(_ count: Int) {
        counterLock.lock()
        written += Int64(count)
        counterLock.unlock()
    }

    /// Counts one failure and logs the first ten, then every hundredth.
    private func recordFailure(_ what: String, _ error: Error?) {
        counterLock.lock()
        failures += 1
        let count = failures
        counterLock.unlock()
        guard count <= 10 || count % 100 == 0 else { return }
        let reason = error.map { StoreFiles.describe($0) } ?? "refused"
        LogStore.shared.write("writer \(folder.url.lastPathComponent): \(what) failed (\(reason)), failure \(count)",
                              category: "store")
    }

    /// Counts one dropped write; logs only the first.
    private func noteDropped() {
        counterLock.lock()
        dropped += 1
        let first = !loggedDrop
        loggedDrop = true
        counterLock.unlock()
        if first {
            LogStore.shared.write("writer \(folder.url.lastPathComponent): write after close dropped", category: "store")
        }
    }
}
