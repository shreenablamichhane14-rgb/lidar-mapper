import Foundation
import simd

/// Plain-Swift checks for the ExportUI module (no XCTest), run from Settings > Diagnostics off
/// the main thread. Deterministic (fixed ids and dates), no ARKit, RoomPlan session, camera or
/// network; temporary files only under `FileManager.default.temporaryDirectory`, removed
/// afterwards.
enum ExportUISelfTest {
    /// Failing checks as "name: detail"; empty when all pass.
    static func run() -> [String] {
        var log = ExportUISelfTestLog()
        catalogChecks(&log)
        labelAndNameChecks(&log)
        stagingRuleChecks(&log)
        cleanSceneChecks(&log)
        planChecks(&log)
        summaryChecks(&log)
        fileChecks(&log)
        return log.failures
    }

    /// A catalog option (availability does not matter to the callers).
    static func option(_ representation: ExportRepresentation, _ format: ExportFileFormat) -> ExportOption {
        ExportOption(representation: representation, format: format, isAvailable: true, reason: nil)
    }

    // MARK: - Catalog

    /// Availability for demo inputs, no texture, color still being added, no plan, nothing, and
    /// the simplified note rule.
    private static func catalogChecks(_ log: inout ExportUISelfTestLog) {
        typealias F = ExportUISelfTestFixtures
        let demo = ExportCatalog.options(for: F.demoInputs())
        log.expect("catalog.count", demo.count == 16, "got \(demo.count)")
        log.expect("catalog.uniqueIDs", Set(demo.map { $0.id }).count == demo.count)
        log.expect("catalog.demoAllAvailable", demo.allSatisfy { $0.isAvailable && $0.reason == nil })
        log.expect("catalog.order", demo.first?.id == "realistic.usdz" && demo.last?.id == "data.json",
                   "\(demo.first?.id ?? "nil") ... \(demo.last?.id ?? "nil")")
        let raw = demo.filter { $0.representation == .raw }.map { $0.format }
        log.expect("catalog.rawFormats", raw == [.usdz, .obj, .ply, .stl, .glb], "\(raw)")
        let plan = demo.filter { $0.representation == .floorPlan }.map { $0.format }
        log.expect("catalog.planFormats", plan == [.pdf, .svg, .dxf, .png], "\(plan)")

        var noColor = F.demoInputs()
        noColor.hasTexture = false
        noColor.hasKeyframes = false
        let withoutColor = ExportCatalog.options(for: noColor)
        let realistic = withoutColor.filter { $0.representation == .realistic }
        log.expect("catalog.noColorReason", realistic.count == 3
                   && realistic.allSatisfy { !$0.isAvailable && $0.reason == Copy.Export.noColor })
        log.expect("catalog.noTextureKeepsOthers",
                   withoutColor.filter { $0.representation != .realistic }.allSatisfy { $0.isAvailable })

        var pending = noColor
        pending.hasKeyframes = true
        let notReady = ExportCatalog.options(for: pending).filter { $0.representation == .realistic }
        log.expect("catalog.colorNotReady", notReady.allSatisfy { !$0.isAvailable && $0.reason == Copy.ExportUI.colorNotReady })

        var noPlan = F.demoInputs()
        noPlan.hasPlan = false
        let withoutPlan = ExportCatalog.options(for: noPlan)
        log.expect("catalog.noFloorPlanReason", withoutPlan.filter { $0.representation == .floorPlan }
                   .allSatisfy { !$0.isAvailable && $0.reason == Copy.Export.noFloorPlan })
        log.expect("catalog.noPlanKeepsClean", withoutPlan.filter { $0.representation == .clean }.allSatisfy { $0.isAvailable })

        let empty = ExportCatalog.options(for: ExportInputs())
        log.expect("catalog.emptyNothingAvailable", empty.allSatisfy { !$0.isAvailable && $0.reason != nil })

        var big = F.demoInputs()
        big.meshTriangles = ExportCatalog.textTriangleLimit + 1
        let simplifiedOK = ExportCatalog.isSimplified(option(.raw, .obj), inputs: big)
            && ExportCatalog.isSimplified(option(.raw, .usdz), inputs: big)
            && !ExportCatalog.isSimplified(option(.raw, .ply), inputs: big)
            && !ExportCatalog.isSimplified(option(.clean, .obj), inputs: big)
            && !ExportCatalog.isSimplified(option(.raw, .obj), inputs: F.demoInputs())
        log.expect("catalog.simplifiedNoteRule", simplifiedOK)
    }

    // MARK: - Labels and file names

    /// Each format its own label, PNG "Images", JSON "JSON", DXF "_mm", names start with a letter.
    private static func labelAndNameChecks(_ log: inout ExportUISelfTestLog) {
        typealias F = ExportUISelfTestFixtures
        let labels = ExportFileFormat.allCases.map { ExportCatalog.label(for: $0) }
        log.expect("label.distinct", Set(labels.map { $0.label }).count == ExportFileFormat.allCases.count,
                   labels.map { $0.label }.joined(separator: ","))
        log.expect("label.nonEmpty", labels.allSatisfy { !$0.label.isEmpty && !$0.detail.isEmpty })
        log.expect("label.pngImages", ExportCatalog.label(for: .png).label == "Images", ExportCatalog.label(for: .png).label)
        log.expect("label.json", ExportCatalog.label(for: .json).label == "JSON", ExportCatalog.label(for: .json).label)
        log.expect("label.glbIsGLTF", ExportCatalog.label(for: .glb).label == "glTF")
        log.expect("label.plyDetail", ExportCatalog.label(for: .ply).detail == Copy.ExportUI.plyDetail)

        let dxfName = ExportCatalog.fileName(project: "Kitchen", option: option(.floorPlan, .dxf), date: F.date)
        log.expect("name.dxfMillimeters", dxfName.hasSuffix("_mm.dxf") && dxfName.hasPrefix("Kitchen_Floor_Plan_"), dxfName)
        let third = ExportCatalog.fileName(project: "3rd floor", option: option(.clean, .usdz), date: F.date)
        log.expect("name.startsWithLetter", ExportCatalog.startsWithLetter(third) && third.hasPrefix("Mapper_3rd_floor_"), third)
        log.expect("name.hasDay", third.contains(ExportCatalog.dayStamp(F.date)) && third.hasSuffix(".usdz"), third)
        let unnamed = ExportCatalog.fileName(project: "", option: option(.data, .json), date: F.date)
        log.expect("name.emptyProject", ExportCatalog.startsWithLetter(unnamed) && unnamed.hasSuffix(".json"), unnamed)
        let accented = ExportCatalog.fileName(project: "K\u{00FC}che / Nord", option: option(.raw, .ply), date: F.date)
        let asciiOnly = accented.unicodeScalars.allSatisfy { $0.value < 128 }
        log.expect("name.asciiOnly", asciiOnly && !accented.contains(" ") && !accented.contains("/"), accented)
        log.expect("name.zip", ExportCatalog.zipFileName(for: "A_B.obj") == "A_B_obj.zip",
                   ExportCatalog.zipFileName(for: "A_B.obj"))
    }

    // MARK: - Staging and rules

    /// Staging stamp round trip, staleness, the RoomPlan USDZ rule and log-safe errors.
    private static func stagingRuleChecks(_ log: inout ExportUISelfTestLog) {
        typealias F = ExportUISelfTestFixtures
        let stamp = ExportRunner.stagingName(for: F.date)
        let parsed = ExportRunner.stagingDate(folderName: stamp)
        log.expect("staging.roundTrip", parsed.map { abs($0.timeIntervalSince(F.date)) < 1 } ?? false, stamp)
        log.expect("staging.suffix", ExportRunner.stagingDate(folderName: stamp + "-2") != nil)
        let others = ["simple", "2026-09-28", stamp + "-x", "", "abc-def"]
        log.expect("staging.rejectsOtherNames", others.allSatisfy { ExportRunner.stagingDate(folderName: $0) == nil })
        let day: TimeInterval = 86_400
        log.expect("staging.stale", ExportRunner.isStale(folderName: stamp, olderThan: day, now: F.date.addingTimeInterval(day + 60)))
        log.expect("staging.fresh", !ExportRunner.isStale(folderName: stamp, olderThan: day, now: F.date.addingTimeInterval(3600)))
        log.expect("staging.simpleNeverStale",
                   !ExportRunner.isStale(folderName: "simple", olderThan: day, now: F.date.addingTimeInterval(10 * day)))

        func rule(rooms: Int = 1, finalRoom: Bool = true, edits: Bool = false, furniture: Bool = true, hide: Bool = false,
                  includeHidden: Bool = false, hidden: Bool = false) -> Bool {
            ExportRunner.usesRoomPlanUSDZ(roomCount: rooms, hasFinalCapturedRoom: finalRoom, hasActiveEdits: edits,
                                          keepsFurniture: furniture, hideFurniture: hide, includeHidden: includeHidden,
                                          hasHiddenObjects: hidden)
        }
        log.expect("roomPlanUSDZ.eligible", rule())
        log.expect("roomPlanUSDZ.hideFurniture", !rule(hide: true))
        log.expect("roomPlanUSDZ.includeHidden", rule(hide: true, includeHidden: true))
        log.expect("roomPlanUSDZ.rejects", !rule(rooms: 2) && !rule(finalRoom: false) && !rule(edits: true)
                   && !rule(furniture: false) && !rule(hidden: true))

        let error = ExportError.writeFailed(path: "Private Name.usdz", reason: "disk")
        let text = ExportRunner.logDescription(error)
        log.expect("log.noPayload", !text.contains("Private") && text.contains("writeFailed"), text)
    }

    // MARK: - Clean scene

    /// Clean scene: validates, furniture and fixtures, Hide Furniture, hidden objects, no
    /// occluded surfaces, merged scenes.
    private static func cleanSceneChecks(_ log: inout ExportUISelfTestLog) {
        let model = ExportUISelfTestFixtures.demoModel()
        let full = ExportAdapters.cleanScene(model, includeHidden: false, includeMovable: true)
        do {
            try full.validate()
            log.expect("clean.validates", true)
        } catch {
            log.fail("clean.validates", error)
        }
        let names = full.meshes.map { $0.name }
        log.expect("clean.walls", names.filter { $0.hasPrefix("wall_") }.count == 4, names.joined(separator: ","))
        log.expect("clean.doorAndWindow", names.contains("door_1") && names.contains("window_1"))
        log.expect("clean.furnitureAndFixture", names.contains { $0.hasPrefix("furniture_sofa") }
                   && names.contains { $0.hasPrefix("fixture_sink") })
        log.expect("clean.hiddenObjectLeftOut", !names.contains { $0.hasPrefix("furniture_table") })
        let noSurfaces = !names.contains { $0.hasPrefix("ceiling") || $0.contains("occluded") || $0.hasPrefix("opening") }
        log.expect("clean.noOccludedOrCeiling", noSurfaces && !full.materials.contains { $0.name.contains("occluded") })
        log.expect("clean.flatNormals", full.meshes.allSatisfy { $0.normals?.count == $0.positions.count })
        let materialNames = full.materials.map { $0.name }
        log.expect("clean.materialPerKind", Set(materialNames).count == materialNames.count && materialNames.contains("wall"))

        let hideFurniture = ExportAdapters.cleanScene(model, includeHidden: false, includeMovable: false)
        log.expect("clean.noMovableObjects", !hideFurniture.meshes.contains { $0.name.hasPrefix("furniture_") }
                   && hideFurniture.meshes.contains { $0.name.hasPrefix("fixture_sink") })
        let withHidden = ExportAdapters.cleanScene(model, includeHidden: true, includeMovable: false)
        log.expect("clean.includeHidden", withHidden.meshes.contains { $0.name.hasPrefix("furniture_table") }
                   && withHidden.meshes.contains { $0.name.hasPrefix("furniture_sofa") })

        let merged = ExportAdapters.merged([full, hideFurniture])
        let second = merged.meshes.count > full.meshes.count ? merged.meshes[full.meshes.count] : nil
        let expectedIndex = hideFurniture.meshes.first?.materialIndex.map { $0 + full.materials.count }
        log.expect("merge.counts", merged.meshes.count == full.meshes.count + hideFurniture.meshes.count
                   && merged.materials.count == full.materials.count + hideFurniture.materials.count)
        log.expect("merge.materialOffset", second?.materialIndex != nil && second?.materialIndex == expectedIndex)
        do {
            try merged.validate()
            log.expect("merge.validates", true)
        } catch {
            log.fail("merge.validates", error)
        }
    }

    // MARK: - Plan

    /// Plan drawing with the result screen's toggles, hidden fixtures, toggles and units, DXF note.
    private static func planChecks(_ log: inout ExportUISelfTestLog) {
        typealias F = ExportUISelfTestFixtures
        let plan = F.demoPlan()
        let model = F.demoModel()
        let prefs = UnitPreferences.standard
        var off = PlanToggles.standard
        off.furniture = false
        do {
            let on = try ExportAdapters.planDrawing(plan: plan, clean: model, name: "Demo", prefs: prefs, toggles: .standard,
                                                    includeHidden: false)
            log.expect("plan.furnitureOn", F.count(on, layer: PlanLayers.furniture) > 0)
            let noFurniture = try ExportAdapters.planDrawing(plan: plan, clean: model, name: "Demo", prefs: prefs,
                                                             toggles: off, includeHidden: false)
            log.expect("plan.furnitureOffNoAFURN", F.count(noFurniture, layer: PlanLayers.furniture) == 0
                       && !noFurniture.layers.contains { $0.name == PlanLayers.furniture }
                       && F.count(noFurniture, layer: PlanLayers.walls) > 0)
            let shown = try ExportAdapters.planDrawing(plan: plan, clean: model, name: "Demo", prefs: prefs,
                                                       toggles: .standard, includeHidden: true)
            log.expect("plan.includeHiddenFixture",
                       F.count(shown, layer: PlanLayers.furniture) > F.count(on, layer: PlanLayers.furniture))
            let dxf = try DXFWriter.data(for: on, millimeters: true, unitsNote: Copy.ExportUI.dxfUnitsNote)
            let text = String(decoding: dxf, as: UTF8.self)
            log.expect("plan.dxfUnitsNote", text.contains(Copy.ExportUI.dxfUnitsNote) && !text.contains("$INSUNITS"))
        } catch {
            log.fail("plan.drawing", error)
        }
        do {
            _ = try ExportAdapters.planDrawing(plan: PlanModel.empty, clean: nil, name: "", prefs: prefs,
                                               toggles: .standard, includeHidden: false)
            log.expect("plan.emptyThrows", false)
        } catch {
            log.expect("plan.emptyThrows", true)
        }

        let hide = ExportViewState(planToggles: .standard, hideFurniture: true)
        var settings = ExportSettings()
        log.expect("plan.hideFurnitureFollowed", !ExportAdapters.planToggles(viewState: hide, settings: settings).furniture)
        log.expect("plan.togglesFollowed", ExportAdapters.planToggles(viewState: ExportViewState(planToggles: off, hideFurniture: false),
                                                                   settings: settings).furniture == false)
        settings.includeHidden = true
        log.expect("plan.includeHiddenToggle", ExportAdapters.planToggles(viewState: hide, settings: settings).furniture)
        settings.includeMeasurements = false
        log.expect("plan.measurementsOff", !ExportAdapters.planToggles(viewState: hide, settings: settings).measurements)
        settings.unitsOverride = .metric
        log.expect("plan.unitsOverride", ExportAdapters.planPrefs(prefs, settings: settings).system == .metric)
        log.expect("plan.unitsApp", ExportAdapters.planPrefs(prefs, settings: ExportSettings()).system == prefs.system)
    }
}
