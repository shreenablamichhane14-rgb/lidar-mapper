import CoreGraphics
import Foundation
import simd

// Public inputs and outputs of the texture baker. The module uses its own plain types
// (no ARKit, no Geometry module) so it can be built, tested and merged on its own.

/// A triangle mesh to texture: world space, meters, ARKit convention (right handed, Y up).
/// Every 3 entries of `indices` name one triangle, counter-clockwise seen from outside.
struct TXMesh {
    /// Vertex positions in world space, meters.
    var positions: [SIMD3<Float>]
    /// Triangle corner indices, 3 per triangle.
    var indices: [UInt32]

    /// Number of whole triangles (a trailing partial triangle is ignored).
    var faceCount: Int { indices.count / 3 }

    /// Corners of face `f`, or nil when an index is out of range.
    func corners(_ f: Int) -> (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)? {
        let i0 = Int(indices[3 * f]), i1 = Int(indices[3 * f + 1]), i2 = Int(indices[3 * f + 2])
        let n = positions.count
        guard i0 < n, i1 < n, i2 < n else { return nil }
        return (positions[i0], positions[i1], positions[i2])
    }
}

/// One captured camera image with the pose and intrinsics it was taken with.
///
/// `intrinsics` belong to `imageResolution` in the sensor's native orientation, exactly as
/// ARKit reports them for `ARFrame.capturedImage` (landscape-right, for example 1920 x 1440).
/// Column-major: `intrinsics[0][0]` = fx, `intrinsics[1][1]` = fy, `intrinsics[2][0]` = cx,
/// `intrinsics[2][1]` = cy, all in pixels. `image` may be any resolution with the same aspect
/// ratio; the projection is rescaled to the image's pixel size (see `TXCamera`). Every pixel
/// coordinate in this module is in pixels of `image`, continuous, origin at the top-left
/// corner of the top-left pixel (so pixel `i` has its center at `i + 0.5`).
struct TXKeyframe {
    /// The camera image, row 0 at the top, in the sensor's native (landscape-right) orientation.
    var image: CGImage
    /// Pinhole intrinsics in pixels of `imageResolution` (ARCamera.intrinsics).
    var intrinsics: simd_float3x3
    /// Width and height in pixels that `intrinsics` refer to (ARCamera.imageResolution).
    var imageResolution: SIMD2<Float>
    /// Camera-to-world transform (ARCamera.transform).
    var cameraToWorld: simd_float4x4
    /// Capture time in seconds (ARFrame.timestamp).
    var timestamp: Double
    /// ARCamera.exposureOffset in EV when known; used only as a hint.
    var exposureOffset: Float?
}

/// Tuning knobs for `TextureBaker`.
struct TXOptions {
    /// Width and maximum height of each atlas texture, in texels.
    var atlasSize: Int = 4096
    /// Target texture resolution on the surface.
    var texelsPerMeter: Float = 400
    /// Most atlases produced; resolution is lowered to fit.
    var maxAtlases: Int = 8
    /// Smallest cosine between face normal and view direction accepted (0.25 is about 75 degrees).
    var minViewCosine: Float = 0.25
    /// A face is occluded when it lies more than this many meters behind the depth buffer.
    var occlusionTolerance: Float = 0.03
    /// Blend texels near chart borders with the neighboring chart's keyframe.
    var blendSeams: Bool = true
    /// Equalize brightness between keyframes before baking.
    var normalizeExposure: Bool = true

    /// Default options.
    init() {}
}

/// The baked texture: atlases plus per-corner texture coordinates.
///
/// The mesh is un-indexed for UVs: face `f` owns texcoords `3f`, `3f+1`, `3f+2`, matching the
/// corner order of `indices`. Texcoords are normalized with the origin at the BOTTOM-LEFT of
/// the atlas (v up, the OBJ, USD and RealityKit convention), so texel row `y` from the top of
/// an atlas of height `h` is at `v = 1 - y / h`. Untextured faces have texcoords (0, 0),
/// `faceAtlas` 0 and `faceSource` -1.
struct TXResult {
    /// Per-corner texture coordinates, 3 per face, bottom-left origin.
    var texcoords: [SIMD2<Float>]
    /// Atlas index used by each face.
    var faceAtlas: [UInt16]
    /// Atlas images, row 0 at the top. Width is `atlasSize`; height may be smaller (power of two).
    var atlases: [CGImage]
    /// Keyframe chosen for each face, -1 when untextured.
    var faceSource: [Int32]
    /// Textured surface area divided by total surface area, 0...1.
    var coverage: Float
}

/// Errors thrown by `TextureBaker.bake`.
enum TXError: Error, Equatable {
    /// The mesh has no triangles or an out-of-range index.
    case invalidMesh(String)
    /// No keyframes were given.
    case noKeyframes
    /// `TextureBaker.cancel()` was called.
    case cancelled
    /// A bitmap or CGImage could not be created.
    case imageFailed(String)
}

/// One face seen by one keyframe, with the numbers view selection scores it by.
struct TXViewCandidate: Equatable {
    /// Index into the keyframe array.
    var keyframe: Int32
    /// Cosine between the face normal and the direction to the camera, 0...1.
    var cosine: Float
    /// Keyframe image pixels per meter on this face, in pixels of `TXKeyframe.image`
    /// (square root of projected pixel area over world area).
    var pixelsPerMeter: Float
}

/// Visibility of every face in every keyframe, stored compactly (CSR layout).
struct TXVisibility {
    /// Most candidates kept per face (the best by cosine times density).
    static let maxCandidatesPerFace = 6

    /// Candidates for face `f` are `candidates[offsets[f] ..< offsets[f + 1]]`.
    var offsets: [Int32]
    /// All candidates, grouped by face.
    var candidates: [TXViewCandidate]

    /// Candidates of face `f`.
    func candidates(forFace f: Int) -> ArraySlice<TXViewCandidate> {
        candidates[Int(offsets[f]) ..< Int(offsets[f + 1])]
    }

    /// The candidate of face `f` from `keyframe`, if that keyframe sees it.
    func candidate(forFace f: Int, keyframe: Int32) -> TXViewCandidate? {
        candidates(forFace: f).first { $0.keyframe == keyframe }
    }
}

/// A group of adjacent faces textured from the same keyframe, laid out in its own rectangle.
///
/// Chart texel coordinates are an affine map of the keyframe's image pixels:
/// `texel = (pixel - pixelOrigin) * texelsPerPixel + gutter`, so baking maps back with
/// `pixel = (texel - gutter) / texelsPerPixel + pixelOrigin`. Texel (0, 0) is the top-left
/// corner of the rectangle (row 0 at the top, like the image).
struct TXChart {
    /// Gutter width in texels on every side of a chart.
    static let gutter = 2

    /// Keyframe the chart is textured from.
    var keyframe: Int32
    /// Faces in the chart.
    var faces: [Int32]
    /// Chart-local texel coordinates of each face's 3 corners, in `faces` order (3 per face).
    var cornerTexels: [SIMD2<Float>]
    /// Top-left of the chart's bounding box in pixels of the keyframe's `image`.
    var pixelOrigin: SIMD2<Float>
    /// Chart texels per keyframe image pixel.
    var texelsPerPixel: Float
    /// Rectangle width in texels, gutters included.
    var width: Int
    /// Rectangle height in texels, gutters included.
    var height: Int
}

/// Where a chart's rectangle landed: atlas index and top-left texel (row 0 at the top).
struct TXPlacement: Equatable {
    /// Atlas index.
    var atlas: Int
    /// Left edge in texels.
    var x: Int
    /// Top edge in texels.
    var y: Int
}

/// Output of the packer for a list of rectangles.
struct TXPacking {
    /// One placement per input rectangle, in input order.
    var placements: [TXPlacement]
    /// Number of atlases used.
    var atlasCount: Int
    /// Lowest used texel row + 1 in each atlas (so an atlas can be trimmed in height).
    var usedHeights: [Int]
}
