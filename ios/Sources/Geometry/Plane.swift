import Foundation
import simd

/// An infinite plane `dot(normal, x) + d = 0` with a unit-length normal. Positive signed
/// distances lie on the side the normal points to.
struct Plane: Equatable {
    /// Unit normal.
    var normal: SIMD3<Float>
    /// Offset, equal to `-dot(normal, pointOnPlane)` (the signed distance of the origin).
    var d: Float

    /// Normals, determinants and ray-plane cosines below this count as zero.
    static let epsilon: Float = 1e-6
    /// Fewer points than this cannot define a fitted plane.
    static let minimumFitPoints = 3

    /// Creates a plane from a unit normal and offset. The normal is normalized again to be safe;
    /// a zero normal becomes world up (0, 1, 0).
    init(normal: SIMD3<Float>, d: Float) {
        let length = simd_length(normal)
        if length > Plane.epsilon {
            self.normal = normal / length
            self.d = d / length
        } else {
            self.normal = SIMD3<Float>(0, 1, 0)
            self.d = d
        }
    }

    /// Plane through `point` with the given normal (normalized here; a zero normal becomes up).
    init(point: SIMD3<Float>, normal: SIMD3<Float>) {
        let length = simd_length(normal)
        let n = length > Plane.epsilon ? normal / length : SIMD3<Float>(0, 1, 0)
        self.normal = n
        self.d = -simd_dot(n, point)
    }

    /// Plane through three points, normal following the right-hand rule (a, b, c counter-
    /// clockwise seen from the normal side). Nil when the points are collinear.
    init?(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) {
        let n = simd_cross(b - a, c - a)
        let length = simd_length(n)
        guard length > Plane.epsilon * max(1, simd_length(b - a) * simd_length(c - a)) else { return nil }
        self.init(point: a, normal: n / length)
    }

    /// Signed distance from the plane to `p`, positive on the normal side.
    func signedDistance(to p: SIMD3<Float>) -> Float {
        simd_dot(normal, p) + d
    }

    /// Orthogonal projection of `p` onto the plane.
    func project(_ p: SIMD3<Float>) -> SIMD3<Float> {
        p - normal * signedDistance(to: p)
    }

    /// Where the ray meets the plane, if it does so at or in front of its origin.
    /// Nil when the ray is parallel to the plane or points away from it.
    func intersection(with ray: Ray) -> SIMD3<Float>? {
        let length = simd_length(ray.direction)
        guard length > Plane.epsilon else { return nil }
        let direction = ray.direction / length
        let cosine = simd_dot(normal, direction)
        guard abs(cosine) > Plane.epsilon else { return nil }
        let t = -signedDistance(to: ray.origin) / cosine
        guard t >= 0 else { return nil }
        return ray.origin + direction * t
    }

    /// The single point shared by three planes, or nil when two or more are (nearly)
    /// parallel so the system is singular.
    static func intersection(_ p1: Plane, _ p2: Plane, _ p3: Plane) -> SIMD3<Float>? {
        let n23 = simd_cross(p2.normal, p3.normal)
        let det = simd_dot(p1.normal, n23)
        guard abs(det) > Plane.epsilon else { return nil }
        let n31 = simd_cross(p3.normal, p1.normal)
        let n12 = simd_cross(p1.normal, p2.normal)
        return -(n23 * p1.d + n31 * p2.d + n12 * p3.d) / det
    }

    /// Least-squares plane through `points` by PCA: the normal is the eigenvector of the
    /// covariance matrix with the smallest eigenvalue. `rms` is the root mean square of the
    /// point-to-plane distances. The normal sign is chosen so `normal.y >= 0` (floors face
    /// up); for exactly vertical planes the sign is arbitrary. Nil for fewer than 3 points,
    /// non-finite input, or points that are (nearly) collinear.
    static func fit(_ points: [SIMD3<Float>]) -> (plane: Plane, rms: Float)? {
        guard points.count >= minimumFitPoints else { return nil }
        guard let stats = SymmetricEigen3.covariance(of: points) else { return nil }
        let (values, vectors) = SymmetricEigen3.decompose(stats.covariance)
        // Collinear points: the middle eigenvalue vanishes too, so the normal is undefined.
        guard values.z > 0, values.y > Plane.epsilon * values.z else { return nil }
        var normal = vectors.columns.0
        if normal.y < 0 { normal = -normal }
        let plane = Plane(point: stats.mean, normal: normal)
        var squares = 0.0
        for p in points {
            let distance = Double(plane.signedDistance(to: p))
            squares += distance * distance
        }
        return (plane, Float((squares / Double(points.count)).squareRoot()))
    }
}
