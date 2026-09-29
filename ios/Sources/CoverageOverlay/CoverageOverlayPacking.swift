import Foundation
import simd

// Pure side of the live coverage overlay (docs/MODULES.md 3.38): the four state colors, the
// grouping of triangles by coverage state into four LowLevelMesh parts, the interleaved vertex
// packing, buffer capacities, the view-cone visibility test and the per-tick schedule. Every
// member runs on any queue; CoverageOverlayRenderer only copies the packed bytes into RealityKit
// on the main actor. States always come from CoverageLive; nothing here decides one.

/// Colors of the four states; alpha is the opacity.
struct CoverageOverlayStyle: Equatable, Sendable {
    /// Opacity of every color, 0...1 (the transparent blending of the overlay materials).
    var opacity: Float = 0.45

    /// The live overlay: opacity 0.45 over the camera.
    static let standard = CoverageOverlayStyle()
    /// Minimap cells and legend swatches: the same colors, nearly opaque.
    static let display = CoverageOverlayStyle(opacity: 0.9)

    /// RGB of the four states, 0...1.
    static let greenRGB = SIMD3<Float>(0.15, 0.80, 0.35)
    static let yellowRGB = SIMD3<Float>(0.98, 0.80, 0.15)
    static let redRGB = SIMD3<Float>(0.92, 0.25, 0.22)
    static let grayRGB = SIMD3<Float>(0.60, 0.60, 0.62)

    /// Green (0.15, 0.80, 0.35), yellow (0.98, 0.80, 0.15), red (0.92, 0.25, 0.22), gray (0.60, 0.60, 0.62),
    /// alpha `opacity` (clamped to 0...1; the standard 0.45 when not finite).
    func color(for state: CoverageState) -> SIMD4<Float> {
        let rgb: SIMD3<Float>
        switch state {
        case .green: rgb = CoverageOverlayStyle.greenRGB
        case .yellow: rgb = CoverageOverlayStyle.yellowRGB
        case .red: rgb = CoverageOverlayStyle.redRGB
        case .gray: rgb = CoverageOverlayStyle.grayRGB
        }
        let alpha: Float = opacity.isFinite ? min(max(opacity, 0), 1) : 0.45
        return SIMD4<Float>(rgb.x, rgb.y, rgb.z, alpha)
    }
}

/// One anchor packed for upload (built off main).
struct CoverageOverlayBuffers {
    /// `CoverageAnchorFaces.anchorID`.
    var anchorID: UUID
    /// `CoverageAnchorFaces.revision` of the version packed.
    var revision: UInt64
    /// Anchor to world (the entity's transform).
    var transform: simd_float4x4
    /// 32 bytes per vertex: position .float3 at 0, normal .float3 at 12 ((0, 1, 0) when unknown), uv0 .float2 at 24 (zero).
    var vertexData: Data
    /// Vertices in `vertexData`.
    var vertexCount: Int
    /// Triangles grouped by state in `CoverageOverlayPacking.stateOrder`, each group in its original order.
    var indices: [UInt32]
    /// Index count per state, 4 entries in `stateOrder`.
    var groupCounts: [Int]
    /// Anchor-local bounds.
    var boundsMin: SIMD3<Float>
    var boundsMax: SIMD3<Float>
}

/// One `LowLevelMesh.Part` of a packed anchor.
struct CoverageOverlayPart: Equatable, Sendable {
    /// Bytes from the start of the index buffer (`LowLevelMesh.Part.indexOffset` is in bytes).
    var byteOffset: Int
    /// Indices in the part (3 per triangle).
    var indexCount: Int
    /// Position of the state in `stateOrder` (the material index).
    var materialIndex: Int
}

/// The anchors of one pack, handed to the detached packing task. The anchors are value copies
/// whose arrays are never mutated (copy on write), so sending them to another thread is safe.
struct CoverageOverlayPackJob: @unchecked Sendable {
    /// Anchors to pack, in schedule order.
    var anchors: [CoverageAnchorFaces]
}

/// What one packing task hands back to the main actor.
struct CoverageOverlayPackResult: @unchecked Sendable {
    /// Packed anchors, in job order.
    var buffers: [CoverageOverlayBuffers]
    /// Anchors that could not be packed (inconsistent counts or indices; logged).
    var failed: [UUID]
    /// Packing time of the whole job, milliseconds.
    var milliseconds: Double
}

/// Pure packing and scheduling. Any queue.
enum CoverageOverlayPacking {
    /// Material order of the four parts: green, yellow, red, gray.
    static let stateOrder: [CoverageState] = [.green, .yellow, .red, .gray]
    /// Interleaved vertex layout (as Viewer3D): stride and attribute byte offsets.
    static let vertexStride = 32, positionOffset = 0, normalOffset = 12, uvOffset = 24
    /// Growth factor of a `LowLevelMesh` that no longer fits.
    static let capacityFactor: Double = 1.5
    /// Floats per vertex (stride / 4) and bytes per `UInt32` index.
    static let floatsPerVertex = 8, bytesPerIndex = 4
    /// Normal written when ARKit gave none (or a zero or non-finite one).
    static let unknownNormal = SIMD3<Float>(0, 1, 0)
    /// Log category of the overlay.
    static let logCategory = "overlay"

    // MARK: Grouping and packing

    /// Group of a state: its position in `stateOrder`.
    static func slot(of state: CoverageState) -> Int {
        switch state {
        case .green: return 0
        case .yellow: return 1
        case .red: return 2
        case .gray: return 3
        }
    }

    /// Stable grouping of index triples by their triangle's state. Triangles past the end of
    /// `states` count as gray; trailing indices that do not make a whole triangle are dropped.
    static func grouped(indices: [UInt32], states: [CoverageState]) -> (indices: [UInt32], counts: [Int]) {
        let triangles = indices.count / 3
        let groups = stateOrder.count
        let graySlot = slot(of: .gray)
        var counts = [Int](repeating: 0, count: groups)
        var slots = [Int](repeating: graySlot, count: triangles)
        for t in 0..<triangles {
            let s = t < states.count ? slot(of: states[t]) : graySlot
            slots[t] = s
            counts[s] += 3
        }
        var starts = [Int](repeating: 0, count: groups)
        var running = 0
        for g in 0..<groups {
            starts[g] = running
            running += counts[g]
        }
        var out = [UInt32](repeating: 0, count: running)
        for t in 0..<triangles {
            let g = slots[t]
            let at = starts[g]
            out[at] = indices[3 * t]
            out[at + 1] = indices[3 * t + 1]
            out[at + 2] = indices[3 * t + 2]
            starts[g] = at + 3
        }
        return (indices: out, counts: counts)
    }

    /// Nil (logged) when `states.count != indices.count / 3`, the index count is not a multiple
    /// of 3, or an index is out of range. Triangles touching a non-finite position are left out
    /// (the position is written as zero); bounds cover the finite positions (zero when none).
    static func pack(_ anchor: CoverageAnchorFaces) -> CoverageOverlayBuffers? {
        let positions = anchor.localPositions
        let vertexCount = positions.count
        let triangles = anchor.indices.count / 3
        guard anchor.indices.count % 3 == 0, anchor.states.count == triangles else {
            log("pack skipped \(anchor.anchorID.uuidString): \(anchor.indices.count) indices, "
                + "\(anchor.states.count) states")
            return nil
        }
        let limit = UInt32(clamping: vertexCount)
        if anchor.indices.contains(where: { $0 >= limit }) {
            log("pack skipped \(anchor.anchorID.uuidString): an index is out of range of \(vertexCount) vertices")
            return nil
        }
        var finite = [Bool](repeating: true, count: vertexCount)
        var anyNonFinite = false
        for v in 0..<vertexCount where !isFinite(positions[v]) {
            finite[v] = false
            anyNonFinite = true
        }
        var kept: (indices: [UInt32], states: [CoverageState]) = (indices: anchor.indices, states: anchor.states)
        if anyNonFinite { kept = finiteTriangles(anchor.indices, states: anchor.states, finite: finite) }
        let grouping = grouped(indices: kept.indices, states: kept.states)
        let packed = interleave(positions, normals: anchor.localNormals, finite: finite)
        return CoverageOverlayBuffers(anchorID: anchor.anchorID, revision: anchor.revision, transform: anchor.transform,
                                      vertexData: packed.data, vertexCount: vertexCount, indices: grouping.indices,
                                      groupCounts: grouping.counts, boundsMin: packed.low, boundsMax: packed.high)
    }

    /// The triangles (and their states) whose three vertices are finite.
    static func finiteTriangles(_ indices: [UInt32], states: [CoverageState],
                                finite: [Bool]) -> (indices: [UInt32], states: [CoverageState]) {
        var keptIndices: [UInt32] = []
        var keptStates: [CoverageState] = []
        keptIndices.reserveCapacity(indices.count)
        keptStates.reserveCapacity(states.count)
        let triangles = min(indices.count / 3, states.count)
        for t in 0..<triangles {
            let a = Int(indices[3 * t])
            let b = Int(indices[3 * t + 1])
            let c = Int(indices[3 * t + 2])
            guard finite[a], finite[b], finite[c] else { continue }
            keptIndices.append(indices[3 * t])
            keptIndices.append(indices[3 * t + 1])
            keptIndices.append(indices[3 * t + 2])
            keptStates.append(states[t])
        }
        return (indices: keptIndices, states: keptStates)
    }

    /// Interleaved bytes (position, unit normal or `unknownNormal`, zero uv) and the bounds of the
    /// finite positions. Non-finite positions are written as zero.
    static func interleave(_ positions: [SIMD3<Float>], normals: [SIMD3<Float>],
                           finite: [Bool]) -> (data: Data, low: SIMD3<Float>, high: SIMD3<Float>) {
        let vertexCount = positions.count
        guard vertexCount > 0 else { return (data: Data(), low: .zero, high: .zero) }
        let hasNormals = normals.count == vertexCount
        var floats = [Float](repeating: 0, count: vertexCount * floatsPerVertex)
        var low = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var high = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var sawFinite = false
        for v in 0..<vertexCount {
            let base = v * floatsPerVertex
            let ok = v < finite.count ? finite[v] : isFinite(positions[v])
            let p: SIMD3<Float> = ok ? positions[v] : .zero
            floats[base] = p.x
            floats[base + 1] = p.y
            floats[base + 2] = p.z
            var n = unknownNormal
            if hasNormals {
                let given = normals[v]
                let length = simd_length(given)
                if length.isFinite, length > 1e-6 { n = given / length }
            }
            floats[base + 3] = n.x
            floats[base + 4] = n.y
            floats[base + 5] = n.z
            if ok {
                low = simd_min(low, p)
                high = simd_max(high, p)
                sawFinite = true
            }
        }
        let data = floats.withUnsafeBufferPointer { Data(buffer: $0) }
        if sawFinite { return (data: data, low: low, high: high) }
        return (data: data, low: .zero, high: .zero)
    }

    /// Packs every anchor of a job (the detached task's body).
    static func packAll(_ job: CoverageOverlayPackJob) -> CoverageOverlayPackResult {
        let started = DispatchTime.now().uptimeNanoseconds
        var buffers: [CoverageOverlayBuffers] = []
        var failed: [UUID] = []
        buffers.reserveCapacity(job.anchors.count)
        for anchor in job.anchors {
            if let packed = pack(anchor) {
                buffers.append(packed)
            } else {
                failed.append(anchor.anchorID)
            }
        }
        let nanos = DispatchTime.now().uptimeNanoseconds &- started
        return CoverageOverlayPackResult(buffers: buffers, failed: failed, milliseconds: Double(nanos) / 1_000_000)
    }

    // MARK: Parts and capacity

    /// One part per non-empty group, byte offsets = preceding index counts x 4. Entries past the
    /// four states are ignored; negative counts count as empty.
    static func parts(groupCounts: [Int]) -> [CoverageOverlayPart] {
        var out: [CoverageOverlayPart] = []
        var preceding = 0
        let groups = min(groupCounts.count, stateOrder.count)
        for g in 0..<groups {
            let count = groupCounts[g]
            guard count > 0 else { continue }
            out.append(CoverageOverlayPart(byteOffset: preceding * bytesPerIndex, indexCount: count, materialIndex: g))
            preceding += count
        }
        return out
    }

    /// `current` when it is enough, else ceil(needed x capacityFactor).
    static func capacity(needed: Int, current: Int) -> Int {
        if current >= needed { return max(current, 0) }
        let grown = (Double(needed) * capacityFactor).rounded(.up)
        guard grown.isFinite, grown < Double(Int.max / 2) else { return needed }
        return max(Int(grown), needed)
    }

    // MARK: Visibility and schedule

    /// World bounds (`CoverageAnchorFaces.boundsMin`, `boundsMax`): their bounding sphere meets the cone of
    /// `halfAngleDegrees` around the camera's forward (-Z column) within `maxDistance`; true when the camera is inside them.
    static func isVisible(boundsMin: SIMD3<Float>, boundsMax: SIMD3<Float>, cameraToWorld: simd_float4x4,
                          halfAngleDegrees: Float, maxDistance: Float) -> Bool {
        let m = cameraToWorld
        let origin = SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        guard isFinite(origin), isFinite(boundsMin), isFinite(boundsMax), !maxDistance.isNaN else { return false }
        if contains(origin, low: boundsMin, high: boundsMax) { return true }
        let center = (boundsMin + boundsMax) * 0.5
        let radius = simd_length(boundsMax - boundsMin) * 0.5
        let d = center - origin
        let distance = simd_length(d)
        guard distance.isFinite, radius.isFinite else { return false }
        if distance <= radius { return true }
        if distance - radius > maxDistance { return false }
        let back = SIMD3<Float>(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        let backLength = simd_length(back)
        guard backLength.isFinite, backLength > 1e-6 else { return false }
        let forward = -back / backLength
        let rawCosine: Float = simd_dot(d, forward) / distance
        let cosine: Float = Swift.min(Swift.max(rawCosine, -1), 1)
        let angle: Float = acos(cosine)
        let sine: Float = Swift.min(radius / distance, 1)
        let angularRadius: Float = asin(sine)
        let halfAngle: Float = halfAngleDegrees * Float.pi / 180
        return angle - angularRadius <= halfAngle
    }

    /// Up to `limit` visible anchors from `pending`, nearest bounds center first; the rest stay pending.
    /// Ties are broken by the anchor id's text, so the order is deterministic.
    static func schedule(_ pending: [UUID: CoverageAnchorFaces], cameraToWorld: simd_float4x4, halfAngleDegrees: Float,
                         maxDistance: Float, limit: Int) -> [UUID] {
        guard limit > 0, !pending.isEmpty else { return [] }
        let m = cameraToWorld
        let origin = SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        var candidates: [(id: UUID, key: String, distance: Float)] = []
        for (id, anchor) in pending {
            guard isVisible(boundsMin: anchor.boundsMin, boundsMax: anchor.boundsMax, cameraToWorld: cameraToWorld,
                            halfAngleDegrees: halfAngleDegrees, maxDistance: maxDistance) else { continue }
            let center = (anchor.boundsMin + anchor.boundsMax) * 0.5
            let distance = simd_length(center - origin)
            let sortable: Float = distance.isFinite ? distance : .greatestFiniteMagnitude
            candidates.append((id: id, key: id.uuidString, distance: sortable))
        }
        candidates.sort { (a, b) -> Bool in
            if a.distance != b.distance { return a.distance < b.distance }
            return a.key < b.key
        }
        return candidates.prefix(limit).map { $0.id }
    }

    // MARK: Helpers

    /// Copies as many bytes as both buffers hold from `source` to `destination`.
    static func copyRaw(from source: UnsafeRawBufferPointer, to destination: UnsafeMutableRawBufferPointer) {
        let count = min(source.count, destination.count)
        guard count > 0, let from = source.baseAddress, let to = destination.baseAddress else { return }
        to.copyMemory(from: from, byteCount: count)
    }

    /// True when `p` lies inside the box `low`...`high` (edges included).
    static func contains(_ p: SIMD3<Float>, low: SIMD3<Float>, high: SIMD3<Float>) -> Bool {
        let aboveLow = p.x >= low.x && p.y >= low.y && p.z >= low.z
        let belowHigh = p.x <= high.x && p.y <= high.y && p.z <= high.z
        return aboveLow && belowHigh
    }

    /// True when every component is finite.
    static func isFinite(_ p: SIMD3<Float>) -> Bool {
        p.x.isFinite && p.y.isFinite && p.z.isFinite
    }

    /// Writes one line in the "overlay" category.
    static func log(_ message: String) {
        LogStore.shared.write(message, category: logCategory)
    }
}
