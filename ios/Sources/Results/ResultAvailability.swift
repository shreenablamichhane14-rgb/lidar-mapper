import Foundation

/// The four views of the result screen (SPEC ROOM SCANNING: Realistic, 3D Clean, Floor Plan,
/// Raw Scan). Raw values are stable for logs.
enum ResultTab: String, CaseIterable, Identifiable, Sendable {
    case realistic, clean, floorPlan, raw

    /// Stable identity (the raw value).
    var id: String { rawValue }

    /// Switcher label (`Copy.Viewer`).
    var title: String {
        switch self {
        case .realistic: return Copy.Viewer.realistic
        case .clean: return Copy.Viewer.clean
        case .floorPlan: return Copy.Viewer.floorPlan
        case .raw: return Copy.Viewer.raw
        }
    }

    /// VoiceOver hint of the view (docs/UX_COPY.md section 8).
    var accessibilityHint: String {
        switch self {
        case .realistic: return Copy.Results.realisticHint
        case .clean: return Copy.Results.cleanHint
        case .floorPlan: return Copy.Results.floorPlanHint
        case .raw: return Copy.Results.rawHint
        }
    }

    /// True for the tabs drawn by the 3D viewer (every tab but Floor Plan).
    var uses3DViewer: Bool { self != .floorPlan }
}

/// What a tab can show right now (D20): ready, a preparing chip with an optional percent, an
/// honest reason why it is not available, or a failure text.
enum TabAvailability: Equatable, Sendable {
    case ready
    case preparing(text: String, percent: Int?)
    case unavailable(reason: String)
    case failed(reason: String)

    /// True for `.ready`.
    var isReady: Bool { self == .ready }
}

/// What exists on disk for the project. `isDemo`: the room's raw folder has neither keyframes
/// nor RoomPlan data (Demo Mode rooms), so Realistic is unavailable rather than "preparing".
///
/// `hasClean` means `clean.json` holds at least one room with a wall; `hasEmptyClean` means the
/// file exists without any wall (CleanModelStep writes an empty model when RoomPlan found no
/// room, so the tabs can say "no walls"). `hasPlan` means `plan.json` exists.
struct ResultFiles: Equatable, Sendable {
    var hasClean = false, hasPlan = false, hasMeshView = false, hasTexture = false, hasCapturedRoom = false, isDemo = false
    /// `clean.json` exists but holds no wall (added by Results; see the type comment).
    var hasEmptyClean = false

    /// Nothing on disk.
    init() {}
}

/// Pure decisions of the result screen: tab availability, the processing view, Retry, the
/// step texts and the display style each tab really uses. Any thread.
enum ResultAvailability {
    /// Pure. Decides from the files on disk plus the in-memory processing state, never from stamps
    /// (stamps are the runner's business; a demo or relaunched project has an empty state).
    /// Realistic: texture ready, else preparing while textureLow runs, else failed text, else
    /// "fallback available" when a CapturedRoom exists. Clean and Floor Plan need clean/plan files;
    /// Raw needs the view mesh; RoomPlan failure makes Clean and Floor Plan unavailable with the reason.
    /// `degraded` comes from `RawScanReader.roomLog()?.degraded` (raw truth), overridden to
    /// `.roomPlanFailed` only when `CapturedRoomStore.loadInput` fails after the job finished; never
    /// from `QualityEvaluation.degraded`.
    static func compute(_ tab: ResultTab, files: ResultFiles, processing: ProjectProcessingState, degraded: DegradedMode) -> TabAvailability {
        switch tab {
        case .realistic: return realistic(files: files, processing: processing)
        case .clean: return clean(files: files, processing: processing, degraded: degraded)
        case .floorPlan: return floorPlan(files: files, processing: processing, degraded: degraded)
        case .raw: return raw(files: files, processing: processing, degraded: degraded)
        }
    }

    /// Pure. The processing view shows only while `(processing.isQueued || processing.isRunning) && !files.hasPlan`.
    static func showsProcessingView(files: ResultFiles, processing: ProjectProcessingState) -> Bool {
        isActive(processing) && !files.hasPlan
    }

    /// Pure. Retry shows when `status == .needsAttention` or `processing.failed` is not empty.
    static func showsRetry(status: ProjectStatus, processing: ProjectProcessingState) -> Bool {
        status == .needsAttention || !processing.failed.isEmpty
    }

    /// Text of a processing step for the processing view and the chips (`Copy.Processing`).
    static func stepText(_ step: PipelineStepID) -> String {
        switch step {
        case .buildRoom, .consolidateMesh, .quality, .reconstructObject, .objectMetrics:
            return Copy.Processing.stepShape
        case .cleanModel, .mergeStructure, .alignRooms:
            return Copy.Processing.stepClean
        case .floorPlan:
            return Copy.Processing.stepFloorPlan
        case .textureLow, .textureHigh:
            return Copy.Processing.stepTextures
        case .thumbnail:
            return Copy.Processing.stepSaving
        }
    }

    /// The line a chip shows for an availability; nil for `.ready`.
    static func chipText(_ availability: TabAvailability) -> String? {
        switch availability {
        case .ready:
            return nil
        case .preparing(let text, let percent):
            guard let percent else { return text }
            return Copy.Results.stepProgress(text, percent: percent)
        case .unavailable(let reason), .failed(let reason):
            return reason
        }
    }

    /// The message of the Retry banner: color only when every failed step is a texture step,
    /// else the model.
    static func retryMessage(processing: ProjectProcessingState) -> String {
        let textureSteps: Set<PipelineStepID> = [.textureLow, .textureHigh]
        let failed = Set(processing.failed.keys)
        if !failed.isEmpty && failed.isSubset(of: textureSteps) {
            return Copy.Errors.textureFailed.title
        }
        return Copy.Errors.processingFailed.title
    }

    /// The style a tab really draws for the chosen `style`. Realistic: Textured (Photo Realistic
    /// and Raw Scan fall back to it) when a texture exists, else Solid Color; Solid Color and
    /// Wireframe as chosen. Raw Scan: class colors unless Solid Color or Wireframe is chosen.
    /// 3D Clean and Floor Plan do not use display styles (Solid Color is returned).
    static func effectiveStyle(_ style: ViewerDisplayStyle, tab: ResultTab, hasTexture: Bool) -> ViewerDisplayStyle {
        switch tab {
        case .realistic:
            switch style {
            case .solidColor, .wireframe: return style
            case .photoRealistic, .textured, .rawScan: return hasTexture ? .textured : .solidColor
            }
        case .raw:
            switch style {
            case .solidColor, .wireframe: return style
            case .photoRealistic, .textured, .rawScan: return .rawScan
            }
        case .clean, .floorPlan:
            return .solidColor
        }
    }

    /// Styles listed in a tab's Display menu (Photo Realistic is listed but disabled in build 4).
    static func menuStyles(for tab: ResultTab) -> [ViewerDisplayStyle] {
        switch tab {
        case .realistic: return [.photoRealistic, .textured, .solidColor, .wireframe]
        case .raw: return [.rawScan, .solidColor, .wireframe]
        case .clean, .floorPlan: return []
        }
    }

    /// One degraded mode for a project from its rooms' logs (nil for a room without a log): the
    /// RoomPlan failure only when every logged room failed, else the mesh, then the depth
    /// stream, else all good.
    static func combinedDegraded(_ modes: [DegradedMode?]) -> DegradedMode {
        let known = modes.compactMap { $0 }
        guard !known.isEmpty else { return .allGood }
        if known.allSatisfy({ $0 == .roomPlanFailed }) { return .roomPlanFailed }
        if known.contains(.meshStripped) { return .meshStripped }
        if known.contains(.depthStripped) { return .depthStripped }
        return .allGood
    }

    /// The line under the measurements for a degraded capture (D16); nil when nothing to say
    /// (all good, or RoomPlan failed, which the tabs already explain).
    static func degradedNote(_ mode: DegradedMode) -> String? {
        switch mode {
        case .allGood, .roomPlanFailed: return nil
        case .depthStripped: return Copy.Results.degradedDepth
        case .meshStripped: return Copy.Results.degradedMesh
        }
    }

    // MARK: - Per tab

    /// A job for the project waits or runs.
    static func isActive(_ processing: ProjectProcessingState) -> Bool {
        processing.isQueued || processing.isRunning
    }

    /// True while the job is active and `step` has neither completed nor failed in it.
    static func isPending(_ step: PipelineStepID, _ processing: ProjectProcessingState) -> Bool {
        isActive(processing) && !processing.completed.contains(step) && processing.failed[step] == nil
    }

    /// Whole percent of `step` while it is the running step, else nil.
    static func percent(_ step: PipelineStepID, _ processing: ProjectProcessingState) -> Int? {
        guard processing.isRunning, processing.currentStep == step else { return nil }
        let fraction = processing.fraction.isFinite ? Swift.min(Swift.max(processing.fraction, 0), 1) : 0
        return Int((fraction * 100).rounded(.down))
    }

    /// A preparing availability for `step` with its percent when it runs.
    private static func preparing(_ step: PipelineStepID, _ processing: ProjectProcessingState, text: String? = nil) -> TabAvailability {
        .preparing(text: text ?? stepText(step), percent: percent(step, processing))
    }

    /// Realistic tab.
    private static func realistic(files: ResultFiles, processing: ProjectProcessingState) -> TabAvailability {
        if files.hasTexture { return .ready }
        if files.isDemo { return .unavailable(reason: Copy.Results.noColor) }
        if isPending(.textureLow, processing) {
            return preparing(.textureLow, processing, text: Copy.Results.colorPreparing)
        }
        if processing.failed[.textureLow] != nil { return .failed(reason: Copy.Errors.textureFailed.title) }
        if files.hasCapturedRoom { return .unavailable(reason: Copy.Results.simpleModelNote) }
        return .unavailable(reason: Copy.Results.noColor)
    }

    /// 3D Clean tab.
    private static func clean(files: ResultFiles, processing: ProjectProcessingState, degraded: DegradedMode) -> TabAvailability {
        if degraded == .roomPlanFailed { return .unavailable(reason: Copy.Results.noWalls) }
        if files.hasClean { return .ready }
        if processing.failed[.cleanModel] != nil { return .failed(reason: Copy.Errors.processingFailed.title) }
        if isPending(.cleanModel, processing) { return preparing(.cleanModel, processing) }
        if files.hasEmptyClean { return .unavailable(reason: Copy.Results.noWalls) }
        return .unavailable(reason: Copy.Results.notReady)
    }

    /// Floor Plan tab.
    private static func floorPlan(files: ResultFiles, processing: ProjectProcessingState, degraded: DegradedMode) -> TabAvailability {
        if degraded == .roomPlanFailed { return .unavailable(reason: Copy.Results.noWalls) }
        if files.hasPlan && files.hasClean { return .ready }
        if processing.failed[.floorPlan] != nil || processing.failed[.cleanModel] != nil {
            return .failed(reason: Copy.Errors.processingFailed.title)
        }
        if isPending(.floorPlan, processing) { return preparing(.floorPlan, processing) }
        if files.hasEmptyClean { return .unavailable(reason: Copy.Results.noWalls) }
        return .unavailable(reason: Copy.Results.notReady)
    }

    /// Raw Scan tab.
    private static func raw(files: ResultFiles, processing: ProjectProcessingState, degraded: DegradedMode) -> TabAvailability {
        if files.hasMeshView { return .ready }
        if processing.failed[.consolidateMesh] != nil { return .failed(reason: Copy.Errors.processingFailed.title) }
        if isPending(.consolidateMesh, processing) { return preparing(.consolidateMesh, processing) }
        if degraded == .meshStripped { return .unavailable(reason: Copy.Results.noDetailedScan) }
        return .unavailable(reason: Copy.Results.notReady)
    }
}
