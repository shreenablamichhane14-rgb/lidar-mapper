import CoreGraphics
import Foundation
import simd

/// A running list of named checks and the ones that failed.
struct TXTestChecks {
    /// Failure messages, one per failing check.
    var failures: [String] = []
    /// Number of checks run.
    var count: Int = 0

    /// Records one check; `detail` is appended to the message when it fails.
    mutating func expect(_ name: String, _ ok: Bool, _ detail: String = "") {
        count += 1
        if !ok { failures.append(detail.isEmpty ? "\(name): failed" : "\(name): \(detail)") }
    }
}

/// Plain-Swift checks for the texturing module (no XCTest), meant to run at launch in debug
/// builds. Synthetic scenes (see `TXTestScenes`) are ray cast with a known checkerboard, so the
/// true color of every surface point is known. `run()` returns one line per failing check;
/// empty means all passed. Runs in well under 3 s on an A15 (320 x 240 images, 176 triangles).
enum TexturingSelfTest {
    /// Failing checks as "name: detail".
    static func run() -> [String] {
        let start: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
        var c = TXTestChecks()
        checkProjection(&c)
        checkGeometryAndOcclusion(&c)
        checkPacker(&c)
        checkSelector(&c)
        checkSharpnessAndSmoothing(&c)
        checkScene(&c)
        let elapsed: Double = CFAbsoluteTimeGetCurrent() - start
        c.expect("runtime.under3s", elapsed < 3, String(format: "took %.2f s", elapsed))
        if c.count < 45 { c.failures.append("selfTest.count: only \(c.count) checks ran") }
        return c.failures
    }

    // MARK: - Camera

    /// Projection round trip, sign convention, principal point, behind-camera and resizing.
    private static func checkProjection(_ c: inout TXTestChecks) {
        let cameras: [TXCamera] = TXTestScenes.sceneCameras()
        let offsets: [SIMD3<Float>] = [SIMD3<Float>(0, 0, 0), SIMD3<Float>(0.5, 0.5, 0.5), SIMD3<Float>(-0.4, 0.3, -0.2),
                                       SIMD3<Float>(0.7, -0.5, 0.1), SIMD3<Float>(-0.3, -0.45, 0.6)]
        for (k, cam) in cameras.enumerated() {
            var worst: Float = 0
            for o in offsets {
                let p: SIMD3<Float> = TXTestScenes.cubeCenter + o
                if let q = cam.project(p) {
                    worst = max(worst, simd_length(cam.unproject(SIMD2<Float>(q.x, q.y), depth: q.z) - p))
                } else {
                    worst = Float.infinity
                }
            }
            c.expect("projection.roundTrip.cam\(k)", worst <= 1e-4, "max error \(worst) m")
            let q = cam.project(TXTestScenes.cubeCenter)
            let ok: Bool = q.map { abs($0.x - TXTestScenes.cx) < 1e-3 && abs($0.y - TXTestScenes.cy) < 1e-3 } ?? false
            c.expect("projection.principalAxis.cam\(k)", ok, "target projects to \(String(describing: q))")
        }
        let front: TXCamera = cameras[0]
        let up: SIMD3<Float> = SIMD3<Float>(front.cameraToWorld.columns.1.x, front.cameraToWorld.columns.1.y,
                                            front.cameraToWorld.columns.1.z)
        let above: SIMD3<Float> = front.position + up * 0.1 + front.forward * 1.0
        if let q = front.project(above) {
            c.expect("projection.aboveAxis.vBelowCy", q.y < TXTestScenes.cy, "v = \(q.y)")
            c.expect("projection.aboveAxis.exact", abs(q.y - (TXTestScenes.cy - 20)) < 1e-3 && abs(q.x - TXTestScenes.cx) < 1e-3,
                     "got (\(q.x), \(q.y)), expected (160, 100)")
        } else {
            c.expect("projection.aboveAxis", false, "point did not project")
        }
        c.expect("projection.behindIsNil", front.project(front.position - front.forward * 1.0) == nil)
        let big: TXCamera = front.resized(width: 640, height: 480)
        c.expect("projection.resized.intrinsics", big.fx == 400 && big.fy == 400 && big.cx == 320 && big.cy == 240,
                 "fx \(big.fx) fy \(big.fy) cx \(big.cx) cy \(big.cy)")
        let p = SIMD3<Float>(0.2, 0.3, -1.6)
        if let a = front.project(p), let b = big.project(p) {
            c.expect("projection.resized.pixels", abs(b.x - 2 * a.x) < 1e-3 && abs(b.y - 2 * a.y) < 1e-3)
        } else {
            c.expect("projection.resized.pixels", false, "point did not project")
        }
    }

    // MARK: - Geometry, adjacency, depth buffer, occlusion

    /// Cube normals, areas and adjacency; the depth buffer and occlusion behind a small quad.
    private static func checkGeometryAndOcclusion(_ c: inout TXTestChecks) {
        let cube: TXMesh = TXTestScenes.cubeMesh()
        let g = TXFaceGeometry(mesh: cube)
        c.expect("cube.faceCount", cube.faceCount == 48, "\(cube.faceCount)")
        var outward = true
        for f in 0..<g.normals.count where simd_dot(g.normals[f], g.centroids[f] - TXTestScenes.cubeCenter) <= 0 {
            outward = false
        }
        c.expect("geometry.normalsOutward", outward)
        c.expect("geometry.areaSum6", abs(g.totalArea - 6) < 1e-4, "total \(g.totalArea)")
        let adjacency = TXAdjacency(mesh: cube)
        var allThree = true
        for f in 0..<cube.faceCount where adjacency.neighbors(of: f).count != 3 { allThree = false }
        c.expect("adjacency.closedCube3", allThree)

        let mesh: TXMesh = TXTestScenes.occlusionMesh()
        let cam: TXCamera = TXTestScenes.camera(eye: SIMD3<Float>(0, 0, 0), target: TXTestScenes.cubeCenter)
        let buffer = TXDepthBuffer(mesh: mesh, camera: cam, width: 256, height: 192)
        let center: Float = buffer.depth(atSourcePixel: SIMD2<Float>(160, 120), sourceCamera: cam)
        c.expect("depthBuffer.center", abs(center - 1.5) < 0.01, "depth \(center)")
        let corner: Float = buffer.depth(atSourcePixel: SIMD2<Float>(10, 10), sourceCamera: cam)
        c.expect("depthBuffer.emptyIsInfinite", corner == Float.infinity, "depth \(corner)")

        var options = TXOptions()
        options.normalizeExposure = false
        let geometry = TXFaceGeometry(mesh: mesh)
        guard let vis = try? TXVisibilityBuilder.compute(mesh: mesh, geometry: geometry, cameras: [cam], options: options) else {
            c.expect("occlusion.compute", false, "visibility threw")
            return
        }
        var hidden = 0, hiddenSeen = 0, far = 0, farHidden = 0
        for f in 2..<mesh.faceCount {
            guard let t = mesh.corners(f) else { continue }
            let limit: Float = 0.2 * 2.5 / 1.5
            let covered: Bool = [t.0, t.1, t.2].allSatisfy { abs($0.x) <= limit && abs($0.y) <= limit }
            let seen: Bool = vis.candidate(forFace: f, keyframe: 0) != nil
            if covered {
                hidden += 1
                if seen { hiddenSeen += 1 }
            }
            let centroid = geometry.centroids[f]
            if (centroid.x * centroid.x + centroid.y * centroid.y).squareRoot() > 0.5 {
                far += 1
                if !seen { farHidden += 1 }
            }
        }
        c.expect("occlusion.hiddenCount", hidden == 8, "\(hidden) fully hidden faces")
        c.expect("occlusion.hiddenOccluded", hiddenSeen == 0, "\(hiddenSeen) hidden faces reported visible")
        c.expect("occlusion.farVisible", far > 0 && farHidden == 0, "\(farHidden) of \(far) far faces occluded")
        c.expect("occlusion.frontQuadVisible",
                 vis.candidate(forFace: 0, keyframe: 0) != nil && vis.candidate(forFace: 1, keyframe: 0) != nil)
    }

    // MARK: - Packer

    /// Skyline packer spill, failure cases and atlas trimming.
    private static func checkPacker(_ c: inout TXTestChecks) {
        let five = [SIMD2<Int>](repeating: SIMD2<Int>(100, 100), count: 5)
        if let p = TXAtlasPacker.pack(sizes: five, atlasSize: 256, maxAtlases: 8) {
            c.expect("packer.fiveInto256.atlases", p.atlasCount == 2, "\(p.atlasCount) atlases")
            c.expect("packer.fiveInto256.usedHeights", p.usedHeights == [200, 100], "\(p.usedHeights)")
            c.expect("packer.fiveInto256.noOverlap", TXTestScenes.overlappingPairs(sizes: five, placements: p.placements) == 0)
        } else {
            c.expect("packer.fiveInto256", false, "returned nil")
        }
        c.expect("packer.maxAtlases1.nil", TXAtlasPacker.pack(sizes: five, atlasSize: 256, maxAtlases: 1) == nil)
        c.expect("packer.oversize.nil", TXAtlasPacker.pack(sizes: [SIMD2<Int>(300, 10)], atlasSize: 256, maxAtlases: 8) == nil)
        let h1: Int = TXAtlasPacker.atlasHeight(usedHeight: 435, atlasSize: 512)
        let h2: Int = TXAtlasPacker.atlasHeight(usedHeight: 100, atlasSize: 512)
        c.expect("packer.atlasHeight.435", h1 == 512, "\(h1)")
        c.expect("packer.atlasHeight.100", h2 == 128, "\(h2)")
    }

    // MARK: - Keyframe selector

    /// Acceptance, rejection reasons and thinning of `KeyframeSelector`.
    private static func checkSelector(_ c: inout TXTestChecks) {
        var s = KeyframeSelector()
        let origin = SIMD3<Float>(0, 0, 0), moved = SIMD3<Float>(0.2, 0, 0)
        let d0 = s.consider(cameraToWorld: TXTestScenes.pose(yawDegrees: 0, translation: origin), timestamp: 0, exposureOffset: 0)
        c.expect("selector.firstAccepted", d0 == .accept, "\(d0)")
        let d1 = s.consider(cameraToWorld: TXTestScenes.pose(yawDegrees: 0, translation: origin), timestamp: 1, exposureOffset: 0)
        c.expect("selector.samePoseTooClose", d1 == .rejectTooClose, "\(d1)")
        let d2 = s.consider(cameraToWorld: TXTestScenes.pose(yawDegrees: 0, translation: moved), timestamp: 2, exposureOffset: 0)
        c.expect("selector.translationAccepted", d2 == .accept, "\(d2)")
        let d3 = s.consider(cameraToWorld: TXTestScenes.pose(yawDegrees: 15, translation: moved), timestamp: 3, exposureOffset: 0)
        c.expect("selector.rotationAccepted", d3 == .accept, "\(d3)")
        _ = s.consider(cameraToWorld: TXTestScenes.pose(yawDegrees: 15, translation: moved), timestamp: 4, exposureOffset: 0)
        let d4 = s.consider(cameraToWorld: TXTestScenes.pose(yawDegrees: 30, translation: moved), timestamp: 4.01, exposureOffset: 0)
        c.expect("selector.fastRotationBlur", d4 == .rejectBlur, "\(d4)")
        let d5 = s.consider(cameraToWorld: TXTestScenes.pose(yawDegrees: 30, translation: moved), timestamp: 5, exposureOffset: 3)
        c.expect("selector.exposure3EV", d5 == .rejectExposure, "\(d5)")
        let d6 = s.consider(cameraToWorld: TXTestScenes.pose(yawDegrees: 45, translation: moved), timestamp: 6, exposureOffset: 0)
        c.expect("selector.laterRotationAccepted", d6 == .accept, "\(d6)")
        let d7 = s.consider(cameraToWorld: TXTestScenes.pose(yawDegrees: 45, translation: SIMD3<Float>(1, 0, 0)),
                            timestamp: 6.05, exposureOffset: 0)
        c.expect("selector.tooSoon", d7 == .rejectTooSoon, "\(d7)")
        c.expect("selector.count", s.count == 4, "\(s.count)")

        var config = KeyframeSelector.Config()
        config.maxKeyframes = 3
        var t = KeyframeSelector(config: config)
        let xs: [Float] = [0, 0.2, 0.4, 0.6, 1.2]
        for (i, x) in xs.enumerated() {
            _ = t.consider(cameraToWorld: TXTestScenes.pose(yawDegrees: 0, translation: SIMD3<Float>(x, 0, 0)),
                           timestamp: Double(i), exposureOffset: nil)
        }
        c.expect("thinning.allAccepted", t.count == 5, "\(t.count)")
        let dropped: Int? = t.thinIfNeeded()
        c.expect("thinning.returnsIndex", dropped.map { $0 >= 1 && $0 <= 3 } ?? false, "\(String(describing: dropped))")
        c.expect("thinning.reducesCount", t.count == 4, "\(t.count)")
        _ = t.thinIfNeeded()
        c.expect("thinning.keepsFirstAndLast", t.count == 3 && t.keyframeTimestamps.first == 0 && t.keyframeTimestamps.last == 4,
                 "\(t.keyframeTimestamps)")
        c.expect("thinning.stopsAtMax", t.thinIfNeeded() == nil)
    }

    // MARK: - Sharpness and smoothing

    /// Sharpness of a flat image, weight range, and label smoothing on a hand-made strip.
    private static func checkSharpnessAndSmoothing(_ c: inout TXTestChecks) {
        var flat = TXRGBImage(width: 64, height: 48)
        for y in 0..<48 { for x in 0..<64 { flat.setPixel(x, y, SIMD3<Float>(128, 128, 128)) } }
        if let cg = flat.makeCGImage(), let luma = TXLumaImage(image: cg) {
            let s: Float = TXViewSelection.sharpness(of: luma)
            c.expect("sharpness.flatIsZero", abs(s) < 1e-6, "\(s)")
        } else {
            c.expect("sharpness.flatIsZero", false, "could not make the flat image")
        }
        let w: [Float] = TXViewSelection.sharpnessWeights([10, 100, 50, 0.1, 400])
        c.expect("sharpness.weightsInRange", w.count == 5 && w.allSatisfy { $0 >= 0.5 && $0 <= 1 }, "\(w)")
        c.expect("sharpness.blurryGetsHalf", w.count == 5 && w[3] == 0.5 && w[4] == 1, "\(w)")

        let strip: TXMesh = TXTestScenes.stripMesh()
        let geometry = TXFaceGeometry(mesh: strip)
        let adjacency = TXAdjacency(mesh: strip)
        let special = 3
        var offsets: [Int32] = [0]
        var list: [TXViewCandidate] = []
        for f in 0..<strip.faceCount {
            list.append(TXViewCandidate(keyframe: 0, cosine: 1.0, pixelsPerMeter: 1000))
            list.append(TXViewCandidate(keyframe: 1, cosine: f == special ? 1.05 : 0.9, pixelsPerMeter: 1000))
            offsets.append(Int32(list.count))
        }
        let vis = TXVisibility(offsets: offsets, candidates: list)
        let ones = [Float](repeating: 1, count: 2)
        let raw = TXViewSelection.select(visibility: vis, adjacency: adjacency, geometry: geometry, weights: ones,
                                         targetPixelsPerMeter: 1, smoothness: 0.35, iterations: 0)
        c.expect("smoothing.rawPicksB", raw.count == strip.faceCount && raw[special] == 1, "\(raw)")
        let smooth = TXViewSelection.select(visibility: vis, adjacency: adjacency, geometry: geometry, weights: ones,
                                            targetPixelsPerMeter: 1)
        c.expect("smoothing.outlierBecomesA", smooth.count == strip.faceCount && smooth[special] == 0, "\(smooth)")
        c.expect("smoothing.allA", smooth.allSatisfy { $0 == 0 }, "\(smooth)")
    }

    // MARK: - Cube and floor scene

    /// Rendering, visibility, view selection, charts, packing, full bakes and exposure.
    private static func checkScene(_ c: inout TXTestChecks) {
        let mesh: TXMesh = TXTestScenes.cubeAndFloorMesh()
        let cameras: [TXCamera] = TXTestScenes.sceneCameras()
        c.expect("scene.faceCount", mesh.faceCount == 176, "\(mesh.faceCount)")
        var images: [TXRGBImage] = []
        var keyframes: [TXKeyframe] = []
        for (k, cam) in cameras.enumerated() {
            let image = TXTestScenes.render(mesh: mesh, camera: cam)
            images.append(image)
            if let kf = TXTestScenes.keyframe(image: image, camera: cam, timestamp: Double(k)) { keyframes.append(kf) }
        }
        guard keyframes.count == cameras.count else {
            c.expect("scene.keyframes", false, "could not create keyframe images")
            return
        }
        let geometry = TXFaceGeometry(mesh: mesh)
        let adjacency = TXAdjacency(mesh: mesh)
        guard let vis = try? TXVisibilityBuilder.compute(mesh: mesh, geometry: geometry, cameras: cameras, options: TXOptions()) else {
            c.expect("scene.visibility", false, "visibility threw")
            return
        }
        let side: (Int) -> Range<Int> = { d in (d * TXTestScenes.trianglesPerSide)..<((d + 1) * TXTestScenes.trianglesPerSide) }
        c.expect("visibility.frontSeesPlusZ", side(4).allSatisfy { vis.candidate(forFace: $0, keyframe: 0) != nil })
        c.expect("visibility.frontMissesMinusZ", side(5).allSatisfy { vis.candidate(forFace: $0, keyframe: 0) == nil })
        c.expect("visibility.backSeesMinusZ", side(5).allSatisfy { vis.candidate(forFace: $0, keyframe: 3) != nil })
        c.expect("visibility.topSeesPlusY", side(2).allSatisfy { vis.candidate(forFace: $0, keyframe: 4) != nil })
        c.expect("visibility.bottomSeenByNobody", side(3).allSatisfy { vis.candidates(forFace: $0).isEmpty })
        let allCandidates: [TXViewCandidate] = vis.candidates
        c.expect("visibility.cosinesValid", allCandidates.allSatisfy { $0.cosine >= 0.25 && $0.keyframe >= 0 && $0.keyframe < 5 })

        // Pure scores: target 1 px/m saturates density, so the score is the cosine.
        let ones = [Float](repeating: 1, count: cameras.count)
        let pure = TXViewSelection.select(visibility: vis, adjacency: adjacency, geometry: geometry, weights: ones,
                                          targetPixelsPerMeter: 1, smoothness: 0, iterations: 0)
        var wrongSide = 0, notFrontal = 0
        for f in 0..<48 {
            let expected: Int32 = TXTestScenes.expectedKeyframeOfSide[f / TXTestScenes.trianglesPerSide]
            if pure.count != mesh.faceCount || pure[f] != expected { wrongSide += 1; continue }
            if let best = vis.candidates(forFace: f).max(by: { $0.cosine < $1.cosine }), best.keyframe != pure[f] { notFrontal += 1 }
        }
        c.expect("viewSelection.expectedCameraPerSide", wrongSide == 0, "\(wrongSide) cube faces with another camera")
        c.expect("viewSelection.mostFrontal", notFrontal == 0, "\(notFrontal) faces not on the most frontal camera")
        var sharp: [Float] = []
        for image in images {
            if let cg = image.makeCGImage(), let luma = TXLumaImage(image: cg) { sharp.append(TXViewSelection.sharpness(of: luma)) }
        }
        c.expect("sharpness.checkerPositive", sharp.count == 5 && sharp.allSatisfy { $0 > 0 }, "\(sharp)")

        checkCharts(&c, mesh: mesh, cameras: cameras, vis: vis, geometry: geometry, adjacency: adjacency)
        checkBakes(&c, mesh: mesh, keyframes: keyframes, geometry: geometry)

        // Exposure: keyframe 1 darkened by 0.7 should get a gain about 1/0.7 relative to keyframe 0.
        var lumas: [TXLumaImage?] = []
        var darkLumas: [TXLumaImage?] = []
        for (k, image) in images.enumerated() {
            lumas.append(image.makeCGImage().flatMap { TXLumaImage(image: $0) })
            let dark: TXRGBImage = k == 1 ? TXTestScenes.scaled(image, gain: 0.7) : image
            darkLumas.append(dark.makeCGImage().flatMap { TXLumaImage(image: $0) })
        }
        let equal = TXExposure.solveGains(visibility: vis, geometry: geometry, cameras: cameras, lumas: lumas)
        c.expect("exposure.equalNearOne", equal.count == 5 && equal.allSatisfy { abs($0 - 1) < 0.1 }, "\(equal)")
        let gains = TXExposure.solveGains(visibility: vis, geometry: geometry, cameras: cameras, lumas: darkLumas)
        let ratio: Float = gains.count == 5 && gains[0] > 0 ? gains[1] / gains[0] : 0
        c.expect("exposure.darkenedRatio", abs(ratio * 0.7 - 1) <= 0.1, "ratio \(ratio), expected \(1 / 0.7), gains \(gains)")
        let sorted = gains.sorted()
        c.expect("exposure.medianIsOne", sorted.count == 5 && abs(sorted[2] - 1) < 1e-3, "\(gains)")

        checkErrors(&c, mesh: mesh, keyframes: keyframes)
    }

    /// Chart layout bounds and packing of the scene's charts at 512 and 256 texels.
    private static func checkCharts(_ c: inout TXTestChecks, mesh: TXMesh, cameras: [TXCamera], vis: TXVisibility,
                                    geometry: TXFaceGeometry, adjacency: TXAdjacency) {
        let ones = [Float](repeating: 1, count: cameras.count)
        for size in [512, 256] {
            var source = TXViewSelection.select(visibility: vis, adjacency: adjacency, geometry: geometry,
                                                weights: ones, targetPixelsPerMeter: 80)
            let charts = TXChartBuilder.build(mesh: mesh, faceSource: &source, adjacency: adjacency, cameras: cameras,
                                              visibility: vis, geometry: geometry, texelsPerMeter: 80, maxChartSize: size)
            let name = "charts\(size)"
            c.expect("\(name).nonEmpty", !charts.isEmpty)
            let g = Float(TXChart.gutter)
            var outside = 0, tooBig = 0
            var owners = [Int](repeating: 0, count: mesh.faceCount)
            for chart in charts {
                if chart.width > size || chart.height > size { tooBig += 1 }
                for t in chart.cornerTexels where t.x < g - 1e-3 || t.y < g - 1e-3
                    || t.x > Float(chart.width) - g + 1e-3 || t.y > Float(chart.height) - g + 1e-3 {
                    outside += 1
                }
                for f in chart.faces where Int(f) >= 0 && Int(f) < owners.count { owners[Int(f)] += 1 }
            }
            c.expect("\(name).cornersInsideGutter", outside == 0, "\(outside) corners outside")
            c.expect("\(name).fitMaxSize", tooBig == 0, "\(tooBig) charts too big")
            var wrongOwner = 0
            for f in 0..<min(mesh.faceCount, source.count) where owners[f] != (source[f] >= 0 ? 1 : 0) { wrongOwner += 1 }
            c.expect("\(name).eachTexturedFaceOnce", wrongOwner == 0, "\(wrongOwner) faces")
            guard let packed = TXAtlasPacker.packCharts(charts, atlasSize: size, maxAtlases: 8) else {
                c.expect("\(name).pack", false, "packCharts returned nil")
                continue
            }
            let sizes: [SIMD2<Int>] = packed.charts.map { SIMD2<Int>($0.width, $0.height) }
            c.expect("\(name).noOverlap", TXTestScenes.overlappingPairs(sizes: sizes, placements: packed.packing.placements) == 0)
            var inside = packed.packing.placements.count == sizes.count
            for (i, p) in packed.packing.placements.enumerated() where i < sizes.count {
                if p.x < 0 || p.y < 0 || p.x + sizes[i].x > size || p.y + sizes[i].y > size
                    || p.atlas < 0 || p.atlas >= packed.packing.atlasCount { inside = false }
            }
            c.expect("\(name).placementsInside", inside)
            if size == 256 {
                c.expect("charts256.spills", packed.packing.atlasCount > 1, "\(packed.packing.atlasCount) atlases")
            }
        }
    }

    // MARK: - Full bakes

    /// Full bakes at 512 (one atlas, colors against ground truth) and 256 (spill to several atlases).
    private static func checkBakes(_ c: inout TXTestChecks, mesh: TXMesh, keyframes: [TXKeyframe], geometry: TXFaceGeometry) {
        for size in [512, 256] {
            var options = TXOptions()
            options.atlasSize = size
            options.texelsPerMeter = 80
            options.normalizeExposure = false
            let name = "bake\(size)"
            let result: TXResult
            do {
                result = try TextureBaker(options: options).bake(mesh: mesh, keyframes: keyframes, progress: nil)
            } catch {
                c.expect("\(name).succeeds", false, "threw \(error)")
                continue
            }
            let n: Int = mesh.faceCount
            let countsOK: Bool = result.texcoords.count == 3 * n && result.faceAtlas.count == n && result.faceSource.count == n
            c.expect("\(name).arrayCounts", countsOK,
                     "texcoords \(result.texcoords.count), faceAtlas \(result.faceAtlas.count), faceSource \(result.faceSource.count)")
            if !countsOK { continue }
            var inRange = true, atlasOK = true
            var texturedArea: Float = 0
            for f in 0..<n where result.faceSource[f] >= 0 {
                texturedArea += geometry.areas[f]
                if Int(result.faceAtlas[f]) >= result.atlases.count { atlasOK = false }
                for k in 0..<3 {
                    let t: SIMD2<Float> = result.texcoords[3 * f + k]
                    if !(t.x >= 0 && t.x <= 1 && t.y >= 0 && t.y <= 1) { inRange = false }
                }
            }
            c.expect("\(name).texcoordsInUnitSquare", inRange)
            c.expect("\(name).faceAtlasValid", atlasOK)
            let sizes: [SIMD2<Int>] = result.atlases.map { SIMD2<Int>($0.width, $0.height) }
            c.expect("\(name).atlasWidth", sizes.allSatisfy { $0.x == size && $0.y <= size }, "\(sizes)")
            c.expect("\(name).noTexelShared", TXTestScenes.texelClashes(result: result, sizes: sizes) == 0)
            let expected: Float = geometry.totalArea > 0 ? texturedArea / geometry.totalArea : 0
            c.expect("\(name).coverageMatchesArea", abs(result.coverage - expected) < 1e-3,
                     "coverage \(result.coverage), textured area fraction \(expected)")
            if size == 256 {
                c.expect("bake256.spills", result.atlases.count > 1, "\(result.atlases.count) atlases")
                continue
            }
            c.expect("bake512.oneAtlas", result.atlases.count == 1, "\(result.atlases.count) atlases")
            c.expect("bake512.coverageRange", result.coverage > 0.5 && result.coverage < 0.9, "\(result.coverage)")
            c.expect("bake512.bottomUntextured", (24..<32).allSatisfy { result.faceSource[$0] == -1 })
            c.expect("bake512.topTextured", (16..<24).allSatisfy { result.faceSource[$0] >= 0 })
            let errors: [Float] = TXTestScenes.colorErrors(result: result, mesh: mesh, geometry: geometry, count: 200)
            c.expect("bake512.colorSamples", errors.count == 200, "only \(errors.count) sample points")
            let bad: Int = errors.filter { $0 > 12 }.count
            let worst: Float = errors.max() ?? 0
            c.expect("bake512.colorsMatchGroundTruth", errors.count > 0 && bad * 50 <= errors.count,
                     "\(bad) of \(errors.count) points off by more than 12, max error \(worst)")
        }
    }

    // MARK: - Errors

    /// Invalid meshes, missing keyframes and cancellation make `bake` throw the right error.
    private static func checkErrors(_ c: inout TXTestChecks, mesh: TXMesh, keyframes: [TXKeyframe]) {
        let empty: TXError? = bakeError(TextureBaker(), TXMesh(positions: [], indices: []), keyframes)
        c.expect("errors.emptyMesh", isInvalidMesh(empty), "\(String(describing: empty))")
        let triangle: [SIMD3<Float>] = [SIMD3<Float>(0, 0, -1), SIMD3<Float>(1, 0, -1), SIMD3<Float>(0, 1, -1)]
        let outOfRange: TXError? = bakeError(TextureBaker(), TXMesh(positions: triangle, indices: [0, 1, 5]), keyframes)
        c.expect("errors.indexOutOfRange", isInvalidMesh(outOfRange), "\(String(describing: outOfRange))")
        let none: TXError? = bakeError(TextureBaker(), mesh, [])
        c.expect("errors.noKeyframes", none == TXError.noKeyframes, "\(String(describing: none))")
        let baker = TextureBaker()
        baker.cancel()
        let cancelled: TXError? = bakeError(baker, mesh, keyframes)
        c.expect("errors.cancelled", cancelled == TXError.cancelled, "\(String(describing: cancelled))")
    }

    /// The `TXError` thrown by a bake, or nil when it succeeds or throws something else.
    private static func bakeError(_ baker: TextureBaker, _ mesh: TXMesh, _ keyframes: [TXKeyframe]) -> TXError? {
        do {
            _ = try baker.bake(mesh: mesh, keyframes: keyframes, progress: nil)
            return nil
        } catch let error as TXError {
            return error
        } catch {
            return nil
        }
    }

    /// True for `TXError.invalidMesh` with any message.
    private static func isInvalidMesh(_ error: TXError?) -> Bool {
        guard let error = error else { return false }
        switch error {
        case .invalidMesh(_):
            return true
        default:
            return false
        }
    }
}
