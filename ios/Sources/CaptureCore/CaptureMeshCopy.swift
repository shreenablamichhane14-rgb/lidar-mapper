import ARKit
import Metal
import simd

/// Copies an ARMeshAnchor into Core's anchor-local MeshChunk (D8). Hub queue.
///
/// Every source is read through its own `offset`, `stride`, `format` and `count` (stride can
/// exceed 12; RESEARCH 3.1 gotchas 2 to 4, 3.9 gotcha 4); normals are per vertex,
/// classification is one UInt8 per face, faces are UInt32 (or UInt16) triples. The bytes are
/// copied inside the call, so no ARKit buffer outlives it. Malformed sources are dropped and
/// logged once: bad normals or classes leave those arrays empty, bad vertices or faces give
/// an empty chunk, and faces with an out-of-range index are removed with their class.
enum MeshAnchorCopier {
    /// Largest element count accepted from one source (guards the byte arithmetic).
    static let maxElements = 50_000_000
    /// Largest stride accepted, bytes.
    static let maxStride = 4096

    /// Copies the anchor's geometry, identifier and transform into a chunk.
    static func copy(_ anchor: ARMeshAnchor, updateCount: UInt32) -> MeshChunk {
        let geometry = anchor.geometry
        let positions = readFloat3(geometry.vertices, name: "vertices")
        var normals = readFloat3(geometry.normals, name: "normals")
        if normals.count != positions.count {
            if !normals.isEmpty {
                CaptureCoreLog.once("mesh.normals.count", "mesh normals count differs from vertex count; normals dropped")
            }
            normals = []
        }
        var indices = positions.isEmpty ? [] : readIndices(geometry.faces)
        var classes: [UInt8] = []
        if let classification = geometry.classification {
            classes = readClasses(classification, faceCount: indices.count / 3)
        }
        let vertexCount = UInt32(clamping: positions.count)
        if let largest = indices.max(), largest >= vertexCount {
            CaptureCoreLog.once("mesh.index.range", "mesh face index out of range; bad faces dropped")
            let kept = dropInvalidFaces(indices: indices, classes: classes, vertexCount: vertexCount)
            indices = kept.indices
            classes = kept.classes
        }
        return MeshChunk(anchorID: anchor.identifier, transform: anchor.transform, updateCount: updateCount,
                         positions: positions, normals: normals, indices: indices, classes: classes)
    }

    /// Unpacks `count` float3 values at `offset` with `stride` bytes (testable without ARKit).
    /// Returns an empty array when `count` is not positive, `offset` is negative or `stride`
    /// is under 12 bytes. The caller guarantees the bytes exist.
    static func unpackFloat3(_ base: UnsafeRawPointer, count: Int, offset: Int, stride: Int) -> [SIMD3<Float>] {
        guard count > 0, offset >= 0, stride >= 12 else { return [] }
        var values = [SIMD3<Float>]()
        values.reserveCapacity(count)
        for index in 0..<count {
            let at = offset + index * stride
            let x = base.loadUnaligned(fromByteOffset: at, as: Float.self)
            let y = base.loadUnaligned(fromByteOffset: at + 4, as: Float.self)
            let z = base.loadUnaligned(fromByteOffset: at + 8, as: Float.self)
            values.append(SIMD3<Float>(x, y, z))
        }
        return values
    }

    /// Unpacks `count` UInt32 values at `offset` with `stride` bytes (testable without ARKit).
    /// Returns an empty array when `count` is not positive, `offset` is negative or `stride`
    /// is under 4 bytes. The caller guarantees the bytes exist.
    static func unpackUInt32(_ base: UnsafeRawPointer, count: Int, offset: Int, stride: Int) -> [UInt32] {
        guard count > 0, offset >= 0, stride >= 4 else { return [] }
        var values = [UInt32]()
        values.reserveCapacity(count)
        for index in 0..<count {
            values.append(base.loadUnaligned(fromByteOffset: offset + index * stride, as: UInt32.self))
        }
        return values
    }

    /// Removes faces that reference a vertex at or beyond `vertexCount`, keeping classes
    /// aligned with the remaining faces (classes stay empty when they were empty or did not
    /// match the face count).
    static func dropInvalidFaces(indices: [UInt32], classes: [UInt8], vertexCount: UInt32) -> (indices: [UInt32], classes: [UInt8]) {
        let faceCount = indices.count / 3
        let keepClasses = classes.count == faceCount
        var keptIndices: [UInt32] = []
        var keptClasses: [UInt8] = []
        keptIndices.reserveCapacity(indices.count)
        for face in 0..<faceCount {
            let a = indices[face * 3], b = indices[face * 3 + 1], c = indices[face * 3 + 2]
            guard a < vertexCount, b < vertexCount, c < vertexCount else { continue }
            keptIndices.append(contentsOf: [a, b, c])
            if keepClasses { keptClasses.append(classes[face]) }
        }
        return (keptIndices, keptClasses)
    }

    /// True when `count` elements of `width` bytes at `offset` with `stride` fit in `length`.
    static func fits(count: Int, offset: Int, stride: Int, width: Int, length: Int) -> Bool {
        guard count > 0, count <= maxElements, offset >= 0, stride >= width, stride <= maxStride else { return false }
        let last = offset + (count - 1) * stride + width
        return last <= length
    }

    // MARK: - ARKit sources

    /// Reads a float3 source, or [] (logged once) when its layout is not float3 or does not fit.
    private static func readFloat3(_ source: ARGeometrySource, name: String) -> [SIMD3<Float>] {
        guard source.count > 0 else { return [] }
        guard source.format == .float3, source.componentsPerVector == 3 else {
            CaptureCoreLog.once("mesh.format.\(name)", "mesh \(name) format \(source.format.rawValue) is not float3; skipped")
            return []
        }
        let buffer = source.buffer
        guard fits(count: source.count, offset: source.offset, stride: source.stride, width: 12, length: buffer.length) else {
            CaptureCoreLog.once("mesh.layout.\(name)", "mesh \(name) layout does not fit its buffer; skipped")
            return []
        }
        return unpackFloat3(UnsafeRawPointer(buffer.contents()), count: source.count,
                            offset: source.offset, stride: source.stride)
    }

    /// Reads triangle indices (UInt32, or UInt16 widened), or [] (logged once) for another
    /// primitive type or a layout that does not fit.
    private static func readIndices(_ element: ARGeometryElement) -> [UInt32] {
        guard element.count > 0 else { return [] }
        guard element.primitiveType == .triangle, element.indexCountPerPrimitive == 3 else {
            CaptureCoreLog.once("mesh.faces.type", "mesh faces are not triangles; skipped")
            return []
        }
        let total = element.count * 3
        let width = element.bytesPerIndex
        let buffer = element.buffer
        guard width == 4 || width == 2,
              fits(count: total, offset: 0, stride: width, width: width, length: buffer.length) else {
            CaptureCoreLog.once("mesh.faces.layout", "mesh face index layout (\(width) bytes) does not fit; skipped")
            return []
        }
        let base = UnsafeRawPointer(buffer.contents())
        if width == 4 {
            return unpackUInt32(base, count: total, offset: 0, stride: 4)
        }
        var values = [UInt32]()
        values.reserveCapacity(total)
        for index in 0..<total {
            values.append(UInt32(base.loadUnaligned(fromByteOffset: index * 2, as: UInt16.self)))
        }
        return values
    }

    /// Reads one UInt8 class per face, or [] (logged once) when the source does not match.
    private static func readClasses(_ source: ARGeometrySource, faceCount: Int) -> [UInt8] {
        guard faceCount > 0 else { return [] }
        guard source.format == .uchar, source.count >= faceCount else {
            CaptureCoreLog.once("mesh.classes.format", "mesh classification format or count unexpected; classes dropped")
            return []
        }
        let buffer = source.buffer
        guard fits(count: faceCount, offset: source.offset, stride: source.stride, width: 1, length: buffer.length) else {
            CaptureCoreLog.once("mesh.classes.layout", "mesh classification layout does not fit; classes dropped")
            return []
        }
        let base = UnsafeRawPointer(buffer.contents())
        var values = [UInt8](repeating: 0, count: faceCount)
        for face in 0..<faceCount {
            values[face] = base.load(fromByteOffset: source.offset + face * source.stride, as: UInt8.self)
        }
        return values
    }
}
