import Foundation
import simd

// Pure helpers of CoverageLive (docs/MODULES.md 3.31): the coverage faces of one mesh chunk,
// their voxel keys, the per-anchor and per-face visibility tests and the integration rate.
//
// Normals: ARKit mesh normals are per vertex (RESEARCH 3.8 gotcha 6), so a face normal is the
// cross product of its corners, oriented like the mean of its three vertex normals.
// Keys: ARKit face indices are not stable across updates (RESEARCH 3.8 gotcha 7), so states are
// always looked up by the voxel key of a face's world centroid, never by face index.

/// Faces of a chunk, visibility and rate. Pure, any queue.
enum CoverageLiveFaces {
    /// Extra half-angle added to the camera's half field of view by `mayBeVisible`, degrees.
    static let viewConeMarginDegrees: Float = 10
    /// Triangles with an area at or below this are degenerate (area 0), square meters.
    static let minimumFaceArea: Float = 1e-9
    /// Tolerance of `isDue`, seconds, so frames arriving exactly on the rate are not pushed to
    /// the next frame by float rounding.
    static let dueTolerance: Double = 1e-4

    // MARK: Faces

    /// One face per triangle: corners through `chunk.transform`; the normal is the cross product,
    /// flipped when it disagrees with the mean of the three ARKit vertex normals rotated to world,
    /// kept when that mean is zero (normals are per vertex, RESEARCH 3.8 gotcha 6); class
    /// `SurfaceClass(rawValue: chunk.classes[t])` when the count matches, else `.none`; area 0 and a
    /// zero normal for degenerate or out-of-range triangles.
    static func faces(of chunk: MeshChunk) -> [CoverageFace] {
        faces(of: chunk, world: chunk.worldPositions)
    }

    /// `faces(of:)` with the chunk's world positions already computed (`chunk.worldPositions`), so
    /// the recorder transforms every vertex once. An area-0 face sits at its first corner (the
    /// anchor origin when that corner is out of range or not finite).
    static func faces(of chunk: MeshChunk, world: [SIMD3<Float>]) -> [CoverageFace] {
        let count = chunk.indices.count / 3
        guard count > 0 else { return [] }
        let vertexCount = world.count
        let normals = chunk.normals
        let hasNormals = !normals.isEmpty && normals.count == chunk.positions.count && normals.count == vertexCount
        let hasClasses = chunk.classes.count == count
        let t = chunk.transform
        let axisX = SIMD3<Float>(t.columns.0.x, t.columns.0.y, t.columns.0.z)
        let axisY = SIMD3<Float>(t.columns.1.x, t.columns.1.y, t.columns.1.z)
        let axisZ = SIMD3<Float>(t.columns.2.x, t.columns.2.y, t.columns.2.z)
        let origin = SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        let indices = chunk.indices
        var out: [CoverageFace] = []
        out.reserveCapacity(count)
        for f in 0..<count {
            let i0 = Int(indices[3 * f])
            let i1 = Int(indices[3 * f + 1])
            let i2 = Int(indices[3 * f + 2])
            var surface = SurfaceClass.none
            if hasClasses { surface = SurfaceClass(rawValue: chunk.classes[f]) ?? SurfaceClass.none }
            guard i0 < vertexCount, i1 < vertexCount, i2 < vertexCount else {
                let first = i0 < vertexCount && isFinite(world[i0]) ? world[i0] : origin
                out.append(CoverageFace(centroid: first, normal: .zero, area: 0, surface: surface))
                continue
            }
            let a = world[i0]
            let b = world[i1]
            let c = world[i2]
            let cross = simd_cross(b - a, c - a)
            let length = simd_length(cross)
            let area = 0.5 * length
            guard area.isFinite, area > minimumFaceArea else {
                let first = isFinite(a) ? a : origin
                out.append(CoverageFace(centroid: first, normal: .zero, area: 0, surface: surface))
                continue
            }
            var normal = cross / length
            if hasNormals {
                let mean = normals[i0] + normals[i1] + normals[i2]
                let rotated = axisX * mean.x + axisY * mean.y + axisZ * mean.z
                let squared = simd_length_squared(rotated)
                if squared.isFinite, squared > 1e-12, simd_dot(rotated, normal) < 0 { normal = -normal }
            }
            let centroid = (a + b + c) / 3
            out.append(CoverageFace(centroid: centroid, normal: normal, area: area, surface: surface))
        }
        return out
    }

    /// World bounds of finite points; both zero when there is none.
    static func worldBounds(_ world: [SIMD3<Float>]) -> (min: SIMD3<Float>, max: SIMD3<Float>) {
        var low = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var high = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var any = false
        for p in world where isFinite(p) {
            low = simd_min(low, p)
            high = simd_max(high, p)
            any = true
        }
        if any { return (min: low, max: high) }
        return (min: .zero, max: .zero)
    }

    /// Voxel key per face (`grid.key(for: centroid)`) and the unique keys of the anchor (area-0
    /// faces get the key of their first corner and are never integrated; they are left out of
    /// the unique keys, which feed the minimap and the expected-mark checks).
    static func keys(_ faces: [CoverageFace], grid: CoverageGrid) -> (perFace: [SIMD3<Int32>], unique: [SIMD3<Int32>]) {
        var perFace: [SIMD3<Int32>] = []
        perFace.reserveCapacity(faces.count)
        var unique = Set<SIMD3<Int32>>()
        for face in faces {
            let key = grid.key(for: face.centroid)
            perFace.append(key)
            if face.area > 0 { unique.insert(key) }
        }
        return (perFace: perFace, unique: Array(unique))
    }

    // MARK: Visibility

    /// Cone test: the bounding sphere of the bounds meets the view cone (the wider half field of view
    /// from the intrinsics plus 10 degrees) within `CoverageGrid.maxRange` of the camera.
    static func mayBeVisible(boundsMin: SIMD3<Float>, boundsMax: SIMD3<Float>, observation: CoverageObservation) -> Bool {
        let m = observation.cameraToWorld
        let origin = SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        let back = SIMD3<Float>(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        let backLength = simd_length(back)
        guard backLength.isFinite, backLength > 1e-6, isFinite(origin) else { return false }
        let forward = -back / backLength
        let center = (boundsMin + boundsMax) * 0.5
        let radius = simd_length(boundsMax - boundsMin) * 0.5
        guard isFinite(center), radius.isFinite else { return false }
        let d = center - origin
        let distance = simd_length(d)
        if distance <= radius { return true }
        if distance - radius > CoverageGrid.maxRange { return false }
        let cosine = min(max(simd_dot(d, forward) / distance, -1), 1)
        let angle = acos(cosine)
        let angularRadius = asin(min(radius / distance, 1))
        return angle - angularRadius <= halfFieldOfView(observation)
    }

    /// The wider of the horizontal and vertical half fields of view from the intrinsics (the
    /// farther image edge from the principal point), plus `viewConeMarginDegrees`, radians; pi
    /// when the intrinsics are unusable.
    static func halfFieldOfView(_ observation: CoverageObservation) -> Float {
        let k = observation.intrinsics
        let fx = k.columns.0.x
        let fy = k.columns.1.y
        let cx = k.columns.2.x
        let cy = k.columns.2.y
        let width = observation.imageResolution.x
        let height = observation.imageResolution.y
        guard fx > 0, fy > 0, width > 0, height > 0, cx.isFinite, cy.isFinite else { return .pi }
        let halfX = atan(max(cx, width - cx) / fx)
        let halfY = atan(max(cy, height - cy) / fy)
        let margin = viewConeMarginDegrees * .pi / 180
        return min(max(halfX, halfY) + margin, .pi)
    }

    /// CoverageGrid's own projection test for one face: inside the image with the same margin,
    /// `CoverageGrid.minRange` to `maxRange` away, facing the camera.
    static func isInView(_ face: CoverageFace, observation: CoverageObservation) -> Bool {
        let m = observation.cameraToWorld
        let axisX = SIMD3<Float>(m.columns.0.x, m.columns.0.y, m.columns.0.z)
        let axisY = SIMD3<Float>(m.columns.1.x, m.columns.1.y, m.columns.1.z)
        let axisZ = SIMD3<Float>(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        let origin = SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        let k = observation.intrinsics
        let fx = k.columns.0.x
        let fy = k.columns.1.y
        let cx = k.columns.2.x
        let cy = k.columns.2.y
        let width = observation.imageResolution.x
        let height = observation.imageResolution.y
        guard fx > 0, fy > 0, width > 0, height > 0 else { return false }
        let d = face.centroid - origin
        let distance2 = simd_dot(d, d)
        let minRange = CoverageGrid.minRange
        let maxRange = CoverageGrid.maxRange
        guard distance2.isFinite, distance2 >= minRange * minRange, distance2 <= maxRange * maxRange else { return false }
        let depth = -simd_dot(axisZ, d)
        guard depth > CoverageGrid.minProjectionDepth else { return false }
        let margin = width * CoverageGrid.frustumMarginFraction
        let u = fx * simd_dot(axisX, d) / depth + cx
        guard u >= -margin, u <= width + margin else { return false }
        let v = fy * -simd_dot(axisY, d) / depth + cy
        guard v >= -margin, v <= height + margin else { return false }
        let viewCosine = -simd_dot(face.normal, d) / distance2.squareRoot()
        return viewCosine > 0
    }

    // MARK: Rate

    /// min(maxHz, policy.coverageHz); 0 means never.
    static func effectiveHz(maxHz: Double, policy: ThermalPolicy) -> Double {
        let cap = maxHz.isFinite ? maxHz : policy.coverageHz
        let hz = min(cap, policy.coverageHz)
        return hz.isFinite && hz > 0 ? hz : 0
    }

    /// True when `timestamp - last >= 1 / hz` (always when `last` is nil); false when hz <= 0.
    /// A `dueTolerance` absorbs float rounding of frame times.
    static func isDue(timestamp: Double, last: Double?, hz: Double) -> Bool {
        guard hz.isFinite, hz > 0 else { return false }
        guard let last else { return true }
        return timestamp - last >= 1 / hz - dueTolerance
    }

    // MARK: Helpers

    /// True when every component is finite.
    static func isFinite(_ p: SIMD3<Float>) -> Bool {
        p.x.isFinite && p.y.isFinite && p.z.isFinite
    }
}
