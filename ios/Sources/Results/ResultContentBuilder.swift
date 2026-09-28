import Foundation
import simd

/// Pure builders that turn the clean model, the textured mesh, missing areas and a selection
/// into Viewer3D parts (docs/MODULES.md 3.26, ARCHITECTURE 7.3). Any thread; the result screen
/// calls them from detached tasks.
enum ResultContentBuilder {
    /// Wall color (light gray, shaded).
    static let wallColor = SIMD4<Float>(0.86, 0.86, 0.84, 1)
    /// Floor color (warm gray, shaded).
    static let floorColor = SIMD4<Float>(0.62, 0.60, 0.56, 1)
    /// Translucent door, window and open passage fills.
    static let doorColor = SIMD4<Float>(0.30, 0.52, 0.85, 0.55)
    static let windowColor = SIMD4<Float>(0.45, 0.80, 0.95, 0.45)
    static let openingColor = SIMD4<Float>(0.80, 0.80, 0.80, 0.30)
    /// Translucent object boxes: movable furniture and built-in fixtures.
    static let furnitureColor = SIMD4<Float>(0.85, 0.60, 0.35, 0.35)
    static let fixtureColor = SIMD4<Float>(0.35, 0.70, 0.60, 0.35)
    /// Occluded regions: translucent gray plus a wireframe copy, so they read as hatched.
    static let occludedColor = SIMD4<Float>(0.5, 0.5, 0.5, 0.45)
    static let occludedLineColor = SIMD4<Float>(0.5, 0.5, 0.5, 1)
    /// Missing (unscanned) areas: translucent red squares.
    static let missingColor = SIMD4<Float>(1, 0.2, 0.2, 0.5)
    /// Selection highlight: translucent amber plus an amber outline.
    static let highlightColor = SIMD4<Float>(1.0, 0.78, 0.0, 0.45)
    static let highlightLineColor = SIMD4<Float>(1.0, 0.78, 0.0, 1)
    /// Untextured faces of the textured mesh (same gray as Solid Color).
    static let untexturedColor = ViewerContentBuilder.solidColor
    /// Missing area squares sit this far in front of their surface, meters.
    static let missingOffset: Float = 0.02
    /// Highlight copies sit this far off the selected surface on both sides, meters.
    static let highlightOffset: Float = 0.01

    // MARK: - Missing areas

    /// One overlay part per missing area: a square of side sqrt(area) centered at the centroid,
    /// facing the normal, 2 cm in front of the surface, 2 triangles, translucent red, not
    /// pickable. Records with a non-finite or non-positive area or centroid are skipped.
    static func missingAreaParts(_ records: [MissingAreaRecord]) -> [ViewerPart] {
        var parts: [ViewerPart] = []
        for record in records {
            let area = record.area
            let centroid = record.centroid.simd
            guard area.isFinite, area > 0, centroid.x.isFinite, centroid.y.isFinite, centroid.z.isFinite else { continue }
            let normal = ViewerContentBuilder.safeNormalize(record.normal.simd, fallback: SIMD3<Float>(0, 1, 0))
            let axes = tangentAxes(normal)
            let half: Float = area.squareRoot() * 0.5
            let center: SIMD3<Float> = centroid + normal * missingOffset
            let du: SIMD3<Float> = axes.u * half
            let dv: SIMD3<Float> = axes.v * half
            let corners: [SIMD3<Float>] = [center - du - dv, center + du - dv, center + du + dv, center - du + dv]
            parts.append(ViewerPart(id: "missing.\(record.id)", positions: corners,
                                    normals: [SIMD3<Float>](repeating: normal, count: 4),
                                    indices: [0, 1, 2, 0, 2, 3], material: .translucent(missingColor),
                                    layer: .overlay, pickTag: nil))
        }
        return parts
    }

    /// Two unit vectors u, v spanning the plane of `normal`, with u x v = normal.
    static func tangentAxes(_ normal: SIMD3<Float>) -> (u: SIMD3<Float>, v: SIMD3<Float>) {
        let reference = abs(normal.y) < 0.9 ? SIMD3<Float>(0, 1, 0) : SIMD3<Float>(1, 0, 0)
        let u = ViewerContentBuilder.safeNormalize(simd_cross(reference, normal), fallback: SIMD3<Float>(1, 0, 0))
        let v = simd_cross(normal, u)
        return (u, v)
    }

    // MARK: - 3D Clean

    /// The 3D Clean parts of an (edited) clean model from `CleanMeshBuilder.parts` (ceiling and
    /// hidden objects left out): walls light gray `.lit` on `.cleanStructure` and pickable,
    /// floors on `.cleanStructure` (not pickable), doors, windows and openings translucent on
    /// `.cleanOpenings` and pickable, objects as a translucent pickable fill plus a wireframe
    /// outline on `.cleanFurniture` (movable) or `.cleanFixtures`, and occluded regions as a
    /// translucent gray fill plus a wireframe copy on `.cleanOccluded` (never pickable, never
    /// drawn as measured).
    static func cleanParts(_ model: CleanModel) -> [ViewerPart] {
        let meshParts = CleanMeshBuilder.parts(for: model, includeCeiling: false, includeHidden: false)
        var parts: [ViewerPart] = []
        for (index, part) in meshParts.enumerated() {
            let positions = part.mesh.positions
            let indices = part.mesh.indices
            guard !positions.isEmpty, indices.count >= 3 else { continue }
            let id = "clean.\(index)"
            let tag = ViewerPickTag.element(part.element)
            switch part.kind {
            case .wall:
                parts.append(ViewerPart(id: id, positions: positions, indices: indices, material: .lit(wallColor),
                                        layer: .cleanStructure, pickTag: tag))
            case .floor:
                parts.append(ViewerPart(id: id, positions: positions, indices: indices, material: .lit(floorColor),
                                        layer: .cleanStructure, pickTag: nil))
            case .ceiling:
                continue
            case .door:
                parts.append(ViewerPart(id: id, positions: positions, indices: indices, material: .translucent(doorColor),
                                        layer: .cleanOpenings, pickTag: tag))
            case .window:
                parts.append(ViewerPart(id: id, positions: positions, indices: indices, material: .translucent(windowColor),
                                        layer: .cleanOpenings, pickTag: tag))
            case .opening:
                parts.append(ViewerPart(id: id, positions: positions, indices: indices, material: .translucent(openingColor),
                                        layer: .cleanOpenings, pickTag: tag))
            case .object:
                let layer: ViewerLayer = part.isMovable ? .cleanFurniture : .cleanFixtures
                let color = part.isMovable ? furnitureColor : fixtureColor
                let opaque = SIMD4<Float>(color.x, color.y, color.z, 1)
                parts.append(ViewerPart(id: id, positions: positions, indices: indices, material: .translucent(color),
                                        layer: layer, pickTag: tag))
                parts.append(ViewerPart(id: id + ".outline", positions: positions, indices: indices,
                                        material: .wireframe(opaque), layer: layer, pickTag: nil))
            case .occluded:
                parts.append(ViewerPart(id: id, positions: positions, indices: indices, material: .translucent(occludedColor),
                                        layer: .cleanOccluded, pickTag: nil))
                parts.append(ViewerPart(id: id + ".hatch", positions: positions, indices: indices,
                                        material: .wireframe(occludedLineColor), layer: .cleanOccluded, pickTag: nil))
            }
        }
        return parts
    }

    /// Highlight copies of the fill parts picked as `.element(element)`: each copied twice, 1 cm
    /// off the surface along its vertex normals on both sides, as translucent amber plus an
    /// amber outline on `.overlay`, not pickable.
    static func highlightParts(for element: ElementID, in parts: [ViewerPart]) -> [ViewerPart] {
        var result: [ViewerPart] = []
        for part in parts where part.pickTag == .element(element) {
            if case .wireframe = part.material { continue }
            let mesh = TriangleMesh(positions: part.positions, indices: part.indices)
            let normals = part.normals.count == part.positions.count ? part.normals : mesh.vertexNormals
            for (side, sign) in [("front", Float(1)), ("back", Float(-1))] {
                var moved: [SIMD3<Float>] = []
                moved.reserveCapacity(part.positions.count)
                for (k, p) in part.positions.enumerated() {
                    let n = k < normals.count ? normals[k] : TriangleMesh.fallbackNormal
                    moved.append(p + n * (highlightOffset * sign))
                }
                result.append(ViewerPart(id: "highlight.\(part.id).\(side)", positions: moved, indices: part.indices,
                                         material: .translucent(highlightColor), layer: .overlay, pickTag: nil))
                result.append(ViewerPart(id: "highlight.\(part.id).\(side).outline", positions: moved, indices: part.indices,
                                         material: .wireframe(highlightLineColor), layer: .overlay, pickTag: nil))
            }
        }
        return result
    }

    // MARK: - Realistic

    /// One `.texture(url)` part per atlas page of `mesh.pageParts()` (bottom-left uvs kept as
    /// they are) plus one `.lit` gray part with the faces no photo covered, all on `.realistic`
    /// and not pickable. `idPrefix` keeps ids unique across rooms.
    static func texturedParts(_ mesh: TexturedMesh, idPrefix: String) -> [ViewerPart] {
        var parts: [ViewerPart] = []
        for page in mesh.pageParts() where page.page >= 0 && page.page < mesh.pageURLs.count {
            parts.append(ViewerPart(id: "\(idPrefix).page\(page.page)", positions: page.positions, uvs: page.texcoords,
                                    indices: page.indices, material: .texture(mesh.pageURLs[page.page]),
                                    layer: .realistic, pickTag: nil))
        }
        if let rest = untexturedPart(mesh, id: "\(idPrefix).untextured") {
            parts.append(rest)
        }
        return parts
    }

    /// The faces of `mesh` without a valid page (or beyond `faceAtlas`), un-indexed, as a `.lit`
    /// gray part; nil when there are none.
    static func untexturedPart(_ mesh: TexturedMesh, id: String) -> ViewerPart? {
        let faceCount = mesh.faceCount
        let pages = mesh.pageURLs.count
        let vertexCount = mesh.positions.count
        var positions: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        for f in 0..<faceCount {
            let textured = f < mesh.faceAtlas.count && Int(mesh.faceAtlas[f]) < pages
            if textured { continue }
            let i0 = Int(mesh.indices[3 * f]), i1 = Int(mesh.indices[3 * f + 1]), i2 = Int(mesh.indices[3 * f + 2])
            guard i0 < vertexCount, i1 < vertexCount, i2 < vertexCount else { continue }
            for source in [i0, i1, i2] {
                indices.append(UInt32(positions.count))
                positions.append(mesh.positions[source])
            }
        }
        guard !indices.isEmpty else { return nil }
        return ViewerPart(id: id, positions: positions, indices: indices, material: .lit(untexturedColor),
                          layer: .realistic, pickTag: nil)
    }

    // MARK: - Lookups

    /// The detected object with `id` in any room, if any.
    static func object(_ id: ElementID, in model: CleanModel) -> DetectedObject? {
        for room in model.rooms {
            if let found = room.objects.first(where: { $0.id == id }) { return found }
        }
        return nil
    }

    /// The room holding the object with `id`, if any.
    static func room(ofObject id: ElementID, in model: CleanModel) -> CleanRoom? {
        model.rooms.first { room in room.objects.contains { $0.id == id } }
    }

    /// True when `id` is a wall or an opening (door, window, passage) of some room.
    static func isWallOrOpening(_ id: ElementID, in model: CleanModel) -> Bool {
        model.rooms.contains { room in
            room.walls.contains { $0.id == id } || room.openings.contains { $0.id == id }
        }
    }

    /// Visible rows: all rows, or only rows whose `element == selection`.
    static func filterRows(_ rows: [DimensionRow], selection: ElementID?) -> [DimensionRow] {
        guard let selection else { return rows }
        return rows.filter { $0.element == selection }
    }
}
