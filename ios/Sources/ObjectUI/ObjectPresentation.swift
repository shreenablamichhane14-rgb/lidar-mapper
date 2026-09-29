import Foundation
import simd

// Pure decisions and text of the object result screen (docs/MODULES.md 3.42): what the screen
// shows from the files on disk and the in-memory processing state (never from stamps), the size
// rows through MeasureDisplay, the reconstruction stage and time left, the notes, and the viewer
// parts. Everything here is nonisolated and safe on any thread.

/// What exists on disk for the object.
struct ObjectResultFiles: Equatable, Sendable {
    /// `derived/objects/<id>/model.usdz` (small and medium only).
    var hasModel = false
    /// `derived/objects/<id>/mesh.mchk`.
    var hasMesh = false
    /// `derived/objects/<id>/dims.json`, readable and for this object.
    var hasDimensions = false
    /// TextureStore has the object's texture (large objects only).
    var hasTexture = false
    /// The object's size class.
    var size: ObjectSize = .smallMedium
    /// False when the manifest holds no `ObjectRecord` (the screen then shows `.noObject`).
    /// True by default, so a caller that only fills the file flags gets the documented rules.
    var hasObject = true

    /// Nothing on disk yet.
    init() {}
}

/// What the object result screen shows.
enum ObjectResultAvailability: Equatable, Sendable {
    /// The processing view: stage text, percent when known, time left when known.
    case processing(text: String, percent: Int?, remaining: String?)
    /// The model, the box and the size panel.
    case ready
    /// Processing failed; `reason` is the text under the title (Retry is offered).
    case failed(reason: String)
    /// The project holds no object.
    case noObject
}

/// One line of the size panel.
struct ObjectDimensionRow: Identifiable, Equatable, Sendable {
    /// "object.width", "object.height", "object.depth", "object.area", "object.volume".
    var id: String
    /// Copy.Viewer.width, height, depth, Copy.Measure.surfaceArea, Copy.Viewer.volume.
    var title: String
    /// MeasureDisplay.valueText, or the volume's unavailable reason.
    var valueText: String
    /// MeasureDisplay.accuracyText with the row's flag; nil for an unavailable volume.
    var accuracyText: String?
    /// Copy.Measure.estimated when the record's provenance is `.estimated`.
    var note: String?
    /// Lengths: MeasureDisplay.isLowConfidence(_:kind:). Surface area and volume take the flag
    /// from their sides (lead decision E3), because their relative sigma alone would flag every
    /// well-scanned object.
    var isLowConfidence: Bool
    /// MeasureDisplay.accessibilityText with the row's flag.
    var accessibility: String
}

/// Pure presentation rules of the object result screen.
enum ObjectPresentation {
    /// Log category of the module.
    static let logCategory = "objectui"
    /// Slack of the centroid test of `texturedParts`, meters.
    static let texturedPartTolerance: Float = 0.01
    /// Box color on the overlay layer (linear RGBA, translucent fill; the outline is opaque).
    static let boxColor = SIMD4<Float>(0.15, 0.55, 1.0, 0.18)
    /// Id of the untextured part.
    static let meshPartID = "object.mesh"
    /// Id of the box parts.
    static let boxPartID = "object.box"

    /// Writes one line to the app log under `logCategory`.
    static func log(_ message: String) {
        LogStore.shared.write(message, category: logCategory)
    }

    // MARK: - Availability

    /// Pure. No object record: `.noObject`. While `reconstructObject` runs: processing (the viewer
    /// holds no GPU memory then). Dims.json plus the model or the mesh: `.ready`. A queued or
    /// running job: processing (stage text from the monitor during reconstruction, else the
    /// runner's current step; `Copy.ObjectUI.waiting` while queued). A `.needsAttention` status
    /// or a failed step: `.failed` with `Copy.Errors.processingFailed.body`; so is a `.ready`
    /// project whose files are missing (Retry rebuilds them). Anything else waits.
    static func availability(files: ObjectResultFiles, processing: ProjectProcessingState, status: ProjectStatus,
                             progress: PhotogrammetryProgress?) -> ObjectResultAvailability {
        guard files.hasObject else { return .noObject }
        let reconstructing = processing.isRunning && processing.currentStep == .reconstructObject
        if !reconstructing && isReady(files) { return .ready }
        if processing.isRunning || processing.isQueued {
            return processingAvailability(processing, progress: progress)
        }
        if status == .needsAttention || !processing.failed.isEmpty || status == .ready {
            return .failed(reason: Copy.Errors.processingFailed.body)
        }
        return .processing(text: Copy.ObjectUI.waiting, percent: nil, remaining: nil)
    }

    /// Dims.json and something to show (the model or the mesh).
    static func isReady(_ files: ObjectResultFiles) -> Bool {
        files.hasDimensions && (files.hasModel || files.hasMesh)
    }

    /// Pure. Retry shows when the status is `.needsAttention` or a step failed.
    static func showsRetry(status: ProjectStatus, processing: ProjectProcessingState) -> Bool {
        status == .needsAttention || !processing.failed.isEmpty
    }

    /// The processing case of a queued or running job.
    private static func processingAvailability(_ processing: ProjectProcessingState,
                                               progress: PhotogrammetryProgress?) -> ObjectResultAvailability {
        guard processing.isRunning else {
            return .processing(text: Copy.ObjectUI.waiting, percent: nil, remaining: nil)
        }
        guard let step = processing.currentStep else {
            let text = processing.completed.contains(.reconstructObject) ? Copy.ObjectUI.stageFinishing
                                                                         : Copy.ObjectUI.stagePreparing
            return .processing(text: text, percent: nil, remaining: nil)
        }
        let runnerPercent = percent(processing.fraction)
        switch step {
        case .reconstructObject:
            let shown = progress.map { percent($0.fraction) } ?? runnerPercent
            return .processing(text: stageText(progress?.stage), percent: shown,
                               remaining: remainingText(seconds: progress?.remainingSeconds))
        case .objectMetrics:
            return .processing(text: Copy.ObjectUI.stageMeasuring, percent: runnerPercent, remaining: nil)
        case .thumbnail:
            return .processing(text: Copy.Processing.stepSaving, percent: runnerPercent, remaining: nil)
        case .textureLow, .textureHigh:
            return .processing(text: Copy.Processing.stepTextures, percent: runnerPercent, remaining: nil)
        default:
            // consolidateMesh (large objects) and any other shape step.
            return .processing(text: Copy.Processing.stepShape, percent: runnerPercent, remaining: nil)
        }
    }

    /// A 0...1 fraction as a whole percent, rounded down, clamped to 0...100 (non-finite gives 0).
    static func percent(_ fraction: Double) -> Int {
        guard fraction.isFinite else { return 0 }
        let clamped: Double = Swift.min(Swift.max(fraction, 0), 1)
        // The small bias keeps 0.29 at 29 percent (0.29 * 100 is 28.999... in binary).
        let scaled: Double = clamped * 100 + 1e-9
        return Swift.min(100, Int(scaled.rounded(.down)))
    }

    // MARK: - Text

    /// Stage text: nil and preProcessing `stagePreparing`, imageAlignment `stageAligning`,
    /// pointCloudGeneration `stageDetail`, meshGeneration `Copy.Processing.stepShape`,
    /// textureMapping `Copy.Processing.stepTextures`, optimization `stageFinishing`.
    static func stageText(_ stage: PhotogrammetryStage?) -> String {
        guard let stage else { return Copy.ObjectUI.stagePreparing }
        switch stage {
        case .preProcessing: return Copy.ObjectUI.stagePreparing
        case .imageAlignment: return Copy.ObjectUI.stageAligning
        case .pointCloudGeneration: return Copy.ObjectUI.stageDetail
        case .meshGeneration: return Copy.Processing.stepShape
        case .textureMapping: return Copy.Processing.stepTextures
        case .optimization: return Copy.ObjectUI.stageFinishing
        }
    }

    /// "About n min left" (minutes rounded up) or "Less than a minute left" under 60 s; nil
    /// without an estimate (nil, negative or not finite).
    static func remainingText(seconds: Double?) -> String? {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return nil }
        if seconds < 60 { return Copy.ObjectUI.remainingSoon }
        let minutes: Double = (seconds / 60).rounded(.up)
        return Copy.ObjectUI.remainingMinutes(Int(minutes))
    }

    /// Notes of a finished reconstruction: photos downsampled, sides not joined.
    static func notes(info: PhotogrammetryInfo?) -> [String] {
        guard let info else { return [] }
        var result: [String] = []
        if info.downsampled { result.append(Copy.ObjectUI.downsampledNote) }
        if info.stitchingIncomplete { result.append(Copy.ObjectUI.stitchingNote) }
        return result
    }

    // MARK: - Size rows

    /// Width, height, depth, surface area, volume, in that order, through
    /// `ObjectDimensions.measuredValues` and MeasureDisplay. A record without a volume keeps the
    /// volume row with its reason (`Copy.Viewer.volumeUnavailable`, or `volumeTooThin` for a
    /// closed model that encloses nothing) and no accuracy, so no bounding-box volume is ever
    /// shown in its place.
    static func rows(for record: ObjectDimensionsRecord, prefs: UnitPreferences) -> [ObjectDimensionRow] {
        let values = ObjectDimensions.measuredValues(record)
        let widthLow = MeasureDisplay.isLowConfidence(values.width, kind: .distance)
        let heightLow = MeasureDisplay.isLowConfidence(values.height, kind: .height)
        let depthLow = MeasureDisplay.isLowConfidence(values.depth, kind: .distance)
        let sidesLow = widthLow || heightLow || depthLow
        var result: [ObjectDimensionRow] = [
            row(id: "object.width", title: Copy.Viewer.width, value: values.width, kind: .distance, low: widthLow, prefs: prefs),
            row(id: "object.height", title: Copy.Viewer.height, value: values.height, kind: .height, low: heightLow, prefs: prefs),
            row(id: "object.depth", title: Copy.Viewer.depth, value: values.depth, kind: .distance, low: depthLow, prefs: prefs),
        ]
        let areaLow = sidesLow && carriesFlag(values.surfaceArea)
        result.append(row(id: "object.area", title: Copy.Measure.surfaceArea, value: values.surfaceArea, kind: .area,
                          low: areaLow, prefs: prefs))
        if let volume = values.volume {
            let volumeLow = sidesLow && carriesFlag(volume)
            result.append(row(id: "object.volume", title: Copy.Viewer.volume, value: volume, kind: .volume,
                              low: volumeLow, prefs: prefs))
        } else {
            let text = unavailableVolumeText(record.volumeUnavailableReason)
            result.append(ObjectDimensionRow(id: "object.volume", title: Copy.Viewer.volume, valueText: text,
                                             accuracyText: nil, note: nil, isLowConfidence: false,
                                             accessibility: Copy.A11y.measurement(Copy.Viewer.volume, value: text)))
        }
        return result
    }

    /// Why there is no volume: `volumeTooThin` for `.degenerate`, else `Copy.Viewer.volumeUnavailable`.
    static func unavailableVolumeText(_ reason: ObjectVolumeReason?) -> String {
        reason == .degenerate ? Copy.ObjectUI.volumeTooThin : Copy.Viewer.volumeUnavailable
    }

    /// True when a value can carry a low-confidence flag (measured or estimated with a sigma).
    private static func carriesFlag(_ value: MeasuredValue) -> Bool {
        let provenance = value.provenance == .measured || value.provenance == .estimated
        return provenance && value.sigma != nil
    }

    /// One row with MeasureDisplay's value, accuracy and spoken text for the given flag.
    private static func row(id: String, title: String, value: MeasuredValue, kind: MeasurementKind, low: Bool,
                            prefs: UnitPreferences) -> ObjectDimensionRow {
        let note: String? = value.provenance == .estimated ? Copy.Measure.estimated : nil
        return ObjectDimensionRow(id: id, title: title,
                                  valueText: MeasureDisplay.valueText(value, kind: kind, prefs: prefs),
                                  accuracyText: MeasureDisplay.accuracyText(value, kind: kind, prefs: prefs, lowConfidence: low),
                                  note: note, isLowConfidence: low,
                                  accessibility: MeasureDisplay.accessibilityText(label: title, value: value, kind: kind,
                                                                                  prefs: prefs, lowConfidence: low))
    }

    // MARK: - Viewer

    /// Small and medium: the model exists. Large: TextureStore has the object's texture (no
    /// build 5 processing plan textures large objects, so this stays false for them until a
    /// later build).
    static func canShowTextured(files: ObjectResultFiles) -> Bool {
        switch files.size {
        case .smallMedium: return files.hasModel
        case .large: return files.hasTexture
        }
    }

    /// Large objects: textured page parts whose triangle centroid lies inside the box (within
    /// `texturedPartTolerance`), re-indexed 0, 1, 2, ... with their per-corner texture
    /// coordinates. Parts left without faces are dropped; faces with an out-of-range index or a
    /// non-finite centroid are skipped.
    static func texturedParts(_ parts: [TexturedPagePart], inside box: OrientedBox) -> [TexturedPagePart] {
        var result: [TexturedPagePart] = []
        for part in parts {
            var kept = TexturedPagePart(page: part.page, positions: [], texcoords: [], indices: [])
            let count = Swift.min(part.positions.count, part.texcoords.count)
            let faces = part.indices.count / 3
            for f in 0..<faces {
                let i0 = Int(part.indices[3 * f]), i1 = Int(part.indices[3 * f + 1]), i2 = Int(part.indices[3 * f + 2])
                guard i0 < count, i1 < count, i2 < count else { continue }
                let sum: SIMD3<Float> = part.positions[i0] + part.positions[i1] + part.positions[i2]
                let centroid: SIMD3<Float> = sum / Float(3)
                guard centroid.x.isFinite, centroid.y.isFinite, centroid.z.isFinite,
                      box.contains(centroid, tolerance: texturedPartTolerance) else { continue }
                for corner in [i0, i1, i2] {
                    kept.indices.append(UInt32(truncatingIfNeeded: kept.positions.count))
                    kept.positions.append(part.positions[corner])
                    kept.texcoords.append(part.texcoords[corner])
                }
            }
            if !kept.indices.isEmpty { result.append(kept) }
        }
        return result
    }

    /// The untextured mesh as one lit gray part on `.raw` with pick tag `.rawMesh`.
    static func untexturedPart(_ mesh: MeshWithAttributes) -> ViewerPart {
        ViewerPart(id: meshPartID, positions: mesh.mesh.positions, normals: mesh.mesh.vertexNormals,
                   indices: mesh.mesh.indices, material: .lit(ViewerContentBuilder.solidColor), layer: .raw,
                   pickTag: .rawMesh)
    }

    /// Box parts (`ViewerContentBuilder.boxParts`) on `.overlay`, no pick tag.
    static func boxParts(_ box: OrientedBox) -> [ViewerPart] {
        ViewerContentBuilder.boxParts(box, color: boxColor, layer: .overlay, pickTag: nil, id: boxPartID)
    }

    /// The uniform scale that `loadModel` gives the Object Capture model, so it lines up with
    /// mesh.mchk (ObjectMetricsStep scales the mesh about the file origin). An unusable factor
    /// gives the identity.
    static func scaleTransform(_ scale: Float) -> simd_float4x4 {
        guard scale.isFinite, scale > 0 else { return matrix_identity_float4x4 }
        return simd_float4x4(diagonal: SIMD4<Float>(scale, scale, scale, 1))
    }
}
