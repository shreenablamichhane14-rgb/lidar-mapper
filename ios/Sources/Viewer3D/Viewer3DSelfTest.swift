import Foundation
import CoreGraphics
import simd

/// Plain-Swift checks for the viewer (no XCTest, no ARView, no RealityKit), run at launch like
/// the other module self-tests. `run()` returns one line per failing case; empty means all
/// passed. Covers the pure builders, the vertex packer, the orbit math, CPU picking and the
/// UV checker image. Meshes are tiny, so a run takes a few milliseconds plus about 50 ms for
/// the checker JPEG, written to and removed from a temporary subfolder.
enum Viewer3DSelfTest {
    /// Fewer checks than this means a section stopped early without reporting.
    private static let minimumChecks = 40

    /// Collects failing assertions and counts every check.
    final class Recorder {
        /// Failure lines, "name: detail".
        var failures: [String] = []
        /// Number of checks run so far.
        var count = 0

        /// Records a failure when `condition` is false.
        func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
            count += 1
            if !condition { failures.append("\(name): failed \(detail())") }
        }

        /// Records a failure when `actual` is farther than `tolerance` from `expected`.
        func near(_ name: String, _ actual: Float, _ expected: Float, _ tolerance: Float) {
            count += 1
            if !(abs(actual - expected) <= tolerance) { failures.append("\(name): expected \(expected), got \(actual)") }
        }
    }

    /// Failing cases as "name: detail".
    static func run() -> [String] {
        let r = Recorder()
        typeCases(r)
        tileCases(r)
        meshPartCases(r)
        boxCases(r)
        expandCases(r)
        packCases(r)
        cameraCases(r)
        framingCases(r)
        pickingCases(r)
        checkerCases(r)
        if r.failures.isEmpty && r.count < minimumChecks {
            r.failures.append("selfTest: only \(r.count) cases ran")
        }
        return r.failures
    }

    // MARK: - Fixtures

    /// A floor strip 6 m long (x) and 1 m deep (z) plus a 1 m tall back wall at z = 0: a
    /// 6 x 1 x 1 m strip of 1 m squares, 24 triangles.
    static func stripMesh() -> TriangleMesh {
        var positions: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        for i in 0...6 {
            let x = Float(i)
            positions.append(SIMD3<Float>(x, 0, 0))   // 4i: floor front
            positions.append(SIMD3<Float>(x, 0, 1))   // 4i + 1: floor back
            positions.append(SIMD3<Float>(x, 0, 0))   // 4i + 2: wall bottom
            positions.append(SIMD3<Float>(x, 1, 0))   // 4i + 3: wall top
        }
        for i in 0..<6 {
            let a = UInt32(4 * i), n = UInt32(4 * (i + 1))
            indices.append(contentsOf: [a, n, n + 1, a, n + 1, a + 1])
            indices.append(contentsOf: [a + 2, n + 2, n + 3, a + 2, n + 3, a + 3])
        }
        return TriangleMesh(positions: positions, indices: indices)
    }

    /// Six triangles inside one 1 m square (one tile): a fan around the square's center.
    static func squareMesh() -> TriangleMesh {
        let positions: [SIMD3<Float>] = [
            SIMD3<Float>(0.5, 0, 0.5),
            SIMD3<Float>(0, 0, 0), SIMD3<Float>(0.5, 0, 0), SIMD3<Float>(1, 0, 0),
            SIMD3<Float>(1, 0, 1), SIMD3<Float>(0.5, 0, 1), SIMD3<Float>(0, 0, 1),
        ]
        let indices: [UInt32] = [0, 1, 2, 0, 2, 3, 0, 3, 4, 0, 4, 5, 0, 5, 6, 0, 6, 1]
        return TriangleMesh(positions: positions, indices: indices)
    }

    /// Palette used by the mesh part cases.
    static let palette: [UInt8: SIMD4<Float>] = [
        0: SIMD4<Float>(0.5, 0.5, 0.5, 1),
        1: SIMD4<Float>(1, 0, 0, 1),
        2: SIMD4<Float>(0, 1, 0, 1),
        3: SIMD4<Float>(0, 0, 1, 1),
    ]

    /// Inferred color used by the mesh part cases.
    static let inferred = SIMD4<Float>(1, 0.6, 0, 1)

    /// A single triangle part in the z = 0 plane.
    static func trianglePart(normals: [SIMD3<Float>], uvs: [SIMD2<Float>] = []) -> ViewerPart {
        ViewerPart(id: "tri", positions: [SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0)],
                   normals: normals, uvs: uvs, indices: [0, 1, 2], material: .unlit(SIMD4<Float>(1, 1, 1, 1)), layer: .raw)
    }

    /// Float at a byte offset of packed data (offsets are multiples of 4).
    static func floatAt(_ data: Data, _ offset: Int) -> Float {
        guard offset >= 0, offset + 4 <= data.count else { return .nan }
        return data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: Float.self) }
    }

    // MARK: - Cases

    /// Display style titles and default layer visibility.
    static func typeCases(_ r: Recorder) {
        r.check("style.titles", ViewerDisplayStyle.allCases.allSatisfy { !$0.title.isEmpty })
        r.check("layer.occludedHidden", !ViewerLayer.defaultVisible.contains(.cleanOccluded))
        r.check("layer.othersVisible", ViewerLayer.defaultVisible.count == ViewerLayer.allCases.count - 1)
        r.check("material.color", ViewerMaterial.lit(SIMD4<Float>(1, 2, 3, 4)).color == SIMD4<Float>(1, 2, 3, 4))
    }

    /// `ViewerContentBuilder.tiles`.
    static func tileCases(_ r: Recorder) {
        let strip = stripMesh()
        let tiles = ViewerContentBuilder.tiles(strip, tileSize: ViewerContentBuilder.tileSize)
        r.check("tiles.stripGivesThree", tiles.count == 3, "\(tiles.count)")
        let all = tiles.flatMap { $0 }.sorted()
        r.check("tiles.everyFaceOnce", all == Array(0..<strip.triangleCount), "\(all.count)")
        r.check("tiles.eightFacesEach", tiles.allSatisfy { $0.count == 8 })
        var broken = strip
        broken.indices[0] = 999
        let brokenTiles = ViewerContentBuilder.tiles(broken, tileSize: 2)
        r.check("tiles.skipsBrokenFace", brokenTiles.flatMap { $0 }.count == strip.triangleCount - 1)
        r.check("tiles.zeroSizeOneGroup", ViewerContentBuilder.tiles(strip, tileSize: 0).count == 1)
        r.check("tiles.empty", ViewerContentBuilder.tiles(TriangleMesh(), tileSize: 2).isEmpty)
    }

    /// `ViewerContentBuilder.meshParts` for Raw Scan, Solid, Wireframe and inferred faces.
    static func meshPartCases(_ r: Recorder) {
        let square = squareMesh()
        let classed = MeshWithAttributes(mesh: square, faceClass: [1, 1, 2, 2, 3, 3])
        let raw = ViewerContentBuilder.meshParts(classed, style: .rawScan, palette: palette, inferredColor: inferred,
                                                 layer: .raw, idPrefix: "raw")
        r.check("meshParts.raw.threeParts", raw.count == 3, "\(raw.count)")
        let colors = raw.compactMap { $0.material.color }
        let expected = [palette[1], palette[2], palette[3]].compactMap { $0 }
        r.check("meshParts.raw.paletteColors", colors == expected)
        r.check("meshParts.raw.unlit", raw.allSatisfy { part -> Bool in
            if case .unlit = part.material { return true }
            return false
        })
        let indexTotal = raw.reduce(0) { $0 + $1.indices.count }
        r.check("meshParts.raw.indexSum", indexTotal == square.indices.count, "\(indexTotal)")
        r.check("meshParts.raw.layerAndTag", raw.allSatisfy { $0.layer == .raw && $0.pickTag == .rawMesh })
        r.check("meshParts.raw.compact", raw.allSatisfy { part in
            part.normals.count == part.positions.count && part.indices.allSatisfy { Int($0) < part.positions.count }
        })

        let strip = MeshWithAttributes(mesh: stripMesh(), faceClass: [UInt8](repeating: 1, count: 12) + [UInt8](repeating: 2, count: 12))
        let solid = ViewerContentBuilder.meshParts(strip, style: .solidColor, palette: palette, inferredColor: inferred,
                                                   layer: .raw, idPrefix: "solid")
        r.check("meshParts.solid.onePerTile", solid.count == 3, "\(solid.count)")
        r.check("meshParts.solid.lit", solid.allSatisfy { $0.material == .lit(ViewerContentBuilder.solidColor) })
        let wire = ViewerContentBuilder.meshParts(strip, style: .wireframe, palette: palette, inferredColor: inferred,
                                                  layer: .raw, idPrefix: "wire")
        r.check("meshParts.wireframe", wire.count == 3 && wire.allSatisfy { $0.material == .wireframe(ViewerContentBuilder.wireframeColor) })

        let flagged = MeshWithAttributes(mesh: square, faceClass: [1, 1, 2, 2, 3, 3],
                                         isInferred: [false, false, true, true, false, false])
        let withInferred = ViewerContentBuilder.meshParts(flagged, style: .rawScan, palette: palette, inferredColor: inferred,
                                                          layer: .raw, idPrefix: "inf")
        let inferredParts = withInferred.filter { $0.layer == .rawInferred }
        r.check("meshParts.inferred.layer", inferredParts.count == 1 && inferredParts.first?.indices.count == 6)
        r.check("meshParts.inferred.color", inferredParts.first?.material == .unlit(inferred))
        r.check("meshParts.inferred.classPartsLeft", withInferred.filter { $0.layer == .raw }.count == 2)
    }

    /// `ViewerContentBuilder.boxParts`.
    static func boxCases(_ r: Recorder) {
        let center = SIMD3<Float>(1, 2, 3)
        let box = OrientedBox(center: center, axes: matrix_identity_float3x3, halfExtents: SIMD3<Float>(0.5, 1, 1.5))
        let tag = ViewerPickTag.element(ElementID(uuid: UUID(uuid: (1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16))))
        let color = SIMD4<Float>(0.2, 0.4, 0.6, 0.5)
        let parts = ViewerContentBuilder.boxParts(box, color: color, layer: .cleanFurniture, pickTag: tag, id: "box")
        r.check("box.twoParts", parts.count == 2, "\(parts.count)")
        guard parts.count == 2 else { return }
        r.check("box.fillTwelveTriangles", parts[0].triangleCount == 12 && parts[0].material == .translucent(color))
        r.check("box.wireframeCopy", parts[1].triangleCount == 12 && parts[1].material == .wireframe(SIMD4<Float>(0.2, 0.4, 0.6, 1)))
        r.check("box.pickTagOnFill", parts[0].pickTag == tag && parts[1].pickTag == nil && parts[0].layer == .cleanFurniture)
        let mesh = TriangleMesh(positions: parts[0].positions, indices: parts[0].indices)
        var outward = true
        for t in 0..<mesh.triangleCount {
            guard let corners = mesh.triangle(t) else { outward = false; continue }
            let (a, b, c) = corners
            let centroid: SIMD3<Float> = (a + b + c) / 3
            if simd_dot(simd_cross(b - a, c - a), centroid - center) <= 0 { outward = false }
        }
        r.check("box.outwardWinding", outward)
        r.near("box.volumeFromArea", mesh.welded().signedVolume, 6, 1e-4)
    }

    /// `ViewerContentBuilder.expandCorners` and `ViewerContent` bounds.
    static func expandCases(_ r: Recorder) {
        let positions: [SIMD3<Float>] = [SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0), SIMD3<Float>(1, 1, 0), SIMD3<Float>(0, 1, 0)]
        let uvs: [SIMD2<Float>] = (0..<6).map { SIMD2<Float>(Float($0) * 0.1, 1 - Float($0) * 0.1) }
        let out = ViewerContentBuilder.expandCorners(positions: positions, indices: [0, 1, 2, 0, 2, 3], cornerUVs: uvs)
        r.check("expand.sixVertices", out.positions.count == 6 && out.uvs.count == 6)
        r.check("expand.sequentialIndices", out.indices == [0, 1, 2, 3, 4, 5])
        r.check("expand.uvsInOrder", out.uvs == uvs)
        r.check("expand.positionsFollowCorners", out.positions == [positions[0], positions[1], positions[2], positions[0], positions[2], positions[3]])

        let a = ViewerPart(id: "a", positions: [SIMD3<Float>(-1, 0, 2), SIMD3<Float>(0, 3, 0)], indices: [],
                           material: .unlit(SIMD4<Float>(1, 1, 1, 1)), layer: .overlay)
        let b = ViewerPart(id: "b", positions: [SIMD3<Float>(4, -2, 1)], indices: [],
                           material: .unlit(SIMD4<Float>(1, 1, 1, 1)), layer: .overlay)
        let content = ViewerContent(parts: [a, b])
        let expectedMin = SIMD3<Float>(-1, -2, 0)
        let expectedMax = SIMD3<Float>(4, 3, 2)
        let minOK = content.bounds.min == expectedMin
        let maxOK = content.bounds.max == expectedMax
        r.check("content.boundsUnion", minOK && maxOK)
        r.check("content.emptyBounds", ViewerContent.empty.bounds.isEmpty && ViewerContent.empty.parts.isEmpty)
    }

    /// `ViewerRenderMesh.pack`, normals and renderability.
    static func packCases(_ r: Recorder) {
        let normals = [SIMD3<Float>](repeating: SIMD3<Float>(0, 0, 1), count: 3)
        let uvs = [SIMD2<Float>(0.1, 0.2), SIMD2<Float>(0.3, 0.4), SIMD2<Float>(0.5, 0.6)]
        let data = ViewerRenderMesh.pack(trianglePart(normals: normals, uvs: uvs))
        r.check("pack.stride32", data.count == 3 * 32 && ViewerRenderMesh.vertexStride == 32, "\(data.count)")
        let position = SIMD3<Float>(floatAt(data, 32), floatAt(data, 36), floatAt(data, 40))
        r.check("pack.position", position == SIMD3<Float>(1, 0, 0), "\(position)")
        let normal = SIMD3<Float>(floatAt(data, 32 + 12), floatAt(data, 32 + 16), floatAt(data, 32 + 20))
        r.check("pack.normalAt12", normal == SIMD3<Float>(0, 0, 1), "\(normal)")
        let uv = SIMD2<Float>(floatAt(data, 64 + 24), floatAt(data, 64 + 28))
        r.check("pack.uvAt24", uv == SIMD2<Float>(0.5, 0.6), "\(uv)")
        let noUV = ViewerRenderMesh.pack(trianglePart(normals: normals))
        let zeroUV = SIMD2<Float>(floatAt(noUV, 24), floatAt(noUV, 28))
        r.check("pack.missingUVsZero", zeroUV == SIMD2<Float>(0, 0))

        let zero = ViewerRenderMesh.resolvedNormals(trianglePart(normals: [SIMD3<Float>](repeating: .zero, count: 3)))
        r.check("pack.zeroNormalsComputed", zero.count == 3 && zero.allSatisfy { abs(abs($0.z) - 1) < 1e-5 })
        let given: [SIMD3<Float>] = [SIMD3<Float>(0, 0, 2), SIMD3<Float>(0, 0, 0), SIMD3<Float>(0, 0, 1)]
        let mixed = ViewerRenderMesh.resolvedNormals(trianglePart(normals: given))
        let mixedOK = mixed.count == 3
        let computedZ: Float = mixedOK ? abs(mixed[1].z) : 0
        let keptUnit = mixedOK && mixed[0] == SIMD3<Float>(0, 0, 1)
        r.check("pack.oneZeroNormalComputed", keptUnit && abs(computedZ - 1) < 1e-5)
        let absent = ViewerRenderMesh.resolvedNormals(trianglePart(normals: []))
        r.check("pack.absentNormalsComputed", absent.count == 3 && absent.allSatisfy { abs(simd_length($0) - 1) < 1e-5 })

        let empty = ViewerPart(id: "empty", positions: [], indices: [], material: .lit(SIMD4<Float>(1, 1, 1, 1)), layer: .raw)
        let emptyRenderable = ViewerRenderMesh.isRenderable(empty)
        let emptyData = ViewerRenderMesh.pack(empty)
        let emptyPacked = ViewerRenderMesh.packedPart(empty)
        r.check("pack.emptyPartSkipped", !emptyRenderable && emptyData.isEmpty && emptyPacked == nil)
        var broken = trianglePart(normals: normals)
        broken.indices = [0, 1, 7]
        r.check("pack.badIndexSkipped", !ViewerRenderMesh.isRenderable(broken))
        let packed = ViewerContent(parts: [empty, trianglePart(normals: normals), broken]).parts.compactMap(ViewerRenderMesh.packedPart)
        let onlyOne = packed.count == 1
        let firstVertexCount: Int = packed.first?.vertexCount ?? 0
        let firstMax: SIMD3<Float> = packed.first?.boundsMax ?? SIMD3<Float>(0, 0, 0)
        r.check("pack.onlyRenderableUploaded", onlyOne && firstVertexCount == 3 && firstMax == SIMD3<Float>(1, 1, 0))
    }

    /// `ViewerOrbitMath.lookAt`, `eye` and `ViewerOrbitState`.
    static func cameraCases(_ r: Recorder) {
        let eye = SIMD3<Float>(3, 2, 4)
        let target = SIMD3<Float>(0, 1, 0)
        let m = ViewerOrbitMath.lookAt(eye: eye, target: target)
        let x = SIMD3<Float>(m.columns.0.x, m.columns.0.y, m.columns.0.z)
        let y = SIMD3<Float>(m.columns.1.x, m.columns.1.y, m.columns.1.z)
        let z = SIMD3<Float>(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        let toTarget = simd_normalize(target - eye)
        r.check("lookAt.minusZToTarget", simd_distance(-z, toTarget) < 1e-5, "\(-z)")
        r.check("lookAt.upKept", abs(x.y) < 1e-5 && y.y > 0, "\(x) \(y)")
        let dotXY: Float = simd_dot(x, y)
        let dotYZ: Float = simd_dot(y, z)
        let lengthX: Float = simd_length(x)
        r.check("lookAt.orthonormal", abs(dotXY) < 1e-5 && abs(dotYZ) < 1e-5 && abs(lengthX - 1) < 1e-5)
        r.check("lookAt.rightHanded", simd_distance(simd_cross(x, y), z) < 1e-5)
        r.check("lookAt.translation", m.columns.3 == SIMD4<Float>(3, 2, 4, 1))
        let down = ViewerOrbitMath.lookAt(eye: SIMD3<Float>(0, 5, 0), target: .zero)
        r.check("lookAt.verticalFinite", down.columns.0.x.isFinite && abs(down.columns.2.y - 1) < 1e-5)

        let high = ViewerOrbitMath.eye(target: .zero, yaw: 0.3, pitch: 1.5, distance: 10)
        r.near("eye.clampsTo85", asin(high.y / 10), ViewerOrbitMath.maxPitch, 1e-4)
        let low = ViewerOrbitMath.eye(target: .zero, yaw: 0.3, pitch: -1, distance: 10)
        r.near("eye.clampsTo5", asin(low.y / 10), ViewerOrbitMath.minPitch, 1e-4)
        r.near("eye.distance", simd_length(high), 10, 1e-4)
        let front = ViewerOrbitMath.eye(target: SIMD3<Float>(1, 0, 0), yaw: 0, pitch: ViewerOrbitMath.minPitch, distance: 2)
        r.check("eye.yawZeroOnPlusZ", front.z > 1.9 && abs(front.x - 1) < 1e-5)

        var state = ViewerOrbitState()
        state.distance = 4
        state.dolly(scale: 100, minDistance: 0.5, maxDistance: 20)
        r.near("orbit.dollyClampsNear", state.distance, 0.5, 1e-6)
        state.dolly(scale: 0.001, minDistance: 0.5, maxDistance: 20)
        r.near("orbit.dollyClampsFar", state.distance, 20, 1e-6)
        state.orbit(dx: 0, dy: 10_000)
        r.near("orbit.pitchClamped", state.pitch, ViewerOrbitMath.maxPitch, 1e-6)
        let before = state.target
        state.pan(dx: 100, dy: 0, viewHeight: 800, verticalFieldOfViewDegrees: 60)
        let moved = state.target - before
        r.check("orbit.panHorizontal", abs(moved.y) < 1e-5 && simd_length(moved) > 0)
    }

    /// `ViewerOrbitMath.framing`, field of view and the projection round trip.
    static func framingCases(_ r: Recorder) {
        let box = AABB3(min: SIMD3<Float>(0, 0, 0), max: SIMD3<Float>(4, 2.5, 5))
        let framing = ViewerOrbitMath.framing(box, fieldOfViewDegrees: 60)
        r.check("framing.targetCenter", simd_distance(framing.target, box.center) < 1e-5)
        let corners: [SIMD3<Float>] = (0..<8).map { i -> SIMD3<Float> in
            let x: Float = (i & 1) == 0 ? 0 : 4
            let y: Float = (i & 2) == 0 ? 0 : 2.5
            let z: Float = (i & 4) == 0 ? 0 : 5
            return SIMD3<Float>(x, y, z)
        }
        let halfAngle: Float = 30 * Float.pi / 180 + 1e-4
        var inside = true
        for yaw: Float in [0, 1, 2, 3, 4, 5] {
            for pitch in [ViewerOrbitMath.minPitch, 0.6, ViewerOrbitMath.maxPitch] {
                let eye = ViewerOrbitMath.eye(target: framing.target, yaw: yaw, pitch: pitch, distance: framing.distance)
                let axis = simd_normalize(framing.target - eye)
                for corner in corners {
                    let cosine = simd_dot(simd_normalize(corner - eye), axis)
                    if acos(Swift.min(cosine, 1)) > halfAngle { inside = false }
                }
            }
        }
        r.check("framing.boxInside60", inside)
        r.near("framing.empty", ViewerOrbitMath.framing(.empty, fieldOfViewDegrees: 60).distance, ViewerOrbitMath.emptyDistance, 1e-6)
        let narrow = ViewerOrbitMath.effectiveFieldOfView(verticalDegrees: 60, aspect: 0.5)
        r.near("framing.portraitNarrower", narrow, 2 * atan(tan(Float.pi / 6) * 0.5) * 180 / Float.pi, 1e-3)
        r.near("framing.landscapeKeepsVertical", ViewerOrbitMath.effectiveFieldOfView(verticalDegrees: 60, aspect: 2), 60, 1e-4)
        r.check("framing.similarSame", ViewerModel.similar(box, box))
        let shifted = AABB3(min: SIMD3<Float>(3, 0, 0), max: SIMD3<Float>(7, 2.5, 5))
        r.check("framing.similarShifted", !ViewerModel.similar(box, shifted))

        var state = ViewerOrbitState()
        state.target = SIMD3<Float>(1, 1, 1)
        state.distance = 5
        let pose = state.cameraToWorld
        let size = CGSize(width: 390, height: 844)
        let point = SIMD3<Float>(1.4, 0.7, 1.9)
        if let screen = ViewerOrbitMath.project(point, cameraToWorld: pose, verticalFieldOfViewDegrees: 60, viewSize: size),
           let ray = ViewerOrbitMath.ray(through: screen, cameraToWorld: pose, verticalFieldOfViewDegrees: 60, viewSize: size) {
            let along = simd_dot(point - ray.origin, ray.direction)
            let miss = simd_distance(ray.origin + ray.direction * along, point)
            r.check("projection.roundTrip", miss < 1e-3, "\(miss)")
        } else {
            r.check("projection.roundTrip", false, "nil")
        }
        let center = ViewerOrbitMath.project(state.target, cameraToWorld: pose, verticalFieldOfViewDegrees: 60, viewSize: size)
        let centerPoint: CGPoint = center ?? CGPoint(x: -1, y: -1)
        let dx: CGFloat = abs(centerPoint.x - 195)
        let dy: CGFloat = abs(centerPoint.y - 422)
        r.check("projection.targetCentered", center != nil && dx < 0.01 && dy < 0.01)
        let behind = state.eye + (state.eye - state.target)
        r.check("projection.behindNil", ViewerOrbitMath.project(behind, cameraToWorld: pose, verticalFieldOfViewDegrees: 60, viewSize: size) == nil)
    }

    /// `ViewerPicking` nearest hit and layer filtering.
    static func pickingCases(_ r: Recorder) {
        /// A pickable 2 x 2 m square facing +Z at depth `z`.
        func quad(_ id: String, z: Float, layer: ViewerLayer) -> ViewerPart {
            ViewerPart(id: id, positions: [SIMD3<Float>(-1, -1, z), SIMD3<Float>(1, -1, z), SIMD3<Float>(1, 1, z), SIMD3<Float>(-1, 1, z)],
                       indices: [0, 2, 1, 0, 3, 2], material: .lit(SIMD4<Float>(1, 1, 1, 1)), layer: layer, pickTag: .rawMesh)
        }
        let unpickable = ViewerPart(id: "none", positions: [SIMD3<Float>(-1, -1, 1), SIMD3<Float>(1, -1, 1), SIMD3<Float>(0, 1, 1)],
                                    indices: [0, 1, 2], material: .lit(SIMD4<Float>(1, 1, 1, 1)), layer: .raw)
        let entries = ViewerPicking.entries(for: [unpickable, quad("near", z: 0, layer: .raw), quad("far", z: -1, layer: .overlay)])
        r.check("pick.onlyTaggedParts", entries.count == 2)
        let ray = Ray(origin: SIMD3<Float>(0.2, 0.3, 5), direction: SIMD3<Float>(0, 0, -1))
        let hit = ViewerPicking.nearestHit(ray, entries: entries, visibleLayers: Set(ViewerLayer.allCases))
        let hitPart: String = hit?.partID ?? "nil"
        let hitZ: Float = hit?.position.z ?? 9
        r.check("pick.nearest", hitPart == "near" && abs(hitZ) < 1e-5, hitPart)
        let normalZ: Float = hit?.normal.z ?? 0
        r.check("pick.normalFacesRay", normalZ > 0.99)
        let hitTriangle: Int = hit?.triangle ?? -1
        let hitTag: ViewerPickTag? = hit?.pickTag
        r.check("pick.triangleAndTag", hitTriangle >= 0 && hitTriangle < 2 && hitTag == ViewerPickTag.rawMesh)
        let hidden = ViewerPicking.nearestHit(ray, entries: entries, visibleLayers: [.overlay])
        r.check("pick.hiddenLayerSkipped", hidden?.partID == "far")
        let miss = ViewerPicking.nearestHit(Ray(origin: SIMD3<Float>(5, 5, 5), direction: SIMD3<Float>(0, 0, -1)),
                                           entries: entries, visibleLayers: Set(ViewerLayer.allCases))
        r.check("pick.missNil", miss == nil)
    }

    /// `ViewerDiagnostics` checkerboard image and content.
    static func checkerCases(_ r: Recorder) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("viewer3d-selftest", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            let content = try ViewerDiagnostics.uvCheckerContent(directory: folder)
            let part = content.parts.first
            r.check("checker.onePart", content.parts.count == 1 && part?.positions.count == 4 && part?.indices.count == 6)
            let uvs: [SIMD2<Float>] = part?.uvs ?? []
            let positions: [SIMD3<Float>] = part?.positions ?? []
            let lowerLeftUV = uvs.count == 4 && uvs[0] == SIMD2<Float>(0, 0) && uvs[2] == SIMD2<Float>(1, 1)
            let lowerLeftCorner = positions.count == 4 && positions[0] == SIMD3<Float>(-0.5, 0, 0)
            r.check("checker.uvOriginLowerLeft", lowerLeftUV && lowerLeftCorner)
            guard case .texture(let url)? = part?.material else {
                r.check("checker.textureMaterial", false)
                return
            }
            r.check("checker.fileWritten", FileManager.default.fileExists(atPath: url.path))
            if let decoded = ViewerImages.decodedImage(at: url), let pixels = ViewerImages.rgbaPixels(decoded.image) {
                let bottomLeft = 4 * ((pixels.height - 9) * pixels.width + 8)
                let topLeft = 4 * (8 * pixels.width + 8)
                let red = pixels.bytes[bottomLeft] > 180 && pixels.bytes[bottomLeft + 1] < 80
                let blue = pixels.bytes[topLeft + 2] > 180 && pixels.bytes[topLeft] < 80
                r.check("checker.redAtBottomLeft", red && blue)
            } else {
                r.check("checker.redAtBottomLeft", false, "decode")
            }
        } catch {
            r.check("checker.content", false, "\(error)")
        }
    }
}
