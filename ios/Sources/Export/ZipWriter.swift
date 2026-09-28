import Foundation

/// CRC-32 as used by ZIP, PNG and Ethernet (IEEE 802.3, reflected polynomial
/// 0xEDB88320, initial value and final xor 0xFFFFFFFF), table driven.
enum CRC32 {
    /// 256-entry lookup table, built once.
    static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
        }
        return c
    }

    /// CRC-32 of `data`. Pass a previous result as `previous` to continue a running checksum.
    static func checksum(_ data: Data, previous: UInt32 = 0) -> UInt32 {
        var crc = previous ^ 0xFFFF_FFFF
        table.withUnsafeBufferPointer { lookup in
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                for byte in raw {
                    crc = lookup[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
                }
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

/// Minimal ZIP writer: STORE method only (no compression), UTF-8 names, no ZIP64, so
/// every archive and member must stay below 4 GiB and 65,535 entries. Optionally
/// aligns the start of each file's data to a multiple of `alignment` bytes by padding
/// the local header's extra field (USDZ needs 64). Used for OBJ bundles, project
/// backups and USDZ.
struct ZipWriter {
    /// Extra field header ID used for alignment padding. Unregistered IDs are skipped
    /// by every conforming reader.
    static let paddingExtraFieldID: UInt16 = 0x1986

    private struct CentralRecord {
        var name: [UInt8]
        var crc: UInt32
        var size: UInt32
        var localHeaderOffset: UInt32
    }

    /// Data start alignment in bytes (1 means no alignment).
    let alignment: Int
    private let dosTime: UInt16
    private let dosDate: UInt16
    private var output = ByteWriter()
    private var records: [CentralRecord] = []
    private var names = Set<String>()

    /// Creates a writer. `modified` is stored as every entry's DOS timestamp (local time).
    init(alignment: Int = 1, modified: Date = Date()) {
        self.alignment = max(1, alignment)
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: modified)
        let year = min(max((parts.year ?? 1980) - 1980, 0), 127)
        dosDate = UInt16(year << 9 | (parts.month ?? 1) << 5 | (parts.day ?? 1))
        dosTime = UInt16((parts.hour ?? 0) << 11 | (parts.minute ?? 0) << 5 | (parts.second ?? 0) / 2)
    }

    /// Number of entries added so far.
    var entryCount: Int { records.count }

    /// Adds a stored file. Names use "/" as separator, must be relative, non-empty and unique.
    mutating func add(name: String, data: Data) throws {
        guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("\\") else {
            throw ExportError.invalidArchiveEntry(name: name, reason: "the name must be a relative path using /")
        }
        guard !names.contains(name) else {
            throw ExportError.invalidArchiveEntry(name: name, reason: "the name is already used")
        }
        let nameBytes = Array(name.utf8)
        guard nameBytes.count <= Int(UInt16.max) else {
            throw ExportError.invalidArchiveEntry(name: name, reason: "the name is too long")
        }
        guard records.count < Int(UInt16.max) else {
            throw ExportError.tooLarge(format: "ZIP", detail: "more than 65,535 files")
        }
        let headerStart = output.count
        let fixedEnd = headerStart + 30 + nameBytes.count
        var pad = ByteWriter.padding(for: fixedEnd, alignment: alignment)
        // An extra field record needs at least its 4-byte header.
        while pad > 0 && pad < 4 { pad += alignment }
        guard pad <= Int(UInt16.max) else {
            throw ExportError.invalidArchiveEntry(name: name, reason: "alignment is too large")
        }
        let end = UInt64(fixedEnd) + UInt64(pad) + UInt64(data.count)
        guard data.count < Int(UInt32.max), end < UInt64(UInt32.max) else {
            throw ExportError.tooLarge(format: "ZIP", detail: "the archive would exceed 4 GB")
        }
        let crc = CRC32.checksum(data)

        output.appendUInt32(0x0403_4B50)            // local file header signature
        output.appendUInt16(10)                     // version needed: 1.0 (stored)
        output.appendUInt16(0x0800)                 // flags: bit 11 = UTF-8 names
        output.appendUInt16(0)                      // method: 0 = stored
        output.appendUInt16(dosTime)
        output.appendUInt16(dosDate)
        output.appendUInt32(crc)
        output.appendUInt32(UInt32(data.count))     // compressed size
        output.appendUInt32(UInt32(data.count))     // uncompressed size
        output.appendUInt16(UInt16(nameBytes.count))
        output.appendUInt16(UInt16(pad))            // extra field length
        output.appendData(Data(nameBytes))
        if pad > 0 {
            output.appendUInt16(ZipWriter.paddingExtraFieldID)
            output.appendUInt16(UInt16(pad - 4))
            output.appendPadding(pad - 4)
        }
        output.appendData(data)

        records.append(CentralRecord(name: nameBytes, crc: crc, size: UInt32(data.count), localHeaderOffset: UInt32(headerStart)))
        names.insert(name)
    }

    /// Appends the central directory and end record and returns the whole archive.
    func finish() throws -> Data {
        var archive = output
        let directoryStart = archive.count
        for record in records {
            archive.appendUInt32(0x0201_4B50)       // central directory header signature
            archive.appendUInt16(20)                // version made by: 2.0, MS-DOS attributes
            archive.appendUInt16(10)                // version needed
            archive.appendUInt16(0x0800)            // flags: UTF-8
            archive.appendUInt16(0)                 // method: stored
            archive.appendUInt16(dosTime)
            archive.appendUInt16(dosDate)
            archive.appendUInt32(record.crc)
            archive.appendUInt32(record.size)
            archive.appendUInt32(record.size)
            archive.appendUInt16(UInt16(record.name.count))
            archive.appendUInt16(0)                 // extra field length
            archive.appendUInt16(0)                 // comment length
            archive.appendUInt16(0)                 // disk number start
            archive.appendUInt16(0)                 // internal attributes
            archive.appendUInt32(0)                 // external attributes
            archive.appendUInt32(record.localHeaderOffset)
            archive.appendData(Data(record.name))
        }
        let directorySize = archive.count - directoryStart
        guard archive.count + 22 < Int(UInt32.max) else {
            throw ExportError.tooLarge(format: "ZIP", detail: "the archive would exceed 4 GB")
        }
        archive.appendUInt32(0x0605_4B50)           // end of central directory signature
        archive.appendUInt16(0)                     // this disk
        archive.appendUInt16(0)                     // disk with the central directory
        archive.appendUInt16(UInt16(records.count)) // entries on this disk
        archive.appendUInt16(UInt16(records.count)) // total entries
        archive.appendUInt32(UInt32(directorySize))
        archive.appendUInt32(UInt32(directoryStart))
        archive.appendUInt16(0)                     // comment length
        return archive.data
    }

    /// Convenience: archives `entries` in order.
    static func archive(_ entries: [(name: String, data: Data)], alignment: Int = 1, modified: Date = Date()) throws -> Data {
        var writer = ZipWriter(alignment: alignment, modified: modified)
        for entry in entries {
            try writer.add(name: entry.name, data: entry.data)
        }
        return try writer.finish()
    }
}
