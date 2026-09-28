import Foundation
import simd

/// Deterministic pseudo-random generator (SplitMix64) for RANSAC in MeshProcessing. The
/// same seed always gives the same sequence, so results never depend on the clock or on
/// system randomness.
struct MeshProcessingRandom: RandomNumberGenerator {
    /// Current state, advanced by a fixed odd constant per draw.
    private var state: UInt64

    /// A generator starting from `seed`.
    init(seed: UInt64) {
        state = seed
    }

    /// Next 64 random bits.
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform integer in `0 ..< bound` by the multiply-shift method on the high 32 bits;
    /// 0 when `bound` is 1 or less. Bounds above 2^32 - 1 are clamped to it.
    mutating func index(below bound: Int) -> Int {
        guard bound > 1 else { return 0 }
        let clamped = UInt64(Swift.min(bound, Int(UInt32.max)))
        return Int(((next() >> 32) &* clamped) >> 32)
    }
}

/// Isolates a scanned object from its surroundings for OBJECT scans (SPEC.txt): keeps the
/// faces inside the user's selection, removes the supporting surface (the largest
/// horizontal plane with nothing under it, found by deterministic RANSAC over face
/// centroids) and everything below it, keeps the largest remaining component, and measures
/// the result. World space is ARKit's: gravity aligned, y up.
///
/// The selection should include some of the surface the object rests on. When it does not,
/// the lowest large horizontal face of the object itself may be taken for the support and
/// removed; the dimensions stay right but the volume becomes unavailable (not watertight).
enum ObjectIsolation {
    /// World up.
    static let up = SIMD3<Float>(0, 1, 0)
    /// Closed meshes enclosing less than this (cubic meters, 1 cubic millimeter) report a
    /// degenerate volume.
    static let minimumVolume: Float = 1e-9

    /// Settings for the support plane search.
    struct PlaneOptions {
        /// Faces whose centroid is within this distance (meters) of the plane, and whose
        /// normal is parallel to it, are plane inliers.
        var inlierDistance: Float
        /// Largest angle in degrees between a support plane normal and world up.
        var maxTiltDegrees: Float
        /// Largest angle in degrees between an inlier face's normal and the plane normal
        /// (either side, so inconsistent winding does not matter).
        var normalToleranceDegrees: Float
        /// Number of RANSAC hypotheses.
        var iterations: Int
        /// A plane only counts as a support when the face area more than two inlier
        /// distances below it is at most this fraction of the non-inlier area.
        var maxBelowFraction: Float
        /// Smallest inlier area of a support, in square meters.
        var minimumArea: Float
        /// At most about this many faces are scored (an even stride over the mesh, areas
        /// scaled by the stride), bounding the cost on large meshes.
        var maxScoredFaces: Int
        /// Seed of the deterministic generator.
        var seed: UInt64

        /// Creates options; the defaults suit LiDAR meshes (about 1 cm noise).
        init(inlierDistance: Float = 0.01, maxTiltDegrees: Float = 10, normalToleranceDegrees: Float = 25,
             iterations: Int = 256, maxBelowFraction: Float = 0.1, minimumArea: Float = 0.01,
             maxScoredFaces: Int = 20_000, seed: UInt64 = 0x4D61_7070_6572_0001) {
            self.inlierDistance = inlierDistance
            self.maxTiltDegrees = maxTiltDegrees
            self.normalToleranceDegrees = normalToleranceDegrees
            self.iterations = iterations
            self.maxBelowFraction = maxBelowFraction
            self.minimumArea = minimumArea
            self.maxScoredFaces = maxScoredFaces
            self.seed = seed
        }
    }

    /// Settings for `isolate`.
    struct Options {
        /// Support plane search settings.
        var plane: PlaneOptions
        /// How a face is judged inside the selection.
        var faceTest: MeshCrop.FaceTest
        /// When true, faces more than `plane.inlierDistance` below the support are removed
        /// too (the object sits above its support).
        var removeBelowSupport: Bool

        /// Creates options with the given settings.
        init(plane: PlaneOptions = PlaneOptions(), faceTest: MeshCrop.FaceTest = .centroid,
             removeBelowSupport: Bool = true) {
            self.plane = plane
            self.faceTest = faceTest
            self.removeBelowSupport = removeBelowSupport
        }
    }

    /// Why an isolated object has no volume.
    enum VolumeUnavailableReason: Equatable {
        /// The mesh has open edges, typically where it rested on its support and the
        /// scanner could not see it.
        case notWatertight
        /// The mesh is closed but encloses no measurable volume.
        case degenerate
    }

    /// An isolated object and its measurements.
    struct IsolatedObject {
        /// The object mesh, winding made consistent (outward when closed).
        var mesh: MeshWithAttributes
        /// Gravity-aligned box: axis 0 along the width, axis 1 world up, axis 2 along the
        /// depth.
        var box: OrientedBox
        /// Longer horizontal side of `box`, in meters.
        var width: Float
        /// Vertical side of `box`, in meters.
        var height: Float
        /// Shorter horizontal side of `box`, in meters.
        var depth: Float
        /// Highest point above the support plane, in meters, or nil without a support.
        var heightAboveSupport: Float?
        /// Surface area of `mesh`, in square meters.
        var surfaceArea: Float
        /// Enclosed volume in cubic meters when the mesh is watertight, else nil.
        var volume: Float?
        /// Why `volume` is nil; nil when there is a volume.
        var volumeUnavailableReason: VolumeUnavailableReason?
        /// The support plane that was removed, if one was found.
        var supportPlane: Plane?
    }

    // MARK: - Isolation

    /// Isolates the object inside `selection`: crop (`MeshCrop`, keep inside), remove the
    /// support plane (`findSupportPlane` on the cropped faces) and, with
    /// `removeBelowSupport`, everything under it, keep the largest component
    /// (`MeshCleanup.largestComponent`), fix the winding (`MeshCleanup.fixingWinding`) and
    /// measure. Nil when nothing is left. The input is never mutated.
    static func isolate(_ input: MeshWithAttributes, selection: CropRegion, options: Options = Options()) -> IsolatedObject? {
        let selected = MeshCrop.crop(input, region: selection, mode: .keepInside, test: options.faceTest)
        guard selected.triangleCount > 0 else { return nil }
        let support = findSupportPlane(selected.mesh, options: options.plane)
        var object = selected
        if let plane = support {
            object = selected.keepingFaces(aboveSupportMask(selected.mesh, plane: plane, options: options))
        }
        let isolated = MeshCleanup.fixingWinding(MeshCleanup.largestComponent(object))
        guard isolated.triangleCount > 0 else { return nil }
        return measure(isolated, support: support)
    }

    /// `isolate` with an oriented box selection.
    static func isolate(_ input: MeshWithAttributes, box: OrientedBox, options: Options = Options()) -> IsolatedObject? {
        isolate(input, selection: .orientedBox(box), options: options)
    }

    /// `isolate` with an axis-aligned box selection.
    static func isolate(_ input: MeshWithAttributes, box: AABB3, options: Options = Options()) -> IsolatedObject? {
        isolate(input, selection: .box(box), options: options)
    }

    /// Measurements of an already isolated object: gravity-aligned box (width is the longer
    /// horizontal side), surface area, height above `support`, and the volume when the
    /// mesh is watertight (Geometry's `isWatertight` and `signedVolume`), else a reason.
    /// Nil for a mesh without finite vertices.
    static func measure(_ object: MeshWithAttributes, support: Plane?) -> IsolatedObject? {
        guard let box = gravityAlignedBox(object.mesh.positions) else { return nil }
        var volume: Float?
        var reason: VolumeUnavailableReason?
        if object.mesh.isWatertight {
            let enclosed = abs(object.mesh.signedVolume)
            if enclosed.isFinite && enclosed > minimumVolume {
                volume = enclosed
            } else {
                reason = .degenerate
            }
        } else {
            reason = .notWatertight
        }
        let above = support.map { plane in
            object.mesh.positions.reduce(-Float.infinity) { Swift.max($0, plane.signedDistance(to: $1)) }
        }
        let extents: SIMD3<Float> = 2 * box.halfExtents
        return IsolatedObject(mesh: object, box: box, width: extents.x, height: extents.y, depth: extents.z,
                              heightAboveSupport: above, surfaceArea: object.mesh.surfaceArea,
                              volume: volume, volumeUnavailableReason: reason, supportPlane: support)
    }

    /// `OrientedBox.fit(_:gravityAligned: true)` with the axes reordered so axis 0 is the
    /// longer horizontal side, axis 1 is up and the frame stays right-handed.
    static func gravityAlignedBox(_ points: [SIMD3<Float>]) -> OrientedBox? {
        guard let box = OrientedBox.fit(points, gravityAligned: true) else { return nil }
        guard box.halfExtents.z > box.halfExtents.x else { return box }
        let first = box.axes.columns.2
        return OrientedBox(center: box.center, axes: simd_float3x3(first, up, simd_cross(first, up)),
                           halfExtents: SIMD3<Float>(box.halfExtents.z, box.halfExtents.y, box.halfExtents.x))
    }

    /// Per face: true when the face is neither on the support plane (centroid within
    /// `inlierDistance` and normal parallel to the plane) nor, with `removeBelowSupport`,
    /// more than `inlierDistance` below it.
    private static func aboveSupportMask(_ mesh: TriangleMesh, plane: Plane, options: Options) -> [Bool] {
        let cosNormal = cos(options.plane.normalToleranceDegrees * .pi / 180)
        let band = options.plane.inlierDistance
        var keep = [Bool](repeating: false, count: mesh.triangleCount)
        for t in 0..<mesh.triangleCount {
            guard let centroid = MeshTopology.centroid(mesh, t) else { continue }
            let distance = plane.signedDistance(to: centroid)
            let vector = MeshTopology.areaVector(mesh, t)
            let length = simd_length(vector)
            let parallel = length > 0 && abs(simd_dot(vector, plane.normal)) >= cosNormal * length
            let onPlane = abs(distance) <= band && parallel
            let below = options.removeBelowSupport && distance < -band
            keep[t] = !onPlane && !below
        }
        return keep
    }

    // MARK: - Support plane

    /// Centroid, unit normal and area of an even stride of a mesh's valid faces.
    private struct FaceSample {
        /// Face centroids.
        var centroids: [SIMD3<Float>] = []
        /// Unit face normals.
        var normals: [SIMD3<Float>] = []
        /// Face areas times the stride, so sums estimate the whole mesh.
        var areas: [Float] = []

        /// Samples every `ceil(faces / limit)`-th face of `mesh`, skipping faces with an
        /// out-of-range index, zero area or non-finite corners.
        init(mesh: TriangleMesh, limit: Int) {
            let faces = mesh.triangleCount
            let cap = Swift.max(limit, 1)
            let step = Swift.max(1, (faces + cap - 1) / cap)
            for t in Swift.stride(from: 0, to: faces, by: step) {
                guard let centroid = MeshTopology.centroid(mesh, t),
                      centroid.x.isFinite, centroid.y.isFinite, centroid.z.isFinite else { continue }
                let vector = MeshTopology.areaVector(mesh, t)
                let length = simd_length(vector)
                guard length > 0, length.isFinite else { continue }
                centroids.append(centroid)
                normals.append(vector / length)
                areas.append(0.5 * length * Float(step))
            }
        }

        /// Number of sampled faces.
        var count: Int { areas.count }
    }

    /// The support plane of `mesh`: among near-horizontal planes (normal within
    /// `maxTiltDegrees` of up, oriented up) with at most `maxBelowFraction` of the other
    /// area below them, the one with the largest inlier area, if that area reaches
    /// `minimumArea`. Hypotheses come from triples of near-horizontal face centroids
    /// (only centroids at or below `maxHeight` when given) drawn by a generator seeded with
    /// `options.seed`, so the result is deterministic. The winner is refined by a least
    /// squares fit (`Plane.fit`) through its inlier centroids when the refined plane is
    /// still valid.
    static func findSupportPlane(_ mesh: TriangleMesh, maxHeight: Float? = nil,
                                 options: PlaneOptions = PlaneOptions()) -> Plane? {
        let sample = FaceSample(mesh: mesh, limit: options.maxScoredFaces)
        let cosNormal = cos(options.normalToleranceDegrees * .pi / 180)
        let cosTilt = cos(options.maxTiltDegrees * .pi / 180)
        var candidates: [Int] = []
        for i in 0..<sample.count where abs(sample.normals[i].y) >= cosNormal {
            if let limit = maxHeight, sample.centroids[i].y > limit { continue }
            candidates.append(i)
        }
        guard candidates.count >= 3 else { return nil }

        var random = MeshProcessingRandom(seed: options.seed)
        var best: Plane?
        var bestArea: Float = 0
        for _ in 0..<Swift.max(options.iterations, 1) {
            let i = candidates[random.index(below: candidates.count)]
            let j = candidates[random.index(below: candidates.count)]
            let k = candidates[random.index(below: candidates.count)]
            guard i != j, j != k, i != k,
                  let raw = Plane(sample.centroids[i], sample.centroids[j], sample.centroids[k]) else { continue }
            let plane = raw.normal.y < 0 ? Plane(normal: -raw.normal, d: -raw.d) : raw
            guard plane.normal.y >= cosTilt,
                  let area = supportArea(plane, sample, options: options, cosNormal: cosNormal),
                  area > bestArea else { continue }
            best = plane
            bestArea = area
        }
        guard let found = best, bestArea >= options.minimumArea else { return nil }

        var inliers: [SIMD3<Float>] = []
        for i in 0..<sample.count where isInlier(i, found, sample, options: options, cosNormal: cosNormal) {
            inliers.append(sample.centroids[i])
        }
        if let fit = Plane.fit(inliers), fit.plane.normal.y >= cosTilt,
           let area = supportArea(fit.plane, sample, options: options, cosNormal: cosNormal),
           area >= options.minimumArea {
            return fit.plane
        }
        return found
    }

    /// True when sampled face `i` lies on `plane`: centroid within `inlierDistance` and
    /// normal within `normalToleranceDegrees` of the plane normal, either side.
    private static func isInlier(_ i: Int, _ plane: Plane, _ sample: FaceSample, options: PlaneOptions,
                                 cosNormal: Float) -> Bool {
        abs(plane.signedDistance(to: sample.centroids[i])) <= options.inlierDistance
            && abs(simd_dot(sample.normals[i], plane.normal)) >= cosNormal
    }

    /// Inlier area of `plane`, or nil when it cannot be a support: no inliers, or more
    /// than `maxBelowFraction` of the non-inlier area lies more than two inlier distances
    /// below it.
    private static func supportArea(_ plane: Plane, _ sample: FaceSample, options: PlaneOptions,
                                    cosNormal: Float) -> Float? {
        var inlier = 0.0, below = 0.0, total = 0.0
        let belowLimit = -2 * options.inlierDistance
        for i in 0..<sample.count {
            let area = Double(sample.areas[i])
            total += area
            if isInlier(i, plane, sample, options: options, cosNormal: cosNormal) {
                inlier += area
            } else if plane.signedDistance(to: sample.centroids[i]) < belowLimit {
                below += area
            }
        }
        guard inlier > 0, below <= Double(options.maxBelowFraction) * (total - inlier) else { return nil }
        return Float(inlier)
    }
}
