import Foundation
import simd

/// Adapts consolidated meshes to the Export writers' input types. With `colorByClass` each
/// vertex carries its face's classification color from `MeshClassPalette` (vertices shared by
/// faces of different classes are split, so every face shows its own class color) and no
/// material is bound, because USD shows `displayColor` only on unbound meshes. Without it
/// there are no vertex colors and the meshes get plain materials: white for measured faces,
/// the Inferred color for hole fills, so estimated geometry stays distinguishable (SPEC,
/// FURNITURE REMOVAL). Pure and nonisolated.
enum MeshExportAdapter {
    /// Name of the measured mesh and its material inside exported files.
    static let measuredName = "measured"
    /// Name of the inferred mesh and its material inside exported files.
    static let inferredName = "inferred"
    /// Color key used for inferred faces while splitting vertices (above every class value).
    private static let inferredKey: UInt8 = 255

    /// One export mesh: positions, area-weighted normals and triangles of `mesh`; per-vertex
    /// class colors (faces flagged `isInferred` get the Inferred color) when `colorByClass`,
    /// otherwise no colors. Faces with an out-of-range index or a non-finite corner are left
    /// out and unused vertices dropped, so `ExportMesh.validate()` passes.
    static func exportMesh(_ mesh: MeshWithAttributes, name: String, colorByClass: Bool) -> ExportMesh {
        let source = sanitized(mesh)
        guard colorByClass else {
            return ExportMesh(name: name, positions: source.mesh.positions, normals: MeshCleanup.normals(source.mesh),
                              indices: source.mesh.indices)
        }
        let normals = MeshCleanup.normals(source.mesh)
        let faces = source.triangleCount
        let vertexCount = source.mesh.positions.count
        var firstKey = [UInt8](repeating: 0, count: vertexCount)
        var firstIndex = [Int32](repeating: -1, count: vertexCount)
        var extra: [UInt64: UInt32] = [:]
        var positions: [SIMD3<Float>] = []
        var outNormals: [SIMD3<Float>] = []
        var colors: [SIMD4<UInt8>] = []
        var indices: [UInt32] = []
        positions.reserveCapacity(vertexCount)
        outNormals.reserveCapacity(vertexCount)
        colors.reserveCapacity(vertexCount)
        indices.reserveCapacity(3 * faces)

        for t in 0..<faces {
            let key = colorKey(source, face: t)
            let color = key == inferredKey ? MeshClassPalette.inferredBytes : MeshClassPalette.bytes(for: key)
            for corner in 0..<3 {
                let v = Int(source.mesh.indices[3 * t + corner])
                if firstIndex[v] < 0 {
                    firstIndex[v] = Int32(positions.count)
                    firstKey[v] = key
                    indices.append(UInt32(positions.count))
                    positions.append(source.mesh.positions[v])
                    outNormals.append(normals[v])
                    colors.append(color)
                } else if firstKey[v] == key {
                    indices.append(UInt32(firstIndex[v]))
                } else {
                    let composite = UInt64(v) << 8 | UInt64(key)
                    if let existing = extra[composite] {
                        indices.append(existing)
                    } else {
                        let index = UInt32(positions.count)
                        extra[composite] = index
                        indices.append(index)
                        positions.append(source.mesh.positions[v])
                        outNormals.append(normals[v])
                        colors.append(color)
                    }
                }
            }
        }
        return ExportMesh(name: name, positions: positions, normals: outNormals, colors: colors, indices: indices)
    }

    /// The measured mesh plus, when given and not empty, the inferred mesh as a second mesh
    /// (every face treated as inferred). Metadata records both triangle counts.
    static func scene(measured: MeshWithAttributes, inferred: MeshWithAttributes?, colorByClass: Bool) -> ExportScene {
        var measuredMesh = exportMesh(measured, name: measuredName, colorByClass: colorByClass)
        var meshes: [ExportMesh] = []
        var materials: [ExportMaterial] = []
        if !colorByClass {
            measuredMesh.materialIndex = materials.count
            materials.append(ExportMaterial(name: measuredName))
        }
        meshes.append(measuredMesh)

        var inferredCount = 0
        if let inferred = inferred, inferred.triangleCount > 0 {
            var flagged = inferred
            flagged.isInferred = [Bool](repeating: true, count: inferred.triangleCount)
            var inferredMesh = exportMesh(flagged, name: inferredName, colorByClass: colorByClass)
            inferredCount = inferredMesh.triangleCount
            if !colorByClass {
                inferredMesh.materialIndex = materials.count
                materials.append(ExportMaterial(name: inferredName, baseColor: MeshClassPalette.inferred))
            }
            meshes.append(inferredMesh)
        }
        let metadata: [String: String] = [
            "measuredTriangles": String(measuredMesh.triangleCount),
            "inferredTriangles": String(inferredCount)
        ]
        return ExportScene(meshes: meshes, materials: materials, metadata: metadata)
    }

    // MARK: - Helpers

    /// Class value of face `t`, or `inferredKey` when the face is flagged inferred.
    private static func colorKey(_ mesh: MeshWithAttributes, face t: Int) -> UInt8 {
        if let flags = mesh.isInferred, t < flags.count, flags[t] { return inferredKey }
        if let classes = mesh.faceClass, t < classes.count { return classes[t] }
        return MeshWithAttributes.unclassified
    }

    /// The mesh without faces that have an out-of-range index or a non-finite corner, with
    /// unused vertices dropped; the input itself when every face is valid and the attribute
    /// arrays are consistent.
    private static func sanitized(_ mesh: MeshWithAttributes) -> MeshWithAttributes {
        let faces = mesh.triangleCount
        var keep = [Bool](repeating: true, count: faces)
        var used = [Bool](repeating: false, count: mesh.mesh.positions.count)
        var allValid = mesh.isConsistent && mesh.mesh.indices.count == 3 * faces
        for t in 0..<faces {
            guard let corners = mesh.mesh.triangle(t),
                  isFinite(corners.0) && isFinite(corners.1) && isFinite(corners.2) else {
                keep[t] = false
                allValid = false
                continue
            }
            used[Int(mesh.mesh.indices[3 * t])] = true
            used[Int(mesh.mesh.indices[3 * t + 1])] = true
            used[Int(mesh.mesh.indices[3 * t + 2])] = true
        }
        if allValid && !used.contains(false) { return mesh }
        return mesh.keepingFaces(keep)
    }

    /// True when all three components are finite.
    private static func isFinite(_ p: SIMD3<Float>) -> Bool {
        p.x.isFinite && p.y.isFinite && p.z.isFinite
    }
}
