import Foundation
import ModelIO
import simd

/// Why the Object Capture model could not be read into a mesh.
enum ObjectModelError: Error, Equatable {
    /// MDLAsset (or, in the fallback, RealityKit) cannot read the file; the payload says why,
    /// for the log.
    case cannotImport(String)
    /// The file holds no triangle submesh (or every triangle was invalid).
    case noTriangles
}

/// Reads the Object Capture USDZ (RESEARCH 3.3 "Reading the finished model") into a Mapper
/// mesh in the file's own frame (meters, y up), with UV-seam duplicates welded so a closed
/// model tests watertight. This is the only file that imports ModelIO. Any queue off main;
/// never call `mesh(fromUSDZ:)` on the main thread (the RealityKit fallback in
/// `ObjectModelEntityLoader.swift` is the only main-actor path).
enum ObjectModelLoader {
    /// Positions closer than this are one vertex (UV seams duplicate them), meters.
    static let weldTolerance: Float = 1e-5
    /// LogStore category of the whole module.
    static let logCategory = "objectmodel"

    /// `MDLAsset.canImportFileExtension("usdz")` (logged once).
    static var canReadUSDZ: Bool { usdzImportSupported }

    /// Evaluated once, on first use, and logged then.
    private static let usdzImportSupported: Bool = {
        let supported = MDLAsset.canImportFileExtension("usdz")
        LogStore.shared.write("ModelIO canImportFileExtension(usdz): \(supported)", category: logCategory)
        return supported
    }()

    /// Positions and triangles collected from the meshes of one asset, before welding.
    private struct Collected {
        /// Positions in the asset's root frame.
        var positions: [SIMD3<Float>] = []
        /// Triangle corners into `positions`.
        var indices: [UInt32] = []
        /// Submeshes that were read.
        var submeshesRead = 0
        /// Why submeshes or meshes were skipped, for the log.
        var skipped: [String] = []
    }

    // MARK: - ModelIO path

    /// `MDLAsset(url:)`, every `childObjects(of: MDLMesh.self)`: positions through
    /// `vertexAttributeData(forAttributeNamed: MDLVertexAttributePosition, as: .float3)`
    /// honoring its `stride`, transformed by `MDLTransform.globalTransform(with:atTime: 0)`;
    /// triangle submeshes only (`geometryType == .triangles`, 16- or 32-bit indices; others
    /// skipped and logged); welded with `TriangleMesh.welded(tolerance: weldTolerance)`.
    /// Throws `ObjectModelError`: `.cannotImport` when the file is missing, ModelIO cannot
    /// import USDZ or the asset has no mesh; `.noTriangles` when no triangle survives.
    static func mesh(fromUSDZ url: URL) throws -> MeshWithAttributes {
        let started = ProcessInfo.processInfo.systemUptime
        let name = url.lastPathComponent
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ObjectModelError.cannotImport("file missing: \(name)")
        }
        guard canReadUSDZ else {
            throw ObjectModelError.cannotImport("ModelIO cannot import usdz on this device")
        }
        let asset = MDLAsset(url: url)
        let meshes = asset.childObjects(of: MDLMesh.self).compactMap { $0 as? MDLMesh }
        guard !meshes.isEmpty else {
            throw ObjectModelError.cannotImport("no MDLMesh in \(name)")
        }
        var collected = Collected()
        for mesh in meshes {
            append(mesh, to: &collected)
        }
        let assetBox = asset.boundingBox
        let assetMin = SIMD3<Float>(assetBox.minBounds.x, assetBox.minBounds.y, assetBox.minBounds.z)
        let assetMax = SIMD3<Float>(assetBox.maxBounds.x, assetBox.maxBounds.y, assetBox.maxBounds.z)
        for note in collected.skipped {
            LogStore.shared.write("ModelIO \(name): skipped \(note)", category: logCategory)
        }
        let rawTriangles = collected.indices.count / 3
        guard rawTriangles > 0 else { throw ObjectModelError.noTriangles }
        let result = weldedModelMesh(TriangleMesh(positions: collected.positions, indices: collected.indices))
        guard result.triangleCount > 0 else { throw ObjectModelError.noTriangles }

        let seconds = ProcessInfo.processInfo.systemUptime - started
        let fields: [String] = [
            "\(meshes.count) meshes",
            "\(collected.submeshesRead) triangle submeshes",
            "\(collected.skipped.count) skipped",
            "\(rawTriangles) triangles read",
            "\(result.triangleCount) welded, \(result.mesh.positions.count) vertices",
            "asset bounds " + boundsText(min: assetMin, max: assetMax),
            "mesh bounds " + boundsText(result.mesh.boundingBox),
            String(format: "%.2f s", seconds)
        ]
        LogStore.shared.write("ModelIO read \(name): " + fields.joined(separator: ", "), category: logCategory)
        return result
    }

    /// Reads one MDLMesh into `collected`: its positions (stride honored, global transform
    /// applied) and the triangles of its 16- and 32-bit triangle submeshes. Triangles with an
    /// index outside the mesh are dropped; a mirroring transform flips the winding so the
    /// outside stays counter-clockwise.
    private static func append(_ mesh: MDLMesh, to collected: inout Collected) {
        let label = mesh.name.isEmpty ? "mesh" : "mesh \(mesh.name)"
        let vertexCount = mesh.vertexCount
        guard vertexCount > 0 else {
            collected.skipped.append("\(label): no vertices")
            return
        }
        guard let attribute = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributePosition, as: .float3) else {
            collected.skipped.append("\(label): no float3 positions")
            return
        }
        let floatSize = MemoryLayout<Float>.size
        let stride = attribute.stride
        guard stride >= 3 * floatSize else {
            collected.skipped.append("\(label): position stride \(stride) bytes")
            return
        }
        let base = collected.positions.count
        guard base + vertexCount < Int(UInt32.max) else {
            collected.skipped.append("\(label): too many vertices")
            return
        }
        let matrix: simd_float4x4 = MDLTransform.globalTransform(with: mesh, atTime: 0)
        collected.positions.reserveCapacity(base + vertexCount)
        withExtendedLifetime(attribute) {
            let start = UnsafeRawPointer(attribute.dataStart)
            for i in 0..<vertexCount {
                let offset = i * stride
                let x = start.loadUnaligned(fromByteOffset: offset, as: Float.self)
                let y = start.loadUnaligned(fromByteOffset: offset + floatSize, as: Float.self)
                let z = start.loadUnaligned(fromByteOffset: offset + 2 * floatSize, as: Float.self)
                collected.positions.append(transformed(SIMD3<Float>(x, y, z), by: matrix))
            }
        }
        let mirrored = simd_determinant(matrix) < 0
        let limit = UInt32(base + vertexCount)
        guard let submeshes = mesh.submeshes else {
            collected.skipped.append("\(label): no submeshes")
            return
        }
        for case let submesh as MDLSubmesh in submeshes {
            guard submesh.geometryType == .triangles else {
                collected.skipped.append("\(label): submesh geometry type \(submesh.geometryType.rawValue)")
                continue
            }
            let width: Int
            if submesh.indexType == .uInt16 {
                width = 2
            } else if submesh.indexType == .uInt32 {
                width = 4
            } else {
                collected.skipped.append("\(label): index bit depth \(submesh.indexType.rawValue)")
                continue
            }
            let buffer = submesh.indexBuffer
            let map = buffer.map()
            let found: [UInt32]? = withExtendedLifetime(map) {
                let bytes = UnsafeRawBufferPointer(start: UnsafeRawPointer(map.bytes), count: buffer.length)
                return triangleIndices(bytes, count: submesh.indexCount, bytesPerIndex: width, vertexBase: UInt32(base))
            }
            guard let corners = found else {
                collected.skipped.append("\(label): unreadable index buffer (\(submesh.indexCount) indices)")
                continue
            }
            collected.submeshesRead += 1
            var dropped = 0
            for t in 0..<(corners.count / 3) {
                let a = corners[3 * t], b = corners[3 * t + 1], c = corners[3 * t + 2]
                guard a < limit, b < limit, c < limit else {
                    dropped += 1
                    continue
                }
                collected.indices.append(contentsOf: mirrored ? [a, c, b] : [a, b, c])
            }
            if dropped > 0 {
                collected.skipped.append("\(label): \(dropped) triangles with an out-of-range index")
            }
        }
    }

    // MARK: - Pure helpers

    /// Pure helper: indices from a raw index buffer, offset by `vertexBase`; nil when
    /// `bytesPerIndex` is not 2 or 4 or `count` is not a multiple of 3 (also when `count` is
    /// negative, the buffer is shorter than `count` indices or an offset index overflows).
    /// Reads little-endian values without assuming alignment.
    static func triangleIndices(_ bytes: UnsafeRawBufferPointer, count: Int, bytesPerIndex: Int, vertexBase: UInt32) -> [UInt32]? {
        guard bytesPerIndex == 2 || bytesPerIndex == 4 else { return nil }
        guard count >= 0, count % 3 == 0 else { return nil }
        let needed = count.multipliedReportingOverflow(by: bytesPerIndex)
        guard !needed.overflow, needed.partialValue <= bytes.count else { return nil }
        var result: [UInt32] = []
        result.reserveCapacity(count)
        for i in 0..<count {
            let offset = i * bytesPerIndex
            let value: UInt32
            if bytesPerIndex == 2 {
                value = UInt32(bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
            } else {
                value = bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
            }
            let shifted = value.addingReportingOverflow(vertexBase)
            guard !shifted.overflow else { return nil }
            result.append(shifted.partialValue)
        }
        return result
    }

    /// The finishing step both loaders share: `welded(tolerance: weldTolerance)`, then faces
    /// with a non-finite corner and every vertex no face uses are dropped, so stray vertices
    /// never widen the measured box.
    static func weldedModelMesh(_ raw: TriangleMesh) -> MeshWithAttributes {
        let welded = raw.welded(tolerance: weldTolerance)
        var keep = [Bool](repeating: false, count: welded.triangleCount)
        for t in 0..<welded.triangleCount {
            guard let corners = welded.triangle(t) else { continue }
            keep[t] = isFinite(corners.0) && isFinite(corners.1) && isFinite(corners.2)
        }
        return MeshWithAttributes(mesh: welded).keepingFaces(keep)
    }

    /// `p` moved by the affine or projective matrix `m`.
    static func transformed(_ p: SIMD3<Float>, by m: simd_float4x4) -> SIMD3<Float> {
        let h: SIMD4<Float> = simd_mul(m, SIMD4<Float>(p, 1))
        let point = SIMD3<Float>(h.x, h.y, h.z)
        return h.w != 0 && h.w != 1 ? point / h.w : point
    }

    /// True when all three components are finite.
    static func isFinite(_ p: SIMD3<Float>) -> Bool {
        p.x.isFinite && p.y.isFinite && p.z.isFinite
    }

    /// Log text of a mesh's bounds.
    static func boundsText(_ box: AABB3) -> String {
        box.isEmpty ? "empty" : boundsText(min: box.min, max: box.max)
    }

    /// Log text of a box in meters with millimeter digits.
    static func boundsText(min low: SIMD3<Float>, max high: SIMD3<Float>) -> String {
        "min " + vectorText(low) + " max " + vectorText(high)
    }

    /// Log text of a vector in meters with millimeter digits.
    static func vectorText(_ v: SIMD3<Float>) -> String {
        String(format: "(%.3f, %.3f, %.3f)", Double(v.x), Double(v.y), Double(v.z))
    }
}
