import Foundation
import simd

// File-based checks of the HouseUI self-test: the relocalization map choice in a temporary
// package, and the demo house (two ScanUI demo rooms placed side by side, written with Structure's
// shared wall rules). Temporary files live under FileManager.default.temporaryDirectory and are
// removed before returning.

extension HouseUISelfTest {
    /// A fresh temporary folder named `name` (removed first); nil when it cannot be made.
    static func temporaryFolder(_ name: String, _ c: inout Checker) -> URL? {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try? fm.removeItem(at: root)
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            return root
        } catch {
            c.check("files.temporaryFolder", false, "\(error)")
            return nil
        }
    }

    /// Writes a small stand-in world map file for a room (the content is never unarchived here).
    static func writeMap(_ package: ProjectPackage, session: UUID, room: UUID) throws {
        let folder = RawScanFolder(url: package.rawRoomURL(session: session, room: room))
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        try Data([0x6D, 0x61, 0x70]).write(to: folder.worldMapURL)
    }

    /// `sourceMap` picks the rescanned room's map, else the latest anchor-group room with a map,
    /// skips an unaligned room's map, and returns nil without maps.
    static func sourceMapChecks(_ c: inout Checker) {
        guard let root = temporaryFolder("HouseUISelfTest-sourceMap.mapperproj", &c) else { return }
        defer { try? FileManager.default.removeItem(at: root) }
        let package = ProjectPackage(root: root)
        let s0 = uuid(10), s1 = uuid(11)
        let r1 = uuid(1), r2 = uuid(2), r3 = uuid(3)
        let rooms = [room(r1, session: s0, capturedAt: 100), room(r2, session: s0, capturedAt: 200),
                     room(r3, session: s1, link: .unaligned, capturedAt: 300)]
        let m = manifest(rooms: rooms, sessions: [session(s0), session(s1, link: .unaligned)])
        do {
            try writeMap(package, session: s0, room: r1)
            try writeMap(package, session: s0, room: r2)
            try writeMap(package, session: s1, room: r3)
        } catch {
            c.check("sourceMap.files", false, "\(error)")
            return
        }
        let preferred = HouseRelocalization.sourceMap(manifest: m, package: package, preferRoom: r1)
        c.check("sourceMap.rescannedRoom", preferred?.room == r1 && preferred?.session == s0, "\(String(describing: preferred?.room))")
        let latest = HouseRelocalization.sourceMap(manifest: m, package: package, preferRoom: nil)
        c.check("sourceMap.latestAnchorRoom", latest?.room == r2, "\(String(describing: latest?.room))")
        let unaligned = HouseRelocalization.sourceMap(manifest: m, package: package, preferRoom: r3)
        c.check("sourceMap.skipsUnaligned", unaligned?.room == r2, "\(String(describing: unaligned?.room))")
        let expectedURL = RawScanFolder(url: package.rawRoomURL(session: s0, room: r2)).worldMapURL
        c.check("sourceMap.url", latest?.url.standardizedFileURL.path == expectedURL.standardizedFileURL.path)

        try? FileManager.default.removeItem(at: RawScanFolder(url: package.rawRoomURL(session: s0, room: r2)).worldMapURL)
        let fallback = HouseRelocalization.sourceMap(manifest: m, package: package, preferRoom: nil)
        c.check("sourceMap.nextLatest", fallback?.room == r1, "\(String(describing: fallback?.room))")
        try? FileManager.default.removeItem(at: RawScanFolder(url: package.rawRoomURL(session: s0, room: r1)).worldMapURL)
        c.check("sourceMap.nilWithoutMaps", HouseRelocalization.sourceMap(manifest: m, package: package, preferRoom: nil) == nil)
    }

    /// `HouseDemo.offset` leaves a 0.12 m gap between two demo rooms, the placed rooms have their
    /// own element ids, and the written demo model has one shared wall pair and a plan.
    static func demoChecks(_ c: inout Checker) {
        let first = CleanModelBuilder.buildRoom(DemoProjectFactory.roomInput(), recordID: uuid(41), name: "", floorIndex: 0,
                                                mesh: nil, options: CleanBuildOptions())
        let second = CleanModelBuilder.buildRoom(DemoProjectFactory.roomInput(), recordID: uuid(42), name: "", floorIndex: 0,
                                                 mesh: nil, options: CleanBuildOptions())
        let a = HouseDemo.placed(first, name: "", floorIndex: 0, after: [])
        let b = HouseDemo.placed(second, name: "", floorIndex: 0, after: [a])
        let offset = HouseDemo.offset(for: second, after: [a])
        c.check("demo.offsetMovesAlongX", offset.yaw == 0 && offset.translation.x > 0 && abs(offset.translation.z) < 1e-4,
                "\(offset.translation.simd)")
        if let boundsA = HouseDemo.planBounds([a]), let boundsB = HouseDemo.planBounds([b]) {
            let gap = boundsB.lower.x - boundsA.upper.x
            c.check("demo.gap012", abs(gap - HouseDemo.sharedWallGap) < 1e-3, "\(gap)")
            c.check("demo.southEdgesAligned", abs(boundsB.lower.y - boundsA.lower.y) < 1e-3)
        } else {
            c.check("demo.gap012", false, "no bounds")
        }
        let wallIDsA = Set(a.walls.map { $0.id })
        let wallIDsB = Set(b.walls.map { $0.id })
        c.check("demo.ownIdentifiers", a.id != b.id && wallIDsA.isDisjoint(with: wallIDsB) && !wallIDsA.isEmpty)
        c.check("demo.reidentifiedDeterministic", HouseDemo.reidentified(second) == HouseDemo.reidentified(second))

        guard let root = temporaryFolder("HouseUISelfTest-demo.mapperproj", &c) else { return }
        defer { try? FileManager.default.removeItem(at: root) }
        let package = ProjectPackage(root: root)
        let m = manifest(rooms: [], sessions: [])
        do {
            try HouseDemo.write([a, b], manifest: m, package: package)
            let written = try CleanModelStore.loadBase(package)
            let pairs = StructureWalls.sharedWalls(in: written)
            c.check("demo.oneSharedWallPair", pairs.count == 1, "\(pairs.count) pairs")
            let measured = written.rooms.flatMap { $0.walls }.filter { $0.thicknessSource == .measured }
            c.check("demo.sharedWallThickness", measured.count == 2 && measured.allSatisfy { abs($0.thickness - HouseDemo.sharedWallGap) < 1e-3 },
                    "\(measured.map { $0.thickness })")
            c.check("demo.planWritten", FileManager.default.fileExists(atPath: package.planModelURL.path))
        } catch {
            c.check("demo.write", false, "\(error)")
        }
    }
}
