import Foundation
import UIKit
import os

/// Persistent troubleshooting log.
///
/// One text file per day in Documents/Logs (visible in the Files app under
/// "On My iPhone > Mapper", pullable over USB with pymobiledevice3 and
/// readable over Wi-Fi through DebugServer). Lines are also mirrored to the
/// unified system log (subsystem com.shreehub.mapper) so
/// `pymobiledevice3 syslog live` shows them live. API keys are never written.
final class LogStore {
    static let shared = LogStore()

    static let keepDays = 7

    private let queue = DispatchQueue(label: "LogStore")
    private let osLog = Logger(subsystem: "com.shreehub.mapper", category: "app")
    private let dayFormat: DateFormatter
    private let timeFormat: DateFormatter
    private var handle: FileHandle?
    private var handleDay = ""
    /// Last lines kept in memory for the live tail endpoint (sequence number, line).
    private var recent: [(Int, String)] = []
    private var seq = 0

    let directory: URL

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        directory = docs.appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        dayFormat = DateFormatter()
        dayFormat.locale = Locale(identifier: "en_US_POSIX")
        dayFormat.dateFormat = "yyyy-MM-dd"
        timeFormat = DateFormatter()
        timeFormat.locale = Locale(identifier: "en_US_POSIX")
        timeFormat.dateFormat = "HH:mm:ss.SSS"
        queue.async { self.prune() }
    }

    // MARK: - writing

    func write(_ message: String, category: String = "app") {
        let now = Date()
        queue.async {
            let line = "\(self.timeFormat.string(from: now)) [\(category)] \(message)"
            self.osLog.log("\(line, privacy: .public)")
            self.append(line, day: self.dayFormat.string(from: now))
            self.seq += 1
            self.recent.append((self.seq, line))
            if self.recent.count > 500 { self.recent.removeFirst(self.recent.count - 500) }
        }
    }

    /// Header written at the start of every scan session.
    func sessionHeader(_ details: [String: String]) {
        let device = UIDevice.current
        let bundle = Bundle.main.infoDictionary ?? [:]
        var info = details
        info["app"] = "\(bundle["CFBundleShortVersionString"] ?? "?") (\(bundle["CFBundleVersion"] ?? "?"))"
        info["ios"] = device.systemVersion
        info["model"] = LogStore.hardwareModel
        let body = info.keys.sorted().map { "  \($0): \(info[$0] ?? "")" }.joined(separator: "\n")
        write("===== session start =====\n\(body)", category: "session")
    }

    private func append(_ line: String, day: String) {
        if handle == nil || handleDay != day {
            try? handle?.close()
            let url = directory.appendingPathComponent("mapper-\(day).log")
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            handle = try? FileHandle(forWritingTo: url)
            _ = try? handle?.seekToEnd()
            handleDay = day
        }
        try? handle?.write(contentsOf: Data((line + "\n").utf8))
    }

    private func prune() {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -LogStore.keepDays, to: Date()) else { return }
        for url in files() {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            if let modified = values?.contentModificationDate, modified < cutoff {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - reading

    /// Log files, newest first.
    func files() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return urls.filter { $0.pathExtension == "log" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    func read(_ name: String) -> String? {
        // Only plain file names inside the log directory.
        guard !name.contains("/"), !name.contains(".."), name.hasSuffix(".log") else { return nil }
        let url = directory.appendingPathComponent(name)
        queue.sync { _ = try? handle?.synchronize() }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// Lines with a sequence number greater than `after`, and the newest sequence number.
    func tail(after: Int) -> (lines: [String], last: Int) {
        queue.sync {
            (recent.filter { $0.0 > after }.map { $0.1 }, seq)
        }
    }

    func clear() {
        queue.sync {
            try? handle?.close()
            handle = nil
            handleDay = ""
            for url in files() { try? FileManager.default.removeItem(at: url) }
            recent.removeAll()
        }
    }

    static var hardwareModel: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
}
