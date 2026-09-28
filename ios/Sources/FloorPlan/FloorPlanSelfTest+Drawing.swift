import Foundation
import simd
import CoreGraphics

/// FloorPlan self-test, part 2: drawing layers and toggles, hit testing, viewport, images,
/// room titles and category names.
extension FloorPlanSelfTest {
    /// Imperial eighths, the Units default, for every label check.
    static let testPrefs = UnitPreferences.standard

    /// Every toggle on, including the grid.
    static let allOn = PlanToggles(furniture: true, measurements: true, roomNames: true, doorsWindows: true,
                                   fixtures: true, grid: true, scale: true)

    /// The drawing of the fixture room's level with `toggles`.
    static func drawing(_ plan: PlanModel, toggles: PlanToggles) -> PlanDrawingResult {
        let level = plan.levels.first ?? PlanLevel(id: 0, name: "", elevation: 0, rooms: [], walls: [], openings: [],
                                                     fixtures: [], annotations: [], dimensions: [])
        let titles = RoomTitles.titles(for: FloorPlanSelfTestFixtures.rectangleModel())
        return PlanDrawing.make(level: level, toggles: toggles, prefs: testPrefs, roomTitles: titles, name: "Test")
    }

    /// Layers, labels, toggles, grid, scale bar, door swings, estimated faces, occlusion.
    static func drawingChecks(_ log: inout FloorPlanSelfTestLog) {
        typealias F = FloorPlanSelfTestFixtures
        let plan = rectanglePlan()
        let base = drawing(plan, toggles: allOn)
        let counts = F.layerCounts(base.plan)

        let labels = F.dimensionLabels(base.plan)
        log.expect("draw.dimensionCount", labels.count == 6, "got \(labels.count)")
        let fourMeters = LengthFormat.primary(4, prefs: testPrefs)
        let fiveMeters = LengthFormat.primary(5, prefs: testPrefs)
        let fourCount = labels.filter { $0 == fourMeters }.count
        let fiveCount = labels.filter { $0 == fiveMeters }.count
        log.expect("draw.dimensionLabelsUseUnits", fourCount == 3 && fiveCount == 3, "got \(labels)")
        let layerNames = Set(PlanLayers.all().map { $0.name })
        log.expect("draw.layersDeclared", Set(base.plan.entities.map { $0.layer }).isSubset(of: layerNames))
        let someLayers = [PlanLayers.walls, PlanLayers.doorSwingEstimated, PlanLayers.wallsEstimated, PlanLayers.scaleBar]
        let expectedNames = ["A-WALL", "A-DOOR-EST", "A-WALL-EST", "A-ANNO-SCAL"]
        log.expect("draw.layerNames", someLayers == expectedNames)

        let toggles: [(name: String, path: WritableKeyPath<PlanToggles, Bool>, layers: [String])] = [
            ("furniture", \.furniture, [PlanLayers.furniture]),
            ("measurements", \.measurements, [PlanLayers.dimensions]),
            ("roomNames", \.roomNames, [PlanLayers.roomNames]),
            ("doorsWindows", \.doorsWindows, [PlanLayers.doors, PlanLayers.doorSwingEstimated, PlanLayers.windows]),
            ("fixtures", \.fixtures, [PlanLayers.fixtures]),
            ("grid", \.grid, [PlanLayers.grid]),
            ("scale", \.scale, [PlanLayers.scaleBar])
        ]
        for toggle in toggles {
            var off = allOn
            off[keyPath: toggle.path] = false
            let reduced = F.layerCounts(drawing(plan, toggles: off).plan)
            let hadContent = toggle.layers.contains { (counts[$0] ?? 0) > 0 }
            let removed = toggle.layers.allSatisfy { (reduced[$0] ?? 0) == 0 }
            let othersKept = PlanLayers.drawingOrder.allSatisfy { layer in
                toggle.layers.contains(layer) || (reduced[layer] ?? 0) == (counts[layer] ?? 0)
            }
            log.expect("draw.toggle.\(toggle.name)", hadContent && removed && othersKept,
                       "before \(counts), after \(reduced)")
        }

        let standard = F.layerCounts(drawing(plan, toggles: .standard).plan)
        log.expect("draw.gridOffByDefault", (standard[PlanLayers.grid] ?? 0) == 0)
        log.expect("draw.gridOn", (counts[PlanLayers.grid] ?? 0) > 0)
        log.expect("draw.scaleBar", (standard[PlanLayers.scaleBar] ?? 0) >= 5, "got \(standard[PlanLayers.scaleBar] ?? 0)")

        let hitIDs = Set(base.hits.map { $0.element })
        log.expect("draw.hiddenFixtureSkipped", !hitIDs.contains(F.hiddenTable) && hitIDs.contains(F.sofa))
        let fixtureHits = base.hits.filter { $0.kind == .fixture }.count
        log.expect("draw.visibleFixtureHits", fixtureHits == 2, "got \(fixtureHits)")

        log.expect("draw.estimatedSwingNoSolidDoor", (counts[PlanLayers.doors] ?? 0) == 0)
        let estimatedArcs = F.arcRadii(base.plan, layer: PlanLayers.doorSwingEstimated)
        log.expect("draw.estimatedSwingDashedArc", estimatedArcs.count > 1, "got \(estimatedArcs.count) pieces")

        var userPlan = plan
        _ = userPlan.apply(.setDoorSwing(door: F.door, swing: DoorSwing(hingeAtStart: true, opensToNormalSide: true, source: .user)))
        let userDrawing = drawing(userPlan, toggles: allOn).plan
        let userArcs = F.arcRadii(userDrawing, layer: PlanLayers.doors)
        let userRadius: Double = userArcs.first ?? 0
        log.expect("draw.userSwingSolidArc", userArcs.count == 1 && abs(userRadius - 0.9) < 0.00001, "got \(userArcs)")
        log.expect("draw.userSwingNotEstimated", F.arcRadii(userDrawing, layer: PlanLayers.doorSwingEstimated).isEmpty)

        log.expect("draw.estimatedOuterFace", (counts[PlanLayers.wallsEstimated] ?? 0) > 0)
        var measuredPlan = plan
        for wall in plan.levels.first?.walls ?? [] {
            _ = measuredPlan.apply(.setWallThickness(wall: wall.id, thickness: wall.thickness))
        }
        let measuredCounts = F.layerCounts(drawing(measuredPlan, toggles: allOn).plan)
        log.expect("draw.userThicknessSolid", (measuredCounts[PlanLayers.wallsEstimated] ?? 0) == 0)

        log.expect("draw.occludedDashed", (counts[PlanLayers.occluded] ?? 0) > 1, "got \(counts[PlanLayers.occluded] ?? 0)")
        let windowLines = counts[PlanLayers.windows] ?? 0
        log.expect("draw.windowThreeLines", windowLines == 3, "got \(windowLines)")

        let names = ObjectCategory.allCases.map { Copy.FloorPlan.categoryName($0) }
        log.expect("draw.categoryNamesNonEmpty", names.allSatisfy { !$0.isEmpty })
        log.expect("draw.categoryNamesDistinct", Set(names).count == ObjectCategory.allCases.count)

        let roomTexts = base.plan.entities.compactMap { entity -> String? in
            guard entity.layer == PlanLayers.roomNames, case let .text(_, _, string, _) = entity.geometry else { return nil }
            return string
        }
        let areaText = AreaFormat.primary(20, prefs: testPrefs)
        log.expect("draw.roomTag", roomTexts == [Copy.FloorPlan.defaultRoomTitle(1), areaText], "got \(roomTexts)")
    }

    /// Hit testing, room titles and the viewport mapping.
    static func interactionChecks(_ log: inout FloorPlanSelfTestLog) {
        typealias F = FloorPlanSelfTestFixtures
        let hits = drawing(rectanglePlan(), toggles: .standard).hits
        let near = PlanDrawing.hitTest(hits, at: SIMD2<Float>(0.05, 2.5), tolerance: 0.1)
        log.expect("hit.wallAt5cm", near?.kind == .wall && near?.element == F.westWall, "got \(String(describing: near?.kind))")
        let far = PlanDrawing.hitTest(hits, at: SIMD2<Float>(1.0, 2.5), tolerance: 0.1)
        log.expect("hit.noWallAt1m", far?.element != F.westWall && far?.kind == .room, "got \(String(describing: far?.kind))")
        let onDoor = PlanDrawing.hitTest(hits, at: SIMD2<Float>(1.45, 0.02), tolerance: 0.1)
        log.expect("hit.openingBeforeWall", onDoor?.element == F.door, "got \(String(describing: onDoor?.kind))")
        let onSofa = PlanDrawing.hitTest(hits, at: SIMD2<Float>(2.2, 4.3), tolerance: 0.1)
        log.expect("hit.fixture", onSofa?.element == F.sofa, "got \(String(describing: onSofa?.kind))")
        let outside = PlanDrawing.hitTest(hits, at: SIMD2<Float>(-3, -3), tolerance: 0.1)
        log.expect("hit.nothingOutside", outside == nil)

        log.expect("titles.kitchen", RoomTitles.title(name: "", sectionLabel: "kitchen", index: 0) == Copy.FloorPlan.sectionKitchen)
        log.expect("titles.default", RoomTitles.title(name: "", sectionLabel: nil, index: 1) == Copy.FloorPlan.defaultRoomTitle(2))
        log.expect("titles.unidentified", RoomTitles.title(name: " ", sectionLabel: "unidentified", index: 0) == "Room 1")
        log.expect("titles.userName", RoomTitles.title(name: "Studio", sectionLabel: "kitchen", index: 0) == "Studio")
        let titles = RoomTitles.titles(for: F.rectangleModel())
        log.expect("titles.model", titles[F.roomID] == Copy.FloorPlan.defaultRoomTitle(1))

        let size = CGSize(width: 300, height: 200)
        let margin: CGFloat = 20
        let viewport = PlanViewport.fitting(min: SIMD2<Double>(0, 0), max: SIMD2<Double>(4, 5), in: size, margin: margin)
        let corners = [SIMD2<Double>(0, 0), SIMD2<Double>(4, 0), SIMD2<Double>(4, 5), SIMD2<Double>(0, 5)]
        let low: CGFloat = margin - 0.000001
        let highX: CGFloat = size.width - margin + 0.000001
        let highY: CGFloat = size.height - margin + 0.000001
        var inside = true
        for corner in corners {
            let p = viewport.toScreen(corner)
            let insideX = p.x >= low && p.x <= highX
            let insideY = p.y >= low && p.y <= highY
            if !(insideX && insideY) { inside = false }
        }
        log.expect("viewport.fitsInsideMargins", inside)
        log.expect("viewport.scale", abs(viewport.pointsPerMeter - 32) < 1e-9, "got \(viewport.pointsPerMeter)")
        let sample = SIMD2<Double>(1.234, -5.678)
        let back = viewport.toPlan(viewport.toScreen(sample))
        log.expect("viewport.roundTrip", simd_distance(back, sample) < 1e-9, "got \(back)")
        log.expect("viewport.yFlip", viewport.toScreen(SIMD2<Double>(0, 1)).y < viewport.toScreen(SIMD2<Double>(0, 0)).y)
        let zoomed = viewport.zoomed(by: 2, about: CGPoint(x: 100, y: 50))
        let anchorPlan = viewport.toPlan(CGPoint(x: 100, y: 50))
        let anchorAfter = zoomed.toScreen(anchorPlan)
        let anchorDX: CGFloat = abs(anchorAfter.x - 100)
        let anchorDY: CGFloat = abs(anchorAfter.y - 50)
        log.expect("viewport.zoomKeepsAnchor", anchorDX < 0.000000001 && anchorDY < 0.000000001)
    }

    /// PNG and JPEG output of the same drawing.
    static func renderChecks(_ log: inout FloorPlanSelfTestLog) {
        let plan = drawing(rectanglePlan(), toggles: .standard).plan
        let png = PlanRenderer.pngData(plan, pixelWidth: 300)
        let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        log.expect("render.png", png.map { Array($0.prefix(8)) == pngSignature } ?? false, "got \(png?.count ?? 0) bytes")
        let jpeg = PlanRenderer.jpegThumbnail(plan, pixelSize: 64)
        let jpegSignature: [UInt8] = [0xFF, 0xD8, 0xFF]
        log.expect("render.jpeg", jpeg.map { Array($0.prefix(3)) == jpegSignature } ?? false, "got \(jpeg?.count ?? 0) bytes")
        let empty = Plan2D(name: "Empty", layers: PlanLayers.all(), entities: [])
        log.expect("render.emptyPlanNil", PlanRenderer.pngData(empty, pixelWidth: 300) == nil)
    }
}
