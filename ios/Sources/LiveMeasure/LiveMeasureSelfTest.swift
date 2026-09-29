import Foundation
import ARKit
import CoreGraphics
import simd

/// Plain-Swift checks for LiveMeasure (no XCTest), run from the Diagnostics suite list off the
/// main actor. Deterministic (fixed identifiers, dates and samples), no ARKit session, camera,
/// clock or network; the store checks write only under `FileManager.default.temporaryDirectory`
/// and remove what they wrote. 66 checks.
enum LiveMeasureSelfTest {
    /// Failing checks as "name: detail"; empty when all pass.
    static func run() -> [String] {
        var c = LiveMeasureSelfTestChecker()
        cornerChecks(&c)
        resolveChecks(&c)
        snapKindChecks(&c)
        tagChecks(&c)
        evidenceChecks(&c)
        confidenceChecks(&c)
        storeChecks(&c)
        guidanceChecks(&c)
        return c.failures
    }

    /// Shorter name for the fixtures.
    private typealias F = LiveMeasureSelfTestFixtures

    // MARK: Plane corners (checks 1 to 4)

    /// Extent corners, rotation and translation, wall-wall-floor corners, parallel walls, far corners.
    private static func cornerChecks(_ c: inout LiveMeasureSelfTestChecker) {
        let flat = F.plane(matrix_identity_float4x4, width: 1, length: 2, facing: .horizontal, id: 1)
        let corners = LiveMeasureSnapping.extentCorners(flat)
        let expected: [SIMD3<Float>] = [SIMD3<Float>(0.5, 0, 1), SIMD3<Float>(-0.5, 0, 1),
                                        SIMD3<Float>(0.5, 0, -1), SIMD3<Float>(-0.5, 0, -1)]
        c.check("corners.extent", F.sameSet(corners, expected), "\(corners)")

        var turned = flat
        turned.rotationOnYAxis = Float.pi / 2
        let swapped = LiveMeasureSnapping.extentCorners(turned)
        let swappedExpected: [SIMD3<Float>] = [SIMD3<Float>(1, 0, 0.5), SIMD3<Float>(-1, 0, 0.5),
                                               SIMD3<Float>(1, 0, -0.5), SIMD3<Float>(-1, 0, -0.5)]
        c.check("corners.rotation", F.sameSet(swapped, swappedExpected), "\(swapped)")
        var lifted = flat
        lifted.transform = F.moved(matrix_identity_float4x4, SIMD3<Float>(0, 0.75, 0))
        let liftedCorners = LiveMeasureSnapping.extentCorners(lifted)
        let allLifted = liftedCorners.allSatisfy { abs($0.y - 0.75) < 1e-5 }
        c.check("corners.translation", allLifted && liftedCorners.count == 4, "\(liftedCorners)")

        let wallX = F.wallX(at: SIMD3<Float>(0, 1, 0), id: 2)
        let wallZ = F.wallZ(at: SIMD3<Float>(0, 1, 0), id: 3)
        let floor = F.plane(matrix_identity_float4x4, width: 4, length: 4, facing: .horizontal, kind: .floor, id: 4)
        let meeting = LiveMeasureSnapping.intersectionCorners([wallX, wallZ, floor])
        c.check("corners.intersection", meeting.count == 1 && F.contains(meeting, SIMD3<Float>(0, 0, 0)), "\(meeting)")
        let plane = LiveMeasureSnapping.worldPlane(wallX)
        let normalError = simd_distance(plane.normal, SIMD3<Float>(1, 0, 0))
        let offset = plane.signedDistance(to: SIMD3<Float>(0.5, 0, 0))
        c.check("corners.worldPlane", normalError < 1e-4 && abs(offset - 0.5) < 1e-4, "normal \(plane.normal)")
        let inside = LiveMeasureSnapping.distanceToExtent(SIMD3<Float>(0, 0, 0), wallX)
        c.check("corners.extentDistance", inside < 1e-4, "\(inside)")

        let parallel = F.wallX(at: SIMD3<Float>(2, 1, 0), id: 5)
        let noCorners = LiveMeasureSnapping.intersectionCorners([wallX, parallel, floor])
        c.check("corners.parallel", noCorners.isEmpty, "\(noCorners)")
        let farWall = F.wallZ(at: SIMD3<Float>(3, 1, 0), id: 6)
        let outside = LiveMeasureSnapping.intersectionCorners([wallX, farWall, floor])
        c.check("corners.outsideExtent", outside.isEmpty, "\(outside)")

        let near = LiveMeasureSnapping.cornerPoints([flat], camera: SIMD3<Float>(0, 1, 0))
        let far = LiveMeasureSnapping.cornerPoints([flat], camera: SIMD3<Float>(10, 0, 0))
        c.check("corners.cameraDistance", near.count == 4 && far.isEmpty, "near \(near.count), far \(far.count)")
        let room = LiveMeasureSnapping.cornerPoints([wallX, wallZ, floor], camera: SIMD3<Float>(1, 1, 1))
        c.check("corners.roomIncludesIntersection", F.contains(room, SIMD3<Float>(0, 0, 0)), "\(room.count)")

        var twin = wallX
        c.check("plane.equal", twin == wallX, "copy differs")
        twin.transform = F.moved(twin.transform, SIMD3<Float>(0, 1.5, 0))
        c.check("plane.notEqual", twin != wallX, "moved plane equals the original")
    }

    // MARK: Resolution (checks 5 to 9)

    /// Priority, world and screen radii, fallback, occlusion.
    private static func resolveChecks(_ c: inout LiveMeasureSelfTestChecker) {
        let reticle = CGPoint(x: 100, y: 100)
        let hit = F.candidate(0, screen: reticle, source: .planeGeometry, snap: .plane, tag: .wall)
        let existing = F.candidate(0.05, screen: CGPoint(x: 106, y: 100), source: .existingPoint, snap: .corner, tag: .corner)
        let corner3 = F.candidate(0.03, screen: CGPoint(x: 103, y: 100), source: .planeCorner, snap: .corner, tag: .corner)
        let first = LiveMeasureSnapping.resolve(hit: hit, fallback: nil, candidates: [corner3, existing], reticle: reticle)
        let firstPoint = first?.point == existing.point
        c.check("resolve.existingWins", F.matches(first, .existingPoint, snapped: true) && firstPoint,
                "\(String(describing: first))")
        let firstKinds = first?.measurementSnap == MeasurementSnapKind.plane && first?.snap == SnapKind.corner
        c.check("resolve.existingInherits", firstKinds, "\(String(describing: first))")

        let corner12 = F.candidate(0.12, screen: CGPoint(x: 112, y: 100), source: .planeCorner, snap: .corner, tag: .corner)
        let far = LiveMeasureSnapping.resolve(hit: hit, fallback: nil, candidates: [corner12], reticle: reticle)
        let farPoint = far?.point == hit.point
        c.check("resolve.worldRadius", F.matches(far, .planeGeometry, snapped: false) && farPoint, "\(String(describing: far))")
        let farTag = far?.tag == LiveMeasureSnapTag.wall && far?.snap == SnapKind.plane
        let farKind = far?.measurementSnap == MeasurementSnapKind.plane
        c.check("resolve.planeHitKinds", farTag && farKind, "\(String(describing: far))")
        let corner8Far = F.candidate(0.08, screen: CGPoint(x: 140, y: 100), source: .planeCorner, snap: .corner, tag: .corner)
        let offScreen = LiveMeasureSnapping.resolve(hit: hit, fallback: nil, candidates: [corner8Far], reticle: reticle)
        c.check("resolve.screenRadius", F.matches(offScreen, .planeGeometry, snapped: false), "\(String(describing: offScreen))")
        let corner8Near = F.candidate(0.08, screen: CGPoint(x: 110, y: 100), source: .planeCorner, snap: .corner, tag: .corner)
        let snapped = LiveMeasureSnapping.resolve(hit: hit, fallback: nil, candidates: [corner8Near], reticle: reticle)
        let snappedTag = snapped?.tag == LiveMeasureSnapTag.corner
        c.check("resolve.cornerSnaps", F.matches(snapped, .planeCorner, snapped: true) && snappedTag,
                "\(String(describing: snapped))")
        let unprojected = F.candidate(0.03, screen: nil, source: .planeCorner, snap: .corner, tag: .corner)
        let worldOnly = LiveMeasureSnapping.resolve(hit: hit, fallback: nil, candidates: [unprojected], reticle: reticle)
        c.check("resolve.unprojected", F.matches(worldOnly, .planeCorner, snapped: true), "\(String(describing: worldOnly))")

        let fallback = F.candidate(0, screen: reticle, source: .estimatedPlane, snap: SnapKind.none, tag: nil)
        let estimated = LiveMeasureSnapping.resolve(hit: nil, fallback: fallback, candidates: [], reticle: reticle)
        let freeSnap = estimated?.snap == SnapKind.none
        let freeKind = estimated?.measurementSnap == MeasurementSnapKind.none
        c.check("resolve.fallback", F.matches(estimated, .estimatedPlane, snapped: false) && freeSnap && freeKind,
                "\(String(describing: estimated))")
        let fallbackSnap = LiveMeasureSnapping.resolve(hit: nil, fallback: fallback, candidates: [corner3], reticle: reticle)
        c.check("resolve.fallbackReference", F.matches(fallbackSnap, .planeCorner, snapped: true),
                "\(String(describing: fallbackSnap))")
        let nothing = LiveMeasureSnapping.resolve(hit: nil, fallback: nil, candidates: [corner3, existing], reticle: reticle)
        c.check("resolve.nothing", nothing == nil, "\(String(describing: nothing))")
        let noSnapping = LiveMeasureSnapping.resolve(hit: hit, fallback: fallback, candidates: [], reticle: reticle)
        c.check("resolve.snappingOff", F.matches(noSnapping, .planeGeometry, snapped: false), "\(String(describing: noSnapping))")

        let behind = F.candidate(1.0, screen: reticle, source: .planeGeometry, snap: .plane, tag: .wall)
        let camera = SIMD3<Float>(0, 0, 1)
        let occluded = LiveMeasureSnapping.unoccludedHit(behind, fallback: fallback, camera: camera)
        c.check("resolve.occluded", occluded == nil, "a plane hit behind the surface was kept")
        let kept = LiveMeasureSnapping.unoccludedHit(hit, fallback: fallback, camera: camera)
        c.check("resolve.unoccluded", kept == hit, "a plane hit at the surface was dropped")
    }

    // MARK: Snap kinds (check 21)

    /// `measurementSnap(for:inherited:)`, `measurementSnap(of:)` and the source order.
    private static func snapKindChecks(_ c: inout LiveMeasureSelfTestChecker) {
        let inherited = LiveMeasureSnapping.measurementSnap(for: .existingPoint, inherited: .plane)
        c.check("snap.existingInherits", inherited == .plane, "\(inherited)")
        let corner = LiveMeasureSnapping.measurementSnap(for: .planeCorner, inherited: nil)
        c.check("snap.corner", corner == .plane, "\(corner)")
        let estimated = LiveMeasureSnapping.measurementSnap(for: .estimatedPlane, inherited: .plane)
        c.check("snap.estimated", estimated == MeasurementSnapKind.none, "\(estimated)")
        let free = LiveMeasureSnapping.measurementSnap(for: .existingPoint, inherited: nil)
        c.check("snap.existingFree", free == MeasurementSnapKind.none, "\(free)")
        let ofCorner = LiveMeasureSnapping.measurementSnap(of: .corner)
        let ofNone = LiveMeasureSnapping.measurementSnap(of: SnapKind.none)
        c.check("snap.ofKind", ofCorner == .plane && ofNone == MeasurementSnapKind.none, "\(ofCorner) \(ofNone)")
        let lowFirst: Bool = LiveMeasureSnapSource.existingPoint < LiveMeasureSnapSource.planeCorner
        let midOrder: Bool = LiveMeasureSnapSource.planeCorner < LiveMeasureSnapSource.planeGeometry
        let lastOrder: Bool = LiveMeasureSnapSource.planeGeometry < LiveMeasureSnapSource.estimatedPlane
        c.check("snap.order", lowFirst && midOrder && lastOrder, "priority order")
    }

    // MARK: Tags and plane kinds (checks 10 and 11)

    /// Tag targets from `Copy.Measure.snapTargets` and ARKit classification mapping.
    private static func tagChecks(_ c: inout LiveMeasureSelfTestChecker) {
        let targets = Copy.Measure.snapTargets
        let wallTarget = LiveMeasureSnapping.tag(for: .wall)?.target
        c.check("tag.wall", targets.count > 1 && wallTarget == targets[1], "\(String(describing: wallTarget))")
        c.check("tag.corner", !targets.isEmpty && LiveMeasureSnapTag.corner.target == targets[0], LiveMeasureSnapTag.corner.target)
        c.check("tag.unknown", LiveMeasureSnapping.tag(for: .unknown) == nil, "unknown has a tag")
        let table = LiveMeasureSnapping.tag(for: .table)
        let seat = LiveMeasureSnapping.tag(for: .seat)
        c.check("tag.table", table == .objectEdge && seat == .objectEdge, "\(String(describing: table))")
        let allTargets = LiveMeasureSnapTag.allCases.allSatisfy { !$0.target.isEmpty }
        c.check("tag.allTargets", LiveMeasureSnapTag.allCases.count == targets.count && allTargets, "\(targets.count)")

        c.check("kind.wall", LiveMeasureProbe.kind(.wall) == .wall, "wall")
        c.check("kind.floor", LiveMeasureProbe.kind(.floor) == .floor, "floor")
        c.check("kind.table", LiveMeasureProbe.kind(.table) == .table, "table")
        c.check("kind.none", LiveMeasureProbe.kind(ARPlaneAnchor.Classification.none(.unknown)) == .unknown, "none")
    }

    // MARK: Evidence (checks 12 and 13)

    /// Observations, confidence, tracking fraction and the no-depth and no-sample cases.
    private static func evidenceChecks(_ c: inout LiveMeasureSelfTestChecker) {
        let point = SIMD3<Float>(0, 0, -1)
        let ten = (0..<10).map { i in F.sample(9.1 + Double(i) * 0.1, depth: 1.0 + Float(i) * 0.001) }
        let now = ten.map { $0.timestamp }.max() ?? 0
        let steady = LiveMeasureSnapping.evidence(point: point, samples: ten, snap: .plane, now: now)
        c.check("evidence.observations", steady.observations == 9 && steady.depthConfidence != nil,
                "\(steady.observations), \(String(describing: steady.depthConfidence))")
        let distanceOK = abs(steady.distance - 1) < 1e-4
        let trackingOK = abs(steady.trackingNormalFraction - 1) < 1e-4
        c.check("evidence.distance", distanceOK && trackingOK && steady.snap == .plane, "\(steady.distance)")

        let mixed = (0..<10).map { i in F.sample(5.5 + Double(i) * 0.5, depth: 1.0, normal: i >= 5) }
        let mixedNow = mixed.map { $0.timestamp }.max() ?? 0
        let half = LiveMeasureSnapping.evidence(point: point, samples: mixed, snap: .plane, now: mixedNow)
        c.check("evidence.trackingFraction", abs(half.trackingNormalFraction - 0.5) < 1e-4, "\(half.trackingNormalFraction)")

        let noDepth = (0..<3).map { i in F.sample(1 + Double(i) * 0.1, depth: nil) }
        let blind = LiveMeasureSnapping.evidence(point: point, samples: noDepth, snap: MeasurementSnapKind.none, now: 1.2)
        let blindDistance = abs(blind.distance - 1) < 1e-4
        c.check("evidence.noDepth", blind.observations == 1 && blind.depthConfidence == nil && blindDistance,
                "\(blind.observations), \(blind.distance)")
        let empty = LiveMeasureSnapping.evidence(point: point, samples: [], snap: MeasurementSnapKind.none, now: 0)
        let emptyDistance = empty.distance == ConfidenceAdapter.defaultDistance
        c.check("evidence.noSamples", empty.observations == 1 && empty.depthConfidence == nil && emptyDistance,
                "\(empty.distance)")
        let elsewhere = [F.sample(2, depth: 1.5)]
        let disagree = LiveMeasureSnapping.evidence(point: point, samples: elsewhere, snap: .plane, now: 2)
        c.check("evidence.depthDisagrees", disagree.depthConfidence == nil && disagree.observations == 1,
                "\(String(describing: disagree.depthConfidence))")
    }

    // MARK: Confidence and records (checks 14 and 15)

    /// Sigma and the low-confidence rule through MeasureDisplay, and `record()`.
    private static func confidenceChecks(_ c: inout LiveMeasureSelfTestChecker) {
        let good = MeasurementEvidence(distance: 1, depthConfidence: 1, observations: 9, trackingNormalFraction: 1, snap: .plane)
        let value = ConfidenceAdapter.distance(start: good, end: good, length: 1)
        let sigma = value.sigma ?? 0
        c.check("confidence.good", sigma > 0 && !MeasureDisplay.isLowConfidence(value, kind: .distance), "sigma \(sigma)")
        var shaky = good
        shaky.trackingNormalFraction = 0.3
        let weak = ConfidenceAdapter.distance(start: shaky, end: shaky, length: 1)
        c.check("confidence.lowTracking", MeasureDisplay.isLowConfidence(weak, kind: .distance),
                "sigma \(String(describing: weak.sigma))")

        let start = LiveMeasurePoint(position: SIMD3<Float>(0, 0, 0), snap: .corner, evidence: good)
        let end = LiveMeasurePoint(position: SIMD3<Float>(1, 0, 0), snap: .plane, evidence: good, tag: .wall)
        let segment = LiveMeasureSegment.make(start: start, end: end, id: F.fixedID(7), createdAt: F.fixedDate)
        let lengthOK = abs(segment.value.value - 1) < 1e-6
        c.check("segment.value", lengthOK && segment.value.provenance == .measured, "\(segment.value.value)")
        let record = segment.record()
        let shapeOK = record.kind == .distance && record.points.count == 2 && record.snaps == [.corner, .plane]
        let sourceOK = record.source == .live && record.roomID == nil && record.name.isEmpty
        c.check("record.shape", shapeOK && sourceOK && record.id == segment.id, "\(record.kind) \(record.snaps)")
        let lastPoint = record.points.last == Vec3(x: 1, y: 0, z: 0)
        c.check("record.points", lastPoint && record.result == segment.value, "\(record.points)")
        let line = LiveMeasureLog.describe(record)
        c.check("record.log", line.contains("value 1.0000 m"), line)
    }

    // MARK: Store (checks 16 to 18)

    /// Round trip, save and seal in a temporary package, a deleted package.
    private static func storeChecks(_ c: inout LiveMeasureSelfTestChecker) {
        let records = F.records()
        let file = QuickMeasureFile(version: QuickMeasureFile.currentVersion, createdAt: F.fixedDate, records: records)
        do {
            let data = try ProjectStore.encoder.encode(file)
            let decoded = try ProjectStore.decoder.decode(QuickMeasureFile.self, from: data)
            c.check("store.roundTrip", decoded == file, "decoded file differs")
        } catch {
            c.check("store.roundTrip", false, "\(error)")
        }

        let base = FileManager.default.temporaryDirectory.appendingPathComponent("LiveMeasureSelfTest", isDirectory: true)
        try? FileManager.default.removeItem(at: base)
        defer { try? FileManager.default.removeItem(at: base) }
        let package = ProjectPackage(root: base.appendingPathComponent(F.fixedID(17).uuidString + ".mapperproj",
                                                                       isDirectory: true))
        c.check("store.loadMissing", QuickMeasureStore.load(package) == nil, "loaded a missing file")
        c.check("store.folder", QuickMeasureStore.folder(package).lastPathComponent == "measure",
                QuickMeasureStore.folder(package).lastPathComponent)
        do {
            try ProjectStore.ensureDirectory(package.root)
            try QuickMeasureStore.save(records, to: package, now: F.fixedDate)
            let folder = QuickMeasureStore.folder(package)
            let seal = try ProjectStore.readJSON(SealFile.self, from: folder.appendingPathComponent(SealFile.fileName))
            let exists = FileManager.default.fileExists(atPath: package.quickMeasureURL.path)
            let sealed = seal.files.map { $0.path }
            c.check("store.saveSeals", exists && sealed == ["quick.json"], "\(sealed)")
            c.check("store.sealVerifies", ProjectStore.verifyRawFolder(folder).isEmpty, "seal mismatch")
            let loaded = QuickMeasureStore.load(package)
            let versionOK = loaded?.version == QuickMeasureFile.currentVersion
            c.check("store.load", loaded?.records == records && versionOK, "\(String(describing: loaded?.records.count))")
        } catch {
            c.check("store.saveSeals", false, "\(error)")
        }

        let goneRoot = base.appendingPathComponent(F.fixedID(18).uuidString + ".mapperproj", isDirectory: true)
        let gone = ProjectPackage(root: goneRoot)
        var threw = false
        do {
            try QuickMeasureStore.save(records, to: gone, now: F.fixedDate)
        } catch {
            threw = true
        }
        let created = FileManager.default.fileExists(atPath: goneRoot.path)
        c.check("store.deletedPackage", threw && !created, "threw \(threw), created \(created)")
    }

    // MARK: Guidance (checks 19 and 20)

    /// Tier 1 filter and the guidance input from a hub status.
    private static func guidanceChecks(_ c: inout LiveMeasureSelfTestChecker) {
        let slower = GuidanceOutput(message: .moveSlower, fireHaptic: true)
        c.check("guidance.keepsTier1", LiveMeasureSnapping.filterGuidance(slower) == slower, "moveSlower dropped")
        let closer = LiveMeasureSnapping.filterGuidance(GuidanceOutput(message: .moveCloser, fireHaptic: false))
        c.check("guidance.dropsTier2", closer.message == nil, "\(String(describing: closer.message))")
        let door = LiveMeasureSnapping.filterGuidance(GuidanceOutput(message: .doorDetected, fireHaptic: true))
        c.check("guidance.dropsTier3", door.message == nil && !door.fireHaptic, "\(String(describing: door.message))")

        var status = HubStatus()
        status.tracking = .relocalizing
        status.angularSpeed = 0.5
        status.linearSpeed = 0.2
        status.centerDistance = 1.5
        status.depthConfidenceMean = 0.8
        status.ambientIntensity = 900
        status.thermal = .serious
        let input = LiveMeasureSnapping.guidanceInput(time: 3, status: status)
        let timeOK = input.time == 3 && input.tracking == .relocalizing
        let speedsOK = input.angularSpeed == status.angularSpeed && input.linearSpeed == status.linearSpeed
        let depthOK = input.centerDistance == status.centerDistance && input.depthConfidenceMean == status.depthConfidenceMean
        let lightOK = input.ambientIntensity == status.ambientIntensity
        c.check("guidance.input", timeOK && speedsOK && depthOK && lightOK, "fields not copied")
        c.check("guidance.hotAtSerious", input.deviceHot, "serious is not hot")
        status.thermal = .fair
        c.check("guidance.notHotAtFair", !LiveMeasureSnapping.guidanceInput(time: 3, status: status).deviceHot, "fair is hot")
    }
}

/// Counts checks and collects failures of LiveMeasureSelfTest.
struct LiveMeasureSelfTestChecker {
    /// Failing checks as "name: detail".
    var failures: [String] = []
    /// Number of checks run.
    var count = 0

    /// Records one check; the detail is built only on failure.
    mutating func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String) {
        count += 1
        if !ok { failures.append("\(name): \(detail())") }
    }
}
