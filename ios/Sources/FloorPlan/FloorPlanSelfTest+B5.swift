import Foundation
import simd

/// FloorPlan self-test, part 3 (build 5 revision, docs/MODULES.md 3.37c): walls copied without
/// reversal, the CR-1 operations on the plan, merged rooms, room boundaries and the rules
/// version in the step hash.
extension FloorPlanSelfTest {
    /// Runs every build 5 check.
    static func revisionChecks(_ log: inout FloorPlanSelfTestLog) {
        orientationChecks(&log)
        openingEditChecks(&log)
        mergeChecks(&log)
        splitChecks(&log)
        batchChecks(&log)
        boundaryChecks(&log)
        stepChecks(&log)
    }

    /// The plan of the two-room fixture.
    static func twoRoomPlan() -> PlanModel {
        PlanBuilder.build(from: FloorPlanSelfTestFixtures.twoRoomModel(), floors: FloorPlanSelfTestFixtures.floors)
    }

    /// `plan` with one operation applied, and the result.
    static func applying(_ op: EditOperation, to plan: PlanModel) -> (ok: Bool, plan: PlanModel) {
        var copy = plan
        let ok = copy.apply(op)
        return (ok, copy)
    }

    /// The split of the 4 x 5 room along y = 2 (the part above the line stays the room).
    static let splitAtTwo = EditOperation.splitRoom(room: FloorPlanSelfTestFixtures.roomID,
                                                    line: [Vec2(x: -1, y: 2), Vec2(x: 5, y: 2)],
                                                    newRoom: FloorPlanSelfTestFixtures.splitNewRoom)

    /// Plan walls follow clean start -> end; legacy right-normal walls are only counted.
    private static func orientationChecks(_ log: inout FloorPlanSelfTestLog) {
        typealias F = FloorPlanSelfTestFixtures
        let model = F.revisedModel()
        let plan = PlanBuilder.build(from: model, floors: F.floors)
        let planWalls = plan.levels.first?.walls ?? []
        var sameEnds = !planWalls.isEmpty
        for room in model.rooms {
            for clean in room.walls {
                let planWall = planWalls.first { $0.id == clean.id }
                let startOK = planWall?.a == PlanAxes.toPlan(clean.start)
                let endOK = planWall?.b == PlanAxes.toPlan(clean.end)
                if !(startOK && endOK) { sameEnds = false }
            }
        }
        log.expect("b5.build.aIsCleanStart", sameEnds && planWalls.count == 9, "got \(planWalls.count) walls")

        let legacyWalls = F.flippedWallModel().rooms.first?.walls ?? []
        let flags = legacyWalls.map { wall in
            PlanBuilder.normalPointsRight(a: PlanAxes.toPlan(wall.start.simd), b: PlanAxes.toPlan(wall.end.simd),
                                          wallNormal: wall.normal.simd)
        }
        log.expect("b5.build.rightNormalDetected", flags == [true, false, false, false], "got \(flags)")

        let merged = PlanBuilder.build(from: F.mergedCleanModel(), floors: F.floors)
        let mergedRoom = merged.levels.first?.rooms.first
        let parts = mergedRoom?.mergedOutlines ?? []
        let partCCW = parts.count == 1 && Polygon2D(points: parts[0].map { $0.simd }).signedArea > 0
        log.expect("b5.build.mergedOutlinesCopied", partCCW, "got \(parts.count) parts")
        log.near("b5.build.totalArea", mergedRoom.map { PlanBuilder.totalArea($0) } ?? 0, 32, tolerance: 1e-3)
        let mergedDims = F.overallLengths(F.roomID, in: merged.levels.first)
        log.expect("b5.build.overallEnclosesParts", F.lengthsMatch(mergedDims, [5, 7.12]), "got \(mergedDims)")
    }

    /// moveOpening and resizeOpening clamp to the wall and keep the center.
    private static func openingEditChecks(_ log: inout FloorPlanSelfTestLog) {
        typealias F = FloorPlanSelfTestFixtures
        let base = rectanglePlan()
        /// The fixture door after one operation.
        func door(_ op: EditOperation) -> (ok: Bool, opening: PlanOpening?) {
            let result = applying(op, to: base)
            return (result.ok, result.plan.levels.first?.openings.first(where: { $0.id == F.door }))
        }
        let far = door(.moveOpening(opening: F.door, offset: 3.5))
        let farOffset: Float = far.opening?.offset ?? -1
        log.expect("b5.moveOpening.clampEnd", far.ok && abs(farOffset - 3.1) < 1e-4, "got \(farOffset)")
        let before = door(.moveOpening(opening: F.door, offset: -1))
        log.expect("b5.moveOpening.clampStart", before.ok && before.opening?.offset == 0)
        let moved = door(.moveOpening(opening: F.door, offset: 2))
        let baseSwing: DoorSwing? = base.levels.first?.openings.first(where: { $0.id == F.door })?.swing
        let movedWidth: Bool = moved.opening?.width == 0.9 && moved.opening?.swing == baseSwing
        log.expect("b5.moveOpening.keepsWidthAndSwing", moved.ok && moved.opening?.offset == 2 && movedWidth)
        let missingMove = applying(.moveOpening(opening: F.id(990), offset: 1), to: base)
        log.expect("b5.moveOpening.missing", !missingMove.ok && missingMove.plan == base)

        let wide = door(.resizeOpening(opening: F.door, width: 1.5, sillHeight: 0, headHeight: 2.1))
        let wideOffset: Float = wide.opening?.offset ?? -1
        let wideWidth: Float = wide.opening?.width ?? -1
        log.expect("b5.resizeOpening.keepsCenter", wide.ok && abs(wideOffset - 0.7) < 1e-4 && abs(wideWidth - 1.5) < 1e-4,
                   "got \(wideOffset) + \(wideWidth)")
        let huge = door(.resizeOpening(opening: F.door, width: 10, sillHeight: 0, headHeight: 2.1))
        log.expect("b5.resizeOpening.clampWall", huge.ok && huge.opening?.width == 4 && huge.opening?.offset == 0)
        let tiny = door(.resizeOpening(opening: F.door, width: 0.01, sillHeight: 0, headHeight: 2.1))
        let tinyOffset: Float = tiny.opening?.offset ?? -1
        let tinyWidth: Float = tiny.opening?.width ?? -1
        let tinyOK = abs(tinyWidth - 0.05) < 1e-4 && abs(tinyOffset - 1.425) < 1e-4
        log.expect("b5.resizeOpening.minimumWidth", tiny.ok && tinyOK, "got \(tinyOffset) + \(tinyWidth)")
        let missingResize = applying(.resizeOpening(opening: F.id(991), width: 1, sillHeight: 0, headHeight: 2), to: base)
        log.expect("b5.resizeOpening.missing", !missingResize.ok && missingResize.plan == base)
    }

    /// mergeRooms: one room, summed area, one merged outline, hits on both parts, orphans.
    private static func mergeChecks(_ log: inout FloorPlanSelfTestLog) {
        typealias F = FloorPlanSelfTestFixtures
        let base = twoRoomPlan()
        let merged = applying(.mergeRooms(rooms: [F.roomB], into: F.roomID), to: base)
        let level = merged.plan.levels.first
        let room = level?.rooms.first
        log.expect("b5.merge.oneRoom", merged.ok && level?.rooms.count == 1 && room?.id == F.roomID)
        log.near("b5.merge.areaIsSum", room?.area ?? 0, 32, tolerance: 1e-3)
        log.expect("b5.merge.oneMergedOutline", room?.mergedOutlines?.count == 1)
        log.expect("b5.merge.labelUnchanged", room?.labelAt == base.levels.first?.rooms.first?.labelAt)
        let dims = F.overallLengths(F.roomID, in: level)
        let bDims = F.overallLengths(F.roomB, in: level)
        log.expect("b5.merge.dimensionsFollow", F.lengthsMatch(dims, [5, 7.12]) && bDims.isEmpty, "got \(dims), \(bDims)")

        let drawn = PlanDrawing.make(level: level ?? FloorPlanSelfTest.level(walls: []), toggles: .standard, prefs: testPrefs,
                                     roomTitles: [:], name: "Merged")
        let roomHits = drawn.hits.filter { $0.kind == .room && $0.element == F.roomID }.count
        log.expect("b5.merge.hitPerPart", roomHits == 2, "got \(roomHits)")
        let inSecond = PlanDrawing.hitTest(drawn.hits, at: SIMD2<Float>(5.62, 2), tolerance: 0.1)
        log.expect("b5.merge.hitSecondPart", inSecond?.kind == .room && inSecond?.element == F.roomID,
                   "got \(String(describing: inSecond?.kind))")
        let tags = drawn.plan.entities.filter { $0.layer == PlanLayers.roomNames }.count
        log.expect("b5.merge.oneTag", tags == 2, "got \(tags) texts")

        let missing = applying(.mergeRooms(rooms: [F.roomB, F.id(992)], into: F.roomID), to: base)
        log.expect("b5.merge.missingRoom", !missing.ok && missing.plan == base)
        let missingInto = applying(.mergeRooms(rooms: [F.roomB], into: F.id(993)), to: base)
        log.expect("b5.merge.missingInto", !missingInto.ok && missingInto.plan == base)

        let moved = applying(.moveWallEndpoint(wall: F.bEast, atStart: false, to: Vec2(x: 7.62, y: 4)), to: merged.plan)
        let movedRoom = moved.plan.levels.first?.rooms.first
        let vertexMoved = movedRoom?.mergedOutlines?.first?.contains(Vec2(x: 7.62, y: 4)) == true
        log.expect("b5.moveEndpoint.mergedVertex", moved.ok && vertexMoved)
        log.near("b5.moveEndpoint.totalArea", movedRoom?.area ?? 0, 33, tolerance: 1e-3)

        let roundTrip = (try? ProjectStore.encoder.encode(merged.plan))
            .flatMap { try? ProjectStore.decoder.decode(PlanModel.self, from: $0) }
        log.expect("b5.merge.codableRoundTrip", roundTrip == merged.plan)
    }

    /// splitRoom: two rooms on either side, labels inside, replays and misses unchanged.
    private static func splitChecks(_ log: inout FloorPlanSelfTestLog) {
        typealias F = FloorPlanSelfTestFixtures
        let base = rectanglePlan()
        let split = applying(splitAtTwo, to: base)
        let rooms = split.plan.levels.first?.rooms ?? []
        let kept = rooms.first { $0.id == F.roomID }
        let created = rooms.first { $0.id == F.splitNewRoom }
        log.expect("b5.split.twoRooms", split.ok && rooms.count == 2 && rooms.last?.id == F.splitNewRoom)
        log.near("b5.split.keptArea", kept?.area ?? 0, 12, tolerance: 1e-3)
        log.near("b5.split.newArea", created?.area ?? 0, 8, tolerance: 1e-3)
        log.expect("b5.split.newRoomUnnamed", created?.name == "" && created?.id.roomPlanID == nil)
        let labelsInside = [kept, created].allSatisfy { room in
            guard let room else { return false }
            return Polygon2D(points: room.outline.map { $0.simd }).contains(point: room.labelAt.simd)
        }
        log.expect("b5.split.labelsInside", labelsInside)
        let keptDims = F.overallLengths(F.roomID, in: split.plan.levels.first)
        let newDims = F.overallLengths(F.splitNewRoom, in: split.plan.levels.first)
        log.expect("b5.split.dimensionsFollow", F.lengthsMatch(keptDims, [3, 4]) && F.lengthsMatch(newDims, [2, 4]),
                   "got \(keptDims), \(newDims)")

        let replayed = applying(splitAtTwo, to: split.plan)
        log.expect("b5.split.replayUnchanged", replayed.ok && replayed.plan == split.plan)
        let across = [Vec2(x: 0, y: 1), Vec2(x: 4, y: 1)]
        let missing = applying(.splitRoom(room: F.id(994), line: across, newRoom: F.id(71)), to: base)
        log.expect("b5.split.missingRoom", !missing.ok && missing.plan == base)
        let above = [Vec2(x: 0, y: 10), Vec2(x: 4, y: 10)]
        let outside = applying(.splitRoom(room: F.roomID, line: above, newRoom: F.id(72)), to: base)
        log.expect("b5.split.lineMissesRoom", outside.ok && outside.plan == base)
        let point = applying(.splitRoom(room: F.roomID, line: [Vec2(x: 1, y: 1)], newRoom: F.id(73)), to: base)
        log.expect("b5.split.onePointUnchanged", point.ok && point.plan == base)

        let uPlan = PlanBuilder.build(from: F.uShapedModel(), floors: F.floors)
        let uLine = [Vec2(x: -1, y: 2), Vec2(x: 7, y: 2)]
        let uSplit = applying(.splitRoom(room: F.id(119), line: uLine, newRoom: F.id(74)), to: uPlan)
        let uRooms = uSplit.plan.levels.first?.rooms ?? []
        let uKept: Float = uRooms.first.map { PlanBuilder.totalArea($0) } ?? 0
        let uTotal: Float = uRooms.reduce(Float(0)) { $0 + PlanBuilder.totalArea($1) }
        log.expect("b5.split.concaveAreas", uSplit.ok && abs(uKept - 8) < 1e-3 && abs(uTotal - 18) < 1e-3,
                   "got \(uKept) of \(uTotal)")
        let uEdges = PlanDrawing.openEdges(of: uRooms.first?.outline.map { $0.simd } ?? [])
        let bridge = uEdges.contains { edge in
            let middle = (edge.0 + edge.1) * 0.5
            return abs(middle.y - 2) < 1e-3 && middle.x > 2.001 && middle.x < 3.999
        }
        log.expect("b5.split.noBridgeEdge", !uEdges.isEmpty && !bridge, "got \(uEdges.count) edges")
    }

    /// batch: all operations or none.
    private static func batchChecks(_ log: inout FloorPlanSelfTestLog) {
        typealias F = FloorPlanSelfTestFixtures
        let base = rectanglePlan()
        let both = applying(.batch(operations: [.renameRoom(room: F.roomID, name: "Den"),
                                                .moveOpening(opening: F.door, offset: 2)]), to: base)
        let bothLevel = both.plan.levels.first
        let renamed = bothLevel?.rooms.first?.name == "Den"
        let movedDoor = bothLevel?.openings.first(where: { $0.id == F.door })
        let doorMoved = movedDoor?.offset == 2
        log.expect("b5.batch.appliesAll", both.ok && renamed && doorMoved)
        let broken = applying(.batch(operations: [.renameRoom(room: F.roomID, name: "Den"),
                                                  .renameRoom(room: F.id(995), name: "Nowhere")]), to: base)
        log.expect("b5.batch.allOrNothing", !broken.ok && broken.plan == base)
        let nested = applying(.batch(operations: [.batch(operations: [.renameRoom(room: F.roomID, name: "Den")]),
                                                  splitAtTwo]), to: base)
        let nestedRooms = nested.plan.levels.first?.rooms ?? []
        log.expect("b5.batch.nested", nested.ok && nestedRooms.count == 2 && nestedRooms.first?.name == "Den")
        var editLog = EditLog()
        editLog.append(.batch(operations: [.renameRoom(room: F.roomID, name: "Den"), .deleteElement(element: F.id(996))]))
        let replayed = editLog.applied(to: base)
        log.expect("b5.batch.orphanedWhole", replayed.orphaned.count == 1 && replayed.0 == base)
    }

    /// Room boundaries: along a split, never on walls, hidden with the room names.
    private static func boundaryChecks(_ log: inout FloorPlanSelfTestLog) {
        typealias F = FloorPlanSelfTestFixtures
        let split = applying(splitAtTwo, to: rectanglePlan()).plan
        let splitDrawing = drawing(split, toggles: allOn).plan
        let pieces = F.lines(splitDrawing, layer: PlanLayers.roomBoundaries)
        let alongCut = pieces.allSatisfy { abs($0.0.y - 2) < 1e-3 && abs($0.1.y - 2) < 1e-3 }
        log.expect("b5.boundary.alongSplit", !pieces.isEmpty && alongCut, "got \(pieces.count) pieces")
        let rectangle = F.layerCounts(drawing(rectanglePlan(), toggles: allOn).plan)
        log.expect("b5.boundary.noneWithWalls", (rectangle[PlanLayers.roomBoundaries] ?? 0) == 0)
        let open = PlanBuilder.build(from: F.openLoopModel(), floors: F.floors)
        let openPieces = F.lines(drawing(open, toggles: allOn).plan, layer: PlanLayers.roomBoundaries)
        let onlyOpenSide = openPieces.allSatisfy { abs($0.0.y - 5) < 1e-3 && abs($0.1.y - 5) < 1e-3 }
        log.expect("b5.boundary.openLoopEdgeOnly", !openPieces.isEmpty && onlyOpenSide, "got \(openPieces.count) pieces")

        let before = F.layerCounts(splitDrawing)
        var noNames = allOn
        noNames.roomNames = false
        let after = F.layerCounts(drawing(split, toggles: noNames).plan)
        let removed = (after[PlanLayers.roomBoundaries] ?? 0) == 0 && (after[PlanLayers.roomNames] ?? 0) == 0
        let othersKept = PlanLayers.drawingOrder.allSatisfy { layer in
            layer == PlanLayers.roomBoundaries || layer == PlanLayers.roomNames || after[layer] == before[layer]
        }
        log.expect("b5.boundary.hiddenWithRoomNames", removed && othersKept, "before \(before), after \(after)")

        let names = PlanLayers.all().map { $0.name }
        let order = PlanLayers.drawingOrder
        let boundaryIndex: Int? = order.firstIndex(of: PlanLayers.roomBoundaries)
        let namesIndex: Int? = order.firstIndex(of: PlanLayers.roomNames)
        let afterNames = boundaryIndex != nil && boundaryIndex == namesIndex.map { $0 + 1 }
        let unique = Set(names).count == names.count
        log.expect("b5.layers.uniqueWithBoundaries", unique && names.contains("A-AREA-BNDY") && afterNames)
        let boundaryColor = PlanLayers.color(of: PlanLayers.roomBoundaries)
        log.expect("b5.layers.boundaryColor", boundaryColor == PlanLayers.color(of: PlanLayers.roomNames))
    }

    /// FloorPlanStep hashes its rules version.
    private static func stepChecks(_ log: inout FloorPlanSelfTestLog) {
        log.expect("b5.step.rulesVersion", FloorPlanStep.rulesVersion == "planBuilder-rules=2")
        let current = FloorPlanStep.hash(cleanStamp: "-", floorList: "0:0.0:", rules: FloorPlanStep.rulesVersion)
        let older = FloorPlanStep.hash(cleanStamp: "-", floorList: "0:0.0:", rules: "planBuilder-rules=1")
        log.expect("b5.step.hashFollowsRules", current != older)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloorPlanSelfTestB5-absent." + ProjectPackage.fileExtension, isDirectory: true)
        let floors = FloorPlanSelfTestFixtures.floors
        let manifest = ProjectManifest.new(kind: .room, name: "Test", now: Date(timeIntervalSince1970: 0))
        let ctx = StepContext(package: ProjectPackage(root: root), manifest: manifest, availableMemory: 1 << 30,
                              isCancelled: { false }, progress: { _ in })
        let floorList = floors.map { "\($0.id):\($0.elevation):\($0.name)" }.joined(separator: ",")
        let expected = FloorPlanStep.hash(cleanStamp: "-", floorList: floorList, rules: FloorPlanStep.rulesVersion)
        let actual = try? FloorPlanStep(floors: floors).inputHash(ctx)
        log.expect("b5.step.inputHashUsesRules", actual == expected, "got \(actual ?? "nil")")
    }
}
