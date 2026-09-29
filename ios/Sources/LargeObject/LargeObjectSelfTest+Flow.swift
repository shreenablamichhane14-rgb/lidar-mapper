import Foundation
import simd

// Self-test checks of the LargeObject pass, log file, settings, guidance hook and helpers
// (docs/MODULES.md 3.39, checks 23 to 25 and additions). The tracker and its coverage recorder
// are created but never fed by a session; the log file check writes one folder under the
// temporary directory and removes it.

extension LargeObjectSelfTest {
    // MARK: - The pass

    /// One pass over the cube scene grows the box, views the front and asks for the right side;
    /// a pass without faces keeps the previous box.
    static func checkPass(_ f: inout [String]) {
        let anchor = sampleAnchor(sceneSamples(), id: 9)
        // The grown cube's center is (0.01, _, 0.01); the camera stands straight in front of it, so
        // front-left and front-right are a true tie (the right side wins).
        let front = lookAt(eye: SIMD3<Float>(0.01, 0.5, 2), target: SIMD3<Float>(0.01, 0.5, 0.01))
        let poses = (0..<20).map { _ in LargeObjectPose(cameraToWorld: front, seconds: 0.1, trackingNormal: true) }
        let input = LargeObjectPassInput(seed: SIMD3<Float>(0.01, 0.5, 0.51), seedFloorY: 0, front: SIMD3<Float>(0.01, 0.5, 3),
                                         sectors: nil, lastFloorY: nil, lastBox: nil, poses: poses, lastCamera: nil)
        let output = LargeObjectPass.run(input, anchors: [anchor])
        let size = (output.box?.halfExtents ?? SIMD3<Float>(repeating: 0)) * 2
        check(&f, "pass.box", output.grewBox && near(size.y, 1.05, 0.02), "\(size)")
        check(&f, "pass.front", abs((output.sectors?.viewSeconds[0] ?? 0) - 2) < 1e-6,
              "\(String(describing: output.sectors?.viewSeconds))")
        check(&f, "pass.decision", output.decision == .objectCaptureRight, "\(String(describing: output.decision))")
        check(&f, "pass.floor", near(output.floorY ?? 9, 0, 1e-4), "\(String(describing: output.floorY))")

        var empty = input
        empty.lastBox = unitBox
        empty.poses = []
        let kept = LargeObjectPass.run(empty, anchors: [])
        check(&f, "pass.keepsBox", kept.box == unitBox && !kept.grewBox, "\(String(describing: kept.box))")

        let faces = LargeObjectPass.sectorFaces([anchor], box: unitBox)
        check(&f, "pass.sectorFaces", !faces.isEmpty && faces.allSatisfy { $0.state == .green }, "\(faces.count) faces")
    }

    /// One anchor whose faces are `samples` (area 0.0025 each, normals away from the cube center, green).
    static func sampleAnchor(_ samples: [LargeObjectSample], id: UInt8) -> CoverageAnchorFaces {
        let center = SIMD3<Float>(0, 0.5, 0)
        var faces: [CoverageFace] = []
        var low = SIMD3<Float>(repeating: Float.greatestFiniteMagnitude)
        var high = SIMD3<Float>(repeating: -Float.greatestFiniteMagnitude)
        for sample in samples {
            let offset = sample.position - center
            let length = simd_length(offset)
            let normal = length > 1e-6 ? offset / length : SIMD3<Float>(0, 1, 0)
            faces.append(CoverageFace(centroid: sample.position, normal: normal, area: 0.0025, surface: sample.surface))
            low = simd_min(low, sample.position)
            high = simd_max(high, sample.position)
        }
        let states = [CoverageState](repeating: .green, count: faces.count)
        return CoverageAnchorFaces(anchorID: fixedID(id), updateCount: 1, transform: matrix_identity_float4x4,
                                   localPositions: [], localNormals: [], indices: [], faces: faces, states: states,
                                   boundsMin: low, boundsMax: high, revision: 1)
    }

    // MARK: - Checks 23 and 24: log file and settings

    /// `LargeObjectLog` round trip, sanitizing, the missing-file rule, `defaultSettings()` and the pass target.
    static func checkLogAndSettings(_ f: inout [String]) {
        let box = OrientedBoxRecord(unitBox)
        let log = LargeObjectLog(seed: Vec3(x: 0.01, y: 0.5, z: 0.51), floorY: 0, front: Vec3(x: 0, y: 0.5, z: 3), box: box,
                                 viewSeconds: [2, 0, 1.5, 0, 0, 0, 0, 0, 1], faceScores: [1, nil, 0.5, nil, nil, nil, nil, nil, 1],
                                 topRequired: true, covered: 2, required: 9)
        do {
            let data = try ProjectStore.encoder.encode(log)
            let back = try ProjectStore.decoder.decode(LargeObjectLog.self, from: data)
            check(&f, "log.roundTrip", back == log, "\(back)")
        } catch {
            check(&f, "log.roundTrip", false, "\(error)")
        }
        var broken = log
        broken.floorY = Float.nan
        broken.viewSeconds = [Double.infinity]
        let clean = broken.sanitized()
        let floorDropped: Bool = clean.floorY == nil
        let secondsZeroed: Bool = clean.viewSeconds == [Double(0)]
        let encodes: Bool = broken.encoded() != nil
        check(&f, "log.sanitized", floorDropped && secondsZeroed && encodes,
              "\(String(describing: clean.floorY)) \(clean.viewSeconds)")
        checkLogFile(&f, log)

        let settings = LargeObjectTarget.defaultSettings()
        let detailOK: Bool = settings.detail == DetailLevel.high
        let distanceOK: Bool = settings.distance == ScanDistance.normal
        check(&f, "settings.default", detailOK && distanceOK && !settings.findRooms, "\(settings)")
        let package = ProjectPackage(root: URL(fileURLWithPath: "/tmp/LargeObjectSample.mapperproj", isDirectory: true))
        let target = LargeObjectTarget(projectID: fixedID(1), package: package, sessionID: fixedID(2), objectID: fixedID(3),
                                       settings: settings)
        let pass = target.meshTarget
        let kindOK: Bool = pass.kind == RawScanKind.object
        let modeOK: Bool = pass.mode == ScanMode.object
        let idOK: Bool = pass.passID == fixedID(3)
        let destinationOK: Bool = pass.destination == package.rawObjectURL(fixedID(3))
        let roomOK: Bool = pass.roomID == nil
        check(&f, "target.meshTarget", kindOK && modeOK && idOK && destinationOK && roomOK,
              "\(pass.kind) \(pass.mode) \(pass.destination.lastPathComponent)")
    }

    /// `load(from:)` returns nil without the file (a pass the engine stopped) and the log with it.
    private static func checkLogFile(_ f: inout [String], _ log: LargeObjectLog) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LargeObjectSelfTest-\(fixedID(7).uuidString)",
                                                                                  isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try? FileManager.default.removeItem(at: root)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let folder = RawScanFolder(url: root)
            check(&f, "log.missing", LargeObjectLog.load(from: folder) == nil, "loaded without a file")
            guard let data = log.encoded() else {
                check(&f, "log.file", false, "not encoded")
                return
            }
            try data.write(to: root.appendingPathComponent(LargeObjectLog.fileName, isDirectory: false))
            check(&f, "log.file", LargeObjectLog.load(from: folder) == log, "not read back")
        } catch {
            check(&f, "log.file", false, "\(error)")
        }
    }

    // MARK: - Check 25 and additions: guidance hook and helpers

    /// `apply(decision:to:)`, the composed hook, the seed rules of the tracker, outline math,
    /// manifest helpers, size text and copy.
    static func checkHooksAndHelpers(_ f: inout [String]) {
        var input = GuidanceInput(time: 1)
        input.viewCoverage = 0.2
        input.nearbyMissing = [MissingArea(centroid: SIMD3<Float>(0, 1, 0), normal: SIMD3<Float>(0, 0, 1), area: 0.5,
                                           surface: .wall, suggestedViewpoint: SIMD3<Float>(0, 1.5, 1))]
        LargeObjectTracker.apply(decision: .objectCaptureLeft, to: &input)
        let leftOnly: Set<GuidanceKind> = [GuidanceKind.objectCaptureLeft]
        let conditionsOK: Bool = input.extraConditions == leftOnly
        let coverageCleared: Bool = input.viewCoverage == nil
        check(&f, "apply.decision", conditionsOK && coverageCleared && input.nearbyMissing.isEmpty, "\(input.extraConditions)")
        LargeObjectTracker.apply(decision: nil, to: &input)
        check(&f, "apply.nil", input.extraConditions.isEmpty, "\(input.extraConditions)")

        let coverage = CoverageLiveRecorder(meshSource: MeshStore())
        let tracker = LargeObjectTracker(coverage: coverage)
        var hooked = GuidanceInput(time: 2)
        hooked.viewCoverage = 0.1
        tracker.guidanceHook(after: coverage)(&hooked)
        check(&f, "hook.composed", hooked.viewCoverage == nil && hooked.extraConditions.isEmpty, "\(hooked.extraConditions)")
        check(&f, "tracker.initial", tracker.current() == LargeObjectTrackerState.initial && tracker.log() == LargeObjectLog.empty,
              "\(tracker.current())")
        tracker.setSeed(SIMD3<Float>(Float.nan, 0, 0), floorY: 0, front: nil)
        check(&f, "tracker.nanSeed", tracker.log().seed == nil, "\(String(describing: tracker.log().seed))")
        tracker.setSeed(SIMD3<Float>(1, 0.5, 2), floorY: 0, front: SIMD3<Float>(1, 1.5, 4))
        let seeded = tracker.log()
        let seedOK: Bool = seeded.seed == Vec3(x: 1, y: 0.5, z: 2)
        let floorOK: Bool = seeded.floorY == Float(0)
        check(&f, "tracker.seed", seedOK && floorOK, "\(seeded)")
        check(&f, "tracker.isDue", LargeObjectTracker.isDue(1.1, last: 1.0, interval: 0.1)
              && !LargeObjectTracker.isDue(1.05, last: 1.0, interval: 0.1) && LargeObjectTracker.isDue(0, last: nil, interval: 1),
              "due rule")

        let one = SIMD3<Float>(1, 1, 1)
        check(&f, "outline.threshold", !LargeObjectBoxGeometry.needsNewMesh(current: one, wanted: SIMD3<Float>(1.015, 1, 1))
              && LargeObjectBoxGeometry.needsNewMesh(current: one, wanted: SIMD3<Float>(1.03, 1, 1)), "2 cm rule")
        let matrix = LargeObjectBoxGeometry.matrix(unitBox)
        let translationOK: Bool = matrix.columns.3 == SIMD4<Float>(0, 0.5, 0, 1)
        let upOK: Bool = matrix.columns.1 == SIMD4<Float>(0, 1, 0, 0)
        check(&f, "outline.matrix", translationOK && upOK, "\(matrix.columns.3)")

        var manifest = ProjectManifest.new(kind: .object, name: "Test", now: Date(timeIntervalSince1970: 0))
        let record = LargeObjectModel.objectRecord(id: fixedID(4), keyframes: 12)
        LargeObjectModel.add(record, to: &manifest)
        LargeObjectModel.add(record, to: &manifest)
        let sizeOK: Bool = record.size == ObjectSize.large
        let statusOK: Bool = record.status == RoomStatus.captured
        let countOK: Bool = record.imageCount == 12 && record.modelFile == nil
        let manifestOK: Bool = manifest.objects.count == 1 && manifest.status == ProjectStatus.needsProcessing
        check(&f, "manifest.add", sizeOK && statusOK && countOK && manifestOK,
              "\(manifest.objects.count) \(manifest.status)")

        let metric = UnitPreferences(system: .metric, fraction: .eighth, showBoth: false)
        let long = OrientedBox(center: SIMD3<Float>(0, 0.5, 0), axes: matrix_identity_float3x3,
                               halfExtents: SIMD3<Float>(0.25, 0.5, 1.0))
        let expectedSize = Copy.LargeObject.boxSize(width: LengthFormat.display(2.0, prefs: metric),
                                                    depth: LengthFormat.display(0.5, prefs: metric),
                                                    height: LengthFormat.display(1.0, prefs: metric))
        let sizeText = LargeObjectModel.sizeText(long, prefs: metric)
        check(&f, "size.text", sizeText == expectedSize, sizeText)
        check(&f, "copy.progress", Copy.LargeObject.sidesProgress(3, of: 9) == "3 of 9 sides captured",
              Copy.LargeObject.sidesProgress(3, of: 9))
        let texts = [Copy.LargeObject.tapToSelect, Copy.LargeObject.locating, Copy.LargeObject.noObjectFound,
                     Copy.LargeObject.tappedWall, Copy.LargeObject.chooseAgain, Copy.LargeObject.a11yBox]
        check(&f, "copy.nonEmpty", texts.allSatisfy { !$0.isEmpty }, "empty string")
    }
}
