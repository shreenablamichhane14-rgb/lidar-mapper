import Foundation
import simd

/// Build 5 pre-5a Core checks, run by `CoreSelfTest.run()`: CR-1 (plan editing operations,
/// `flattened`, `EditLog.flattenedActive`, `EditLog.reset(keeping:)`, `mergedOutlines`), CR-7
/// (`RoomRecord.supersededBy`) and CR-8 (`MinimapSnapshot.camera` and `heading`). Old JSON is
/// either written out literally or made by removing the new keys from encoded JSON.
extension CoreSelfTest {
    /// Failing checks as "name: detail".
    static func build5Checks() -> [String] {
        let recorder = CoreBuild5Recorder()
        editOperationChecks(recorder)
        editLogChecks(recorder)
        mergedOutlineChecks(recorder)
        supersededChecks(recorder)
        minimapChecks(recorder)
        return recorder.failures
    }

    /// A fixed element identifier for `n` (deterministic ids).
    private static func element(_ n: Int) -> ElementID {
        ElementID(uuid: fixedUUID(n))
    }

    /// A fixed UUID for `n`.
    private static func fixedUUID(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012ld", n)) ?? UUID()
    }

    /// `value` encoded with the store's encoder as text, or empty when encoding fails.
    private static func jsonText<T: Encodable>(_ value: T) -> String {
        guard let data = try? ProjectStore.encoder.encode(value) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Encodes `value`, removes `key` from every JSON object in it (the file an older build
    /// wrote) and decodes the result with the store's decoder; nil when any step fails.
    private static func decodedWithout<T: Codable>(_ key: String, from value: T) -> T? {
        guard let data = try? ProjectStore.encoder.encode(value),
              let tree = try? JSONSerialization.jsonObject(with: data),
              let stripped = try? JSONSerialization.data(withJSONObject: removing(key, from: tree)) else { return nil }
        return try? ProjectStore.decoder.decode(T.self, from: stripped)
    }

    /// `node` with `key` removed from every JSON object in the tree.
    private static func removing(_ key: String, from node: Any) -> Any {
        if let object = node as? [String: Any] {
            var result: [String: Any] = [:]
            for (name, child) in object where name != key {
                result[name] = removing(key, from: child)
            }
            return result
        }
        if let array = node as? [Any] {
            return array.map { removing(key, from: $0) }
        }
        return node
    }

    /// Decodes literal JSON text with the store's decoder; nil when it fails.
    private static func decodeLiteral<T: Decodable>(_ type: T.Type, _ text: String) -> T? {
        try? ProjectStore.decoder.decode(type, from: Data(text.utf8))
    }

    // MARK: - CR-1 operations

    /// JSON round trips, the batch coding shape, `targets` and `flattened` of the new cases.
    private static func editOperationChecks(_ r: CoreBuild5Recorder) {
        let roomA = element(1), roomB = element(2), roomC = element(3), door = element(4), window = element(5)
        let move = EditOperation.moveOpening(opening: door, offset: 0.75)
        let resize = EditOperation.resizeOpening(opening: window, width: 1.25, sillHeight: 0.9, headHeight: 2.125)
        let merge = EditOperation.mergeRooms(rooms: [roomB, roomC, roomB, roomA], into: roomA)
        let split = EditOperation.splitRoom(room: roomA, line: [Vec2(x: 0, y: 2), Vec2(x: 4, y: 2)], newRoom: roomC)
        let rename = EditOperation.renameRoom(room: roomB, name: "Hall")
        let inner = EditOperation.batch(operations: [move, rename])
        let nested = EditOperation.batch(operations: [resize, inner, split])

        let cases: [(String, EditOperation)] = [("moveOpening", move), ("resizeOpening", resize), ("mergeRooms", merge),
                                                ("splitRoom", split), ("batch", inner), ("nestedBatch", nested)]
        for (name, op) in cases {
            r.roundTrip("cr1.json.\(name)", op)
        }
        let batchJSON = jsonText(EditOperation.batch(operations: []))
        r.check("cr1.json.batchShape", batchJSON == "{\"batch\":{\"operations\":[]}}", batchJSON)

        r.check("cr1.targets.opening", move.targets == [door] && resize.targets == [window], "")
        let mergeTargets = merge.targets
        r.check("cr1.targets.mergeRooms", mergeTargets == [roomA, roomB, roomC], "\(mergeTargets.count) targets")
        r.check("cr1.targets.splitRoom", split.targets == [roomA, roomC], "")
        let batchTargets = nested.targets
        r.check("cr1.targets.batch", batchTargets == [window, door, roomB, roomA, roomC], "\(batchTargets.count) targets")
        r.check("cr1.targets.emptyBatch", EditOperation.batch(operations: []).targets.isEmpty, "")

        r.check("cr1.flattened.single", split.flattened == [split] && rename.flattened == [rename], "")
        let flat = nested.flattened
        r.check("cr1.flattened.nested", flat == [resize, move, rename, split], "\(flat.count) operations")
    }

    // MARK: - CR-1 EditLog

    /// `flattenedActive`, `reset(keeping:)` and a build 4 log written as literal JSON.
    private static func editLogChecks(_ r: CoreBuild5Recorder) {
        let roomA = element(11), roomB = element(12), door = element(13)
        let rename = EditOperation.renameRoom(room: roomA, name: "Kitchen")
        let scale = EditOperation.setScaleCorrection(room: roomA, factor: 1.25)
        let move = EditOperation.moveOpening(opening: door, offset: 0.5)
        let hide = EditOperation.setHidden(element: door, hidden: true)
        let merge = EditOperation.mergeRooms(rooms: [roomB], into: roomA)

        var log = EditLog()
        log.append(rename)
        log.append(.batch(operations: [scale, .batch(operations: [move])]))
        log.append(.batch(operations: [merge, hide]))
        r.check("cr1.flattenedActive.all", log.flattenedActive == [rename, scale, move, merge, hide], "")
        log.undo()
        let afterUndo: [EditOperation] = log.flattenedActive
        let activeAfterUndo: Int = log.active.count
        r.check("cr1.flattenedActive.undoneBatchExcluded", afterUndo == [rename, scale, move] && activeAfterUndo == 2,
                "\(afterUndo.count) operations")
        log.redo()
        r.check("cr1.flattenedActive.redone", log.flattenedActive.count == 5, "")

        var resetLog = EditLog()
        for op in [rename, move, scale, hide] { resetLog.append(op) }
        resetLog.undo()
        let revisionBefore = resetLog.revision
        let changed = resetLog.reset { op in
            if case .setScaleCorrection = op { return true }
            if case .renameRoom = op { return true }
            return false
        }
        let keptInOrder: Bool = resetLog.operations == [rename, scale] && resetLog.cursor == 2
        r.check("cr1.reset.keepsInOrder", changed && keptInOrder,
                "\(resetLog.operations.count) operations, cursor \(resetLog.cursor)")
        let revisionRaised: Bool = resetLog.revision == revisionBefore + 1
        r.check("cr1.reset.dropsRedoTail", !resetLog.canRedo && revisionRaised, "revision \(resetLog.revision)")
        let beforeNoop = resetLog
        let noop = resetLog.reset { _ in true }
        r.check("cr1.reset.unchangedReturnsFalse", !noop && resetLog == beforeNoop, "")
        var tailOnly = EditLog()
        tailOnly.append(rename)
        tailOnly.append(hide)
        tailOnly.undo()
        let droppedTail = tailOnly.reset { _ in true }
        let tailDropped: Bool = tailOnly.operations == [rename] && tailOnly.cursor == 1 && tailOnly.revision == 4
        r.check("cr1.reset.tailOnlyChanges", droppedTail && tailDropped, "revision \(tailOnly.revision)")
        var emptied = EditLog()
        emptied.append(rename)
        let clearedAll = emptied.reset { _ in false }
        let nothingLeft: Bool = emptied.operations.isEmpty && emptied.cursor == 0 && !emptied.canUndo
        r.check("cr1.reset.dropsAll", clearedAll && nothingLeft, "")

        let build4Log = """
        {"cursor":1,"operations":[{"renameRoom":{"name":"Den","room":{"uuid":"00000000-0000-4000-8000-000000000011"}}},\
        {"setHidden":{"element":{"uuid":"00000000-0000-4000-8000-000000000013"},"hidden":true}}],"revision":3}
        """
        if let old = decodeLiteral(EditLog.self, build4Log) {
            let expected: [EditOperation] = [.renameRoom(room: roomA, name: "Den")]
            let flatMatches: Bool = old.flattenedActive == expected
            let activeMatches: Bool = Array(old.active) == expected
            r.check("cr1.build4Log", flatMatches && activeMatches && old.canRedo && old.revision == 3, "")
        } else {
            r.check("cr1.build4Log", false, "did not decode")
        }
    }

    // MARK: - CR-1 merged outlines

    /// `CleanFloor.mergedOutlines` and `PlanRoom.mergedOutlines`: absent when nil, build 4 JSON
    /// decodes with nil, set values round trip.
    private static func mergedOutlineChecks(_ r: CoreBuild5Recorder) {
        let outline = [Vec2(x: 0, y: 0), Vec2(x: 4, y: 0), Vec2(x: 4, y: 5), Vec2(x: 0, y: 5)]
        let part = [Vec2(x: 4, y: 0), Vec2(x: 7, y: 0), Vec2(x: 7, y: 4), Vec2(x: 4, y: 4)]
        let floor = CleanFloor(outline: outline, elevation: -1.25, occludedArea: 0.5, provenance: .measured)
        let floorJSON: String = jsonText(floor)
        r.check("cr1.cleanFloor.nilHasNoKey", floor.mergedOutlines == nil && !floorJSON.isEmpty
                && !floorJSON.contains("mergedOutlines"), floorJSON)
        let build4Floor = """
        {"elevation":-1.25,"occludedArea":0.5,"outline":[{"x":0,"y":0},{"x":4,"y":0},{"x":4,"y":5},{"x":0,"y":5}],\
        "provenance":"measured"}
        """
        r.check("cr1.cleanFloor.build4Decodes", decodeLiteral(CleanFloor.self, build4Floor) == floor, "")
        var merged = floor
        merged.mergedOutlines = [part]
        r.roundTrip("cr1.cleanFloor.mergedRoundTrip", merged)
        r.check("cr1.cleanFloor.strippedIsNil", decodedWithout("mergedOutlines", from: merged) == floor, "")

        let room = PlanRoom(id: element(21), name: "Kitchen", outline: outline, labelAt: Vec2(x: 2, y: 2.5), area: 20)
        let roomJSON: String = jsonText(room)
        r.check("cr1.planRoom.nilHasNoKey", room.mergedOutlines == nil && !roomJSON.isEmpty
                && !roomJSON.contains("mergedOutlines"), roomJSON)
        let build4Room = """
        {"area":20,"id":{"uuid":"00000000-0000-4000-8000-000000000021"},"labelAt":{"x":2,"y":2.5},"name":"Kitchen",\
        "outline":[{"x":0,"y":0},{"x":4,"y":0},{"x":4,"y":5},{"x":0,"y":5}]}
        """
        r.check("cr1.planRoom.build4Decodes", decodeLiteral(PlanRoom.self, build4Room) == room, "")
        var mergedRoom = room
        mergedRoom.mergedOutlines = [part, part]
        mergedRoom.area = 32
        let decodedRoom: PlanRoom? = decodeLiteral(PlanRoom.self, jsonText(mergedRoom))
        let partCount: Int = decodedRoom?.mergedOutlines?.count ?? 0
        r.check("cr1.planRoom.mergedRoundTrip", decodedRoom == mergedRoom && partCount == 2, "\(partCount) parts")
    }

    // MARK: - CR-7 superseded rooms

    /// `RoomRecord.supersededBy`: build 4 manifests decode with nil, a set value round trips.
    private static func supersededChecks(_ r: CoreBuild5Recorder) {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let session = fixedUUID(31)
        var manifest = ProjectManifest.new(kind: .house, name: "Rescan", now: now)
        manifest.sessions.append(CaptureSessionRef(id: session, startedAt: now, frameLink: .projectFrame(sessionID: session),
                                                   worldMapFile: nil))
        let record = RoomRecord(id: fixedUUID(32), name: "", sessionID: session, floorIndex: 0, status: .captured,
                                capturedRoomID: nil, quality: nil, hasMeshPass: false, keyframeCount: 12,
                                capturedAt: now, frameLink: .projectFrame(sessionID: session))
        manifest.rooms.append(record)
        let manifestJSON: String = jsonText(manifest)
        r.check("cr7.defaultNil", record.supersededBy == nil && !manifestJSON.isEmpty
                && !manifestJSON.contains("supersededBy"), "")
        var replaced = manifest
        replaced.rooms[0].supersededBy = fixedUUID(33)
        r.roundTrip("cr7.roundTripKeepsValue", replaced)
        let expectedKey: String = "\"supersededBy\":\"" + fixedUUID(33).uuidString + "\""
        r.check("cr7.encodesValue", jsonText(replaced).contains(expectedKey), "")
        let build4: ProjectManifest? = decodedWithout("supersededBy", from: replaced)
        let build4Room: RoomRecord? = build4?.rooms.first
        r.check("cr7.build4ManifestDecodes", build4 == manifest && build4Room != nil && build4Room?.supersededBy == nil, "")
    }

    // MARK: - CR-8 minimap camera

    /// `MinimapSnapshot.camera` and `heading`: round trip, old lines decode with nil.
    private static func minimapChecks(_ r: CoreBuild5Recorder) {
        let plain = MinimapSnapshot(cellSize: 0.5, origin: Vec2(x: 1, y: -2), width: 2, height: 1, cells: [3, 1],
                                    walls: [[Vec2(x: 0, y: 0), Vec2(x: 1, y: 0)]])
        var located = plain
        located.camera = Vec2(x: 1.5, y: -1.25)
        located.heading = 0.75
        r.roundTrip("cr8.roundTrip", located)
        let plainJSON: String = jsonText(plain)
        r.check("cr8.nilHasNoKeys", !plainJSON.isEmpty && !plainJSON.contains("camera") && !plainJSON.contains("heading"),
                plainJSON)
        let oldLine = """
        {"cellSize":0.5,"cells":[3,1],"height":1,"origin":{"x":1,"y":-2},"walls":[[{"x":0,"y":0},{"x":1,"y":0}]],"width":2}
        """
        let old: MinimapSnapshot? = try? JSONDecoder().decode(MinimapSnapshot.self, from: Data(oldLine.utf8))
        let oldCell: MinimapCell = old?.cell(x: 0, y: 0) ?? .empty
        r.check("cr8.oldLineDecodes", old == plain && old?.camera == nil && old?.heading == nil && oldCell == .covered, "")
        var recording = SnapshotRecording.synthetic(count: 2)
        recording.snapshots[1].minimap = located
        let replayed: SnapshotRecording? = try? SnapshotRecording.decodeJSONLines(recording.encodeJSONLines())
        let replayedHeading: Float? = replayed?.snapshots.last?.minimap?.heading
        r.check("cr8.recordingLines", replayed == recording && replayedHeading == 0.75, "")
    }
}

/// Collects failing checks of `CoreSelfTest.build5Checks()`.
private final class CoreBuild5Recorder {
    /// Failure lines, "name: detail".
    private(set) var failures: [String] = []

    /// Records a failure when `condition` is false.
    func check(_ name: String, _ condition: Bool, _ detail: String = "") {
        if !condition { failures.append(detail.isEmpty ? name : "\(name): \(detail)") }
    }

    /// Encodes and decodes with the store's coders and checks equality.
    func roundTrip<T: Codable & Equatable>(_ name: String, _ value: T) {
        do {
            let data = try ProjectStore.encoder.encode(value)
            let decoded = try ProjectStore.decoder.decode(T.self, from: data)
            check(name, decoded == value)
        } catch {
            check(name, false, "\(error)")
        }
    }
}
