import Foundation
import CoreGraphics
import simd

/// Pure orbit camera math (ViewerOrbitCamera.swift), any queue.
///
/// Conventions: world +Y is up; the camera looks down its local -Z with +Y up and +X right
/// (RealityKit's camera convention); yaw 0 puts the eye on the +Z side of the target; pitch is
/// the elevation of the eye above the target's horizontal plane.
enum ViewerOrbitMath {
    /// Lowest pitch (5 degrees), so the camera never looks from below the floor.
    static let minPitch: Float = 5 * Float.pi / 180
    /// Highest pitch (85 degrees), short of straight down where yaw is undefined.
    static let maxPitch: Float = 85 * Float.pi / 180
    /// Yaw of the home view (Reset View), in radians.
    static let defaultYaw: Float = 0.6
    /// Pitch of the home view (Reset View), in radians.
    static let defaultPitch: Float = 0.6
    /// Vertical field of view of the viewer camera, in degrees.
    static let defaultFieldOfViewDegrees: Float = 60
    /// Extra distance factor when framing, so the model does not touch the screen edges.
    static let framingMargin: Float = 1.05
    /// Smallest bounding sphere radius used for framing, in meters.
    static let minimumRadius: Float = 0.05
    /// Eye distance when there is nothing to frame, in meters.
    static let emptyDistance: Float = 3

    /// `pitch` clamped to 5...85 degrees; the home pitch when it is not finite.
    static func clampPitch(_ pitch: Float) -> Float {
        guard pitch.isFinite else { return defaultPitch }
        return Swift.min(Swift.max(pitch, minPitch), maxPitch)
    }

    /// Camera-to-world matrix at `eye` looking at `target` with world +Y up (camera looks down -Z).
    ///
    /// The camera's +X stays horizontal and its +Y has a positive world y component. When the
    /// view direction is vertical (or `eye == target`) world +X is used as the camera's right.
    static func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>) -> simd_float4x4 {
        let worldUp = SIMD3<Float>(0, 1, 0)
        let forward = ViewerContentBuilder.safeNormalize(target - eye, fallback: SIMD3<Float>(0, 0, -1))
        var right = simd_cross(forward, worldUp)
        if simd_length(right) < 1e-6 {
            let fallback = SIMD3<Float>(1, 0, 0)
            right = fallback - forward * simd_dot(fallback, forward)
        }
        right = ViewerContentBuilder.safeNormalize(right, fallback: SIMD3<Float>(1, 0, 0))
        let back = -forward
        let up = simd_cross(back, right)
        return simd_float4x4(columns: (SIMD4<Float>(right, 0), SIMD4<Float>(up, 0),
                                       SIMD4<Float>(back, 0), SIMD4<Float>(eye, 1)))
    }

    /// Eye position for yaw and pitch (radians, pitch clamped to 5...85 degrees) at `distance` from `target`.
    static func eye(target: SIMD3<Float>, yaw: Float, pitch: Float, distance: Float) -> SIMD3<Float> {
        let p = clampPitch(pitch)
        let y = yaw.isFinite ? yaw : defaultYaw
        let d = distance.isFinite ? Swift.max(distance, 0) : emptyDistance
        let horizontal = cos(p)
        let offset = SIMD3<Float>(horizontal * sin(y), sin(p), horizontal * cos(y))
        return target + offset * d
    }

    /// Target and distance that frame `bounds` for a vertical field of view in degrees.
    ///
    /// The target is the box center and the distance fits the box's bounding sphere inside
    /// the view cone (times `framingMargin`), so the whole box is visible from any yaw and
    /// pitch. Pass the narrower of the vertical and horizontal fields of view
    /// (`effectiveFieldOfView`) for a portrait screen. An empty box gives the origin at
    /// `emptyDistance`.
    static func framing(_ bounds: AABB3, fieldOfViewDegrees: Float) -> (target: SIMD3<Float>, distance: Float) {
        let size = bounds.size
        guard !bounds.isEmpty, size.x.isFinite, size.y.isFinite, size.z.isFinite else {
            return (SIMD3<Float>(0, 0, 0), emptyDistance)
        }
        let radius = Swift.max(simd_length(size) * 0.5, minimumRadius)
        let degrees = fieldOfViewDegrees.isFinite ? Swift.min(Swift.max(fieldOfViewDegrees, 10), 170) : defaultFieldOfViewDegrees
        let halfAngle = degrees * Float.pi / 360
        let distance = radius / sin(halfAngle) * framingMargin
        return (bounds.center, distance)
    }

    /// The narrower of the vertical field of view and the horizontal one implied by `aspect`
    /// (width over height), in degrees. Returns the vertical value for an unusable aspect.
    static func effectiveFieldOfView(verticalDegrees: Float, aspect: Float) -> Float {
        guard aspect > 0, aspect.isFinite, verticalDegrees > 0, verticalDegrees < 180 else { return verticalDegrees }
        let halfVertical = verticalDegrees * Float.pi / 360
        let halfHorizontal = atan(tan(halfVertical) * aspect)
        return Swift.min(verticalDegrees, halfHorizontal * 360 / Float.pi)
    }

    /// Screen point (UIKit points, origin top-left) of `world` for a pinhole camera with the
    /// given pose, vertical field of view and view size; nil behind the camera or for an
    /// empty view. Used when no `ARView` is attached and by the self-test.
    static func project(_ world: SIMD3<Float>, cameraToWorld: simd_float4x4, verticalFieldOfViewDegrees: Float,
                        viewSize: CGSize) -> CGPoint? {
        guard viewSize.width > 0, viewSize.height > 0 else { return nil }
        let local = simd_mul(simd_inverse(cameraToWorld), SIMD4<Float>(world, 1))
        let depth = -local.z
        guard depth > 1e-4 else { return nil }
        let tanHalf = tan(verticalFieldOfViewDegrees * Float.pi / 360)
        let aspect = Float(viewSize.width / viewSize.height)
        guard tanHalf > 0, aspect > 0 else { return nil }
        let ndcX = local.x / (depth * tanHalf * aspect)
        let ndcY = local.y / (depth * tanHalf)
        let x = (ndcX + 1) * 0.5 * Float(viewSize.width)
        let y = (1 - ndcY) * 0.5 * Float(viewSize.height)
        return CGPoint(x: CGFloat(x), y: CGFloat(y))
    }

    /// World ray from the camera through a screen point (UIKit points, origin top-left), the
    /// inverse of `project`; nil for an empty view.
    static func ray(through point: CGPoint, cameraToWorld: simd_float4x4, verticalFieldOfViewDegrees: Float,
                    viewSize: CGSize) -> Ray? {
        guard viewSize.width > 0, viewSize.height > 0 else { return nil }
        let ndcX = Float(point.x / viewSize.width) * 2 - 1
        let ndcY = 1 - Float(point.y / viewSize.height) * 2
        let tanHalf = tan(verticalFieldOfViewDegrees * Float.pi / 360)
        let aspect = Float(viewSize.width / viewSize.height)
        let local = SIMD4<Float>(ndcX * tanHalf * aspect, ndcY * tanHalf, -1, 0)
        let world = simd_mul(cameraToWorld, local)
        let direction = ViewerContentBuilder.safeNormalize(SIMD3<Float>(world.x, world.y, world.z),
                                                          fallback: SIMD3<Float>(0, 0, -1))
        let origin = cameraToWorld.columns.3
        return Ray(origin: SIMD3<Float>(origin.x, origin.y, origin.z), direction: direction)
    }
}

/// Orbit camera state driven by the viewer gestures: a target point, yaw, pitch and distance.
/// Pure value type; `ViewerModel` owns one on the main actor.
struct ViewerOrbitState: Equatable, Sendable {
    /// Point the camera looks at and orbits around.
    var target = SIMD3<Float>(0, 0, 0)
    /// Rotation around world +Y, in radians.
    var yaw: Float = ViewerOrbitMath.defaultYaw
    /// Elevation, in radians (kept within 5...85 degrees).
    var pitch: Float = ViewerOrbitMath.defaultPitch
    /// Eye distance from the target, in meters.
    var distance: Float = ViewerOrbitMath.emptyDistance

    /// Radians of yaw or pitch per point of finger travel.
    static let radiansPerPoint: Float = 0.008

    /// Eye position.
    var eye: SIMD3<Float> {
        ViewerOrbitMath.eye(target: target, yaw: yaw, pitch: pitch, distance: distance)
    }

    /// Camera-to-world matrix.
    var cameraToWorld: simd_float4x4 {
        ViewerOrbitMath.lookAt(eye: eye, target: target)
    }

    /// One-finger drag: horizontal travel turns the model with the finger, vertical travel
    /// tilts it (dragging down raises the eye). Pitch stays within 5...85 degrees.
    mutating func orbit(dx: Float, dy: Float) {
        guard dx.isFinite, dy.isFinite else { return }
        let turned: Float = yaw - dx * ViewerOrbitState.radiansPerPoint
        yaw = turned.remainder(dividingBy: 2 * Float.pi)
        pitch = ViewerOrbitMath.clampPitch(pitch + dy * ViewerOrbitState.radiansPerPoint)
    }

    /// Two-finger drag: moves the target in the camera's image plane so the model follows the
    /// fingers, scaled by the distance and the view height in points.
    mutating func pan(dx: Float, dy: Float, viewHeight: Float, verticalFieldOfViewDegrees: Float) {
        guard dx.isFinite, dy.isFinite, viewHeight > 0 else { return }
        let tanHalf = tan(verticalFieldOfViewDegrees * Float.pi / 360)
        let metersPerPoint = 2 * distance * tanHalf / viewHeight
        guard metersPerPoint.isFinite else { return }
        let pose = cameraToWorld
        let right = SIMD3<Float>(pose.columns.0.x, pose.columns.0.y, pose.columns.0.z)
        let up = SIMD3<Float>(pose.columns.1.x, pose.columns.1.y, pose.columns.1.z)
        let moveRight: SIMD3<Float> = right * (-dx * metersPerPoint)
        let moveUp: SIMD3<Float> = up * (dy * metersPerPoint)
        target += moveRight + moveUp
    }

    /// Pinch: divides the distance by `scale` (spreading the fingers moves closer), clamped to
    /// `minDistance...maxDistance`.
    mutating func dolly(scale: Float, minDistance: Float, maxDistance: Float) {
        guard scale > 0, scale.isFinite, minDistance <= maxDistance else { return }
        distance = Swift.min(Swift.max(distance / scale, minDistance), maxDistance)
    }
}
