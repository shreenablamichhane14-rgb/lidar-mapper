import Foundation

// Checks 13 to 15 of LiveMeshViewSelfTest (docs/MODULES.md 3.32): `MeshPassFolders` in a
// temporary package under `FileManager.default.temporaryDirectory`, removed afterwards. Fixed
// ids and dates keep the result deterministic.

extension LiveMeshViewSelfTest {
    /// One mesh-pass folder of the fixture.
    struct PassFixture {
        /// Folder name (pass id) and scan.json `scanID`.
        var id: UUID
        /// scan.json `roomID`.
        var roomID: UUID?
        /// scan.json `startedAt`, seconds after the fixture's base date.
        var startedAfter: Double
        /// True writes SEAL.json.
        var sealed: Bool
        /// How scan.json is written.
        var info: InfoFile
    }

    /// The scan.json variants of the fixture.
    enum InfoFile {
        /// A valid scan.json of kind `.meshPass`.
        case valid
        /// A valid scan.json padded past `InProgressScanInfo.maxBytes`.
        case oversized
        /// Bytes that are not JSON.
        case unreadable
        /// A valid scan.json of kind `.object`.
        case objectKind
    }

    /// `forRoom` returns the sealed passes of one room oldest first; `spacePasses` the sealed
    /// pass without a room; unsealed, oversized, unreadable and wrong-kind folders are skipped.
    static func checkFolders(_ f: inout [String]) {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("LiveMeshViewSelfTest", isDirectory: true)
        try? fm.removeItem(at: base)
        defer { try? fm.removeItem(at: base) }
        let package = ProjectPackage(root: base.appendingPathComponent(fixedID(0xA0).uuidString + ".mapperproj",
                                                                        isDirectory: true))
        let session = fixedID(0xA1)
        let roomA = fixedID(0xA2), roomB = fixedID(0xA3)
        let late = fixedID(0xB1), early = fixedID(0xB2), other = fixedID(0xB3), unsealed = fixedID(0xB4)
        let space = fixedID(0xB5), oversized = fixedID(0xB6), unreadable = fixedID(0xB7), wrongKind = fixedID(0xB8)
        let fixtures: [PassFixture] = [
            PassFixture(id: late, roomID: roomA, startedAfter: 200, sealed: true, info: .valid),
            PassFixture(id: early, roomID: roomA, startedAfter: 100, sealed: true, info: .valid),
            PassFixture(id: other, roomID: roomB, startedAfter: 150, sealed: true, info: .valid),
            PassFixture(id: unsealed, roomID: roomA, startedAfter: 50, sealed: false, info: .valid),
            PassFixture(id: space, roomID: nil, startedAfter: 300, sealed: true, info: .valid),
            PassFixture(id: oversized, roomID: roomA, startedAfter: 10, sealed: true, info: .oversized),
            PassFixture(id: unreadable, roomID: roomA, startedAfter: 20, sealed: true, info: .unreadable),
            PassFixture(id: wrongKind, roomID: roomA, startedAfter: 30, sealed: true, info: .objectKind),
        ]
        do {
            for fixture in fixtures {
                try writeFixture(fixture, package: package, session: session)
            }
        } catch {
            check(&f, "folders.fixture", false, MeshScanStats.describe(error))
            return
        }
        let forA = MeshPassFolders.forRoom(roomA, in: package).map { $0.url.lastPathComponent }
        let expectedA = [early.uuidString, late.uuidString]
        check(&f, "folders.forRoom", forA == expectedA, "\(forA.count) folders: \(forA)")
        let forB = MeshPassFolders.forRoom(roomB, in: package).map { $0.url.lastPathComponent }
        check(&f, "folders.otherRoom", forB == [other.uuidString], "\(forB)")
        let spaces = MeshPassFolders.spacePasses(in: package).map { $0.url.lastPathComponent }
        check(&f, "folders.spacePasses", spaces == [space.uuidString], "\(spaces)")
        let skipped = [unsealed, oversized, unreadable, wrongKind].map { $0.uuidString }
        let all = MeshPassFolders.sealedPasses(in: package).map { $0.folder.url.lastPathComponent }
        let leaked = skipped.filter { all.contains($0) }
        check(&f, "folders.skipped", leaked.isEmpty && all.count == 4, "leaked \(leaked.count), listed \(all.count)")
        let emptyPackage = ProjectPackage(root: base.appendingPathComponent("missing.mapperproj", isDirectory: true))
        check(&f, "folders.missingPackage", MeshPassFolders.forRoom(roomA, in: emptyPackage).isEmpty, "not empty")
    }

    /// Writes one pass folder: scan.json as the fixture says, then SEAL.json when sealed.
    private static func writeFixture(_ fixture: PassFixture, package: ProjectPackage, session: UUID) throws {
        let folder = package.rawMeshPassURL(session: session, pass: fixture.id)
        try ProjectStore.ensureDirectory(folder)
        let infoURL = folder.appendingPathComponent(InProgressScanInfo.fileName, isDirectory: false)
        let started = Date(timeIntervalSince1970: 1_750_000_000 + fixture.startedAfter)
        let kind: RawScanKind = fixture.info == .objectKind ? .object : .meshPass
        let info = InProgressScanInfo(scanID: fixture.id, projectID: fixedID(0xA0), sessionID: session,
                                      roomID: fixture.roomID, kind: kind, mode: .room, startedAt: started)
        switch fixture.info {
        case .valid, .objectKind:
            try ProjectStore.writeJSON(info, to: infoURL)
        case .oversized:
            try ProjectStore.writeData(try paddedInfo(info), to: infoURL)
        case .unreadable:
            try ProjectStore.writeData(Data("not a scan record".utf8), to: infoURL)
        }
        if fixture.sealed {
            try ProjectStore.sealRawFolder(folder, now: started)
        }
    }

    /// A valid scan.json with an extra key that makes it larger than `InProgressScanInfo.maxBytes`
    /// (it would decode without the size cap).
    private static func paddedInfo(_ info: InProgressScanInfo) throws -> Data {
        var data = try ProjectStore.encoder.encode(info)
        guard data.last == UInt8(ascii: "}") else { return data }
        data.removeLast()
        let padding = String(repeating: "x", count: Int(InProgressScanInfo.maxBytes) + 1024)
        data.append(Data(",\"zzPadding\":\"\(padding)\"}".utf8))
        return data
    }
}

