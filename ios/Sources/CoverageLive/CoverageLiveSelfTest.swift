import Foundation
import simd

/// Plain-Swift checks for CoverageLive (no XCTest), docs/MODULES.md 3.31 items 1 to 23. Pure
/// helpers are tested directly; the recorder is driven hardware-free: `MeshStore.ingest(_:)`
/// after `beginRecording` into a folder under `FileManager.default.temporaryDirectory` (removed
/// at the end), observations through the internal `ingest(observation:)` and `waitForWork()`.
/// No ARKit session, camera or network; fixed ids, poses and times. The ARFrame path is covered
/// on device. `run()` returns one line per failing check ("name: detail"); empty means all passed.
enum CoverageLiveSelfTest {
    /// Failing checks as "name: detail".
    static func run() -> [String] {
        let checks = Checks()
        faceChecks(checks)
        visibilityChecks(checks)
        boundaryChecks(checks)
        missingChecks(checks)
        minimapChecks(checks)
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoverageLiveSelfTest-" + UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: base) }
            try recorderChecks(checks, base: base)
            try shellChecks(checks, base: base)
            seedChecks(checks, base: base)
        } catch {
            checks.check("setup.folders", false, error.localizedDescription)
        }
        return checks.failures
    }

    // MARK: 1 to 3: faces

    /// Areas, centroids, normal orientation, class, translation, bounds and degenerate triangles.
    static func faceChecks(_ t: Checks) {
        let faces = CoverageLiveFaces.faces(of: square(anchor: 1))
        t.check("faces.count", faces.count == 2, "\(faces.count)")
        if faces.count == 2 {
            let areas = abs(faces[0].area - 0.5) < 1e-5 && abs(faces[1].area - 0.5) < 1e-5
            t.check("faces.area", areas, "\(faces[0].area) \(faces[1].area)")
            let c0 = near(faces[0].centroid, SIMD3<Float>(2.0 / 3.0, 1.0 / 3.0, 0))
            let c1 = near(faces[1].centroid, SIMD3<Float>(1.0 / 3.0, 2.0 / 3.0, 0))
            t.check("faces.centroids", c0 && c1, "\(faces[0].centroid) \(faces[1].centroid)")
            t.check("faces.classes", faces[0].surface == .wall && faces[1].surface == .floor)
        }

        let up = SIMD3<Float>(0, 0, 1)
        let flipped = CoverageLiveFaces.faces(of: reversedTriangle(normals: [up, up, up]))
        t.check("faces.normalFollowsVertexNormals", flipped.count == 1 && near(flipped[0].normal, up),
                "\(flipped.first?.normal ?? .zero)")
        let kept = CoverageLiveFaces.faces(of: reversedTriangle(normals: [.zero, .zero, .zero]))
        t.check("faces.zeroNormalsKeepCross", kept.count == 1 && near(kept[0].normal, -up),
                "\(kept.first?.normal ?? .zero)")
        let noClasses = CoverageLiveFaces.faces(of: reversedTriangle(normals: []))
        t.check("faces.noClassesIsNone", noClasses.first?.surface == SurfaceClass.none)

        let offset = SIMD3<Float>(1, 2, 3)
        let moved = square(anchor: 2, transform: translation(offset), degenerate: true)
        let movedFaces = CoverageLiveFaces.faces(of: moved)
        let shifted = movedFaces.count == 3 && near(movedFaces[0].centroid, SIMD3<Float>(2.0 / 3.0, 1.0 / 3.0, 0) + offset)
        t.check("faces.translation", shifted, "\(movedFaces.first?.centroid ?? .zero)")
        let bounds = CoverageLiveFaces.worldBounds(moved.worldPositions)
        t.check("faces.worldBounds", near(bounds.min, SIMD3<Float>(1, 2, 3)) && near(bounds.max, SIMD3<Float>(2, 3, 3)),
                "\(bounds.min) \(bounds.max)")
        let degenerate = movedFaces.count == 3 && movedFaces[2].area == 0 && movedFaces[2].normal == .zero
        t.check("faces.degenerateAreaZero", degenerate)
        let outOfRange = MeshChunk(anchorID: fixedID(3), transform: matrix_identity_float4x4, updateCount: 0,
                                   positions: [SIMD3<Float>(0, 0, 0)], indices: [0, 5, 7])
        t.check("faces.outOfRangeAreaZero", CoverageLiveFaces.faces(of: outOfRange).first?.area == 0)

        let grid = CoverageGrid()
        let keys = CoverageLiveFaces.keys(movedFaces, grid: grid)
        t.check("keys.perFace", keys.perFace.count == 3 && keys.perFace[0] == grid.key(for: movedFaces[0].centroid))
        t.check("keys.uniqueSkipsAreaZero", keys.unique.count <= 2 && !keys.unique.isEmpty, "\(keys.unique.count)")
    }

    // MARK: 4 to 7: visibility and rate

    /// Cone test, projection test, thermal rate and the due rule.
    static func visibilityChecks(_ t: Checks) {
        let obs = observation(at: .zero, looking: SIMD3<Float>(0, 0, -1), time: 0)
        let half = SIMD3<Float>(repeating: 0.5)
        let ahead = SIMD3<Float>(0, 0, -2)
        let behind = SIMD3<Float>(0, 0, 2)
        let far = SIMD3<Float>(0, 0, -8)
        t.check("visible.ahead", CoverageLiveFaces.mayBeVisible(boundsMin: ahead - half, boundsMax: ahead + half, observation: obs))
        t.check("visible.behind", !CoverageLiveFaces.mayBeVisible(boundsMin: behind - half, boundsMax: behind + half, observation: obs))
        t.check("visible.tooFar", !CoverageLiveFaces.mayBeVisible(boundsMin: far - half, boundsMax: far + half, observation: obs))

        let facing = CoverageFace(centroid: ahead, normal: SIMD3<Float>(0, 0, 1), area: 0.01, surface: .wall)
        let away = CoverageFace(centroid: ahead, normal: SIMD3<Float>(0, 0, -1), area: 0.01, surface: .wall)
        let close = CoverageFace(centroid: SIMD3<Float>(0, 0, -0.1), normal: SIMD3<Float>(0, 0, 1), area: 0.01, surface: .wall)
        t.check("inView.facing", CoverageLiveFaces.isInView(facing, observation: obs))
        t.check("inView.facingAway", !CoverageLiveFaces.isInView(away, observation: obs))
        t.check("inView.tooClose", !CoverageLiveFaces.isInView(close, observation: obs))

        let rates = [ThermalLevel.nominal, .fair, .serious, .critical].map {
            CoverageLiveFaces.effectiveHz(maxHz: 3, policy: ThermalPolicy.forLevel($0))
        }
        t.check("rate.thermalLadder", rates == [3, 3, 1, 0], "\(rates)")
        t.check("rate.cappedByOptions", CoverageLiveFaces.effectiveHz(maxHz: 2, policy: ThermalPolicy.forLevel(.nominal)) == 2)

        t.check("due.tooSoon", !CoverageLiveFaces.isDue(timestamp: 100.2, last: 100, hz: 3))
        t.check("due.after", CoverageLiveFaces.isDue(timestamp: 100.34, last: 100, hz: 3))
        t.check("due.first", CoverageLiveFaces.isDue(timestamp: 5, last: nil, hz: 3))
        t.check("due.zeroHz", !CoverageLiveFaces.isDue(timestamp: 500, last: 100, hz: 0))
    }

    // MARK: 8 to 10: live room boundary and exclusions

    /// Walls, hull, heights, the floor polygon frame, exclusion boxes and expected points.
    static func boundaryChecks(_ t: Checks) {
        let bare = CoverageLiveBoundary.boundary(from: room())
        t.check("boundary.walls", bare?.walls.count == 4, "\(bare?.walls.count ?? -1)")
        let hullArea = bare.map { Polygon2D(points: $0.floorPolygon).area } ?? 0
        t.check("boundary.hullArea", abs(hullArea - 20) < 1e-3, "\(hullArea)")
        let height = bare.map { $0.ceilingY - $0.floorY } ?? 0
        t.check("boundary.height", abs(height - 2.5) < 1e-4 && abs((bare?.floorY ?? 1)) < 1e-4, "\(height)")
        t.check("boundary.ceilingReusesFloor", bare?.ceilingPolygon.isEmpty == true)

        let floored = CoverageLiveBoundary.boundary(from: room(withFloor: true))
        let polygon = floored?.floorPolygon ?? []
        let hasMinus3 = polygon.contains { abs($0.y + 3) < 1e-4 }
        let hasPlus3 = polygon.contains { abs($0.y - 3) < 1e-4 }
        t.check("boundary.floorPolygonFrame", polygon.count == 4 && hasMinus3 && !hasPlus3, "\(polygon)")

        var oneWall = room()
        oneWall.walls = Array(oneWall.walls.prefix(1))
        t.check("boundary.needsTwoWalls", CoverageLiveBoundary.boundary(from: oneWall) == nil)

        let all = room(openings: [window()] + doorAndOpening())
        let boxes = CoverageLiveBoundary.exclusions(from: all, margin: 0)
        t.check("exclusions.onePerOpening", boxes.count == 3, "\(boxes.count)")
        let grown = CoverageLiveBoundary.exclusions(from: room(openings: [window()]), margin: 0.1)
        let grownHalf = grown.first?.halfExtents ?? .zero
        t.check("exclusions.margin", near(grownHalf, SIMD3<Float>(0.6, 0.6, 0.25)), "\(grownHalf)")

        guard let boundary = bare else { return }
        let samples = ExpectedSurfaces.samples(for: boundary)
        let windowBoxes = CoverageLiveBoundary.exclusions(from: room(openings: [window()]), margin: 0)
        let kept = CoverageLiveBoundary.expectedPoints(samples, exclusions: windowBoxes)
        let dropped = samples.count - kept.count
        t.check("expectedPoints.windowDropped", dropped >= 20 && dropped <= 30, "\(dropped) dropped")
        t.check("expectedPoints.noExclusions", CoverageLiveBoundary.expectedPoints(samples, exclusions: []).count == samples.count)
    }

    // MARK: 11 to 13: missing areas

    /// D19 filter, nearby rules and ages.
    static func missingChecks(_ t: Checks) {
        let boxes = CoverageLiveBoundary.exclusions(from: room(openings: [window()]), margin: 0.1)
        let inWindow = area(SIMD3<Float>(0.05, 1.5, -2.5))
        let beside = area(SIMD3<Float>(1.05, 1.5, -2.5))
        let glass = area(SIMD3<Float>(-1.5, 1.5, 2.5), surface: .window)
        let kept = CoverageLiveMissing.filtered([inWindow, beside, glass], exclusions: boxes)
        t.check("filtered.window", kept.count == 1 && near(kept[0].centroid, beside.centroid), "\(kept.count) kept")

        let options = CoverageLiveOptions()
        let camera = SIMD3<Float>(0, 1.4, 0)
        let near2 = area(SIMD3<Float>(2, 0, 0))
        let far4 = area(SIMD3<Float>(4, 0, 0))
        let young = area(SIMD3<Float>(1, 0, 0))
        let early = CoverageLiveMissing.nearby([near2, far4, young], ages: [20, 20, 5], camera: camera, elapsed: 20, options: options)
        t.check("nearby.earlyEmpty", early.isEmpty)
        let late = CoverageLiveMissing.nearby([near2, far4, young], ages: [20, 20, 5], camera: camera, elapsed: 40, options: options)
        t.check("nearby.rules", late.count == 1 && near(late[0].centroid, near2.centroid), "\(late.count)")
        let distances: [Float] = [2.5, 0.5, 1.5, 1.0, 2.0]
        let many = distances.map { area(SIMD3<Float>($0, 2.4, 0), surface: .ceiling) }
        let picked = CoverageLiveMissing.nearby(many, ages: [30, 30, 30, 30, 30], camera: camera, elapsed: 60, options: options)
        let order = picked.map { $0.centroid.x }
        t.check("nearby.nearestThree", order == [0.5, 1.0, 1.5], "\(order)")

        var ages = CoverageLiveMissingAges()
        let a0 = area(SIMD3<Float>(1, 1, 1))
        let first = ages.update([a0], now: 10)
        let moved = ages.update([area(SIMD3<Float>(1.1, 1, 1))], now: 15)
        t.check("ages.keepWhenMoved", first == [0] && moved == [5], "\(first) \(moved)")
        let gone = ages.update([], now: 16)
        let back = ages.update([a0], now: 17)
        t.check("ages.resetAfterGone", gone.isEmpty && back == [0], "\(back)")

        let completeWhenCovered = CoverageLiveMissing.isComplete(observedFraction: 0.95, missingCount: 0)
        let incompleteWithMissing = !CoverageLiveMissing.isComplete(observedFraction: 0.95, missingCount: 1)
        let incompleteBelow = !CoverageLiveMissing.isComplete(observedFraction: 0.85, missingCount: 0)
        t.check("complete.rule", completeWhenCovered && incompleteWithMissing && incompleteBelow)
        let faces = CoverageLiveFaces.faces(of: square(anchor: 4))
        t.check("greenFraction.half", CoverageLiveMissing.greenFraction(faces: faces, states: [.green, .yellow]) == 0.5)
        let tiny = [CoverageFace(centroid: .zero, normal: SIMD3<Float>(0, 1, 0), area: 0.01, surface: .floor)]
        t.check("greenFraction.tinyNil", CoverageLiveMissing.greenFraction(faces: tiny, states: [.green]) == nil)
    }

    // MARK: 21 and 22: minimap and heading

    /// Cell codes, cell size doubling, wall frame, heading and the camera marker.
    static func minimapChecks(_ t: Checks) {
        let voxels: [(key: SIMD3<Int32>, state: CoverageState)] = [(key: SIMD3<Int32>(0, 0, 0), state: .green),
                                                                    (key: SIMD3<Int32>(20, 5, 0), state: .yellow)]
        let missing = SIMD3<Float>(0.55, 0, 1.55)
        let map = CoverageLiveMinimap.make(voxels: voxels, voxelSize: 0.1, boundary: nil, unobservedExpected: [missing],
                                           camera: nil, cellSize: 0.25, maxCells: 96)
        let greenCell = CoverageLiveMinimap.cellIndex(of: SIMD2<Float>(0.05, -0.05), in: map)
        let yellowCell = CoverageLiveMinimap.cellIndex(of: SIMD2<Float>(2.05, -0.05), in: map)
        let missingCell = CoverageLiveMinimap.cellIndex(of: PlanAxes.toPlan(missing), in: map)
        let codes = [greenCell, yellowCell, missingCell].map { index -> UInt8 in
            guard let index else { return 255 }
            return map.cell(x: index.x, y: index.y).rawValue
        }
        t.check("minimap.codes", codes == [3, 2, 1], "\(codes)")
        let emptyCells = map.cells.filter { $0 == 0 }.count
        t.check("minimap.restEmpty", emptyCells == map.cells.count - 3, "\(emptyCells) of \(map.cells.count)")

        let wide: [(key: SIMD3<Int32>, state: CoverageState)] = [(key: SIMD3<Int32>(0, 0, 0), state: .green),
                                                                  (key: SIMD3<Int32>(399, 0, 0), state: .green)]
        let big = CoverageLiveMinimap.make(voxels: wide, voxelSize: 0.1, boundary: nil, unobservedExpected: [],
                                           camera: nil, cellSize: 0.25, maxCells: 96)
        t.check("minimap.cellDoubling", big.cellSize == 0.5 && big.width <= 96 && big.height <= 96,
                "cell \(big.cellSize) size \(big.width) x \(big.height)")

        let wall = CoverageWall(start: SIMD2<Float>(0, 2), end: SIMD2<Float>(3, 2), baseY: 0, height: 2.5)
        let boundary = CoverageRoomBoundary(walls: [wall], floorPolygon: [], floorY: 0, ceilingPolygon: [], ceilingY: 2.5)
        let walled = CoverageLiveMinimap.make(voxels: [], voxelSize: 0.1, boundary: boundary, unobservedExpected: [],
                                              camera: nil, cellSize: 0.25, maxCells: 96)
        let planWall = walled.walls.first ?? []
        t.check("minimap.wallFrame", planWall == [Vec2(x: 0, y: -2), Vec2(x: 3, y: -2)], "\(planWall)")
        let none = CoverageLiveMinimap.make(voxels: [], voxelSize: 0.1, boundary: nil, unobservedExpected: [],
                                            camera: nil, cellSize: 0.25, maxCells: 96)
        t.check("minimap.emptyInput", none.width == 0 && none.height == 0 && none.cells.isEmpty)

        let identity = CoverageLiveMinimap.heading(cameraToWorld: matrix_identity_float4x4)
        t.check("heading.identity", angleDifference(identity, .pi / 2) < 1e-4, "\(identity)")
        let down = CoverageLiveMinimap.heading(cameraToWorld: camera(at: .zero, looking: SIMD3<Float>(0, -1, 0)))
        t.check("heading.lookingDownUsesTopEdge", angleDifference(down, .pi) < 1e-4, "\(down)")
        let east = CoverageLiveMinimap.heading(cameraToWorld: camera(at: .zero, looking: SIMD3<Float>(1, -0.2, 0)))
        t.check("heading.east", angleDifference(east, 0) < 1e-4, "\(east)")
        let placed = camera(at: SIMD3<Float>(1, 1.4, 2), looking: SIMD3<Float>(0, 0, -1))
        let marker = CoverageLiveMinimap.make(voxels: voxels, voxelSize: 0.1, boundary: nil, unobservedExpected: [],
                                              camera: placed, cellSize: 0.25, maxCells: 96)
        t.check("minimap.cameraMarker", marker.camera == Vec2(x: 1, y: -2) && marker.heading != nil,
                "\(String(describing: marker.camera))")
    }
}
