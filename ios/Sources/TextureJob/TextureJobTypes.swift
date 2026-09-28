import Foundation
import simd

// Public value types of the TextureJob module (docs/MODULES.md 3.23, ARCHITECTURE 5.5).
// This file and TextureStore.swift never slip: Results and ExportUI (wave 4c) import them,
// so they depend only on Core, Texturing, MeshModel and Support, never on KeyframeLoader or
// TextureLowStep.

/// Texture density of a textured room: which `TXOptions` the baker runs with. Build 4 bakes
/// `.textured` (TextureLowStep, the Textured display style); `.photoRealistic` is build 6
/// (TextureHighStep, Photo Realistic). Raw values are persisted.
enum TextureDensity: String, Codable, CaseIterable, Sendable {
    /// Build 4 Textured: 2048 atlases, 100 texels per meter, up to 4 pages, no exposure
    /// normalization.
    case textured
    /// Build 6 Photo Realistic: 4096 atlases, 250 to 500 texels per meter by `DetailLevel`,
    /// up to 8 pages, exposure normalization (`TXExposure`).
    case photoRealistic

    /// Baker options at the Standard detail level. Textured: atlasSize 2048, texelsPerMeter
    /// 100, maxAtlases 4, normalizeExposure false. Photo Realistic: atlasSize 4096,
    /// texelsPerMeter 250, maxAtlases 8, normalizeExposure true.
    var options: TXOptions { detailedOptions(.standard) }

    /// Baker options for a detail level. Textured ignores the level; Photo Realistic takes
    /// its texel density from `photoRealisticTexelsPerMeter(_:)`.
    func detailedOptions(_ detail: DetailLevel) -> TXOptions {
        var result = TXOptions()
        switch self {
        case .textured:
            result.atlasSize = 2048
            result.texelsPerMeter = 100
            result.maxAtlases = 4
            result.normalizeExposure = false
        case .photoRealistic:
            result.atlasSize = 4096
            result.texelsPerMeter = TextureDensity.photoRealisticTexelsPerMeter(detail)
            result.maxAtlases = 8
            result.normalizeExposure = true
        }
        return result
    }

    /// Options of the reduced (low memory) variant: the same as `options` with smaller atlas
    /// pages, 1024 for Textured and 2048 for Photo Realistic. The baker lowers the texel
    /// density on its own when the charts do not fit.
    var reducedOptions: TXOptions {
        var result = options
        switch self {
        case .textured: result.atlasSize = 1024
        case .photoRealistic: result.atlasSize = 2048
        }
        return result
    }

    /// Photo Realistic texel density: Standard 250, High 375, Maximum 500 texels per meter.
    static func photoRealisticTexelsPerMeter(_ detail: DetailLevel) -> Float {
        switch detail {
        case .standard: return 250
        case .high: return 375
        case .maximum: return 500
        }
    }

    /// The pipeline step that bakes this density.
    var stepID: PipelineStepID {
        switch self {
        case .textured: return .textureLow
        case .photoRealistic: return .textureHigh
        }
    }

    /// Folder name under `derived/rooms/<r>/`: `texture` (build 4) or `texture-high` (build 6).
    var folderName: String {
        switch self {
        case .textured: return "texture"
        case .photoRealistic: return "texture-high"
        }
    }
}

/// A baked, textured room mesh as `TextureStore.load` returns it: the exact mesh that was
/// baked, per-corner texture coordinates, the atlas page of every face and the page JPEG
/// files. Texture coordinates have a bottom-left origin (RealityKit, OBJ, USD and
/// `ExportMesh` convention), so no consumer flips v. Faces no keyframe saw carry
/// `TexturedMesh.untexturedPage` and are left out of `pageParts()`.
struct TexturedMesh: Equatable, Sendable {
    /// Vertex positions, world meters.
    var positions: [SIMD3<Float>]
    /// Triangle corner indices, 3 per face.
    var indices: [UInt32]
    /// Per-corner texture coordinates, 3 per face (face f owns 3f, 3f+1, 3f+2, in the corner
    /// order of `indices`), bottom-left origin.
    var texcoords: [SIMD2<Float>]
    /// Atlas page of each face, or `TexturedMesh.untexturedPage` when the face is untextured.
    var faceAtlas: [UInt16]
    /// Page files `page_<n>.jpg`, index n = page number.
    var pageURLs: [URL]
    /// Textured surface area divided by total surface area, 0...1.
    var coverage: Float
}

/// One atlas page of a textured mesh as flat, un-indexed arrays: 3 vertices per face, so
/// every corner carries its own texture coordinate. `indices` is 0, 1, 2, ... (one per
/// vertex), ready for `ViewerContentBuilder.texturedPart` and `ExportMesh`.
struct TexturedPagePart: Equatable, Sendable {
    /// Page number (index into `TexturedMesh.pageURLs`).
    var page: Int
    /// Corner positions, 3 per face, world meters.
    var positions: [SIMD3<Float>]
    /// Corner texture coordinates, one per position, bottom-left origin.
    var texcoords: [SIMD2<Float>]
    /// Triangle indices into `positions`, 0 ..< positions.count.
    var indices: [UInt32]
}

/// Errors of `TextureStore.save` that are not file errors.
enum TextureJobError: Error, Equatable {
    /// The bake result does not match the mesh (face or texcoord counts, indices, pages);
    /// the payload says what, for the log.
    case invalidResult(String)
    /// An atlas page could not be encoded as JPEG; the payload names the page.
    case encodingFailed(String)
}

extension TexturedMesh {
    /// `faceAtlas` value of a face no keyframe textured (the baker's `faceSource` -1).
    static let untexturedPage: UInt16 = UInt16.max

    /// Number of whole faces.
    var faceCount: Int { indices.count / 3 }

    /// Number of atlas pages.
    var pageCount: Int { pageURLs.count }

    /// Number of faces with a valid page (the faces `pageParts()` can draw).
    var texturedFaceCount: Int {
        let faces = Swift.min(faceCount, faceAtlas.count)
        let pages = pageURLs.count
        var count = 0
        for f in 0..<faces where Int(faceAtlas[f]) < pages { count += 1 }
        return count
    }

    /// Un-indexed per-page arrays (3 vertices per face) for Viewer3D and ExportMesh;
    /// untextured faces skipped. Parts come in page order, one per page that has at least
    /// one face; within a part, faces keep their mesh order and corners their `indices`
    /// order with the matching `texcoords`. Faces with an out-of-range vertex index, a page
    /// beyond `pageURLs` or missing texture coordinates are skipped as well.
    func pageParts() -> [TexturedPagePart] {
        let faces = Swift.min(faceCount, faceAtlas.count, texcoords.count / 3)
        let pages = pageURLs.count
        guard faces > 0, pages > 0 else { return [] }
        let vertexCount = positions.count
        var counts = [Int](repeating: 0, count: pages)
        for f in 0..<faces where isDrawable(face: f, pages: pages, vertexCount: vertexCount) {
            counts[Int(faceAtlas[f])] += 1
        }
        var slotOfPage = [Int](repeating: -1, count: pages)
        var parts: [TexturedPagePart] = []
        for p in 0..<pages where counts[p] > 0 {
            slotOfPage[p] = parts.count
            var part = TexturedPagePart(page: p, positions: [], texcoords: [], indices: [])
            let corners = 3 * counts[p]
            part.positions.reserveCapacity(corners)
            part.texcoords.reserveCapacity(corners)
            part.indices.reserveCapacity(corners)
            parts.append(part)
        }
        for f in 0..<faces where isDrawable(face: f, pages: pages, vertexCount: vertexCount) {
            let slot = slotOfPage[Int(faceAtlas[f])]
            guard slot >= 0 else { continue }
            for k in 0..<3 {
                let corner = 3 * f + k
                let next = UInt32(truncatingIfNeeded: parts[slot].positions.count)
                parts[slot].positions.append(positions[Int(indices[corner])])
                parts[slot].texcoords.append(texcoords[corner])
                parts[slot].indices.append(next)
            }
        }
        return parts
    }

    /// True when face `f` has a page below `pages` and three in-range vertex indices.
    private func isDrawable(face f: Int, pages: Int, vertexCount: Int) -> Bool {
        guard Int(faceAtlas[f]) < pages else { return false }
        let first = 3 * f
        return Int(indices[first]) < vertexCount && Int(indices[first + 1]) < vertexCount
            && Int(indices[first + 2]) < vertexCount
    }

    /// Textured area over total area of the faces (area weighted, 0...1): a face counts as
    /// textured when its page is below `pageCount`. Faces with an out-of-range index or a
    /// non-finite area are ignored; 0 when there is no area at all.
    static func areaCoverage(positions: [SIMD3<Float>], indices: [UInt32], faceAtlas: [UInt16], pageCount: Int) -> Float {
        let faces = Swift.min(indices.count / 3, faceAtlas.count)
        let vertexCount = positions.count
        var total: Double = 0
        var textured: Double = 0
        for f in 0..<faces {
            let i0 = Int(indices[3 * f]), i1 = Int(indices[3 * f + 1]), i2 = Int(indices[3 * f + 2])
            guard i0 < vertexCount, i1 < vertexCount, i2 < vertexCount else { continue }
            let edge1: SIMD3<Float> = positions[i1] - positions[i0]
            let edge2: SIMD3<Float> = positions[i2] - positions[i0]
            let area = Double(simd_length(simd_cross(edge1, edge2))) * 0.5
            guard area.isFinite, area > 0 else { continue }
            total += area
            if Int(faceAtlas[f]) < pageCount { textured += area }
        }
        guard total > 0 else { return 0 }
        return Float(Swift.min(1, Swift.max(0, textured / total)))
    }
}
