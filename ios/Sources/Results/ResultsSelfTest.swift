import Foundation
import simd

/// Plain-Swift checks for Results (no XCTest), run from the Diagnostics suite list off the main
/// actor. Deterministic: fixed ids and values, no clock, no randomness, no ARKit, camera or
/// network; the file checks write only under `FileManager.default.temporaryDirectory` and
/// remove what they wrote. Covers `ResultAvailability` (every tab, the processing view, Retry,
/// step texts, chips, styles, degraded modes), row filtering and grouping, the content builders
/// (missing areas, 3D Clean layers, occluded parts, highlight, textured parts), the demo-room
/// rule, file stamps and the new Copy strings (ResultsSelfTest+Content.swift).
enum ResultsSelfTest {
    /// Failing checks as "name: detail"; empty when all pass.
    static func run() -> [String] {
        var failures: [String] = []
        realisticChecks(&failures)
        otherTabChecks(&failures)
        processingViewChecks(&failures)
        textChecks(&failures)
        styleChecks(&failures)
        rowChecks(&failures)
        contentChecks(&failures)
        fileChecks(&failures)
        return failures
    }

    /// Records a failure when `ok` is false.
    static func check(_ failures: inout [String], _ name: String, _ ok: Bool, _ detail: @autoclosure () -> String) {
        if !ok { failures.append("\(name): \(detail())") }
    }

    // MARK: - Fixture states

    /// A job that is running `step` at `fraction`.
    static func running(_ step: PipelineStepID, fraction: Double) -> ProjectProcessingState {
        var state = ProjectProcessingState()
        state.isRunning = true
        state.currentStep = step
        state.fraction = fraction
        return state
    }

    /// Files of a finished demo room: clean, plan and meshes, no texture, no RoomPlan data.
    static func demoFiles() -> ResultFiles {
        var files = ResultFiles()
        files.hasClean = true
        files.hasPlan = true
        files.hasMeshView = true
        files.isDemo = true
        return files
    }

    // MARK: - Realistic

    /// Realistic: ready, preparing with and without percent, failed, fallback, demo.
    private static func realisticChecks(_ f: inout [String]) {
        let idle = ProjectProcessingState()
        var textured = ResultFiles()
        textured.hasTexture = true
        let ready = ResultAvailability.compute(.realistic, files: textured, processing: idle, degraded: .allGood)
        check(&f, "realistic.ready", ready == .ready, "\(ready)")

        let runningTexture = running(.textureLow, fraction: 0.4)
        let preparing = ResultAvailability.compute(.realistic, files: ResultFiles(), processing: runningTexture, degraded: .allGood)
        check(&f, "realistic.preparingPercent", preparing == .preparing(text: Copy.Results.colorPreparing, percent: 40), "\(preparing)")

        var queued = ProjectProcessingState()
        queued.isQueued = true
        let waiting = ResultAvailability.compute(.realistic, files: ResultFiles(), processing: queued, degraded: .allGood)
        check(&f, "realistic.preparingQueued", waiting == .preparing(text: Copy.Results.colorPreparing, percent: nil), "\(waiting)")

        var failed = ProjectProcessingState()
        failed.failed[.textureLow] = "baker failed"
        var withRoom = ResultFiles()
        withRoom.hasCapturedRoom = true
        let failure = ResultAvailability.compute(.realistic, files: withRoom, processing: failed, degraded: .allGood)
        check(&f, "realistic.failed", failure == .failed(reason: Copy.Errors.textureFailed.title), "\(failure)")

        let fallback = ResultAvailability.compute(.realistic, files: withRoom, processing: idle, degraded: .allGood)
        check(&f, "realistic.fallback", fallback == .unavailable(reason: Copy.Results.simpleModelNote), "\(fallback)")

        let demo = ResultAvailability.compute(.realistic, files: demoFiles(), processing: queued, degraded: .allGood)
        check(&f, "realistic.demoNotPreparing", demo == .unavailable(reason: Copy.Results.noColor), "\(demo)")
    }

    // MARK: - Other tabs

    /// 3D Clean, Floor Plan and Raw Scan decisions.
    private static func otherTabChecks(_ f: inout [String]) {
        let idle = ProjectProcessingState()
        let clean = ResultAvailability.compute(.clean, files: demoFiles(), processing: idle, degraded: .roomPlanFailed)
        check(&f, "clean.roomPlanFailed", clean == .unavailable(reason: Copy.Results.noWalls), "\(clean)")
        let plan = ResultAvailability.compute(.floorPlan, files: demoFiles(), processing: idle, degraded: .roomPlanFailed)
        check(&f, "floorPlan.roomPlanFailed", plan == .unavailable(reason: Copy.Results.noWalls), "\(plan)")

        var cleanOnly = ResultFiles()
        cleanOnly.hasClean = true
        let drawing = ResultAvailability.compute(.floorPlan, files: cleanOnly, processing: running(.floorPlan, fraction: 0.5),
                                                 degraded: .allGood)
        check(&f, "floorPlan.preparing", drawing == .preparing(text: Copy.Processing.stepFloorPlan, percent: 50), "\(drawing)")

        var meshOnly = ResultFiles()
        meshOnly.hasMeshView = true
        let raw = ResultAvailability.compute(.raw, files: meshOnly, processing: idle, degraded: .allGood)
        check(&f, "raw.ready", raw == .ready, "\(raw)")
        let consolidating = ResultAvailability.compute(.raw, files: ResultFiles(), processing: running(.consolidateMesh, fraction: 0.25),
                                                       degraded: .allGood)
        check(&f, "raw.preparing", consolidating == .preparing(text: Copy.Processing.stepShape, percent: 25), "\(consolidating)")
        let stripped = ResultAvailability.compute(.raw, files: ResultFiles(), processing: idle, degraded: .meshStripped)
        check(&f, "raw.meshStripped", stripped == .unavailable(reason: Copy.Results.noDetailedScan), "\(stripped)")

        var emptyClean = ResultFiles()
        emptyClean.hasEmptyClean = true
        emptyClean.hasPlan = true
        let noWalls = ResultAvailability.compute(.clean, files: emptyClean, processing: idle, degraded: .allGood)
        check(&f, "clean.emptyModel", noWalls == .unavailable(reason: Copy.Results.noWalls), "\(noWalls)")
        let noWallsPlan = ResultAvailability.compute(.floorPlan, files: emptyClean, processing: idle, degraded: .allGood)
        check(&f, "floorPlan.emptyModel", noWallsPlan == .unavailable(reason: Copy.Results.noWalls), "\(noWallsPlan)")

        var cleanFailed = ProjectProcessingState()
        cleanFailed.failed[.cleanModel] = "error"
        let broken = ResultAvailability.compute(.clean, files: ResultFiles(), processing: cleanFailed, degraded: .allGood)
        check(&f, "clean.failed", broken == .failed(reason: Copy.Errors.processingFailed.title), "\(broken)")
        let brokenPlan = ResultAvailability.compute(.floorPlan, files: ResultFiles(), processing: cleanFailed, degraded: .allGood)
        check(&f, "floorPlan.dependencyFailed", brokenPlan == .failed(reason: Copy.Errors.processingFailed.title), "\(brokenPlan)")
    }

    // MARK: - Processing view and Retry

    /// The processing view gate, demo and relaunched projects, and Retry.
    private static func processingViewChecks(_ f: inout [String]) {
        let idle = ProjectProcessingState()
        let demo = demoFiles()
        check(&f, "demo.tabsShow", !ResultAvailability.showsProcessingView(files: demo, processing: idle), "processing view shown")
        let demoReady = [ResultTab.clean, .floorPlan, .raw].allSatisfy {
            ResultAvailability.compute($0, files: demo, processing: idle, degraded: .allGood) == .ready
        }
        check(&f, "demo.tabsReady", demoReady, "a demo tab is not ready")
        let demoRealistic = ResultAvailability.compute(.realistic, files: demo, processing: idle, degraded: .allGood)
        check(&f, "demo.realisticNotReady", demoRealistic != .ready, "\(demoRealistic)")

        var relaunched = ResultFiles()
        relaunched.hasMeshView = true
        check(&f, "relaunch.tabsShow", !ResultAvailability.showsProcessingView(files: relaunched, processing: idle), "processing view shown")
        let plan = ResultAvailability.compute(.floorPlan, files: relaunched, processing: idle, degraded: .allGood)
        check(&f, "relaunch.floorPlanUnavailable", plan == .unavailable(reason: Copy.Results.notReady), "\(plan)")

        var queued = ProjectProcessingState()
        queued.isQueued = true
        check(&f, "queued.processingView", ResultAvailability.showsProcessingView(files: ResultFiles(), processing: queued),
              "no processing view while queued without a plan")
        var withPlan = ResultFiles()
        withPlan.hasPlan = true
        check(&f, "running.planShowsTabs", !ResultAvailability.showsProcessingView(files: withPlan, processing: running(.quality, fraction: 0.1)),
              "processing view shown although the plan exists")

        check(&f, "retry.needsAttention", ResultAvailability.showsRetry(status: .needsAttention, processing: idle), "no retry")
        var failed = ProjectProcessingState()
        failed.failed[.textureLow] = "error"
        check(&f, "retry.failedStep", ResultAvailability.showsRetry(status: .processing, processing: failed), "no retry")
        check(&f, "retry.readyIdle", !ResultAvailability.showsRetry(status: .ready, processing: idle), "retry shown")
        check(&f, "retry.textureMessage", ResultAvailability.retryMessage(processing: failed) == Copy.Errors.textureFailed.title,
              ResultAvailability.retryMessage(processing: failed))
        failed.failed[.floorPlan] = "error"
        check(&f, "retry.modelMessage", ResultAvailability.retryMessage(processing: failed) == Copy.Errors.processingFailed.title,
              ResultAvailability.retryMessage(processing: failed))
        settledFailureChecks(&f)
    }

    /// After a relaunch a `.needsAttention` project keeps showing what failed (no runner state).
    private static func settledFailureChecks(_ f: inout [String]) {
        let idle = ProjectProcessingState()
        var captured = ResultFiles()
        captured.hasKeyframes = true
        captured.hasClean = true
        captured.hasPlan = true
        captured.hasCapturedRoom = true
        let color = ResultAvailability.compute(.realistic, files: captured, processing: idle, degraded: .allGood,
                                               status: .needsAttention)
        check(&f, "relaunch.colorFailureKept", color == .failed(reason: Copy.Errors.textureFailed.title), "\(color)")
        let raw = ResultAvailability.compute(.raw, files: captured, processing: idle, degraded: .allGood, status: .needsAttention)
        check(&f, "relaunch.rawFailureKept", raw == .failed(reason: Copy.Errors.processingFailed.title), "\(raw)")
        let readyColor = ResultAvailability.compute(.realistic, files: captured, processing: idle, degraded: .allGood, status: .ready)
        check(&f, "relaunch.readyShowsFallback", readyColor == .unavailable(reason: Copy.Results.simpleModelNote), "\(readyColor)")
        let stripped = ResultAvailability.compute(.raw, files: captured, processing: idle, degraded: .meshStripped,
                                                  status: .needsAttention)
        check(&f, "relaunch.meshStrippedStaysHonest", stripped == .unavailable(reason: Copy.Results.noDetailedScan), "\(stripped)")
        var queued = ProjectProcessingState()
        queued.isQueued = true
        check(&f, "relaunch.retryRunning", !ResultAvailability.isSettledFailure(status: .needsAttention, processing: queued),
              "a queued job is not a settled failure")
        let tabs: [ResultTab: TabAvailability] = [.realistic: color, .clean: .ready, .floorPlan: .ready, .raw: .ready]
        let message = ResultAvailability.retryMessage(processing: idle, availability: tabs)
        check(&f, "relaunch.colorMessage", message == Copy.Errors.textureFailed.title, message)
    }

    // MARK: - Texts

    /// Step texts, chips, tab labels and the new Copy strings.
    private static func textChecks(_ f: inout [String]) {
        let steps: [(PipelineStepID, String)] = [
            (.textureLow, Copy.Processing.stepTextures), (.floorPlan, Copy.Processing.stepFloorPlan),
            (.cleanModel, Copy.Processing.stepClean), (.consolidateMesh, Copy.Processing.stepShape),
            (.thumbnail, Copy.Processing.stepSaving),
        ]
        for (step, text) in steps {
            check(&f, "stepText.\(step.rawValue)", ResultAvailability.stepText(step) == text, ResultAvailability.stepText(step))
        }
        check(&f, "stepText.allNonEmpty", PipelineStepID.allCases.allSatisfy { !ResultAvailability.stepText($0).isEmpty }, "empty text")
        let chip = ResultAvailability.chipText(.preparing(text: Copy.Processing.stepTextures, percent: 40))
        check(&f, "chip.percent", chip == "Adding color and texture 40%", chip ?? "nil")
        check(&f, "chip.ready", ResultAvailability.chipText(.ready) == nil, "text for ready")
        check(&f, "chip.reason", ResultAvailability.chipText(.unavailable(reason: Copy.Results.noWalls)) == Copy.Results.noWalls, "wrong reason")
        let titles = ResultTab.allCases.map { $0.title }
        check(&f, "tabs.titles", titles == [Copy.Viewer.realistic, Copy.Viewer.clean, Copy.Viewer.floorPlan, Copy.Viewer.raw], "\(titles)")
        check(&f, "tabs.hints", ResultTab.allCases.allSatisfy { !$0.accessibilityHint.isEmpty }, "empty hint")
        check(&f, "copy.objectGuess", Copy.Results.objectGuess("Oven") == "Mapper's guess: Oven", Copy.Results.objectGuess("Oven"))
        check(&f, "copy.missingCount", Copy.Results.missingAreasCount(3) == "Missing areas: 3", Copy.Results.missingAreasCount(3))
        check(&f, "degraded.note", ResultAvailability.degradedNote(.depthStripped) != nil
              && ResultAvailability.degradedNote(.allGood) == nil, "degraded notes")
    }

    // MARK: - Styles and degraded modes

    /// The style each tab draws, the menus and the combined degraded mode.
    private static func styleChecks(_ f: inout [String]) {
        let rawTextured = ResultAvailability.effectiveStyle(.textured, tab: .raw, hasTexture: true)
        check(&f, "style.rawClasses", rawTextured == .rawScan, "\(rawTextured)")
        let rawWire = ResultAvailability.effectiveStyle(.wireframe, tab: .raw, hasTexture: false)
        check(&f, "style.rawWireframe", rawWire == .wireframe, "\(rawWire)")
        let noColor = ResultAvailability.effectiveStyle(.textured, tab: .realistic, hasTexture: false)
        check(&f, "style.realisticNoTexture", noColor == .solidColor, "\(noColor)")
        let color = ResultAvailability.effectiveStyle(.rawScan, tab: .realistic, hasTexture: true)
        check(&f, "style.realisticTextured", color == .textured, "\(color)")
        let menu = ResultAvailability.menuStyles(for: .realistic)
        check(&f, "style.menuRealistic", menu == [.photoRealistic, .textured, .solidColor, .wireframe], "\(menu)")
        check(&f, "style.menuClean", ResultAvailability.menuStyles(for: .clean).isEmpty, "clean has styles")

        let mixed = ResultAvailability.combinedDegraded([.allGood, .roomPlanFailed])
        check(&f, "degraded.oneRoomFailed", mixed == .allGood, "\(mixed)")
        let allFailed = ResultAvailability.combinedDegraded([.roomPlanFailed, nil])
        check(&f, "degraded.allFailed", allFailed == .roomPlanFailed, "\(allFailed)")
        let none = ResultAvailability.combinedDegraded([nil])
        check(&f, "degraded.noLog", none == .allGood, "\(none)")
        let streams = ResultAvailability.combinedDegraded([.depthStripped, .meshStripped])
        check(&f, "degraded.mesh", streams == .meshStripped, "\(streams)")
    }

    // MARK: - Rows

    /// Row filtering by selection, grouping and element labels, multi-room ids.
    private static func rowChecks(_ f: inout [String]) {
        let room = ResultsSelfTestFixtures.room()
        let rows = RoomDimensions.rows(for: room, evidence: .unknown)
        let wall = ResultsSelfTestFixtures.id(2)
        let filtered = ResultContentBuilder.filterRows(rows, selection: wall)
        check(&f, "rows.filterWall", filtered.count == 3 && filtered.allSatisfy { $0.element == wall }, "\(filtered.count) rows")
        check(&f, "rows.filterNone", ResultContentBuilder.filterRows(rows, selection: nil).count == rows.count, "rows dropped")
        let door = ResultsSelfTestFixtures.id(11)
        check(&f, "rows.filterDoor", ResultContentBuilder.filterRows(rows, selection: door).count == 2, "door rows")

        let sections = ResultRowSection.sections(rows)
        let groups = sections.map { $0.group }
        check(&f, "rows.groups", groups == [.room, .walls, .doors, .windows], "\(groups)")
        if let walls = sections.first(where: { $0.group == .walls }) {
            let first = ResultRowSection.startsElement(walls.rows, at: 0, group: .walls)
            let second = ResultRowSection.startsElement(walls.rows, at: 1, group: .walls)
            let fourth = ResultRowSection.startsElement(walls.rows, at: 3, group: .walls)
            check(&f, "rows.elementLabels", first && !second && fourth, "\(first) \(second) \(fourth)")
        } else {
            check(&f, "rows.elementLabels", false, "no walls group")
        }
        if let roomSection = sections.first(where: { $0.group == .room }) {
            check(&f, "rows.roomLabelHidden", !ResultRowSection.startsElement(roomSection.rows, at: 0, group: .room), "room label shown")
        }

        var second = ResultsSelfTestFixtures.room()
        second.id = ResultsSelfTestFixtures.id(50)
        second.recordID = ResultsSelfTestFixtures.uuid(51)
        let model = CleanModel(rooms: [room, second], sourceIsStructure: false, stamp: nil)
        let combined = ResultLoader.dimensionRows(model, evidence: [:])
        check(&f, "rows.multiRoomUnique", Set(combined.map { $0.id }).count == combined.count && combined.count == 2 * rows.count,
              "\(combined.count) rows")
    }
}
