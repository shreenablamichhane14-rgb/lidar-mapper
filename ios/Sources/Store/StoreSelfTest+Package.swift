import Foundation

/// Package-level Store checks: sealing, PackageCheck, discardRoom, ManifestWriter, EditStore
/// and StorageUsage. All in temporary packages under the run's base folder.
extension StoreSelfTest {
    /// InProgressScans.seal, PackageCheck.verify and isSafeRecordPath.
    static func sealChecks(_ t: Checks, base: URL) {
        let root = base.appendingPathComponent("InProgressC", isDirectory: true)
        do {
            let (package, _) = try makePackage(in: base, created: 0)
            let session = fixedID(800)
            let roomA = fixedID(31)
            let roomB = fixedID(32)
            let folder = try InProgressScans.create(scanInfo(30), root: root)
            let writer = RawScanWriter(folder: folder)
            var record = keyframe(1)
            record.depthFile = nil
            writer.writeFile(Data(repeating: 7, count: 300), to: folder.url.appendingPathComponent(record.imageFile, isDirectory: false))
            writer.appendJSONLine(record, to: folder.keyframesLogURL)
            writer.close()
            _ = waitFlush(writer)

            let destination = package.rawRoomURL(session: session, room: roomA)
            let seal = try InProgressScans.seal(folder, into: destination, package: package, root: root)
            t.check("seal.moved", !StoreFiles.exists(folder.url) && StoreFiles.isDirectory(destination))
            t.check("seal.fileWritten", StoreFiles.exists(package.sealURL(in: destination)))
            let paths = seal.files.map { $0.path }
            t.check("seal.listsEveryFile", paths == ["keyframes.jsonl", "keyframes/00001.jpg", "scan.json"],
                    paths.joined(separator: ","))
            let jpegSize = seal.files.first { $0.path == "keyframes/00001.jpg" }?.size
            t.check("seal.sizes", jpegSize == 300 && seal.files.allSatisfy { $0.size > 0 })
            t.check("seal.verifyClean", ProjectStore.verifyRawFolder(destination).isEmpty)

            let second = try InProgressScans.create(scanInfo(33), root: root)
            t.check("seal.existingDestinationThrows", throwsError {
                _ = try InProgressScans.seal(second, into: destination, package: package, root: root)
            })
            let untouched = StoreFiles.isDirectory(second.url) && !InProgressScans.isSealed(scanID: fixedID(33), root: root)
            t.check("seal.failureLeavesFolder", untouched)
            let preSeal = try ProjectStore.sealRawFolder(second.url, now: fixedDate(5))
            t.check("seal.isSealedBefore", InProgressScans.isSealed(scanID: fixedID(33), root: root))
            let destinationB = package.rawRoomURL(session: session, room: roomB)
            let resealed = try InProgressScans.seal(second, into: destinationB, package: package, root: root)
            let stored = try ProjectStore.readJSON(SealFile.self, from: package.sealURL(in: destinationB))
            t.check("seal.keepsOriginalSeal", resealed == preSeal && stored.sealedAt == fixedDate(5))

            let third = try InProgressScans.create(scanInfo(34), root: root)
            let outside = base.appendingPathComponent("elsewhere", isDirectory: true)
            t.check("seal.outsidePackageThrows", throwsError {
                _ = try InProgressScans.seal(third, into: outside, package: package, root: root)
            } && !StoreFiles.exists(third.sealURL))

            let withRooms = try ManifestWriter.update(package, now: fixedDate(20)) { manifest in
                manifest.rooms = [roomRecord(roomA, session: session), roomRecord(roomB, session: session)]
            }
            let clean = PackageCheck.verify(package, manifest: withRooms)
            t.check("packageCheck.clean", clean.isEmpty, clean.joined(separator: "; "))
            try FileManager.default.removeItem(at: destination.appendingPathComponent("keyframes/00001.jpg", isDirectory: false))
            let damaged = PackageCheck.verify(package, manifest: withRooms)
            t.check("packageCheck.deletedJPEG", damaged.contains { $0.contains("keyframes/00001.jpg") },
                    damaged.joined(separator: "; "))
            var missingRoom = withRooms
            missingRoom.rooms.append(roomRecord(fixedID(35), session: session))
            let missing = PackageCheck.verify(package, manifest: missingRoom)
            t.check("packageCheck.missingFolder", missing.contains { $0.contains("raw folder missing") })
        } catch {
            t.fail("seal", error)
        }
        let rejected = ["/etc/x", "../x", "keyframes/../../x", ""]
        for path in rejected {
            t.check("safePath.rejects \(path.isEmpty ? "empty" : path)", !PackageCheck.isSafeRecordPath(path))
        }
        t.check("safePath.accepts", PackageCheck.isSafeRecordPath("keyframes/00001.jpg"))
    }

    /// discardRoom of one of two rooms, then of the last room.
    static func discardRoomChecks(_ t: Checks, base: URL) {
        do {
            let (package, _) = try makePackage(in: base, created: 0)
            let session = fixedID(800)
            let rooms = [fixedID(41), fixedID(42)]
            for room in rooms {
                let raw = package.rawRoomURL(session: session, room: room)
                try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
                try Data([1, 2, 3]).write(to: raw.appendingPathComponent(InProgressScanInfo.fileName, isDirectory: false))
                let derived = package.derivedRoomURL(room)
                try FileManager.default.createDirectory(at: derived, withIntermediateDirectories: true)
                try Data([4]).write(to: derived.appendingPathComponent("mesh.mchk", isDirectory: false))
            }
            try ManifestWriter.update(package, now: fixedDate(1)) { manifest in
                manifest.rooms = rooms.map { roomRecord($0, session: session) }
            }
            let remaining = try StorePackageOps.discardRoom(rooms[0], in: package)
            t.check("discardRoom.keepsOtherRecord", remaining?.rooms.map { $0.id } == [rooms[1]])
            let rawGone = !StoreFiles.exists(package.rawRoomURL(session: session, room: rooms[0]))
            let rawKept = StoreFiles.isDirectory(package.rawRoomURL(session: session, room: rooms[1]))
            t.check("discardRoom.removesOnlyThatRaw", rawGone && rawKept)
            let derivedGone = !StoreFiles.exists(package.derivedRoomURL(rooms[0]))
            let derivedKept = StoreFiles.isDirectory(package.derivedRoomURL(rooms[1]))
            t.check("discardRoom.removesOnlyThatDerived", derivedGone && derivedKept)
            t.check("discardRoom.manifestWritten", (try? ManifestWriter.read(package))?.rooms.count == 1)
            let last = try StorePackageOps.discardRoom(rooms[1], in: package)
            t.check("discardRoom.lastDeletesProject", last == nil && !StoreFiles.exists(package.root))
        } catch {
            t.fail("discardRoom", error)
        }
    }

    /// ManifestWriter: 4 queues x 25 increments, modifiedAt, id kept, nesting refused, no
    /// ghost package after delete.
    static func manifestChecks(_ t: Checks, base: URL) {
        do {
            let (package, original) = try makePackage(in: base, created: 0)
            let session = fixedID(800)
            let errors = Counter()
            let group = DispatchGroup()
            for queueIndex in 0..<4 {
                let queue = DispatchQueue(label: "mapper.store.selftest.\(queueIndex)")
                queue.async(group: group) {
                    for step in 0..<25 {
                        let recordID = StoreSelfTest.fixedID(1000 + queueIndex * 100 + step)
                        let record = StoreSelfTest.roomRecord(recordID, session: session)
                        do {
                            try ManifestWriter.update(package, now: StoreSelfTest.fixedDate(100)) { manifest in
                                manifest.rooms.append(record)
                            }
                        } catch {
                            errors.increment()
                        }
                    }
                }
            }
            let finished = group.wait(timeout: .now() + 30) == .success
            let result = try ManifestWriter.read(package)
            t.check("manifest.concurrentUpdates", finished && result.rooms.count == 100 && errors.value == 0,
                    "\(result.rooms.count) rooms, \(errors.value) errors")
            t.check("manifest.noLostRecord", Set(result.rooms.map { $0.id }).count == 100)
            t.check("manifest.modifiedAtBumped", result.modifiedAt == fixedDate(100) && original.modifiedAt == fixedDate(0))

            let renamed = try ManifestWriter.update(package, now: fixedDate(200)) { manifest in
                manifest.name = "Renamed"
                manifest.id = fixedID(999)
            }
            t.check("manifest.idKept", renamed.id == original.id && renamed.name == "Renamed")
            t.check("manifest.nestedRefused", throwsError {
                _ = try ManifestWriter.update(package) { _ in
                    _ = try ManifestWriter.update(package) { _ in }
                }
            })
            t.check("manifest.lockReleased", !throwsError { _ = try ManifestWriter.update(package, now: fixedDate(300)) { _ in } })

            try StorePackageOps.deletePackage(package)
            let refused = throwsError { _ = try ManifestWriter.update(package) { _ in } }
            t.check("manifest.noGhostAfterDelete", refused && !StoreFiles.exists(package.root))
        } catch {
            t.fail("manifest", error)
        }
    }

    /// EditStore: append twice, undo, redo, measurements, damaged log.
    static func editChecks(_ t: Checks, base: URL) {
        do {
            let (package, _) = try makePackage(in: base, created: 0)
            let first = EditOperation.renameRoom(room: ElementID(uuid: fixedID(51)), name: "Kitchen")
            let second = EditOperation.setHidden(element: ElementID(uuid: fixedID(52)), hidden: true)
            try EditStore.append(first, to: package)
            let two = try EditStore.append(second, to: package)
            t.check("edits.appendTwice", two.operations == [first, second] && two.cursor == 2 && two.revision == 2)
            let undone = try EditStore.undo(package)
            t.check("edits.undo", undone.cursor == 1 && undone.revision == 3 && undone.canRedo)
            let redone = try EditStore.redo(package)
            t.check("edits.redo", redone.cursor == 2 && redone.revision == 4 && !redone.canRedo)
            t.check("edits.loadMatches", EditStore.load(package) == redone)
            let extra = try EditStore.redo(package)
            t.check("edits.redoAtEndUnchanged", extra.revision == 4)

            t.check("measurements.missingIsEmpty", EditStore.loadMeasurements(package).isEmpty)
            let value = MeasuredValue(value: 2.358, sigma: 0.012, provenance: .measured)
            let measurement = MeasurementRecord(id: fixedID(53), kind: .distance,
                                                points: [Vec3(x: 0, y: 0, z: 0), Vec3(x: 1.25, y: 0, z: -2)],
                                                snaps: [.corner, .plane], result: value, source: .viewer, name: "Sofa",
                                                roomID: ElementID(uuid: fixedID(51)), createdAt: fixedDate(60))
            try EditStore.saveMeasurements([measurement], to: package)
            t.check("measurements.roundTrip", EditStore.loadMeasurements(package) == [measurement])

            let damaged = Data("{".utf8)
            try damaged.write(to: package.editLogURL)
            t.check("edits.damagedLoadsEmpty", EditStore.load(package) == EditLog())
            let refused = throwsError { _ = try EditStore.append(first, to: package) }
            let kept = (try? Data(contentsOf: package.editLogURL)) == damaged
            t.check("edits.damagedNotOverwritten", refused && kept)
        } catch {
            t.fail("edits", error)
        }
    }

    /// StorageUsage over known file sizes.
    static func usageChecks(_ t: Checks, base: URL) {
        do {
            let (package, _) = try makePackage(in: base, created: 0)
            try Data(count: 1000).write(to: package.rawURL.appendingPathComponent("a.bin", isDirectory: false))
            let sub = package.rawURL.appendingPathComponent("sub", isDirectory: true)
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: false)
            try Data(count: 500).write(to: sub.appendingPathComponent("b.bin", isDirectory: false))
            try Data(count: 250).write(to: package.derivedURL.appendingPathComponent("c.bin", isDirectory: false))
            try Data(count: 40).write(to: package.editsURL.appendingPathComponent("d.bin", isDirectory: false))
            let manifestBytes = StoreFiles.directorySize(package.manifestURL)
            let usage = StorageUsage.usage(of: package)
            t.check("usage.raw", usage.raw == 1500, "\(usage.raw)")
            t.check("usage.derived", usage.derived == 250, "\(usage.derived)")
            t.check("usage.editsAndExports", usage.edits == 40 && usage.exports == 0)
            let expectedTotal: Int64 = 1500 + 250 + 40 + manifestBytes
            t.check("usage.total", manifestBytes > 0 && usage.total == expectedTotal, "\(usage.total)")
            let absent = base.appendingPathComponent("absent", isDirectory: true)
            t.check("usage.missingFolderIsZero", StoreFiles.directorySize(absent) == 0)
        } catch {
            t.fail("usage", error)
        }
    }
}
