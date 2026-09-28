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

        // Exposure: keyframe 1 darkened by 0.7 should get a gain about 1/0.7 relative to keyframe 0.
        var lumas: [TXLumaImage?] = []
        var darkLumas: [TXLumaImage?] = []
        var darkKeyframes: [TXKeyframe] = []
        for (k, image) in images.enumerated() {
            let dark: TXRGBImage = k == 1 ? TXTestScenes.scaled(image, gain: 0.7) : image
            lumas.append(image.makeCGImage().flatMap { TXLumaImage(image: $0) })
            darkLumas.append(dark.makeCGImage().flatMap { TXLumaImage(image: $0) })
            if let kf = TXTestScenes.keyframe(image: dark, camera: cameras[k], timestamp: Double(k)) {
                darkKeyframes.append(kf)
            }
        }
        let equal = TXExposure.solveGains(visibility: vis, geometry: geometry, cameras: cameras, lumas: lumas)
        c.expect("exposure.equalNearOne", equal.count == 5 && equal.allSatisfy { abs($0 - 1) < 0.1 }, "\(equal)")
        let gains = TXExposure.solveGains(visibility: vis, geometry: geometry, cameras: cameras, lumas: darkLumas)
        let ratio: Float = gains.count == 5 && gains[0] > 0 ? gains[1] / gains[0] : 0
        c.expect("exposure.darkenedRatio", abs(ratio * 0.7 - 1) <= 0.1, "ratio \(ratio), expected \(1 / 0.7), gains \(gains)")
        let sorted = gains.sorted()
        c.expect("exposure.medianIsOne", sorted.count == 5 && abs(sorted[2] - 1) < 1e-3, "\(gains)")

        checkBakes(&c, mesh: mesh, keyframes: keyframes, darkKeyframes: darkKeyframes, geometry: geometry)
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

    /// Full bakes: 1024 texels (one atlas, colors against ground truth), 256 texels (spill to
    /// several atlases), and 1024 texels from keyframes with keyframe 1 darkened by 0.7 and
    /// exposure normalization on (colors must still match the ground truth).
    private static func checkBakes(_ c: inout TXTestChecks, mesh: TXMesh, keyframes: [TXKeyframe],
                                   darkKeyframes: [TXKeyframe], geometry: TXFaceGeometry) {
        if let result = bake(&c, name: "bake1024", size: 1024, normalize: false, mesh: mesh, keyframes: keyframes,
                             geometry: geometry) {
            c.expect("bake1024.oneAtlas", result.atlases.count == 1, "\(result.atlases.count) atlases")
            // 5 of 6 cube sides plus most of the floor; the cube bottom (1 of 26 m^2) is never seen.
            c.expect("bake1024.coverageRange", result.coverage > 0.5 && result.coverage < 0.96, "\(result.coverage)")
            c.expect("bake1024.bottomUntextured", (24..<32).allSatisfy { result.faceSource[$0] == -1 })
            c.expect("bake1024.topTextured", (16..<24).allSatisfy { result.faceSource[$0] >= 0 })
            checkColors(&c, name: "bake1024", result: result, mesh: mesh, geometry: geometry)
        }
        if let result = bake(&c, name: "bake256", size: 256, normalize: false, mesh: mesh, keyframes: keyframes,
                             geometry: geometry) {
            c.expect("bake256.spills", result.atlases.count > 1, "\(result.atlases.count) atlases")
        }
        if darkKeyframes.count == keyframes.count,
           let result = bake(&c, name: "bakeExposure", size: 1024, normalize: true, mesh: mesh,
                             keyframes: darkKeyframes, geometry: geometry) {
            checkColors(&c, name: "bakeExposure", result: result, mesh: mesh, geometry: geometry)
        } else if darkKeyframes.count != keyframes.count {
            c.expect("bakeExposure.keyframes", false, "could not create the darkened keyframes")
        }
    }

    /// Runs one bake at `size` texels (80 texels per meter) and the checks every bake must pass:
    /// array sizes, texcoords in the unit square, valid atlas indices, atlas sizes, no atlas
    /// texel shared by two faces, and coverage equal to the textured area fraction. Returns the
    /// result, or nil when the bake threw or its arrays have the wrong size.
    private static func bake(_ c: inout TXTestChecks, name: String, size: Int, normalize: Bool, mesh: TXMesh,
                             keyframes: [TXKeyframe], geometry: TXFaceGeometry) -> TXResult? {
        var options = TXOptions()
        options.atlasSize = size
        options.texelsPerMeter = 80
        options.normalizeExposure = normalize
        let result: TXResult
        do {
            result = try TextureBaker(options: options).bake(mesh: mesh, keyframes: keyframes, progress: nil)
        } catch {
            c.expect("\(name).succeeds", false, "threw \(error)")
            return nil
        }
        let n: Int = mesh.faceCount
        let countsOK: Bool = result.texcoords.count == 3 * n && result.faceAtlas.count == n && result.faceSource.count == n
        c.expect("\(name).arrayCounts", countsOK,
                 "texcoords \(result.texcoords.count), faceAtlas \(result.faceAtlas.count), faceSource \(result.faceSource.count)")
        if !countsOK { return nil }
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
        return result
    }

    /// Baked colors against the ground-truth checkerboard at 200 surface points: at most 1 in 50
    /// may differ by more than 12 (of 255) in any channel.
    private static func checkColors(_ c: inout TXTestChecks, name: String, result: TXResult, mesh: TXMesh,
                                    geometry: TXFaceGeometry) {
        let errors: [Float] = TXTestScenes.colorErrors(result: result, mesh: mesh, geometry: geometry, count: 200)
        c.expect("\(name).colorSamples", errors.count == 200, "only \(errors.count) sample points")
        let bad: Int = errors.filter { $0 > 12 }.count
        let worst: Float = errors.max() ?? 0
        c.expect("\(name).colorsMatchGroundTruth", errors.count > 0 && bad * 50 <= errors.count,
                 "\(bad) of \(errors.count) points off by more than 12, max error \(worst)")
    }
}
