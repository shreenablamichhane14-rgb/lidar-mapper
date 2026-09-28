import Foundation
import simd

/// Pure builders that turn meshes and boxes into `ViewerPart`s. Any queue; call them off the
/// main actor, because a 300k-triangle view mesh takes tens of milliseconds to split.
///
/// Per-face color needs no shader: faces are sorted into parts and each part gets one material
/// (RESEARCH 3.5, no fixed-function material reads vertex colors).
enum ViewerContentBuilder {
    /// Edge of the square floor tiles (world x and z) that meshes are split into, in meters.
    static let tileSize: Float = 2
    /// Color of Solid Color parts (light gray).
    static let solidColor = SIMD4<Float>(0.82, 0.82, 0.82, 1)
    /// Color of Wireframe parts on the dark scan background.
    static let wireframeColor = SIMD4<Float>(0.85, 0.85, 0.85, 1)
    /// Raw Scan color for a class missing from the palette (and from palette entry 0).
    static let fallbackClassColor = SIMD4<Float>(0.62, 0.62, 0.62, 1)
    /// Largest tile index along one axis; keeps the Int32 conversion safe for huge meshes.
    private static let maxTileIndex: Float = 1_000_000

    /// Face indices grouped by 2 m tile of their centroid.
    ///
    /// Tiles are squares of `tileSize` on the world x-z plane, counted from the smallest
    /// corner x and z of the valid faces, so a strip 6 m long always gives 3 tiles. Groups are ordered by tile
    /// (z, then x) and faces keep ascending order inside a group. Faces with an out-of-range
    /// index or a non-finite centroid are left out. A `tileSize` that is not positive and
    /// finite puts every valid face in one group.
    static func tiles(_ mesh: TriangleMesh, tileSize: Float) -> [[Int]] {
        let faceCount = mesh.triangleCount
        var faces: [Int] = []
        var centroids: [SIMD2<Float>] = []
        faces.reserveCapacity(faceCount)
        centroids.reserveCapacity(faceCount)
        var minX = Float.infinity
        var minZ = Float.infinity
        for f in 0..<faceCount {
            guard let corners = mesh.triangle(f) else { continue }
            let c = (corners.0 + corners.1 + corners.2) / 3
            guard c.x.isFinite, c.y.isFinite, c.z.isFinite else { continue }
            faces.append(f)
            centroids.append(SIMD2<Float>(c.x, c.z))
            let lowX = Swift.min(corners.0.x, Swift.min(corners.1.x, corners.2.x))
            let lowZ = Swift.min(corners.0.z, Swift.min(corners.1.z, corners.2.z))
            minX = Swift.min(minX, lowX)
            minZ = Swift.min(minZ, lowZ)
        }
        guard !faces.isEmpty else { return [] }
        guard tileSize > 0, tileSize.isFinite else { return [faces] }

        var groups: [SIMD2<Int32>: [Int]] = [:]
        for k in 0..<faces.count {
            let gx = tileIndex((centroids[k].x - minX) / tileSize)
            let gz = tileIndex((centroids[k].y - minZ) / tileSize)
            groups[SIMD2<Int32>(gx, gz), default: []].append(faces[k])
        }
        let keys = groups.keys.sorted { lhs, rhs in
            lhs.y != rhs.y ? lhs.y < rhs.y : lhs.x < rhs.x
        }
        return keys.compactMap { groups[$0] }
    }

    /// Raw Scan style: one part per (tile, class) with the palette color; Solid and Wireframe styles
    /// ignore classes. Faces with isInferred go to layer .rawInferred with the `inferredColor`.
    ///
    /// Details: Raw Scan parts use `.unlit`, Solid Color `.lit(solidColor)`, Wireframe
    /// `.wireframe(wireframeColor)`; Textured and Photo Realistic have no texture coordinates
    /// here and fall back to Solid Color (textured parts come from `texturedPart`). Inferred
    /// faces use the same material kind with `inferredColor`. Every part carries per-vertex
    /// normals of the whole mesh (no shading seams at tile borders) and the pick tag
    /// `.rawMesh`. Part ids are "<idPrefix>.t<tile>.c<class>" (Raw Scan), "<idPrefix>.t<tile>"
    /// (other styles) and "<idPrefix>.t<tile>.inferred". Attribute arrays whose length does not
    /// match the face count are ignored.
    static func meshParts(_ mesh: MeshWithAttributes, style: ViewerDisplayStyle, palette: [UInt8: SIMD4<Float>],
                          inferredColor: SIMD4<Float>, layer: ViewerLayer, idPrefix: String) -> [ViewerPart] {
        let geometry = mesh.mesh
        let faceCount = geometry.triangleCount
        guard faceCount > 0 else { return [] }
        let classes: [UInt8]? = mesh.faceClass.flatMap { $0.count == faceCount ? $0 : nil }
        let inferredFlags: [Bool]? = mesh.isInferred.flatMap { $0.count == faceCount ? $0 : nil }
        let normals = geometry.vertexNormals
        var remap = [Int32](repeating: -1, count: geometry.positions.count)
        var parts: [ViewerPart] = []

        for (t, faces) in tiles(geometry, tileSize: tileSize).enumerated() {
            var measured: [Int] = []
            var inferred: [Int] = []
            for f in faces {
                if let flags = inferredFlags, flags[f] {
                    inferred.append(f)
                } else {
                    measured.append(f)
                }
            }
            if style == .rawScan {
                var byClass: [UInt8: [Int]] = [:]
                for f in measured {
                    let value = classes?[f] ?? MeshWithAttributes.unclassified
                    byClass[value, default: []].append(f)
                }
                for value in byClass.keys.sorted() {
                    let color = palette[value] ?? palette[MeshWithAttributes.unclassified] ?? fallbackClassColor
                    let group = byClass[value] ?? []
                    parts.append(makePart(id: "\(idPrefix).t\(t).c\(value)", faces: group, mesh: geometry,
                                          normals: normals, remap: &remap, material: .unlit(color),
                                          layer: layer, pickTag: .rawMesh))
                }
            } else if !measured.isEmpty {
                let color = style == .wireframe ? wireframeColor : solidColor
                parts.append(makePart(id: "\(idPrefix).t\(t)", faces: measured, mesh: geometry,
                                      normals: normals, remap: &remap, material: material(for: style, color: color),
                                      layer: layer, pickTag: .rawMesh))
            }
            if !inferred.isEmpty {
                parts.append(makePart(id: "\(idPrefix).t\(t).inferred", faces: inferred, mesh: geometry,
                                      normals: normals, remap: &remap,
                                      material: material(for: style, color: inferredColor),
                                      layer: .rawInferred, pickTag: .rawMesh))
            }
        }
        return parts
    }

    /// Box of a detected object (12 triangles, translucent fill plus a wireframe copy).
    ///
    /// Returns two parts: the fill (`.translucent(color)`, 24 vertices with flat outward
    /// normals, 12 outward-wound triangles, carrying `pickTag`) and the outline
    /// (`.wireframe` with the same color at full opacity, id "<id>.outline", not pickable).
    /// A box with a non-finite corner gives no parts.
    static func boxParts(_ box: OrientedBox, color: SIMD4<Float>, layer: ViewerLayer, pickTag: ViewerPickTag?, id: String) -> [ViewerPart] {
        let corners = box.corners
        guard corners.count == 8,
              corners.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else { return [] }
        // Each face as a cycle of corner numbers (bit 0 axis 0, bit 1 axis 1, bit 2 axis 2).
        let quads: [[Int]] = [[0, 4, 6, 2], [1, 3, 7, 5], [0, 1, 5, 4], [2, 6, 7, 3], [0, 2, 3, 1], [4, 5, 7, 6]]
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        positions.reserveCapacity(24)
        normals.reserveCapacity(24)
        indices.reserveCapacity(36)
        for quad in quads {
            let a = corners[quad[0]], b = corners[quad[1]], c = corners[quad[2]], d = corners[quad[3]]
            let sumAB: SIMD3<Float> = a + b
            let sumCD: SIMD3<Float> = c + d
            let faceCenter: SIMD3<Float> = (sumAB + sumCD) * Float(0.25)
            let outward: SIMD3<Float> = faceCenter - box.center
            var order = quad
            let outwardUnit = safeNormalize(outward, fallback: SIMD3<Float>(0, 1, 0))
            var normal = safeNormalize(simd_cross(b - a, c - a), fallback: outwardUnit)
            if simd_dot(normal, outward) < 0 {
                order = [quad[0], quad[3], quad[2], quad[1]]
                normal = -normal
            }
            let base = UInt32(positions.count)
            for k in order {
                positions.append(corners[k])
                normals.append(normal)
            }
            indices.append(contentsOf: [base, base + 1, base + 2, base, base + 2, base + 3])
        }
        let fill = ViewerPart(id: id, positions: positions, normals: normals, indices: indices,
                              material: .translucent(color), layer: layer, pickTag: pickTag)
        let opaque = SIMD4<Float>(color.x, color.y, color.z, 1)
        let outline = ViewerPart(id: id + ".outline", positions: positions, normals: normals, indices: indices,
                                 material: .wireframe(opaque), layer: layer, pickTag: nil)
        return [fill, outline]
    }

    /// Un-indexes a part when uvs are per corner (texture atlases).
    ///
    /// Face f's corners become vertices 3f', 3f'+1, 3f'+2 of the output (f' counts only faces
    /// with valid indices) with `cornerUVs[3f + k]` as their uv (zero when missing), and the
    /// output indices are 0, 1, 2, ... in order.
    static func expandCorners(positions: [SIMD3<Float>], indices: [UInt32], cornerUVs: [SIMD2<Float>]) -> (positions: [SIMD3<Float>], uvs: [SIMD2<Float>], indices: [UInt32]) {
        let faceCount = indices.count / 3
        let vertexCount = positions.count
        var outPositions: [SIMD3<Float>] = []
        var outUVs: [SIMD2<Float>] = []
        var outIndices: [UInt32] = []
        outPositions.reserveCapacity(faceCount * 3)
        outUVs.reserveCapacity(faceCount * 3)
        outIndices.reserveCapacity(faceCount * 3)
        for f in 0..<faceCount {
            let first = 3 * f
            guard Int(indices[first]) < vertexCount,
                  Int(indices[first + 1]) < vertexCount,
                  Int(indices[first + 2]) < vertexCount else { continue }
            for k in 0..<3 {
                let corner = first + k
                outPositions.append(positions[Int(indices[corner])])
                outUVs.append(corner < cornerUVs.count ? cornerUVs[corner] : SIMD2<Float>(0, 0))
                outIndices.append(UInt32(outIndices.count))
            }
        }
        return (outPositions, outUVs, outIndices)
    }

    /// A textured part from an atlas page with per-corner uvs (for example one page of a
    /// textured mesh): expands the corners and uses `.texture(textureURL)`.
    static func texturedPart(id: String, positions: [SIMD3<Float>], indices: [UInt32], cornerUVs: [SIMD2<Float>],
                             textureURL: URL, layer: ViewerLayer, pickTag: ViewerPickTag? = nil) -> ViewerPart {
        let expanded = expandCorners(positions: positions, indices: indices, cornerUVs: cornerUVs)
        return ViewerPart(id: id, positions: expanded.positions, uvs: expanded.uvs, indices: expanded.indices,
                          material: .texture(textureURL), layer: layer, pickTag: pickTag)
    }

    /// The flat material kind of a display style with `color`.
    static func material(for style: ViewerDisplayStyle, color: SIMD4<Float>) -> ViewerMaterial {
        switch style {
        case .rawScan: return .unlit(color)
        case .wireframe: return .wireframe(color)
        case .solidColor, .textured, .photoRealistic: return .lit(color)
        }
    }

    /// One compacted part holding `faces` of `mesh`: only the vertices those faces use, in
    /// first-use order, with their normals. `remap` is a scratch array of -1 per mesh vertex;
    /// it is restored to all -1 before returning.
    private static func makePart(id: String, faces: [Int], mesh: TriangleMesh, normals: [SIMD3<Float>],
                                 remap: inout [Int32], material: ViewerMaterial, layer: ViewerLayer,
                                 pickTag: ViewerPickTag?) -> ViewerPart {
        var positions: [SIMD3<Float>] = []
        var partNormals: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        var used: [Int] = []
        indices.reserveCapacity(faces.count * 3)
        for f in faces {
            for k in 0..<3 {
                let source = Int(mesh.indices[3 * f + k])
                if remap[source] < 0 {
                    remap[source] = Int32(positions.count)
                    positions.append(mesh.positions[source])
                    partNormals.append(source < normals.count ? normals[source] : TriangleMesh.fallbackNormal)
                    used.append(source)
                }
                indices.append(UInt32(remap[source]))
            }
        }
        for source in used { remap[source] = -1 }
        return ViewerPart(id: id, positions: positions, normals: partNormals, indices: indices,
                          material: material, layer: layer, pickTag: pickTag)
    }

    /// Integer tile coordinate of a non-negative tile-space value.
    private static func tileIndex(_ value: Float) -> Int32 {
        guard value.isFinite else { return 0 }
        return Int32(Swift.max(0, Swift.min(value.rounded(.down), maxTileIndex)))
    }

    /// `v` scaled to unit length, or `fallback` when `v` is zero or not finite.
    static func safeNormalize(_ v: SIMD3<Float>, fallback: SIMD3<Float>) -> SIMD3<Float> {
        let length = simd_length(v)
        guard length > 1e-12, length.isFinite else { return fallback }
        return v / length
    }
}
