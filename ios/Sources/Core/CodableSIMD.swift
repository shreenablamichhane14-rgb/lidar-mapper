import Foundation
import simd

/// A 2D float vector that persists as `{"x":..,"y":..}`. Use it in every Codable model
/// instead of `SIMD2<Float>`, whose Codable form is an unlabeled array.
struct Vec2: Codable, Equatable, Hashable, Sendable {
    /// First component (plan x, meters, in floor plan models).
    var x: Float
    /// Second component (plan y, meters, in floor plan models).
    var y: Float

    /// Creates a vector from components.
    init(x: Float, y: Float) {
        self.x = x
        self.y = y
    }

    /// Creates a vector from a simd value.
    init(_ v: SIMD2<Float>) {
        self.init(x: v.x, y: v.y)
    }

    /// The simd value, for math.
    var simd: SIMD2<Float> { SIMD2<Float>(x, y) }

    /// The origin.
    static let zero = Vec2(x: 0, y: 0)
}

/// A 3D float vector that persists as `{"x":..,"y":..,"z":..}` (world meters, y up).
struct Vec3: Codable, Equatable, Hashable, Sendable {
    /// X component.
    var x: Float
    /// Y component (up in ARKit world space).
    var y: Float
    /// Z component.
    var z: Float

    /// Creates a vector from components.
    init(x: Float, y: Float, z: Float) {
        self.x = x
        self.y = y
        self.z = z
    }

    /// Creates a vector from a simd value.
    init(_ v: SIMD3<Float>) {
        self.init(x: v.x, y: v.y, z: v.z)
    }

    /// The simd value, for math.
    var simd: SIMD3<Float> { SIMD3<Float>(x, y, z) }

    /// The origin.
    static let zero = Vec3(x: 0, y: 0, z: 0)
}

/// A 4x4 transform stored as 16 floats in column-major order (the same order as
/// `simd_float4x4.columns`). Decoding rejects any other element count.
struct Transform4: Equatable, Hashable, Sendable {
    /// The 16 matrix elements, column-major: m[0...3] is column 0, m[12...15] is the
    /// translation column.
    private(set) var m: [Float]

    /// Creates a transform from a simd matrix.
    init(_ t: simd_float4x4) {
        let c = t.columns
        m = [c.0.x, c.0.y, c.0.z, c.0.w,
             c.1.x, c.1.y, c.1.z, c.1.w,
             c.2.x, c.2.y, c.2.z, c.2.w,
             c.3.x, c.3.y, c.3.z, c.3.w]
    }

    /// Creates a transform from 16 column-major floats, or nil for any other count.
    init?(elements: [Float]) {
        guard elements.count == 16 else { return nil }
        m = elements
    }

    /// The simd matrix. Always valid because every initializer checks the count.
    var simd: simd_float4x4 {
        guard m.count == 16 else { return matrix_identity_float4x4 }
        return simd_float4x4(columns: (SIMD4<Float>(m[0], m[1], m[2], m[3]),
                                       SIMD4<Float>(m[4], m[5], m[6], m[7]),
                                       SIMD4<Float>(m[8], m[9], m[10], m[11]),
                                       SIMD4<Float>(m[12], m[13], m[14], m[15])))
    }

    /// The translation part (column 3).
    var translation: SIMD3<Float> {
        guard m.count == 16 else { return .zero }
        return SIMD3<Float>(m[12], m[13], m[14])
    }

    /// The identity transform.
    static let identity = Transform4(matrix_identity_float4x4)
}

extension Transform4: Codable {
    /// JSON key: the transform persists as `{"m":[16 floats]}`.
    enum CodingKeys: String, CodingKey {
        case m
    }

    /// Decodes and validates that exactly 16 elements are present.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let values = try container.decode([Float].self, forKey: .m)
        guard values.count == 16 else {
            throw DecodingError.dataCorruptedError(forKey: .m, in: container,
                                                   debugDescription: "Transform4 needs 16 elements, found \(values.count)")
        }
        m = values
    }

    /// Encodes the 16 elements.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(m, forKey: .m)
    }
}

/// Codable form of Geometry's `OrientedBox` (center, three unit axes, half extents).
struct OrientedBoxRecord: Codable, Equatable, Sendable {
    /// Box center, world meters.
    var center: Vec3
    /// First box axis (unit length).
    var axisX: Vec3
    /// Second box axis (unit length, vertical for gravity-aligned boxes).
    var axisY: Vec3
    /// Third box axis (unit length).
    var axisZ: Vec3
    /// Half the box size along each axis, meters.
    var halfExtents: Vec3

    /// Captures a Geometry box.
    init(_ box: OrientedBox) {
        center = Vec3(box.center)
        axisX = Vec3(box.axes.columns.0)
        axisY = Vec3(box.axes.columns.1)
        axisZ = Vec3(box.axes.columns.2)
        halfExtents = Vec3(box.halfExtents)
    }

    /// The Geometry box.
    var orientedBox: OrientedBox {
        OrientedBox(center: center.simd,
                    axes: simd_float3x3(columns: (axisX.simd, axisY.simd, axisZ.simd)),
                    halfExtents: halfExtents.simd)
    }
}

/// Pinhole camera intrinsics in pixels of an image of `width` x `height` (ARKit
/// `ARCamera.intrinsics`, sensor landscape orientation, origin at the top-left).
///
/// Convention (verified, research-digest texturing): the camera looks down -Z, +Y is up
/// in camera space and image v grows downward. For a camera-space point c:
/// `z = -c.z` (must be > 0), `u = fx * c.x / z + cx`, `v = -fy * c.y / z + cy`.
struct Intrinsics: Codable, Equatable, Hashable, Sendable {
    /// Focal length along u, pixels.
    var fx: Float
    /// Focal length along v, pixels.
    var fy: Float
    /// Principal point u, pixels.
    var cx: Float
    /// Principal point v, pixels.
    var cy: Float
    /// Image width these values refer to, pixels.
    var width: Int
    /// Image height these values refer to, pixels.
    var height: Int

    /// Creates intrinsics from values.
    init(fx: Float, fy: Float, cx: Float, cy: Float, width: Int, height: Int) {
        self.fx = fx
        self.fy = fy
        self.cx = cx
        self.cy = cy
        self.width = width
        self.height = height
    }

    /// Reads ARKit's column-major K: `[0][0]` = fx, `[1][1]` = fy, `[2][0]` = cx, `[2][1]` = cy.
    init(matrix: simd_float3x3, width: Int, height: Int) {
        self.init(fx: matrix.columns.0.x, fy: matrix.columns.1.y,
                  cx: matrix.columns.2.x, cy: matrix.columns.2.y,
                  width: width, height: height)
    }

    /// The column-major K matrix.
    var matrix: simd_float3x3 {
        simd_float3x3(columns: (SIMD3<Float>(fx, 0, 0), SIMD3<Float>(0, fy, 0), SIMD3<Float>(cx, cy, 1)))
    }

    /// The same camera for an image resized to `newWidth` x `newHeight` (for example the
    /// 256x192 depth map of a 1920x1440 frame): fx and cx scale by the width ratio, fy and
    /// cy by the height ratio. Returns self unchanged when either size is not positive.
    func scaled(toWidth newWidth: Int, height newHeight: Int) -> Intrinsics {
        guard width > 0, height > 0, newWidth > 0, newHeight > 0 else { return self }
        let sx = Float(newWidth) / Float(width)
        let sy = Float(newHeight) / Float(height)
        return Intrinsics(fx: fx * sx, fy: fy * sy, cx: cx * sx, cy: cy * sy,
                          width: newWidth, height: newHeight)
    }

    /// Pixel (u, v) of a camera-space point, or nil when the point is not in front of the
    /// camera or the focal lengths are unusable. The pixel may lie outside the image; use
    /// `contains(pixel:)` to check.
    func project(cameraPoint c: SIMD3<Float>) -> SIMD2<Float>? {
        let z = -c.z
        guard z > 0, fx != 0, fy != 0, z.isFinite else { return nil }
        return SIMD2<Float>(fx * c.x / z + cx, -fy * c.y / z + cy)
    }

    /// Pixel of a world point seen by a camera whose pose (camera to world, ARKit
    /// `ARCamera.transform`) is `cameraToWorld`.
    func project(worldPoint p: SIMD3<Float>, cameraToWorld: simd_float4x4) -> SIMD2<Float>? {
        let c = simd_mul(cameraToWorld.inverse, SIMD4<Float>(p, 1))
        return project(cameraPoint: SIMD3<Float>(c.x, c.y, c.z))
    }

    /// Camera-space point at `depth` meters in front of the camera through `pixel`; the
    /// exact inverse of `project(cameraPoint:)`. Returns the origin when a focal length is 0.
    func unproject(pixel: SIMD2<Float>, depth: Float) -> SIMD3<Float> {
        guard fx != 0, fy != 0 else { return .zero }
        let x = (pixel.x - cx) * depth / fx
        let y = -(pixel.y - cy) * depth / fy
        return SIMD3<Float>(x, y, -depth)
    }

    /// True when the pixel lies inside the image bounds.
    func contains(pixel: SIMD2<Float>) -> Bool {
        pixel.x >= 0 && pixel.y >= 0 && pixel.x < Float(width) && pixel.y < Float(height)
    }
}
