import Foundation
import simd

/// Plain-Swift checks for RoomModel (no XCTest), in the style of `UnitsSelfTest`: `run()`
/// returns one line per failing check ("name: detail"), empty when all pass. Deterministic, no
/// ARKit, RoomPlan session, camera or network; temporary files only under
/// `FileManager.default.temporaryDirectory`, removed afterwards.
enum RoomModelSelfTest {
    /// Failing checks as "name: detail".
    static func run() -> [String] {
        var c = Checker()
        outlineChecks(&c)
        openingChecks(&c)
        heightChecks(&c)
        metricsChecks(&c)
        furnitureChecks(&c)
        editChecks(&c)
        meshChecks(&c)
        triangulatorChecks(&c)
        storeChecks(&c)
        b5Checks(&c)
        return c.failures
    }

    /// Collects failures and counts checks.
    struct Checker {
        /// Failure lines so far.
        private(set) var failures: [String] = []
        /// Number of checks run.
        private(set) var count = 0

        /// Records a failure when `condition` is false.
        mutating func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
            count += 1
            guard !condition else { return }
            let text = detail()
            failures.append(text.isEmpty ? name : "\(name): \(text)")
        }
    }

    /// Fixture namespace.
    typealias F = RoomModelSelfTestFixtures

    /// True when two floats differ by at most `tolerance`.
    static func near(_ a: Float, _ b: Float, _ tolerance: Float) -> Bool { abs(a - b) <= tolerance }

    /// True when two plan points are at most `tolerance` apart.
    static func near(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ tolerance: Float) -> Bool { simd_distance(a, b) <= tolerance }

    /// Element id of fixture surface or object `n`.
    static func wid(_ n: Int) -> ElementID { ElementID.derived(fromRoomPlan: F.uuid(n)) }

    /// Builds one fixture room without mesh terms.
    static func build(_ input: RoomInput, options: CleanBuildOptions = CleanBuildOptions(),
                      mesh: MeshWithAttributes? = nil) -> CleanRoom {
        CleanModelBuilder.buildRoom(input, recordID: F.uuid(300), name: "", floorIndex: 0, mesh: mesh, options: options)
    }

    /// True when every wall ends where the next one starts (closing back to the first).
    static func chained(_ walls: [WallSegment]) -> Bool {
        guard !walls.isEmpty else { return false }
        for i in walls.indices where !near(walls[i].end, walls[(i + 1) % walls.count].start, 1e-4) {
            return false
        }
        return true
    }

    /// True when the point 10 cm along the wall normal from its midpoint lies inside the outline.
    static func normalPointsInside(_ wall: CleanWall, _ outline: [Vec2]) -> Bool {
        let middle = (PlanAxes.toPlan(wall.start.simd) + PlanAxes.toPlan(wall.end.simd)) * 0.5
        let normal = PlanAxes.toPlan(wall.normal.simd)
        return Polygon2D(points: outline.map { $0.simd }).contains(point: middle + normal * 0.1)
    }

    // MARK: - Outline

    /// Wall loop, winding, stubs, flipped walls, corners, curves and the fallback.
    static func outlineChecks(_ c: inout Checker) {
        let rect = RoomOutline.build(F.rectangle())
        let rectPolygon = Polygon2D(points: rect.polygon)
        c.check("outline.rectClosed", rect.isClosed && rect.walls.count == 4 && rect.strayWalls.isEmpty,
                "closed \(rect.isClosed), walls \(rect.walls.count)")
        c.check("outline.rectCounterClockwise", rectPolygon.signedArea > 0)
        c.check("outline.rectArea", near(rectPolygon.area, 20, 1e-3), "\(rectPolygon.area)")
        c.check("outline.rectPerimeter", near(rectPolygon.perimeter, 18, 1e-3), "\(rectPolygon.perimeter)")
        c.check("outline.rectChained", chained(rect.walls))
        c.check("outline.rectNoMismatch", (rect.floorPolygonMismatch ?? 1) < 1e-3)

        let segments = RoomOutline.wallSegments(F.rectangle())
        let heightsOK = segments.allSatisfy { near($0.height, 2.5, 1e-5) && near($0.baseY, 0, 1e-5) }
        c.check("outline.segmentsFromTransform", segments.count == 4 && heightsOK)

        let l = RoomOutline.build(F.lShape())
        let lPolygon = Polygon2D(points: l.polygon)
        c.check("outline.lClosed", l.isClosed && l.walls.count == 6, "walls \(l.walls.count)")
        c.check("outline.lCounterClockwise", lPolygon.signedArea > 0)
        c.check("outline.lArea", near(lPolygon.area, 20, 1e-3), "\(lPolygon.area)")
        c.check("outline.lPerimeter", near(lPolygon.perimeter, 20, 1e-4), "\(lPolygon.perimeter)")
        let mismatch = l.floorPolygonMismatch ?? -1
        c.check("outline.lFloorMismatch", near(mismatch, 0.2, 1e-3), "\(mismatch)")
        let floorArea = RoomOutline.floorPolygon(F.lShape()).map { Polygon2D(points: $0).area } ?? 0
        c.check("outline.floorPolygonIsRectangle", near(floorArea, 24, 1e-3), "\(floorArea)")

        let stub = RoomOutline.build(F.withStub())
        c.check("outline.stubLoop", stub.isClosed && stub.walls.count == 4, "walls \(stub.walls.count)")
        c.check("outline.stubStray", stub.strayWalls.map { $0.id } == [wid(F.stubID)], "strays \(stub.strayWalls.count)")

        let flipped = RoomOutline.build(F.rectangle(flippedWall: 2))
        let flippedWall = flipped.walls.first { $0.id == wid(2) }
        let flippedOrder = flippedWall.map { near($0.start, [5, 0], 1e-3) && near($0.end, [5, 4], 1e-3) } ?? false
        c.check("outline.flippedClosed", flipped.isClosed && Polygon2D(points: flipped.polygon).signedArea > 0)
        c.check("outline.flippedChained", chained(flipped.walls))
        c.check("outline.flippedLoopOrder", flippedOrder)

        let over = RoomOutline.build(F.overshoot())
        let first = over.walls.first { $0.id == wid(1) }
        let cornerOK = first.map { near($0.end, [5, 0], 1e-3) } ?? false
        c.check("outline.cornerIntersection", cornerOK, "\(String(describing: first?.end))")

        let curved = RoomOutline.build(F.curved())
        let curvedWall = curved.walls.first { $0.id == wid(F.curvedID) }
        let curvedArea = Polygon2D(points: curved.polygon).area
        c.check("outline.curvedKeepsArc", curved.isClosed && curvedWall?.arc != nil)
        c.check("outline.curvedArea", near(curvedArea, 16 + 2 * Float.pi, 0.1), "\(curvedArea)")
        c.check("outline.curvedSampled", curved.polygon.count > 8 && curved.polygon.contains { $0.y > 5.9 })

        var open = F.rectangle()
        open.walls.removeFirst()
        let openResult = RoomOutline.build(open)
        let openArea = Polygon2D(points: openResult.polygon).area
        c.check("outline.openUsesFloorPolygon", !openResult.isClosed && openResult.walls.count == 3 && near(openArea, 20, 1e-3))
    }

    // MARK: - Openings and walls

    /// Parent attachment, projection, heights, fallback wall, default swing, normals.
    static func openingChecks(_ c: inout Checker) {
        let room = build(F.rectangle(doors: true, window: true, orphanOpening: true))
        let door = room.openings.first { $0.id == wid(F.doorID) }
        c.check("opening.doorParent", door?.wallID == wid(1) && door?.kind == .door)
        c.check("opening.doorOffset", near(door?.offsetAlongWall ?? -1, 1.0, 1e-3), "\(String(describing: door?.offsetAlongWall))")
        c.check("opening.doorWidth", near(door?.width ?? -1, 0.9, 1e-3), "\(String(describing: door?.width))")
        c.check("opening.doorSillZero", door?.sillHeight == 0)
        c.check("opening.doorHead", near(door?.headHeight ?? -1, 2.0, 1e-4))
        c.check("swing.hingeNearStartCorner", door?.swing?.hingeAtStart == true)
        let intoRoom = door?.swing?.opensToNormalSide == true
        c.check("swing.estimatedIntoRoom", door?.swing?.source == .estimated && intoRoom)
        let endDoor = room.openings.first { $0.id == wid(F.endDoorID) }
        c.check("swing.hingeNearEndCorner", endDoor?.swing?.hingeAtStart == false)
        let orphan = room.openings.first { $0.id == wid(F.orphanOpeningID) }
        c.check("opening.nilParentNearestWall", orphan?.wallID == wid(4), "\(String(describing: orphan?.wallID?.roomPlanID))")
        c.check("opening.nilParentOffset", near(orphan?.offsetAlongWall ?? -1, 2.0, 1e-3) && near(orphan?.width ?? -1, 1.0, 1e-3))
        c.check("opening.noSwingForOpening", orphan?.swing == nil)

        let raised = build(F.rectangle(floorY: 0.2, window: true))
        let window = raised.openings.first { $0.id == wid(F.windowID) }
        c.check("opening.windowSillFromFloor", near(window?.sillHeight ?? -1, 0.9, 1e-4), "\(String(describing: window?.sillHeight))")
        c.check("opening.windowHeadFromFloor", near(window?.headHeight ?? -1, 2.1, 1e-4))
        c.check("opening.windowProjected", near(window?.offsetAlongWall ?? -1, 1.5, 1e-3) && near(window?.width ?? -1, 1.5, 1e-3))
        c.check("floor.elevationFromRoomPlan", near(raised.floor.elevation, 0.2, 1e-5) && raised.floor.provenance == .estimated)

        c.check("wall.normalsPointInside", room.walls.allSatisfy { normalPointsInside($0, room.floor.outline) })
        c.check("wall.idsDerived", Set(room.walls.map { $0.id }) == Set(F.rectangleWalls.map { wid($0) }))
        c.check("wall.thicknessEstimated", room.walls.allSatisfy { $0.thickness == 0.115 && $0.thicknessSource == .estimated })
        c.check("room.idAndSection", room.id == ElementID(uuid: F.uuid(300)) && room.sectionLabel == "livingRoom")
        let outline = Polygon2D(points: room.floor.outline.map { $0.simd })
        c.check("room.floorOutlineCounterClockwise", outline.signedArea > 0 && near(outline.area, 20, 1e-3))
    }

    // MARK: - Heights (D13)

    /// Mesh ceiling and floor with and without enough coverage.
    static func heightChecks(_ c: inout Checker) {
        let polygon = F.rectangleCorners
        let high = F.roomMesh(ceilingFraction: 0.8)
        let ceiling = RoomMetricsCalculator.ceilingFromMesh(high, outline: polygon, floorY: 0, gate: 0.25)
        c.check("ceiling.meshHeight", near(ceiling?.height ?? 0, 2.6, 1e-4), "\(String(describing: ceiling?.height))")
        c.check("ceiling.meshCoverage", near(ceiling?.coverage ?? 0, 0.8, 1e-3), "\(String(describing: ceiling?.coverage))")
        let floor = RoomMetricsCalculator.floorFromMesh(high, outline: polygon, gate: 0.25)
        c.check("floor.meshElevation", near(floor?.elevation ?? 1, 0, 1e-5) && near(floor?.coverage ?? 0, 1, 1e-3))

        let measured = build(F.rectangle(), mesh: high)
        c.check("ceiling.measured", measured.ceiling.provenance == .measured && near(measured.ceiling.height, 2.6, 1e-4))
        c.check("floor.measured", measured.floor.provenance == .measured && near(measured.floor.elevation, 0, 1e-5))

        let low = F.roomMesh(ceilingFraction: 0.1)
        c.check("ceiling.lowCoverageRejected", RoomMetricsCalculator.ceilingFromMesh(low, outline: polygon, floorY: 0, gate: 0.25) == nil)
        let fallback = build(F.rectangle(), mesh: low)
        c.check("ceiling.fallbackWallHeight", fallback.ceiling.provenance == .estimated && near(fallback.ceiling.height, 2.5, 1e-4),
                "\(fallback.ceiling.height)")

        let volumeMeasured = measured.metrics.volumeProvenance == .measured
        let volumeEstimated = fallback.metrics.volumeProvenance == .estimated
        c.check("volume.provenanceFollowsCeiling", volumeMeasured && volumeEstimated)
        c.check("volume.areaTimesHeight", near(measured.metrics.volume, 52, 1e-2), "\(measured.metrics.volume)")
        let noMesh = build(F.rectangle())
        c.check("heights.noMeshEstimated", noMesh.floor.provenance == .estimated && noMesh.ceiling.provenance == .estimated)
    }

    // MARK: - Metrics

    /// Length, width, area, perimeter, wall area and scaling.
    static func metricsChecks(_ c: inout Checker) {
        let room = build(F.rectangleOneDoor())
        let m = room.metrics
        c.check("metrics.lengthWidth", near(m.length, 5, 1e-3) && near(m.width, 4, 1e-3), "\(m.length) x \(m.width)")
        c.check("metrics.areaPerimeter", near(m.floorArea, 20, 1e-3) && near(m.perimeter, 18, 1e-3))
        c.check("metrics.wallAreaMinusDoor", near(m.wallArea, 45 - 1.8, 1e-3), "\(m.wallArea)")
        c.check("metrics.ceilingHeight", near(m.ceilingHeight, 2.5, 1e-4) && m.ceilingProvenance == .estimated)
        let l = build(F.lShape()).metrics
        c.check("metrics.lShape", near(l.floorArea, 20, 1e-3) && near(l.length, 6, 1e-3) && near(l.width, 4, 1e-3),
                "\(l.floorArea) \(l.length) \(l.width)")
        let doubled = RoomMetricsCalculator.scaled(m, by: 2)
        let areaOK = near(doubled.floorArea, 80, 1e-2) && near(doubled.wallArea, m.wallArea * 4, 1e-2)
        c.check("metrics.scaledUniformly", areaOK && near(doubled.length, 10, 1e-3) && near(doubled.volume, m.volume * 8, 1e-2))
    }

    // MARK: - Furniture, occlusion, provenance

    /// findFurniture, the occlusion heuristic, provisional provenance and Codable.
    static func furnitureChecks(_ c: inout Checker) {
        var options = CleanBuildOptions()
        options.findFurniture = false
        let dropped = build(F.rectangle(sofa: true), options: options)
        c.check("furniture.findOffDropsObjects", dropped.objects.isEmpty && dropped.floor.occludedArea == 0)

        let kept = build(F.rectangle(sofa: true))
        let sofa = kept.objects.first
        c.check("furniture.kept", kept.objects.count == 1 && sofa?.category == .sofa && sofa?.provenance == .measured)
        let wall = kept.walls.first { $0.id == wid(1) }
        let span = wall?.occludedSpans.first
        let spanOK = near(span?.lowerBound ?? -1, 1.5, 1e-3) && near(span?.upperBound ?? -1, 3.5, 1e-3)
        c.check("occlusion.sofaSpan", wall?.occludedSpans.count == 1 && spanOK, "\(String(describing: wall?.occludedSpans))")
        c.check("occlusion.otherWallsClear", kept.walls.filter { $0.id != wid(1) }.allSatisfy { $0.occludedSpans.isEmpty })
        c.check("occlusion.floorArea", near(kept.floor.occludedArea, 1.8, 1e-3), "\(kept.floor.occludedArea)")
        if let sofa, let wall {
            var moved = sofa
            var pose = matrix_identity_float4x4
            pose.columns.3 = SIMD4<Float>(2.5, 0.4, -0.95, 1)
            moved.transform = Transform4(pose)
            c.check("occlusion.farSofaIgnored", RoomMetricsCalculator.occlusionSpan(of: moved, wall: wall, distance: 0.3) == nil)
        } else {
            c.check("occlusion.farSofaIgnored", false, "fixture missing")
        }

        let provisional = build(F.rectangle(doors: true, sofa: true, provisional: true))
        let wallsEstimated = provisional.walls.allSatisfy { $0.provenance == .estimated }
        let openingsEstimated = provisional.openings.allSatisfy { $0.provenance == .estimated }
        let objectsEstimated = provisional.objects.allSatisfy { $0.provenance == .estimated }
        c.check("provisional.wallsEstimated", wallsEstimated && !provisional.walls.isEmpty)
        c.check("provisional.everythingEstimated", openingsEstimated && objectsEstimated && provisional.floor.provenance == .estimated)
        let finished = build(F.rectangle(doors: true))
        c.check("provenance.finalMeasured", finished.walls.allSatisfy { $0.provenance == .measured })

        let input = F.rectangle(doors: true, window: true, sofa: true, provisional: true)
        do {
            let data = try JSONEncoder().encode(input)
            let back = try JSONDecoder().decode(RoomInput.self, from: data)
            c.check("input.codableRoundTrip", back == input && back.isProvisional)
        } catch {
            c.check("input.codableRoundTrip", false, "\(error)")
        }
    }
}
