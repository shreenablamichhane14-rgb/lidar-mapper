import Foundation
import simd

/// One ARKit mesh anchor as delivered (D8): anchor-local geometry plus the anchor
/// transform. World space is derived with `worldPositions`.
struct MeshChunk: Equatable {
    /// `ARMeshAnchor.identifier`.
    var anchorID: UUID
    /// Anchor to world (`ARMeshAnchor.transform`) at the time of this snapshot.
    var transform: simd_float4x4
    /// How many updates the anchor had received when this snapshot was taken.
    var updateCount: UInt32
    /// Vertex positions, anchor-local meters.
    var positions: [SIMD3<Float>]
    /// Vertex normals, anchor-local: empty or one per vertex.
    var normals: [SIMD3<Float>]
    /// Triangle corner indices, 3 per face.
    var indices: [UInt32]
    /// `ARMeshClassification` raw value per face: empty or one per face.
    var classes: [UInt8]

    /// Creates a chunk.
    init(anchorID: UUID, transform: simd_float4x4, updateCount: UInt32, positions: [SIMD3<Float>],
         normals: [SIMD3<Float>] = [], indices: [UInt32], classes: [UInt8] = []) {
        self.anchorID = anchorID
        self.transform = transform
        self.updateCount = updateCount
        self.positions = positions
        self.normals = normals
        self.indices = indices
        self.classes = classes
    }

    /// Number of whole faces.
    var faceCount: Int { indices.count / 3 }

    /// Positions transformed to world space by `transform`.
    var worldPositions: [SIMD3<Float>] {
        let t = transform
        return positions.map { p in
            let h = simd_mul(t, SIMD4<Float>(p, 1))
            return SIMD3<Float>(h.x, h.y, h.z)
        }
    }

    /// The geometry as a Geometry `TriangleMesh`, in world space or anchor-local.
    func toTriangleMesh(world: Bool) -> TriangleMesh {
        TriangleMesh(positions: world ? worldPositions : positions,
                     indices: Array(indices.prefix(faceCount * 3)))
    }

    /// Field-wise equality (the transform compared element by element).
    static func == (lhs: MeshChunk, rhs: MeshChunk) -> Bool {
        lhs.anchorID == rhs.anchorID && Transform4(lhs.transform) == Transform4(rhs.transform)
            && lhs.updateCount == rhs.updateCount && lhs.positions == rhs.positions
            && lhs.normals == rhs.normals && lhs.indices == rhs.indices && lhs.classes == rhs.classes
    }
}

/// Bounds-checked little-endian reader for Core's binary formats. Every read uses
/// `loadUnaligned`, so no alignment is assumed, and throws `CoreError.corruptFile` when
/// the data ends early.
struct CoreByteReader {
    /// The bytes being read (may be a slice; offsets are relative to its start).
    let data: Data
    /// Name used in error messages.
    let fileKind: String
    /// Offset of the next byte to read.
    private(set) var offset = 0

    /// Creates a reader at offset 0.
    init(_ data: Data, fileKind: String) {
        self.data = data
        self.fileKind = fileKind
    }

    /// Bytes left after `offset`.
    var remaining: Int { data.count - offset }

    /// Throws unless `count` more bytes are available.
    func require(_ count: Int) throws {
        guard count >= 0, count <= remaining else {
            throw CoreError.corruptFile("\(fileKind): need \(count) bytes at offset \(offset), have \(remaining)")
        }
    }

    /// Reads raw bytes.
    mutating func readBytes(_ count: Int) throws -> [UInt8] {
        try require(count)
        let start = offset
        let bytes = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [UInt8] in Array(raw[start..<(start + count)]) }
        offset += count
        return bytes
    }

    /// Reads one byte.
    mutating func readUInt8() throws -> UInt8 {
        try require(1)
        let start = offset
        let value = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> UInt8 in
            raw.loadUnaligned(fromByteOffset: start, as: UInt8.self)
        }
        offset += 1
        return value
    }

    /// Reads a little-endian UInt16.
    mutating func readUInt16() throws -> UInt16 {
        try require(2)
        let start = offset
        let value = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> UInt16 in
            raw.loadUnaligned(fromByteOffset: start, as: UInt16.self)
        }
        offset += 2
        return UInt16(littleEndian: value)
    }

    /// Reads a little-endian UInt32.
    mutating func readUInt32() throws -> UInt32 {
        try require(4)
        let start = offset
        let value = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> UInt32 in
            raw.loadUnaligned(fromByteOffset: start, as: UInt32.self)
        }
        offset += 4
        return UInt32(littleEndian: value)
    }

    /// Reads a little-endian UInt64.
    mutating func readUInt64() throws -> UInt64 {
        let low = UInt64(try readUInt32())
        let high = UInt64(try readUInt32())
        return high << 32 | low
    }

    /// Reads a little-endian Float32.
    mutating func readFloat32() throws -> Float {
        Float(bitPattern: try readUInt32())
    }

    /// Reads a UUID stored as 16 raw bytes.
    mutating func readUUID() throws -> UUID {
        let bytes = try readBytes(16)
        guard let id = UUIDBytes.uuid(from: bytes) else {
            throw CoreError.corruptFile("\(fileKind): bad UUID")
        }
        return id
    }

    /// Reads `count` little-endian UInt32 values in one pass.
    mutating func readUInt32Array(_ count: Int) throws -> [UInt32] {
        guard count >= 0, count <= Int.max / 4 else { throw CoreError.corruptFile("\(fileKind): bad count \(count)") }
        try require(count * 4)
        let start = offset
        let values = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [UInt32] in
            var out = [UInt32]()
            out.reserveCapacity(count)
            for i in 0..<count {
                out.append(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: start + 4 * i, as: UInt32.self)))
            }
            return out
        }
        offset += count * 4
        return values
    }

    /// Reads `count` packed Float32 triples (stride 12 bytes).
    mutating func readPackedVec3(_ count: Int) throws -> [SIMD3<Float>] {
        guard count >= 0, count <= Int.max / 3 else { throw CoreError.corruptFile("\(fileKind): bad count \(count)") }
        let raw = try readUInt32Array(count * 3)
        var out = [SIMD3<Float>]()
        out.reserveCapacity(count)
        for i in 0..<count {
            out.append(SIMD3<Float>(Float(bitPattern: raw[3 * i]), Float(bitPattern: raw[3 * i + 1]),
                                    Float(bitPattern: raw[3 * i + 2])))
        }
        return out
    }

    /// Reads a 4-byte ASCII magic and throws unless it equals `expected`.
    mutating func expectMagic(_ expected: String) throws {
        let bytes = try readBytes(4)
        guard bytes == Array(expected.utf8) else {
            throw CoreError.corruptFile("\(fileKind): bad magic")
        }
    }
}

/// Writers for the shared binary helpers not present in `ByteWriter`.
extension ByteWriter {
    /// Appends a 64-bit unsigned integer, little endian (low word first).
    mutating func appendUInt64(_ value: UInt64) {
        appendUInt32(UInt32(truncatingIfNeeded: value))
        appendUInt32(UInt32(truncatingIfNeeded: value >> 32))
    }

    /// Appends 16 floats of a 4x4 matrix, column-major.
    mutating func appendMatrix(_ m: simd_float4x4) {
        for value in Transform4(m).m { appendFloat32(value) }
    }

    /// Appends each vector as 3 packed Float32 values (stride 12).
    mutating func appendPackedVec3(_ values: [SIMD3<Float>]) {
        for v in values {
            appendFloat32(v.x)
            appendFloat32(v.y)
            appendFloat32(v.z)
        }
    }
}

extension CoreByteReader {
    /// Reads 16 Float32 values as a column-major 4x4 matrix.
    mutating func readMatrix() throws -> simd_float4x4 {
        var values: [Float] = []
        values.reserveCapacity(16)
        for _ in 0..<16 { values.append(try readFloat32()) }
        return (Transform4(elements: values) ?? Transform4.identity).simd
    }
}

/// `.mchk` file (D8): one mesh anchor snapshot, anchor-local.
///
/// Layout, little endian, packed: magic "MCHK", version UInt16 = 1, flags UInt16 (bit 0
/// normals, bit 1 classes), vertexCount UInt32, faceCount UInt32, anchorID 16 bytes,
/// updateCount UInt32, transform 16 x Float32 column-major (100-byte header); then
/// positions Float32 x3, normals Float32 x3 (if flagged), indices UInt32 x3 per face,
/// classes UInt8 per face (if flagged).
enum MeshChunkFile {
    /// Format version written and accepted.
    static let version: UInt16 = 1
    /// Header size in bytes.
    static let headerSize = 100

    /// Serializes a chunk. Normals are written only when there is one per vertex, classes
    /// only when there is one per face; a trailing partial face is dropped.
    static func encode(_ chunk: MeshChunk) -> Data {
        let vertexCount = chunk.positions.count
        let faceCount = chunk.faceCount
        let hasNormals = !chunk.normals.isEmpty && chunk.normals.count == vertexCount
        let hasClasses = !chunk.classes.isEmpty && chunk.classes.count == faceCount
        var flags: UInt16 = 0
        if hasNormals { flags |= 1 }
        if hasClasses { flags |= 2 }
        var w = ByteWriter(capacity: headerSize + vertexCount * 24 + faceCount * 13)
        w.appendString("MCHK")
        w.appendUInt16(version)
        w.appendUInt16(flags)
        w.appendUInt32(UInt32(truncatingIfNeeded: vertexCount))
        w.appendUInt32(UInt32(truncatingIfNeeded: faceCount))
        for byte in UUIDBytes.bytes(of: chunk.anchorID) { w.appendUInt8(byte) }
        w.appendUInt32(chunk.updateCount)
        w.appendMatrix(chunk.transform)
        w.appendPackedVec3(chunk.positions)
        if hasNormals { w.appendPackedVec3(chunk.normals) }
        for index in chunk.indices.prefix(faceCount * 3) { w.appendUInt32(index) }
        if hasClasses { for c in chunk.classes { w.appendUInt8(c) } }
        return w.data
    }

    /// Parses a chunk. Throws `CoreError.corruptFile` on a bad header, truncated data,
    /// trailing bytes or an index out of range.
    static func decode(_ data: Data) throws -> MeshChunk {
        var r = CoreByteReader(data, fileKind: "mchk")
        try r.expectMagic("MCHK")
        let fileVersion = try r.readUInt16()
        guard fileVersion == version else { throw CoreError.corruptFile("mchk: version \(fileVersion)") }
        let flags = try r.readUInt16()
        let vertexCount = Int(try r.readUInt32())
        let faceCount = Int(try r.readUInt32())
        let anchorID = try r.readUUID()
        let updateCount = try r.readUInt32()
        let transform = try r.readMatrix()
        let positions = try r.readPackedVec3(vertexCount)
        var normals: [SIMD3<Float>] = []
        if flags & 1 != 0 { normals = try r.readPackedVec3(vertexCount) }
        let indices = try r.readUInt32Array(faceCount * 3)
        var classes: [UInt8] = []
        if flags & 2 != 0 { classes = try r.readBytes(faceCount) }
        guard r.remaining == 0 else { throw CoreError.corruptFile("mchk: \(r.remaining) trailing bytes") }
        if let bad = indices.first(where: { Int($0) >= vertexCount }) {
            throw CoreError.corruptFile("mchk: index \(bad) out of range \(vertexCount)")
        }
        return MeshChunk(anchorID: anchorID, transform: transform, updateCount: updateCount,
                         positions: positions, normals: normals, indices: indices, classes: classes)
    }
}

/// A decoded depth map: row-major meters plus per-pixel ARKit confidence (0 low, 1 medium,
/// 2 high), in sensor landscape orientation.
struct DepthMap: Equatable, Sendable {
    /// Width in pixels.
    var width: Int
    /// Height in pixels.
    var height: Int
    /// Depth in meters, row-major, `width * height` values.
    var depth: [Float]
    /// Confidence, row-major, `width * height` values, or empty when none was stored.
    var confidence: [UInt8]

    /// Depth at pixel (x, y), or nil outside the map.
    func depthAt(x: Int, y: Int) -> Float? {
        guard x >= 0, y >= 0, x < width, y < height, y * width + x < depth.count else { return nil }
        return depth[y * width + x]
    }
}

/// `.dpth` file: magic "DPTH", version UInt16 = 1, width UInt16, height UInt16, flags
/// UInt16 (bit 0 confidence present) (12-byte header); then Float16 depth row-major, then
/// UInt8 confidence row-major when flagged.
enum DepthFile {
    /// Format version written and accepted.
    static let version: UInt16 = 1

    /// Serializes a depth map. Sizes are clamped to 0...65535; missing depth values are
    /// written as 0, extra values are dropped. Confidence is stored only when it has at
    /// least one value per pixel.
    static func encode(width: Int, height: Int, depth: [Float], confidence: [UInt8]) -> Data {
        let w16 = UInt16(clamping: width), h16 = UInt16(clamping: height)
        let count = Int(w16) * Int(h16)
        let hasConfidence = confidence.count >= count && count > 0
        var w = ByteWriter(capacity: 12 + count * 3)
        w.appendString("DPTH")
        w.appendUInt16(version)
        w.appendUInt16(w16)
        w.appendUInt16(h16)
        w.appendUInt16(hasConfidence ? 1 : 0)
        for i in 0..<count {
            w.appendUInt16(Float16(i < depth.count ? depth[i] : 0).bitPattern)
        }
        if hasConfidence { for i in 0..<count { w.appendUInt8(confidence[i]) } }
        return w.data
    }

    /// Parses a depth file. Throws `CoreError.corruptFile` when malformed.
    static func decode(_ data: Data) throws -> DepthMap {
        var r = CoreByteReader(data, fileKind: "dpth")
        try r.expectMagic("DPTH")
        let fileVersion = try r.readUInt16()
        guard fileVersion == version else { throw CoreError.corruptFile("dpth: version \(fileVersion)") }
        let width = Int(try r.readUInt16())
        let height = Int(try r.readUInt16())
        let flags = try r.readUInt16()
        let count = width * height
        try r.require(count * 2)
        var depth = [Float]()
        depth.reserveCapacity(count)
        for _ in 0..<count { depth.append(Float(Float16(bitPattern: try r.readUInt16()))) }
        var confidence: [UInt8] = []
        if flags & 1 != 0 { confidence = try r.readBytes(count) }
        guard r.remaining == 0 else { throw CoreError.corruptFile("dpth: \(r.remaining) trailing bytes") }
        return DepthMap(width: width, height: height, depth: depth, confidence: confidence)
    }
}

/// `poses.ptrk` pose track (D8): header magic "PTRK", version UInt16 = 1, recordSize
/// UInt16, then fixed-size records: timestamp Float64, transform 16 x Float32
/// column-major, tracking UInt8, thermal UInt8, exposureDuration Float32. The file is
/// append-only; a partial last record (crash while writing) is ignored on decode.
enum PoseTrackFile {
    /// Format version written and accepted.
    static let version: UInt16 = 1
    /// Header size in bytes.
    static let headerSize = 8
    /// Size of one record in bytes: 8 + 64 + 1 + 1 + 4.
    static let recordSize = 78

    /// Appends the file header; call once for a new file.
    static func appendHeader(to w: inout ByteWriter) {
        w.appendString("PTRK")
        w.appendUInt16(version)
        w.appendUInt16(UInt16(recordSize))
    }

    /// Appends one record.
    static func append(_ s: PoseSample, to w: inout ByteWriter) {
        w.appendUInt64(s.timestamp.bitPattern)
        w.appendMatrix(s.transform)
        w.appendUInt8(s.tracking)
        w.appendUInt8(s.thermal)
        w.appendFloat32(s.exposureDuration)
    }

    /// Parses a whole track. Throws on a bad header; ignores a trailing partial record.
    static func decode(_ data: Data) throws -> [PoseSample] {
        var r = CoreByteReader(data, fileKind: "ptrk")
        try r.expectMagic("PTRK")
        let fileVersion = try r.readUInt16()
        let size = Int(try r.readUInt16())
        guard fileVersion == version, size == recordSize else {
            throw CoreError.corruptFile("ptrk: version \(fileVersion) record \(size)")
        }
        var samples: [PoseSample] = []
        samples.reserveCapacity(r.remaining / recordSize)
        while r.remaining >= recordSize {
            let timestamp = Double(bitPattern: try r.readUInt64())
            let transform = try r.readMatrix()
            let tracking = try r.readUInt8()
            let thermal = try r.readUInt8()
            let exposure = try r.readFloat32()
            samples.append(PoseSample(timestamp: timestamp, transform: transform, tracking: tracking,
                                      thermal: thermal, exposureDuration: exposure))
        }
        return samples
    }
}
