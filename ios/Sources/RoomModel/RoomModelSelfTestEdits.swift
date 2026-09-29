import Foundation
import simd

// RoomModelSelfTest, second half: edit replay, clean meshes, triangulation, stores and steps.

extension RoomModelSelfTest {
    /// The fixture model used by the edit and mesh checks: the rectangle with two doors and a
    /// sofa, as room record 300.
    static func editFixture() -> CleanModel {
        CleanModelBuilder.buildModel([(input: F.rectangle(doors: true, sofa: true), record: F.record(300))], meshes: [:])
    }

    // MARK: - Edits

    /// Every EditOperation case once, orphans, other-model operations and full replay.
    static func editChecks(_ c: inout Checker) {
        let base = editFixture()
        let roomID = ElementID(uuid: F.uuid(300))
        let sofa = wid(F.sofaID)
        guard base.rooms.count == 1, base.rooms[0].objects.count == 1 else {
            c.check("edit.fixture", false, "fixture model has \(base.rooms.count) rooms")
            return
        }
        var m = base
        let renamed = m.apply(.renameRoom(room: roomID, name: "Den"))
        c.check("edit.renameRoom", renamed && m.rooms[0].name == "Den")
        let relabeled = m.apply(.relabelObject(object: sofa, label: "Couch"))
        c.check("edit.relabelObject", relabeled && m.rooms[0].objects[0].label == "Couch")
        let recategorized = m.apply(.recategorizeObject(object: sofa, category: .bed))
        c.check("edit.recategorizeObject", recategorized && m.rooms[0].objects[0].category == .bed)
        let hidden = m.apply(.setHidden(element: sofa, hidden: true))
        c.check("edit.setHidden", hidden && m.rooms[0].objects[0].isHidden)
        var pose = matrix_identity_float4x4
        pose.columns.3 = SIMD4<Float>(1, 0.4, -2, 1)
        let moved = m.apply(.moveObject(object: sofa, transform: Transform4(pose)))
        c.check("edit.moveObject", moved && m.rooms[0].objects[0].transform == Transform4(pose))

        var deleted = base
        let deletedOK = deleted.apply(.deleteElement(element: wid(1)))
        let doorGone = !deleted.rooms[0].openings.contains { $0.id == wid(F.doorID) }
        c.check("edit.deleteWall", deletedOK && deleted.rooms[0].walls.count == 3 && doorGone)

        var reshaped = base
        let endpointOK = reshaped.apply(.moveWallEndpoint(wall: wid(2), atStart: false, to: Vec2(x: 6, y: 4)))
        let movedWall = reshaped.rooms[0].walls.first { $0.id == wid(2) }
        let endOK = movedWall.map { near(PlanAxes.toPlan($0.end.simd), [6, 4], 1e-4) } ?? false
        c.check("edit.moveWallEndpoint", endpointOK && endOK)
        c.check("edit.moveWallEndpointArea", near(reshaped.rooms[0].metrics.floorArea, 22, 1e-3),
                "\(reshaped.rooms[0].metrics.floorArea)")

        var added = base
        let newWall = PlanWall(id: ElementID(uuid: F.uuid(500)), a: Vec2(x: 2, y: 1), b: Vec2(x: 2, y: 3), thickness: 0.1,
                               thicknessSource: .user, arc: nil, provenance: .user, occludedSpans: [])
        let wallAdded = added.apply(.addWall(wall: newWall, level: 0))
        let addedWall = added.rooms[0].walls.first(where: { $0.id == newWall.id })
        let addedHeightOK = addedWall?.height == added.rooms[0].ceiling.height
        c.check("edit.addWall", wallAdded && added.rooms[0].walls.count == 5 && addedHeightOK)
        let newOpening = PlanOpening(id: ElementID(uuid: F.uuid(501)), wallID: wid(3), kind: .window, offset: 0.5, width: 1.0,
                                     swing: nil)
        let openingAdded = added.apply(.addOpening(opening: newOpening, level: 0))
        let addedOpening = added.rooms[0].openings.first { $0.id == newOpening.id }
        let heightsOK = near(addedOpening?.sillHeight ?? -1, 0.9, 1e-5) && near(addedOpening?.headHeight ?? -1, 2.1, 1e-5)
        c.check("edit.addOpening", openingAdded && heightsOK && addedOpening?.provenance == .user)
        let orphanOpening = PlanOpening(id: ElementID(uuid: F.uuid(502)), wallID: ElementID(uuid: F.uuid(998)), kind: .door,
                                        offset: 0, width: 0.8, swing: nil)
        c.check("edit.addOpeningMissingWall", !added.apply(.addOpening(opening: orphanOpening, level: 0)))

        var swung = base
        let swing = DoorSwing(hingeAtStart: false, opensToNormalSide: false, source: .user)
        let swingOK = swung.apply(.setDoorSwing(door: wid(F.doorID), swing: swing))
        let swungDoor = swung.rooms[0].openings.first(where: { $0.id == wid(F.doorID) })
        c.check("edit.setDoorSwing", swingOK && swungDoor?.swing == swing)
        let thickOK = swung.apply(.setWallThickness(wall: wid(3), thickness: 0.2))
        let thickWall = swung.rooms[0].walls.first { $0.id == wid(3) }
        c.check("edit.setWallThickness", thickOK && thickWall?.thickness == 0.2 && thickWall?.thicknessSource == .user)

        var scaled = base
        let scaleOK = scaled.apply(.setScaleCorrection(room: roomID, factor: 1.1))
        c.check("edit.setScaleCorrection", scaleOK && near(scaled.rooms[0].metrics.floorArea, 20 * 1.21, 1e-3),
                "\(scaled.rooms[0].metrics.floorArea)")

        var untouched = base
        let missing = ElementID(uuid: F.uuid(999))
        let orphanRename = untouched.apply(.renameRoom(room: missing, name: "x"))
        let orphanDelete = untouched.apply(.deleteElement(element: missing))
        c.check("edit.orphanedReturnsFalse", !orphanRename && !orphanDelete && untouched == base)
        let annotation = PlanAnnotation(id: ElementID(uuid: F.uuid(700)), kind: .text, at: Vec2(x: 0, y: 0), text: "a", symbol: nil)
        let otherOK = untouched.apply(.addAnnotation(annotation: annotation, level: 0))
        let alignment = RoomAlignmentRecord(roomID: F.uuid(300), yaw: 0.5, translation: Vec3(x: 1, y: 0, z: 0), source: .user)
        let alignOK = untouched.apply(.setRoomAlignment(alignment))
        c.check("edit.otherModelUnchanged", otherOK && alignOK && untouched == base)

        var log = EditLog()
        log.append(.setScaleCorrection(room: roomID, factor: 1.1))
        log.append(.moveWallEndpoint(wall: wid(2), atStart: false, to: Vec2(x: 6, y: 4)))
        log.append(.renameRoom(room: missing, name: "x"))
        let replayed = base.applyingEdits(log)
        let replayArea = replayed.model.rooms.first?.metrics.floorArea ?? 0
        c.check("edit.replayKeepsScale", near(replayArea, 22 * 1.21, 1e-2), "\(replayArea)")
        c.check("edit.replayOrphans", replayed.orphaned.count == 1)
        log.undo()
        c.check("edit.replayUndo", base.applyingEdits(log).orphaned.isEmpty)
        c.check("edit.emptyLogIsBase", base.applyingEdits(EditLog()).model == base)
    }

    // MARK: - Clean meshes

    /// Wall cutouts, hidden objects, ceilings, occluded parts and part geometry.
    static func meshChecks(_ c: inout Checker) {
        let wall = CleanWall(id: wid(1), start: Vec3(x: 0, y: 0, z: 0), end: Vec3(x: 4, y: 0, z: 0), height: 2.5,
                             normal: Vec3(x: 0, y: 0, z: -1), thickness: 0.115, thicknessSource: .estimated, arc: nil,
                             confidence: .high, completedEdges: 4, occludedSpans: [], provenance: .measured)
        let door = CleanOpening(id: wid(F.doorID), wallID: wid(1), kind: .door, offsetAlongWall: 1, width: 0.9, sillHeight: 0,
                                headHeight: 2.0, swing: nil, provenance: .measured)
        let cut = CleanMeshBuilder.wallMesh(wall, openings: [door])
        c.check("mesh.wallMinusDoor", near(cut.surfaceArea, 10 - 1.8, 1e-4), "\(cut.surfaceArea)")
        let plain = CleanMeshBuilder.wallMesh(wall, openings: [])
        c.check("mesh.plainWallQuad", plain.triangleCount == 2 && near(plain.surfaceArea, 10, 1e-4))
        c.check("mesh.wallFacesRoom", facesToward(cut, SIMD3<Float>(0, 0, -1)))

        var model = editFixture()
        guard model.rooms.count == 1, model.rooms[0].objects.count == 1 else {
            c.check("mesh.fixture", false, "fixture model missing")
            return
        }
        model.rooms[0].objects[0].isHidden = true
        let visible = CleanMeshBuilder.parts(for: model, includeCeiling: false, includeHidden: false)
        let all = CleanMeshBuilder.parts(for: model, includeCeiling: true, includeHidden: true)
        c.check("parts.hiddenExcluded", objectPartCount(visible) == 0 && objectPartCount(all) == 1)
        let ceilingHidden = !visible.contains { $0.kind == .ceiling }
        c.check("parts.ceilingOnlyWhenAsked", ceilingHidden && all.contains { $0.kind == .ceiling })
        let occluded = all.filter { $0.kind == .occluded }
        let wallQuads = occluded.filter { $0.element == wid(1) }
        let floorQuads = occluded.filter { $0.element == wid(F.sofaID) }
        let wallQuadArea = wallQuads.first?.mesh.surfaceArea ?? 0
        let wallQuadTriangles = wallQuads.first?.mesh.triangleCount ?? 0
        c.check("parts.occludedWallQuad", wallQuads.count == 1 && wallQuadTriangles == 2 && near(wallQuadArea, 1.8, 1e-3),
                "count \(wallQuads.count), area \(wallQuadArea)")
        let floorQuadArea = floorQuads.first?.mesh.surfaceArea ?? 0
        c.check("parts.occludedFloorQuad", floorQuads.count == 1 && near(floorQuadArea, 1.8, 1e-3), "area \(floorQuadArea)")
        c.check("parts.occludedInferred", occluded.count == 2 && occluded.allSatisfy { $0.provenance == .inferred })
        c.check("parts.doorPart", all.contains { $0.kind == .door && $0.element == wid(F.doorID) })
        let floorPart = all.first { $0.kind == .floor }
        c.check("parts.floorFacesUp", floorPart.map { facesToward($0.mesh, SIMD3<Float>(0, 1, 0)) } ?? false)
        let ceilingPart = all.first { $0.kind == .ceiling }
        c.check("parts.ceilingFacesDown", ceilingPart.map { facesToward($0.mesh, SIMD3<Float>(0, -1, 0)) } ?? false)
        let box = all.first(where: { $0.element == wid(F.sofaID) && $0.kind == .object(.sofa) })
        let boxVolume = box?.mesh.signedVolume ?? 0
        c.check("parts.objectBoxClosed", (box?.mesh.isWatertight ?? false) && near(boxVolume, 1.44, 1e-3), "volume \(boxVolume)")

        let curvedModel = CleanModelBuilder.buildModel([(input: F.curved(), record: F.record(301))], meshes: [:])
        let curvedParts = CleanMeshBuilder.parts(for: curvedModel, includeCeiling: false, includeHidden: false)
        let curvedPart = curvedParts.first(where: { $0.element == wid(F.curvedID) && $0.kind == .wall })
        let bulges = curvedPart?.mesh.positions.contains { PlanAxes.toPlan($0).y > 5.9 } ?? false
        c.check("parts.curvedWallFollowsArc", (curvedPart?.mesh.triangleCount ?? 0) > 2 && bulges)
    }

    /// Number of object parts.
    static func objectPartCount(_ parts: [CleanMeshPart]) -> Int {
        parts.filter { part in
            if case .object = part.kind { return true }
            return false
        }.count
    }

    /// True when every triangle's normal points along `direction`.
    static func facesToward(_ mesh: TriangleMesh, _ direction: SIMD3<Float>) -> Bool {
        guard mesh.triangleCount > 0 else { return false }
        for t in 0..<mesh.triangleCount {
            guard let corners = mesh.triangle(t) else { return false }
            let (a, b, cc) = corners
            if simd_dot(simd_cross(b - a, cc - a), direction) <= 0 { return false }
        }
        return true
    }

    // MARK: - Triangulation

    /// Square, L, clockwise, degenerate and collinear inputs.
    static func triangulatorChecks(_ c: inout Checker) {
        let square: [SIMD2<Float>] = [[0, 0], [1, 0], [1, 1], [0, 1]]
        let squareTriangles = PolygonTriangulator.triangulate(square)
        c.check("triangulate.square", squareTriangles.count == 6
                && near(PolygonTriangulator.area(of: squareTriangles, in: square), 1, 1e-5))
        let l: [SIMD2<Float>] = [[0, 0], [6, 0], [6, 2], [4, 2], [4, 4], [0, 4]]
        let lTriangles = PolygonTriangulator.triangulate(l)
        c.check("triangulate.lShape", lTriangles.count == 12 && near(PolygonTriangulator.area(of: lTriangles, in: l), 20, 1e-3),
                "indices \(lTriangles.count)")
        let clockwise = Array(square.reversed())
        let clockwiseTriangles = PolygonTriangulator.triangulate(clockwise)
        c.check("triangulate.clockwiseInput", clockwiseTriangles.count == 6
                && near(PolygonTriangulator.area(of: clockwiseTriangles, in: clockwise), 1, 1e-5))
        let collinear: [SIMD2<Float>] = [[0, 0], [1, 1], [2, 2]]
        let tooFew: [SIMD2<Float>] = [[0, 0], [1, 0]]
        c.check("triangulate.degenerateEmpty", PolygonTriangulator.triangulate(collinear).isEmpty
                && PolygonTriangulator.triangulate(tooFew).isEmpty)
        let withMidpoint: [SIMD2<Float>] = [[0, 0], [1, 0], [2, 0], [2, 1], [0, 1]]
        let midpointTriangles = PolygonTriangulator.triangulate(withMidpoint)
        c.check("triangulate.collinearVertex", near(PolygonTriangulator.area(of: midpointTriangles, in: withMidpoint), 2, 1e-5))
    }

    // MARK: - Stores and steps

    /// Save and load in a temporary package, edit log replay, missing files, step hashes.
    static func storeChecks(_ c: inout Checker) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("RoomModelSelfTest-\(UUID().uuidString).mapperproj", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let package = ProjectPackage(root: root)
        let record = F.record(300)
        let roomID = ElementID(uuid: record.id)
        let rebuilt = CapturedRoomStore.rebuiltURL(package, roomID: record.id).path
        c.check("store.rebuiltURL", rebuilt.hasSuffix("derived/rooms/\(record.id.uuidString)/capturedroom.json"))
        let raw = CapturedRoomStore.rawFolder(package, room: record).url
        c.check("store.rawFolder", raw == package.rawRoomURL(session: record.sessionID, room: record.id))
        do {
            try CleanModelStore.save(.empty, to: package)
            c.check("store.saveNeedsPackage", false, "wrote into a missing package")
        } catch {
            c.check("store.saveNeedsPackage", !fm.fileExists(atPath: root.path))
        }
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            let model = editFixture()
            try CleanModelStore.save(model, to: package)
            let loaded = try CleanModelStore.loadBase(package)
            c.check("store.roundTrip", loaded == model)
            let plain = try CleanModelStore.loadEdited(package)
            c.check("store.missingEditLogIsEmpty", plain.model == model && plain.orphaned.isEmpty)
            var log = EditLog()
            log.append(.renameRoom(room: roomID, name: "Office"))
            log.append(.renameRoom(room: ElementID(uuid: F.uuid(999)), name: "x"))
            try ProjectStore.writeJSON(log, to: package.editLogURL)
            let edited = try CleanModelStore.loadEdited(package)
            c.check("store.editLogApplied", edited.model.rooms.first?.name == "Office" && edited.orphaned.count == 1)
            do {
                _ = try CapturedRoomStore.loadInput(package, room: record)
                c.check("store.noCapturedRoomThrows", false, "loaded a room from nothing")
            } catch {
                c.check("store.noCapturedRoomThrows", (error as? CoreError) == .missingFile("capturedroom.json"), "\(error)")
            }
            try stepChecks(&c, package: package, record: record)
        } catch {
            c.check("store.io", false, "\(error)")
        }
    }

    /// Step identity, budgets and input hashes (stable, sensitive to findFurniture, blind to edits).
    static func stepChecks(_ c: inout Checker, package: ProjectPackage, record: RoomRecord) throws {
        let buildStep = BuildRoomStep(room: record)
        let cleanStep = CleanModelStep(meshProvider: { _, _ in nil })
        let noReduced = buildStep.reducedMemoryBudgetBytes == nil && cleanStep.reducedMemoryBudgetBytes == nil
        c.check("steps.identity", buildStep.id == .buildRoom && cleanStep.id == .cleanModel && noReduced)
        let megabyte: UInt64 = 1024 * 1024
        c.check("steps.budgets", buildStep.memoryBudgetBytes == 150 * megabyte && cleanStep.memoryBudgetBytes == 200 * megabyte)
        var manifest = ProjectManifest.new(kind: .room, name: "Test", now: Date(timeIntervalSince1970: 0))
        manifest.rooms = [record]
        let context = StepContext(package: package, manifest: manifest, availableMemory: 1 << 30,
                                  isCancelled: { false }, progress: { _ in })
        let first = try cleanStep.inputHash(context)
        let again = try cleanStep.inputHash(context)
        try ProjectStore.writeJSON(EditLog(), to: package.editLogURL)
        let afterEdits = try cleanStep.inputHash(context)
        manifest.settings.findFurniture = false
        let noFurniture = StepContext(package: package, manifest: manifest, availableMemory: 1 << 30,
                                      isCancelled: { false }, progress: { _ in })
        let changed = try cleanStep.inputHash(noFurniture)
        c.check("steps.cleanHashStable", first == again && first == afterEdits)
        c.check("steps.cleanHashFollowsFurniture", first != changed)
        c.check("steps.eligibleRooms", CleanModelStep.eligibleRooms(manifest).count == 1)
        let buildHash = try buildStep.inputHash(context)
        let buildHashAgain = try buildStep.inputHash(context)
        c.check("steps.buildHash", buildHash.count == 16 && buildHash == buildHashAgain)
        try roomPlanFailedChecks(&c, package: package, record: record)
    }

    /// A room whose roomlog.json says RoomPlan failed is left out of the clean model; no log
    /// (a recovered scan) or another degraded mode keeps it.
    static func roomPlanFailedChecks(_ c: inout Checker, package: ProjectPackage, record: RoomRecord) throws {
        c.check("steps.noLogNotFailed", !CleanModelStep.roomPlanFailed(package, room: record))
        let logURL = CapturedRoomStore.rawFolder(package, room: record).roomLogURL
        var log = RoomCaptureLog(seconds: 60, instructionSeconds: [:], error: "internalError", relocalizations: 0,
                                 limitedTrackingFraction: 0, degraded: .roomPlanFailed)
        try ProjectStore.writeJSON(log, to: logURL)
        c.check("steps.roomPlanFailedLeftOut", CleanModelStep.roomPlanFailed(package, room: record))
        log.degraded = .depthStripped
        log.error = nil
        try ProjectStore.writeJSON(log, to: logURL)
        c.check("steps.otherDegradedKept", !CleanModelStep.roomPlanFailed(package, room: record))
    }
}
