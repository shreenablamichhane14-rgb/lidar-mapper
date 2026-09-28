import Foundation
import simd

/// How the viewer draws a mesh: the Display menu of the result screen (SPEC "IMAGE / TEXTURE
/// CAPTURE" display modes). Photo Realistic is listed for completeness; in build 4 the screen
/// shows it as not available yet.
enum ViewerDisplayStyle: String, CaseIterable, Sendable {
    case photoRealistic, textured, solidColor, wireframe, rawScan

    /// Menu title from `Copy.Viewer`.
    var title: String {
        switch self {
        case .photoRealistic: return Copy.Viewer.photoRealistic
        case .textured: return Copy.Viewer.textured
        case .solidColor: return Copy.Viewer.solidColor
        case .wireframe: return Copy.Viewer.wireframe
        case .rawScan: return Copy.Viewer.raw
        }
    }
}

/// Material of one drawable part. Every RealityKit material the viewer makes from it sets
/// `faceCulling = .none`, because LiDAR triangles have inconsistent winding (RESEARCH 3.5).
/// Colors are linear RGBA in 0...1.
enum ViewerMaterial: Equatable, Sendable {
    /// `UnlitMaterial(color:)`: flat color, no lighting (Raw Scan classes, overlays).
    case unlit(SIMD4<Float>)
    /// `SimpleMaterial(color:roughness:isMetallic:)`: shaded color (Solid Color, clean walls).
    case lit(SIMD4<Float>)
    /// `UnlitMaterial` with `triangleFillMode = .lines` (Wireframe, box outlines).
    case wireframe(SIMD4<Float>)
    /// `UnlitMaterial` with `blending = .transparent(opacity:)` from the alpha component.
    case translucent(SIMD4<Float>)
    /// `UnlitMaterial(texture:)` from a JPEG atlas page on disk (Textured, UV checker).
    case texture(URL)

    /// The color of a color material; nil for `.texture`.
    var color: SIMD4<Float>? {
        switch self {
        case .unlit(let c), .lit(let c), .wireframe(let c), .translucent(let c):
            return c
        case .texture:
            return nil
        }
    }
}

/// Visibility group of a part. All parts of one layer hang under one parent entity whose
/// `isEnabled` toggles the layer (Hide Furniture, tab changes), so toggling never rebuilds
/// content.
enum ViewerLayer: String, CaseIterable, Hashable, Sendable {
    case realistic, raw, rawInferred, cleanStructure, cleanOpenings, cleanFurniture, cleanFixtures, cleanOccluded, overlay

    /// Layers visible before the caller changes anything. `.cleanOccluded` starts hidden
    /// because it is shown only while Hide Furniture is on (ARCHITECTURE 7.3).
    static let defaultVisible: Set<ViewerLayer> = Set(ViewerLayer.allCases.filter { $0 != .cleanOccluded })
}

/// What a tap on a part refers to: a clean model element (wall, opening, object box) or the
/// raw scan surface.
enum ViewerPickTag: Hashable, Sendable {
    case element(ElementID)
    case rawMesh
}

/// One drawable part: world-space triangles, per-vertex normals and uvs optional (empty or one
/// per vertex). Texture coordinates use a bottom-left origin everywhere; the viewer never flips
/// them. Normals that are missing or zero are computed from the triangles at upload time.
struct ViewerPart: Sendable {
    /// Stable identifier, reported back in `ViewerHit.partID`.
    var id: String
    /// Vertex positions in world meters.
    var positions: [SIMD3<Float>]
    /// Per-vertex normals, or empty.
    var normals: [SIMD3<Float>]
    /// Per-vertex texture coordinates (bottom-left origin), or empty.
    var uvs: [SIMD2<Float>]
    /// Triangle corner indices, 3 per triangle.
    var indices: [UInt32]
    /// How the part is drawn.
    var material: ViewerMaterial
    /// Visibility group.
    var layer: ViewerLayer
    /// What a tap on this part selects; nil makes the part unpickable.
    var pickTag: ViewerPickTag?

    /// Creates a part.
    init(id: String, positions: [SIMD3<Float>], normals: [SIMD3<Float>] = [], uvs: [SIMD2<Float>] = [],
         indices: [UInt32], material: ViewerMaterial, layer: ViewerLayer, pickTag: ViewerPickTag? = nil) {
        self.id = id
        self.positions = positions
        self.normals = normals
        self.uvs = uvs
        self.indices = indices
        self.material = material
        self.layer = layer
        self.pickTag = pickTag
    }

    /// Number of whole triangles.
    var triangleCount: Int { indices.count / 3 }
}

/// Everything one `ViewerModel.load` call shows, with the bounds used for framing.
struct ViewerContent: Sendable {
    /// Parts in draw order.
    var parts: [ViewerPart]
    /// Bounds of every finite position of every part; `AABB3.empty` when there are none.
    var bounds: AABB3

    /// No parts.
    static let empty = ViewerContent(parts: [])

    /// Wraps `parts` and computes their bounds.
    init(parts: [ViewerPart]) {
        self.parts = parts
        var box = AABB3.empty
        for part in parts {
            for p in part.positions where p.x.isFinite && p.y.isFinite && p.z.isFinite {
                box.expand(p)
            }
        }
        self.bounds = box
    }

    /// Total triangles over all parts.
    var triangleCount: Int { parts.reduce(0) { $0 + $1.triangleCount } }
}

/// Result of a tap: the nearest triangle of a visible pickable part under the finger.
struct ViewerHit: Equatable, Sendable {
    /// Hit point in world meters.
    var position: SIMD3<Float>
    /// Unit normal of the hit triangle, turned to face the camera.
    var normal: SIMD3<Float>
    /// `ViewerPart.id` of the hit part.
    var partID: String
    /// Triangle index within that part.
    var triangle: Int
    /// The part's pick tag.
    var pickTag: ViewerPickTag?
}

/// Errors thrown by viewer helpers that write files.
enum ViewerError: Error, Equatable {
    /// A bitmap context or image could not be created.
    case imageCreationFailed
    /// JPEG encoding failed.
    case jpegEncodingFailed
}
