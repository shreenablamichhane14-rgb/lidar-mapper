import Foundation
import simd

// The Show Missing Areas tour as a pure value (docs/MODULES.md 3.40, D19): the stops in walking
// order, their watched sample points, the fill, unscannable and pass rules, and the arrow toward
// a stop's suggested viewpoint, then toward the area itself. No clock, no session, no file: the
// model feeds camera poses, coverage fractions and elapsed seconds, and the self-test does the same.

/// Where one stop of the tour stands.
enum MissingAreaStopStatus: String, Equatable, Sendable {
    /// Not resolved yet.
    case pending
    /// Coverage reached `MissingAreaTour.filledFraction`.
    case filled
    /// Faced long enough without progress (glass, mirrors).
    case unscannable
    /// The user tapped Next Area.
    case passed
}

/// One missing area of the tour with its live state.
struct MissingAreaStop: Identifiable, Equatable {
    /// `MissingAreaRecord.id`.
    var id: Int
    /// The stored area (centroid, normal, area, surface, suggested viewpoint).
    var record: MissingAreaRecord
    /// Points watched by the coverage recorder (`MissingAreaTour.samplePoints(for:spacing:)`).
    var samplePoints: [SIMD3<Float>]
    /// Current state.
    var status: MissingAreaStopStatus
    /// Well-observed fraction of `samplePoints`, 0...1.
    var fraction: Float
    /// Seconds spent facing the area from its viewpoint without progress.
    var facingSeconds: Double
}

/// Where to point the user. Angles in radians.
struct MissingAreaArrow: Equatable, Sendable {
    /// Horizontal bearing from the camera's facing direction to the target, positive to the right (clockwise seen from above).
    var bearing: Float
    /// Elevation of the target above the camera's horizontal plane.
    var pitch: Float
    /// Horizontal distance from the camera to the target, meters.
    var horizontalDistance: Float
    /// Within `MissingAreaTour.arrivalRadius` of the viewpoint (the arrow then points at the area itself).
    var atViewpoint: Bool
}

/// The coarse direction of the arrow, for hints and VoiceOver.
enum MissingAreaDirection: Equatable, Sendable {
    case ahead, left, right, behind, up, down
}

/// What one tour update or Next Area changed.
enum MissingAreaTourEvent: Equatable, Sendable {
    /// The stop with this id reached the filled fraction.
    case filled(Int)
    /// The current stop with this id was given up as unscannable.
    case unscannable(Int)
    /// The stop with this id is the current one now.
    case advanced(Int)
    /// No pending stop is left.
    case finished
}

/// The tour as a value. Pure.
struct MissingAreaTour: Equatable {
    /// Watched fraction at which a stop counts as filled.
    static let filledFraction: Float = 0.8
    /// Spacing of the watched sample points, meters.
    static let sampleSpacing: Float = 0.2
    /// Radius around a sample point that must be well observed (the coverage recorder's watched radius), meters.
    static let observedRadius: Float = 0.15
    /// Horizontal distance to a viewpoint that counts as standing there, meters.
    static let arrivalRadius: Float = 0.75
    /// Half angle of the cone around the camera's forward that counts as facing the area, degrees.
    static let facingConeDegrees: Float = 35
    /// Farthest camera to area distance that counts as facing it, meters.
    static let facingMaxDistance: Float = 3.5
    /// Facing seconds without progress after which the current stop becomes unscannable.
    static let unscannableSeconds: Double = 8
    /// A stop at or above this fraction is never given up as unscannable.
    static let unscannableMaxFraction: Float = 0.3
    /// A rise of the fraction by this much while facing counts as progress (facing time restarts).
    static let progressStep: Float = 0.05
    /// Most seconds one update may add to the facing time (a long gap, such as the app in the
    /// background, never gives an area up at once).
    static let maxUpdateSeconds: Double = 1
    /// The forward direction is replaced by the top edge within this many degrees of vertical.
    static let verticalForwardDegrees: Float = 30
    /// Smallest disc radius of the sample points, meters.
    static let minSampleRadius: Float = 0.1
    /// Most sample rings on each side of the centroid (caps the point count of huge areas).
    static let maxSampleSteps = 25

    /// The stops in walking order.
    private(set) var stops: [MissingAreaStop]
    /// Index into `stops` of the area shown now, nil when none is pending.
    private(set) var currentIndex: Int?
    /// Camera position of the last update (where Next Area looks for the nearest stop).
    private(set) var lastCameraPosition: SIMD3<Float>?
    /// Fraction of the current stop when its facing time last restarted.
    private var facingBaseline: Float?

    /// Orders the records by `order(_:from:)`; records with surface `.window` or `.door` are dropped (D19).
    /// A repeated record id keeps its first record.
    init(records: [MissingAreaRecord], start: SIMD3<Float>) {
        var seen = Set<Int>()
        var usable: [MissingAreaRecord] = []
        for record in records {
            let surface = record.surfaceClass
            guard surface != .window, surface != .door else { continue }
            guard seen.insert(record.id).inserted else { continue }
            usable.append(record)
        }
        let walking = MissingAreaTour.order(usable, from: start)
        let built = walking.map { (index: Int) -> MissingAreaStop in
            let record = usable[index]
            return MissingAreaStop(id: record.id, record: record,
                                   samplePoints: MissingAreaTour.samplePoints(for: record, spacing: MissingAreaTour.sampleSpacing),
                                   status: .pending, fraction: 0, facingSeconds: 0)
        }
        stops = built
        currentIndex = built.isEmpty ? nil : 0
        lastCameraPosition = nil
        facingBaseline = nil
    }

    // MARK: - Updates

    /// Updates fractions of every pending stop; a stop at `filledFraction` or more becomes filled (any stop,
    /// not only the current); facing time counts for the current stop only with normal tracking; the current
    /// stop becomes unscannable after `unscannableSeconds` facing it with its fraction under
    /// `unscannableMaxFraction`; a resolved current stop advances to the nearest pending stop.
    /// "Nearest" is measured horizontally from the camera to each stop's viewpoint.
    mutating func update(fractions: [Int: Float], cameraToWorld: simd_float4x4, seconds: Double,
                         trackingNormal: Bool) -> [MissingAreaTourEvent] {
        var events: [MissingAreaTourEvent] = []
        let cameraUsable = MissingAreaTour.isFinite(cameraToWorld)
        let position: SIMD3<Float>? = cameraUsable ? MissingAreaTour.position(cameraToWorld) : nil
        if let position { lastCameraPosition = position }
        for i in stops.indices where stops[i].status == .pending {
            if let value = fractions[stops[i].id] { stops[i].fraction = MissingAreaTour.unit(value) }
            if stops[i].fraction >= MissingAreaTour.filledFraction {
                stops[i].status = .filled
                events.append(.filled(stops[i].id))
            }
        }
        if let c = currentIndex, stops[c].status == .pending {
            let facing = trackingNormal && cameraUsable
                && MissingAreaTour.isFacing(cameraToWorld: cameraToWorld, record: stops[c].record)
            if facing { countFacing(at: c, seconds: seconds) }
            let longEnough = stops[c].facingSeconds >= MissingAreaTour.unscannableSeconds
            if longEnough && stops[c].fraction < MissingAreaTour.unscannableMaxFraction {
                stops[c].status = .unscannable
                events.append(.unscannable(stops[c].id))
            }
        }
        events.append(contentsOf: advanceIfResolved(from: position))
        return events
    }

    /// Next Area: the current stop becomes passed; advance.
    mutating func next() -> [MissingAreaTourEvent] {
        guard let c = currentIndex, stops[c].status == .pending else { return [] }
        stops[c].status = .passed
        return advanceIfResolved(from: lastCameraPosition)
    }

    /// Stops still pending.
    var remainingCount: Int {
        stops.reduce(0) { $0 + ($1.status == .pending ? 1 : 0) }
    }

    /// True when no stop is pending (at once for an empty tour).
    var isFinished: Bool {
        !stops.contains { $0.status == .pending }
    }

    /// The stop shown now, nil when none is pending.
    var currentStop: MissingAreaStop? {
        guard let c = currentIndex, stops.indices.contains(c) else { return nil }
        return stops[c]
    }

    /// Stops that are filled, unscannable or passed.
    var resolvedCount: Int {
        stops.count - remainingCount
    }

    /// Adds facing time to the stop at `index`, or restarts it when the fraction rose by
    /// `progressStep` since the last restart.
    private mutating func countFacing(at index: Int, seconds: Double) {
        let fraction = stops[index].fraction
        guard let baseline = facingBaseline else {
            facingBaseline = fraction
            stops[index].facingSeconds += MissingAreaTour.clampedSeconds(seconds)
            return
        }
        if fraction >= baseline + MissingAreaTour.progressStep {
            facingBaseline = fraction
            stops[index].facingSeconds = 0
        } else {
            stops[index].facingSeconds += MissingAreaTour.clampedSeconds(seconds)
        }
    }

    /// When the current stop is resolved: the nearest pending stop becomes current (`.advanced`),
    /// or none is left (`.finished`). Measured from `position`, else from the resolved stop's viewpoint.
    private mutating func advanceIfResolved(from position: SIMD3<Float>?) -> [MissingAreaTourEvent] {
        guard let c = currentIndex else {
            guard let n = nearestPending(from: position ?? lastCameraPosition ?? SIMD3<Float>(0, 0, 0)) else { return [] }
            currentIndex = n
            facingBaseline = nil
            return [.advanced(stops[n].id)]
        }
        guard stops[c].status != .pending else { return [] }
        facingBaseline = nil
        let origin = position ?? stops[c].record.suggestedViewpoint.simd
        if let n = nearestPending(from: origin) {
            currentIndex = n
            return [.advanced(stops[n].id)]
        }
        currentIndex = nil
        return [.finished]
    }

    /// Index of the pending stop whose viewpoint is horizontally nearest to `point` (ties: lowest index).
    private func nearestPending(from point: SIMD3<Float>) -> Int? {
        var best: Int?
        var bestDistance = Float.infinity
        for (i, stop) in stops.enumerated() where stop.status == .pending {
            let d = MissingAreaTour.sortableDistance(point, stop.record.suggestedViewpoint.simd)
            if d < bestDistance {
                bestDistance = d
                best = i
            }
        }
        return best
    }

    // MARK: - Pure geometry

    /// Greedy walking order: from `start`, repeatedly the nearest suggested viewpoint (horizontal distance).
    /// Returns indices into `records`; ties keep the lower index; non-finite viewpoints go last.
    static func order(_ records: [MissingAreaRecord], from start: SIMD3<Float>) -> [Int] {
        var remaining = Array(records.indices)
        var out: [Int] = []
        out.reserveCapacity(records.count)
        var here = start
        while !remaining.isEmpty {
            var bestPosition = 0
            var bestDistance = Float.infinity
            for (position, index) in remaining.enumerated() {
                let d = sortableDistance(here, records[index].suggestedViewpoint.simd)
                if d < bestDistance {
                    bestDistance = d
                    bestPosition = position
                }
            }
            let chosen = remaining.remove(at: bestPosition)
            out.append(chosen)
            let viewpoint = records[chosen].suggestedViewpoint.simd
            if isFinite(viewpoint) { here = viewpoint }
        }
        return out
    }

    /// Points on a disc of radius sqrt(area / pi) (at least 0.1 m) in the area's plane, `spacing` apart, centroid included.
    static func samplePoints(for record: MissingAreaRecord, spacing: Float) -> [SIMD3<Float>] {
        let center = record.centroid.simd
        guard isFinite(center) else { return [] }
        let step: Float = spacing.isFinite && spacing > 0.01 ? spacing : sampleSpacing
        let area: Float = record.area.isFinite && record.area > 0 ? record.area : 0
        let radius: Float = Swift.max(minSampleRadius, (area / Float.pi).squareRoot())
        // Capped as a Float first: Int(_:) traps on a value out of range (a huge finite area).
        let stepCount: Float = Swift.min(Float(maxSampleSteps), (radius / step).rounded(.down))
        let steps: Int = stepCount.isFinite && stepCount > 0 ? Int(stepCount) : 0
        let basis = planeBasis(normal: record.normal.simd)
        let limit: Float = radius + 1e-5
        var out: [SIMD3<Float>] = [center]
        guard steps > 0 else { return out }
        for j in -steps...steps {
            for i in -steps...steps where !(i == 0 && j == 0) {
                let x = Float(i) * step
                let y = Float(j) * step
                guard (x * x + y * y).squareRoot() <= limit else { continue }
                let offset: SIMD3<Float> = basis.u * x + basis.v * y
                out.append(center + offset)
            }
        }
        return out
    }

    /// Arrow to the viewpoint, or to the centroid once within `arrivalRadius`. The facing direction is the
    /// camera's forward (-Z column) on the floor plane, or its top edge (-X column, portrait) when the
    /// forward is within 30 degrees of vertical.
    static func arrow(cameraToWorld: simd_float4x4, record: MissingAreaRecord) -> MissingAreaArrow {
        let camera = position(cameraToWorld)
        let viewpoint = record.suggestedViewpoint.simd
        let arrived = horizontalDistance(camera, viewpoint) <= arrivalRadius
        let target = arrived ? record.centroid.simd : viewpoint
        let delta = target - camera
        let flat = SIMD2<Float>(delta.x, delta.z)
        let distance = simd_length(flat)
        let pitch: Float = atan2f(delta.y, distance)
        var bearing: Float = 0
        if distance > 1e-4, let facing = facingOnFloor(cameraToWorld) {
            let d = flat / distance
            let dot: Float = facing.x * d.x + facing.y * d.y
            let cross: Float = facing.x * d.y - facing.y * d.x
            bearing = atan2f(cross, dot)
        }
        return MissingAreaArrow(bearing: finiteOrZero(bearing), pitch: finiteOrZero(pitch),
                                horizontalDistance: finiteOrZero(distance), atViewpoint: arrived)
    }

    /// |bearing| <= 45 degrees ahead, 45 to 135 right or left, beyond behind; at the viewpoint, pitch
    /// above 35 degrees is up and below -35 degrees is down.
    static func direction(_ arrow: MissingAreaArrow) -> MissingAreaDirection {
        let steep: Float = 35 * Float.pi / 180
        if arrow.atViewpoint {
            if arrow.pitch > steep { return .up }
            if arrow.pitch < -steep { return .down }
        }
        let degrees: Float = arrow.bearing * 180 / Float.pi
        let magnitude = abs(degrees)
        if magnitude <= 45 { return .ahead }
        if magnitude <= 135 { return degrees > 0 ? .right : .left }
        return .behind
    }

    /// True when the camera stands within `arrivalRadius` of the record's viewpoint, the area's
    /// centroid lies within `facingMaxDistance` and inside the `facingConeDegrees` cone around the
    /// camera's forward (-Z column).
    static func isFacing(cameraToWorld: simd_float4x4, record: MissingAreaRecord) -> Bool {
        let camera = position(cameraToWorld)
        guard horizontalDistance(camera, record.suggestedViewpoint.simd) <= arrivalRadius else { return false }
        let toArea = record.centroid.simd - camera
        let distance = simd_length(toArea)
        guard distance.isFinite, distance <= facingMaxDistance else { return false }
        guard distance > 1e-4 else { return true }
        let z = cameraToWorld.columns.2
        let forward = -SIMD3<Float>(z.x, z.y, z.z)
        let length = simd_length(forward)
        guard length.isFinite, length > 1e-6 else { return false }
        let cosine: Float = simd_dot(forward / length, toArea / distance)
        let cone: Float = cosf(facingConeDegrees * Float.pi / 180)
        return cosine >= cone
    }

    /// The camera's facing direction on the floor plane as a unit (x, z) vector: forward (-Z
    /// column), or the top edge (-X column) when forward is within 30 degrees of vertical; nil
    /// when neither has a horizontal part.
    static func facingOnFloor(_ cameraToWorld: simd_float4x4) -> SIMD2<Float>? {
        let z = cameraToWorld.columns.2
        let x = cameraToWorld.columns.0
        let forward = -SIMD3<Float>(z.x, z.y, z.z)
        let topEdge = -SIMD3<Float>(x.x, x.y, x.z)
        let forwardLength = simd_length(forward)
        guard forwardLength.isFinite, forwardLength > 1e-6 else { return nil }
        let vertical: Float = cosf(verticalForwardDegrees * Float.pi / 180)
        let chosen = abs(forward.y / forwardLength) >= vertical ? topEdge : forward
        let flat = SIMD2<Float>(chosen.x, chosen.z)
        let length = simd_length(flat)
        guard length.isFinite, length > 1e-6 else { return nil }
        return flat / length
    }

    // MARK: - Small helpers

    /// Translation column of a transform.
    static func position(_ m: simd_float4x4) -> SIMD3<Float> {
        SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)
    }

    /// Distance on the floor plane (x, z).
    static func horizontalDistance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        simd_length(SIMD2<Float>(b.x - a.x, b.z - a.z))
    }

    /// Horizontal distance with non-finite results sorted last.
    private static func sortableDistance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        let d = horizontalDistance(a, b)
        return d.isFinite ? d : Float.greatestFiniteMagnitude
    }

    /// Two unit vectors spanning the plane with this normal (up is used for a zero or non-finite normal).
    static func planeBasis(normal: SIMD3<Float>) -> (u: SIMD3<Float>, v: SIMD3<Float>) {
        let length = simd_length(normal)
        let n: SIMD3<Float> = length.isFinite && length > 1e-6 ? normal / length : SIMD3<Float>(0, 1, 0)
        let helper: SIMD3<Float> = abs(n.y) < 0.9 ? SIMD3<Float>(0, 1, 0) : SIMD3<Float>(1, 0, 0)
        let u = simd_normalize(simd_cross(helper, n))
        let v = simd_cross(n, u)
        return (u: u, v: v)
    }

    /// True when every element of the matrix is finite.
    static func isFinite(_ m: simd_float4x4) -> Bool {
        let c = m.columns
        return isFinite(c.0) && isFinite(c.1) && isFinite(c.2) && isFinite(c.3)
    }

    /// True when every component is finite.
    static func isFinite(_ v: SIMD4<Float>) -> Bool {
        v.x.isFinite && v.y.isFinite && v.z.isFinite && v.w.isFinite
    }

    /// True when every component is finite.
    static func isFinite(_ v: SIMD3<Float>) -> Bool {
        v.x.isFinite && v.y.isFinite && v.z.isFinite
    }

    /// Clamped to 0...1; NaN becomes 0.
    static func unit(_ value: Float) -> Float {
        guard value.isFinite else { return 0 }
        return Swift.min(Swift.max(value, 0), 1)
    }

    /// Seconds of one update, clamped to 0...`maxUpdateSeconds` (NaN counts as 0).
    static func clampedSeconds(_ seconds: Double) -> Double {
        guard seconds.isFinite else { return 0 }
        return Swift.min(Swift.max(seconds, 0), maxUpdateSeconds)
    }

    /// `value` when finite, else 0.
    private static func finiteOrZero(_ value: Float) -> Float {
        value.isFinite ? value : 0
    }
}
