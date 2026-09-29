import Foundation
import simd

/// Build 5 ExportUI checks (docs/MODULES.md 3.43d): the catalog of House, Object and Quick Measure
/// projects, level file names, the whole-house budget, placement transforms, multi-level plan
/// drawings, the joined PDF, and the Quick Measure, object and measurement JSON. The package
/// checks are in `ExportUISelfTest+B5Files.swift`.
extension ExportUISelfTest {
    /// Every build 5 check.
    static func b5Checks(_ log: inout ExportUISelfTestLog) {
        b5CatalogChecks(&log)
        b5NameChecks(&log)
        b5PlacementChecks(&log)
        b5PlanChecks(&log)
        b5JSONChecks(&log)
        b5FileChecks(&log)
    }

    // MARK: - Catalog

    /// House with two levels, Object with and without a model, Quick Measure with and without
    /// measurements, the object section and label, and the House simplified-note rule.
    private static func b5CatalogChecks(_ log: inout ExportUISelfTestLog) {
        typealias F = ExportUISelfTestFixtures
        let house = ExportCatalog.options(for: F.houseInputs())
        let planOptions = house.filter { $0.representation == .floorPlan }
        let planFormats = planOptions.map { $0.format }
        log.expect("b5.house.planFormats", planFormats == [.pdf, .svg, .dxf, .png] && planOptions.allSatisfy { $0.isAvailable },
                   "\(planFormats)")
        log.expect("b5.house.layout", house.count == 16 && !house.contains { $0.representation == .object })
        var pending = F.houseInputs()
        pending.allRoomsTextured = false
        pending.isProcessing = true
        let realistic = ExportCatalog.options(for: pending).filter { $0.representation == .realistic }
        let waits: Bool = realistic.count == 3 && realistic.allSatisfy { !$0.isAvailable && $0.reason == Copy.ExportUI.colorNotReady }
        let textured: Bool = house.filter { $0.representation == .realistic }.allSatisfy { $0.isAvailable }
        log.expect("b5.house.realisticNeedsEveryRoom", waits && textured)

        var object = ExportInputs()
        object.kind = .object
        let notReady = ExportCatalog.options(for: object)
        log.expect("b5.object.layout", notReady.map { $0.id } == ["object.usdz", "data.json"],
                   notReady.map { $0.id }.joined(separator: ","))
        log.expect("b5.object.notReady", notReady.allSatisfy { !$0.isAvailable && $0.reason == Copy.ExportUI.objectNotReady })
        object.hasObjectModel = true
        object.hasObjectDimensions = true
        object.kind = .advancedObject
        let ready = ExportCatalog.options(for: object)
        log.expect("b5.object.ready", ready.count == 2 && ready.allSatisfy { $0.isAvailable && $0.reason == nil })

        var quick = ExportInputs()
        quick.kind = .quickMeasure
        let empty = ExportCatalog.options(for: quick)
        log.expect("b5.quick.jsonOnly", empty.map { $0.id } == ["data.json"], empty.map { $0.id }.joined(separator: ","))
        log.expect("b5.quick.noMeasurements", empty.first?.isAvailable == false
                   && empty.first?.reason == Copy.Empty.noMeasurements.title)
        quick.measurementCount = 2
        log.expect("b5.quick.available", ExportCatalog.options(for: quick).first?.isAvailable == true)

        log.expect("b5.sectionTitle.object", ExportCatalog.sectionTitle(.object) == Copy.Modes.object)
        let objectLabel = ExportCatalog.label(for: option(.object, .usdz))
        let rawLabel = ExportCatalog.label(for: option(.raw, .usdz))
        let usdzLabel = ExportCatalog.label(for: .usdz)
        let labelsOK: Bool = objectLabel.detail == Copy.ExportUI.objectDetail && objectLabel.label == usdzLabel.label
        log.expect("b5.label.object", labelsOK && rawLabel.detail == usdzLabel.detail)

        var big = F.houseInputs()
        big.roomTriangles = [400_000, 100_000]
        let bigOBJ: Bool = ExportCatalog.isSimplified(option(.raw, .obj), inputs: big)
        let bigPLY: Bool = ExportCatalog.isSimplified(option(.raw, .ply), inputs: big)
        let bigClean: Bool = ExportCatalog.isSimplified(option(.clean, .obj), inputs: big)
        big.roomTriangles = [1_500_000, 100_000]
        let hugePLY: Bool = ExportCatalog.isSimplified(option(.raw, .ply), inputs: big)
        log.expect("b5.house.simplifiedRule", bigOBJ && !bigPLY && !bigClean && hugePLY)
        let limitsOK: Bool = ExportHouse.perRoomLimit(total: 600_000, rooms: 8) == 75_000
            && ExportHouse.perRoomLimit(total: 600_000, rooms: 20) == 50_000
        log.expect("b5.perRoomLimit", limitsOK, "\(ExportHouse.perRoomLimit(total: 600_000, rooms: 8))")
        log.expect("b5.binaryBudget", ExportCatalog.rawBudget(for: .stl) == ExportHouse.maxBinaryTriangles
                   && ExportCatalog.rawBudget(for: .obj) == ExportCatalog.textTriangleLimit)
    }

    // MARK: - File names

    /// Level suffix before the extension, DXF still "_mm.dxf", no level unchanged, object names.
    private static func b5NameChecks(_ log: inout ExportUISelfTestLog) {
        typealias F = ExportUISelfTestFixtures
        let suffix = Copy.ExportUI.levelSuffix(2)
        let dxf = ExportCatalog.fileName(project: "Maple House", option: option(.floorPlan, .dxf), date: F.date, level: 2)
        log.expect("b5.name.levelDXF", dxf.contains(suffix) && dxf.hasSuffix("_mm.dxf"), dxf)
        let svg = ExportCatalog.fileName(project: "Maple House", option: option(.floorPlan, .svg), date: F.date, level: 2)
        log.expect("b5.name.levelSVG", svg.hasSuffix("_\(suffix).svg") && svg.hasPrefix("Maple_House_"), svg)
        let plain = ExportCatalog.fileName(project: "Maple House", option: option(.floorPlan, .pdf), date: F.date, level: nil)
        let old = ExportCatalog.fileName(project: "Maple House", option: option(.floorPlan, .pdf), date: F.date)
        log.expect("b5.name.noLevelUnchanged", plain == old && !plain.contains(suffix), plain)
        let object = ExportCatalog.fileName(project: "Chair", option: option(.object, .usdz), date: F.date)
        log.expect("b5.name.object", object.hasPrefix("Chair_Object_") && object.hasSuffix(".usdz"), object)
    }

    // MARK: - Placement

    /// `transformed` moves positions and normals and keeps texcoords; identity keeps the mesh;
    /// the inferred join flags only the hole fills.
    private static func b5PlacementChecks(_ log: inout ExportUISelfTestLog) {
        typealias F = ExportUISelfTestFixtures
        let points = [SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 0, 1), SIMD3<Float>(0, 1, 0)]
        let normal = SIMD3<Float>(1, 0, 0)
        let uvs = [SIMD2<Float>(0, 0), SIMD2<Float>(1, 0), SIMD2<Float>(0, 1)]
        let mesh = ExportMesh(name: "t", positions: points, normals: [normal, normal, normal], texcoords: uvs,
                              indices: [0, 1, 2])
        let record = RoomAlignmentRecord(roomID: F.roomID.uuid, yaw: Float.pi / 2, translation: Vec3(x: 10, y: 0, z: 0),
                                         source: .user)
        let moved = ExportHouse.transformed(ExportScene(meshes: [mesh]), by: StructureAlignment.matrix(record))
        let result = moved.meshes.first
        var positionsOK = result?.positions.count == points.count
        for (index, point) in points.enumerated() where index < (result?.positions.count ?? 0) {
            let expected = StructureAlignment.transform(point, by: record)
            let got = result?.positions[index] ?? SIMD3<Float>(repeating: .nan)
            if !(simd_distance(expected, got) < 1e-4) { positionsOK = false }
        }
        log.expect("b5.transformed.positions", positionsOK, "\(String(describing: result?.positions))")
        let turned = result?.normals?.first ?? SIMD3<Float>(repeating: .nan)
        let expectedNormal = StructureAlignment.rotateWorld(normal, yaw: record.yaw)
        let normalDistance: Float = simd_distance(turned, expectedNormal)
        let normalLength: Float = simd_length(turned)
        log.expect("b5.transformed.normals", normalDistance < 1e-4 && abs(normalLength - 1) < 1e-4, "\(turned)")
        log.expect("b5.transformed.texcoords", result?.texcoords == uvs && result?.indices == mesh.indices)
        let same = ExportHouse.transformed(ExportScene(meshes: [mesh]), by: matrix_identity_float4x4)
        log.expect("b5.transformed.identity", same.meshes.first?.positions == points)

        let hole = TriangleMesh(positions: [SIMD3<Float>(0, 0, 2), SIMD3<Float>(1, 0, 2), SIMD3<Float>(0, 0, 1)],
                                indices: [0, 1, 2])
        let joined = ExportHouse.joinedWithInferred(F.strip(quads: 2), inferred: MeshWithAttributes(mesh: hole))
        let flagged = joined.isInferred?.filter { $0 }.count ?? -1
        let lastFlag = joined.isInferred?.last ?? false
        log.expect("b5.joinedInferred", joined.triangleCount == 5 && flagged == 1 && lastFlag && joined.isConsistent,
                   "\(joined.triangleCount) faces, \(flagged) inferred")
    }

    // MARK: - Plans

    /// Two levels give two drawings in level order with floor titles and level plan names; one
    /// level keeps the project name; two one-page PDFs join into two pages.
    private static func b5PlanChecks(_ log: inout ExportUISelfTestLog) {
        typealias F = ExportUISelfTestFixtures
        do {
            let drawings = try ExportHouse.planDrawings(plan: F.twoLevelPlan(), clean: F.demoModel(), name: "Maple House",
                                                        prefs: .standard, toggles: .standard, includeHidden: false)
            let levels = drawings.map { $0.level }
            let titlesOK: Bool = drawings.first?.title == Copy.House.floorLabel(1) && drawings.last?.title == "Upstairs"
            log.expect("b5.plan.levels", levels == [1, 2] && titlesOK, "\(levels)")
            let upperName = Copy.ExportUI.levelPlanName("Maple House", level: "Upstairs")
            log.expect("b5.plan.levelNames", drawings.last?.plan.name == upperName, drawings.last?.plan.name ?? "nil")
            let single = try ExportHouse.planDrawings(plan: F.demoPlan(), clean: F.demoModel(), name: "Demo",
                                                      prefs: .standard, toggles: .standard, includeHidden: false)
            log.expect("b5.plan.singleKeepsName", single.count == 1 && single.first?.plan.name == "Demo")
            guard let first = drawings.first?.plan, let last = drawings.last?.plan else {
                log.expect("b5.pdfMerge.twoPages", false, "no drawings")
                return
            }
            let pageA = try PDFPlanWriter.data(for: first, options: PDFPlanWriter.Options(date: F.date))
            let pageB = try PDFPlanWriter.data(for: last, options: PDFPlanWriter.Options(date: F.date))
            let merged = try ExportPDFPages.merge([pageA, pageB])
            let pagesOK: Bool = ExportPDFPages.pageCount(pageA) == 1 && ExportPDFPages.pageCount(merged) == 2
            log.expect("b5.pdfMerge.twoPages", pagesOK, "\(ExportPDFPages.pageCount(merged)) pages")
        } catch {
            log.fail("b5.plan.drawings", error)
        }
        do {
            _ = try ExportPDFPages.merge([Data([0x25, 0x50]), Data([0x00])])
            log.expect("b5.pdfMerge.rejectsGarbage", false)
        } catch {
            log.expect("b5.pdfMerge.rejectsGarbage", true)
        }
    }

    // MARK: - JSON

    /// Summary JSON with 2 measurements (numbers as numbers, snaps), the Quick Measure file and
    /// the object file parse with JSONSerialization.
    private static func b5JSONChecks(_ log: inout ExportUISelfTestLog) {
        typealias F = ExportUISelfTestFixtures
        var manifest = ProjectManifest.new(kind: .quickMeasure, name: "Hall", now: F.date)
        manifest.id = F.quickProjectID
        let records = F.measurements()
        do {
            let summary = try ExportSummaryJSON.data(model: F.demoModel(), evidence: [:], manifest: manifest,
                                                     measurements: records)
            let root = try JSONSerialization.jsonObject(with: summary) as? [String: Any]
            let entries = root?["measurements"] as? [[String: Any]] ?? []
            let value = entries.first?["value"] as? [String: Any]
            let valueNumber = value?["value"] as? NSNumber
            let sigmaNumber = value?["sigma"] as? NSNumber
            let valueText = value?["value"] as? String
            let number: Bool = valueNumber != nil && sigmaNumber != nil && valueText == nil
            let snaps = entries.first?["snaps"] as? [String]
            log.expect("b5.summary.measurements", entries.count == 2 && number && snaps == ["corner", "edge"],
                       "\(entries.count) entries")

            let quick = try ExportSummaryJSON.measurementsData(records, manifest: manifest)
            let quickRoot = try JSONSerialization.jsonObject(with: quick) as? [String: Any]
            let quickEntries = quickRoot?["measurements"] as? [[String: Any]] ?? []
            let project = quickRoot?["project"] as? [String: Any]
            let format = quickRoot?["format"] as? String
            let kind = project?["kind"] as? String
            let quickOK: Bool = quickEntries.count == 2 && format == ExportSummaryJSON.measurementsFormatName
            log.expect("b5.measurementsData.parses", quickOK && kind == ScanMode.quickMeasure.rawValue)

            var objectManifest = ProjectManifest.new(kind: .object, name: "Chair", now: F.date)
            objectManifest.objects = [ObjectRecord(id: F.largeObjectID, name: "Chair", size: .large, status: .processed,
                                                   imageCount: 0, modelFile: nil)]
            let objectJSON = try ExportSummaryJSON.objectData([F.largeObjectID: F.dimensions(F.largeObjectID)],
                                                              manifest: objectManifest)
            let objectRoot = try JSONSerialization.jsonObject(with: objectJSON) as? [String: Any]
            let objects = objectRoot?["objects"] as? [[String: Any]] ?? []
            let width = ((objects.first?["width"] as? [String: Any])?["value"] as? NSNumber)?.doubleValue ?? -1
            let reason = objects.first?["volumeUnavailableReason"] as? String
            let noVolume: Bool = objects.first.map { $0["volume"] == nil } ?? false
            let name = objects.first?["name"] as? String
            let shapeOK: Bool = objects.count == 1 && abs(width - 1) < 1e-6 && noVolume
            let textOK: Bool = reason == ObjectVolumeReason.notWatertight.rawValue && name == "Chair"
            log.expect("b5.objectData.parses", shapeOK && textOK, "\(objects.count) objects, width \(width)")
        } catch {
            log.fail("b5.json", error)
        }
    }
}
