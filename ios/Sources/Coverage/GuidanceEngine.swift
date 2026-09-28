import Foundation
import simd

// Live scanning guidance: turns per-tick scan signals into at most one `GuidanceKind`
// to show, plus whether to fire a warning haptic.
//
// Sources:
// - docs/SPEC.txt, LIVE SCANNING EXPERIENCE: the message list, and "Do not overwhelm the
//   user. Only show important instructions."
// - docs/UX_COPY.md section 4 (Guidance messages, Display rules) and `GuidancePolicy` in
//   Copy.swift: tiers, minimum on-screen time, gap, hold, repeat cooldown, tier 3 quiet time
//   and cap, haptic cooldown, interruption rule. Every rule is implemented below.
// - docs/research/raw/quality-coverage-measure.json: `ARLightEstimate.ambientIntensity` is
//   lumens-scaled with 1000 = neutral lighting (the free "lighting is poor" signal); LiDAR
//   range is about 5 m; RoomPlan's `RoomCaptureSession.Instruction` has six cases (normal,
//   moveCloseToWall, moveAwayFromWall, turnOnLight, slowDown, lowTexture) but Apple does not
//   publish the distance, speed or lux thresholds behind them, so the thresholds here are our
//   own, chosen from the LiDAR range and the coverage grid's quality curve.
//
// Determinism: the engine never reads a clock. Time comes from `GuidanceInput.time`, so the
// same input sequence always produces the same output sequence (used by CoverageSelfTest).

/// Camera tracking state reported by the adapter. Mirrors `ARCamera.TrackingState`:
/// `.normal`, `.notAvailable` or `.limited(reason)` where reason is excessiveMotion,
/// insufficientFeatures, initializing or relocalizing. The adapter maps `.notAvailable`
/// to `.initializing`.
enum GuidanceTracking: UInt8 {
    case normal, excessiveMotion, insufficientFeatures, initializing, relocalizing
}

/// Signals for one guidance tick (typically 5 to 10 Hz; the engine only needs monotonic time).
struct GuidanceInput {
    /// Seconds, monotonic, supplied by the caller (for example `ARFrame.timestamp`).
    var time: Double
    /// Tracking state reason.
    var tracking: GuidanceTracking = .normal
    /// Camera angular speed in rad/s.
    var angularSpeed: Float = 0
    /// Camera linear speed in m/s.
    var linearSpeed: Float = 0
    /// Depth at the view center in meters; nil when there is no depth there.
    var centerDistance: Float? = nil
    /// Mean depth confidence 0...1 (ARConfidenceLevel / 2). Below `lowDepthConfidence` with the
    /// view center beyond `lowDepthConfidenceMinDistance` (or unknown) it raises "Move closer".
    var depthConfidenceMean: Float? = nil
    /// `ARLightEstimate.ambientIntensity`, lumens-scaled, 1000 = neutral.
    var ambientIntensity: Float? = nil
    /// Fraction 0...1 of the in-view surface that is green.
    var viewCoverage: Float? = nil
    /// Missing areas near the user, most important first.
    var nearbyMissing: [MissingArea] = []
    /// Newly detected doors, windows and walls since the previous tick.
    var newDoors: Int = 0; var newWindows: Int = 0; var newWalls: Int = 0
    /// Device thermal state is serious or critical.
    var deviceHot: Bool = false
    /// Scan quality says the room is done.
    var overallComplete: Bool = false
}

/// Result of one tick: the message to show now (nil = nothing) and whether to fire a haptic.
/// The caller still obeys the user's Haptics setting.
struct GuidanceOutput: Equatable {
    var message: GuidanceKind?
    var fireHaptic: Bool
}

/// Deterministic guidance state machine implementing `GuidancePolicy`.
struct GuidanceEngine {

    // MARK: Thresholds

    /// `.initializing` longer than this counts as low tracking quality. ARKit normally
    /// initializes in about 1 s; 3 s means the scene lacks features or light.
    static let initializingGraceSeconds: Double = 3.0
    /// Above this rotation speed LiDAR frames smear and the mesh doubles. 1.5 rad/s is
    /// roughly a quarter turn in one second, a fast pan.
    static let fastAngularSpeed: Float = 1.5
    /// Above this walking speed with the phone raised, depth integration falls behind.
    /// 1.0 m/s is a normal walking pace; scanning should be slower.
    static let fastLinearSpeed: Float = 1.0
    /// `ambientIntensity` below this is "Lighting is poor". 1000 is neutral (research file);
    /// 300 is under a third of neutral, a dim room where tracking and texture both degrade.
    static let lightingPoorIntensity: Float = 300
    /// Closer than this the LiDAR returns no usable depth (grid distance term is 0 below 0.2 m
    /// and weak until 0.5 m); 0.3 m leaves room for noise in the center sample.
    static let tooCloseDistance: Float = 0.3
    /// Beyond this nothing is recorded: LiDAR range is about 5 m (research file) and
    /// `CoverageGrid.maxRange` is 5.0 m.
    static let tooFarDistance: Float = 5.0
    /// Beyond this (but in range) surfaces are captured thinly: the grid quality falls past
    /// 2.5 m. 3.0 m gives margin before nudging with tier 2 "Move closer".
    static let moveCloserDistance: Float = 3.0
    /// In-view green fraction below this means the area in front of the user needs another pass.
    static let lowViewCoverage: Float = 0.3
    /// Low view coverage must persist this long (on top of the normal hold) before it counts,
    /// because green needs three good observations and the grid integrates at 2 to 3 Hz, so a
    /// freshly viewed area is legitimately not green for the first second or two.
    static let lowViewCoverageHoldSeconds: Double = 4.0
    /// Mean depth confidence below this means most depth pixels are low confidence (low = 0,
    /// medium = 0.5, high = 1). LiDAR confidence falls with range, so the fix is "Move closer".
    static let lowDepthConfidence: Float = 0.3
    /// Low depth confidence only asks to move closer when the view center is farther than this
    /// (or unknown); nearer, the cause is the material (dark, shiny, glass), not the distance.
    static let lowDepthConfidenceMinDistance: Float = 1.5
    /// A missing wall area is a corner when its nearest edge is within this distance (m,
    /// horizontal) of where two walls meet.
    static let cornerRadius: Float = 0.5
    /// Two wall normals whose |cosine| is at most this (angle over about 45 degrees) belong to
    /// different walls that can form a corner.
    static let cornerMaxNormalCosine: Float = 0.7
    /// A detection event that cannot be shown within this many seconds is dropped.
    static let eventExpirySeconds: Double = 4.0
    /// Relative hysteresis applied to a continuous threshold while its message is visible,
    /// so a value hovering at the threshold does not end the message and restart it.
    static let hysteresis: Float = 0.1
    /// Rolling window for `GuidancePolicy.maxTier3PerMinute`.
    static let tier3WindowSeconds: Double = 60.0

    /// Priority within a tier, following the table order in docs/UX_COPY.md section 4
    /// (display rule 9: lowest tier first, then table order). Kinds absent here rank last.
    static let priorityOrder: [GuidanceKind] = [
        .trackingLost, .trackingLow, .lightingPoor, .moveSlower, .tooClose, .tooFar, .deviceHot, .objectMoved,
        .moveCloser, .scanCorner, .pointAtFloor, .scanCeiling, .scanDoorwayBothSides, .needsAnotherPass,
        .objectMoveAround, .objectCaptureLeft, .objectCaptureRight, .objectCaptureBack, .objectCaptureTop,
        .objectKeepInView, .objectMoveCloserToArea, .objectNeedsDetail,
        .windowDetected, .doorDetected, .wallDetected, .openingDetected, .stairsDetected,
        .roomLooksComplete, .objectLooksComplete,
    ]

    // MARK: State

    /// One detection event waiting for a free slot.
    private struct PendingEvent {
        var kind: GuidanceKind
        var expiresAt: Double
    }

    /// Message on screen now, when it appeared, and whether it is a one-shot detection event.
    private(set) var current: GuidanceKind?
    private(set) var currentShownAt: Double = 0
    private var currentIsEvent = false
    /// Time the last message hid on its own (starts the minimum gap). Interrupts do not set it.
    private var lastHiddenAt: Double?
    /// Per kind, the last time it was visible (hide or replace time); drives the repeat cooldown.
    private var lastVisibleAt: [GuidanceKind: Double] = [:]
    /// Per kind, when its condition became continuously true.
    private var conditionStart: [GuidanceKind: Double] = [:]
    /// Start of continuous `.initializing` tracking and of continuous low view coverage.
    private var initializingSince: Double?
    private var lowCoverageSince: Double?
    /// Show times of tier 3 messages in the rolling minute.
    private var tier3ShownTimes: [Double] = []
    /// Last time a tier 1 message was on screen (refreshed every tick it stays visible, so the
    /// tier 3 quiet period counts from when the trouble ended).
    private var lastTier1At: Double?
    /// Last time a haptic fired.
    private var lastHapticAt: Double?
    /// Detection events waiting to be shown.
    private var pendingEvents: [PendingEvent] = []
    /// Tier 3 conditions already shown during their current run of being true: shown once per
    /// run, so "Looks good" does not come back every cooldown while the room stays complete.
    private var shownThisRun: Set<GuidanceKind> = []

    /// Creates an idle engine.
    init() {}

    /// Returns to the idle state (new scan).
    mutating func reset() {
        self = GuidanceEngine()
    }

    // MARK: Tick

    /// Processes one tick and returns the message to display now.
    mutating func update(_ input: GuidanceInput) -> GuidanceOutput {
        let now = input.time
        updateTimers(input)
        let active = conditions(for: input)

        // Condition hold bookkeeping (display rule 5).
        for kind in active where conditionStart[kind] == nil { conditionStart[kind] = now }
        conditionStart = conditionStart.filter { active.contains($0.key) }
        shownThisRun.formIntersection(active)

        // Tier 3 window, quiet time and events (display rule 8, event expiry).
        tier3ShownTimes.removeAll { now - $0 >= GuidanceEngine.tier3WindowSeconds }
        if let c = current, c.message.tier == 1 { lastTier1At = now }
        enqueueEvents(input)
        pendingEvents.removeAll { $0.expiresAt <= now }
        if tier3Blocked(now) { pendingEvents.removeAll() }

        // Pick the best candidate (display rule 9).
        var best: (kind: GuidanceKind, isEvent: Bool)?
        var bestRank = (Int.max, Int.max)
        for kind in active where !shownThisRun.contains(kind) {
            guard let start = conditionStart[kind], now - start >= GuidancePolicy.conditionHoldSeconds,
                  isEligible(kind, now: now) else { continue }
            let r = GuidanceEngine.rank(kind)
            if r < bestRank { bestRank = r; best = (kind: kind, isEvent: false) }
        }
        for event in pendingEvents where isEligible(event.kind, now: now) {
            // Detection events bypass the hold (they are already confirmed by RoomPlan).
            let r = GuidanceEngine.rank(event.kind)
            if r < bestRank { bestRank = r; best = (kind: event.kind, isEvent: true) }
        }

        // Hide the current message once its minimum time is over and its reason is gone
        // (display rules 2 and 6). Tier 1 and 2 conditions keep their message up while true;
        // events and tier 3 conditions leave after their minimum time so they never hog the slot.
        // A candidate allowed to interrupt takes over directly instead (rule 4: tier 2 replaces
        // tier 3 once it had its minimum time, without waiting out the gap).
        if let c = current {
            let msg = c.message
            let shown = now - currentShownAt
            let holds = !currentIsEvent && msg.tier < 3 && active.contains(c)
            let replaced = best.map {
                GuidancePolicy.canInterrupt(incomingTier: $0.kind.message.tier, currentTier: msg.tier,
                                            currentShownSeconds: shown)
            } ?? false
            if shown >= msg.minimumSeconds && !holds && !replaced {
                lastVisibleAt[c] = now
                lastHiddenAt = now
                current = nil
                currentIsEvent = false
            }
        }

        var fireHaptic = false
        if let pick = best {
            let tier = pick.kind.message.tier
            if let c = current {
                // Interruption (display rule 4).
                if GuidancePolicy.canInterrupt(incomingTier: tier, currentTier: c.message.tier,
                                               currentShownSeconds: now - currentShownAt) {
                    lastVisibleAt[c] = now
                    fireHaptic = show(pick.kind, isEvent: pick.isEvent, now: now)
                }
            } else {
                // Minimum gap after a hide, tier 1 exempt (display rule 3).
                let gapOK = lastHiddenAt.map { now - $0 >= GuidancePolicy.minimumGapSeconds } ?? true
                if gapOK || GuidancePolicy.gapExemptTiers.contains(tier) {
                    fireHaptic = show(pick.kind, isEvent: pick.isEvent, now: now)
                }
            }
        }
        return GuidanceOutput(message: current, fireHaptic: fireHaptic)
    }

    // MARK: Conditions

    /// The set of guidance conditions that are true for this input, ignoring timing rules.
    /// Uses `current` only for hysteresis. Detection events are not included (see `update`).
    func conditions(for input: GuidanceInput) -> Set<GuidanceKind> {
        var out = Set<GuidanceKind>()
        let h = GuidanceEngine.hysteresis

        // Tier 1: tracking.
        switch input.tracking {
        case .relocalizing:
            out.insert(.trackingLost)
        case .insufficientFeatures:
            out.insert(.trackingLow)
        case .initializing:
            if let since = initializingSince, input.time - since > GuidanceEngine.initializingGraceSeconds {
                out.insert(.trackingLow)
            }
        case .excessiveMotion:
            out.insert(.moveSlower)
        case .normal:
            break
        }

        // Tier 1: motion speed.
        let speedFactor: Float = current == .moveSlower ? 1 - h : 1
        if input.angularSpeed.isFinite && input.angularSpeed > GuidanceEngine.fastAngularSpeed * speedFactor {
            out.insert(.moveSlower)
        }
        if input.linearSpeed.isFinite && input.linearSpeed > GuidanceEngine.fastLinearSpeed * speedFactor {
            out.insert(.moveSlower)
        }

        // Tier 1: lighting.
        if let lux = input.ambientIntensity, lux.isFinite {
            let limit = GuidanceEngine.lightingPoorIntensity * (current == .lightingPoor ? 1 + h : 1)
            if lux < limit { out.insert(.lightingPoor) }
        }

        // Tier 1 range limits and tier 2 "Move closer".
        var farForCoverage = false
        if let d = input.centerDistance, d.isFinite, d > 0 {
            let closeLimit = GuidanceEngine.tooCloseDistance * (current == .tooClose ? 1 + h : 1)
            let farLimit = GuidanceEngine.tooFarDistance * (current == .tooFar ? 1 - h : 1)
            let closerLimit = GuidanceEngine.moveCloserDistance * (current == .moveCloser ? 1 - h : 1)
            if d < closeLimit {
                out.insert(.tooClose)
            } else if d > farLimit {
                out.insert(.tooFar)
            } else if d > closerLimit {
                farForCoverage = true
            }
        }

        // Tier 1: heat.
        if input.deviceHot { out.insert(.deviceHot) }

        // Tier 2 and 3 coverage messages need trustworthy tracking: while tracking is limited
        // the pose, and therefore the coverage grid, is unreliable.
        guard input.tracking == .normal else { return out }

        if farForCoverage { out.insert(.moveCloser) }
        if let conf = input.depthConfidenceMean, conf.isFinite {
            let limit = GuidanceEngine.lowDepthConfidence * (current == .moveCloser ? 1 + h : 1)
            let center = input.centerDistance ?? Float.infinity
            if conf < limit && !(center <= GuidanceEngine.lowDepthConfidenceMinDistance) { out.insert(.moveCloser) }
        }
        for area in input.nearbyMissing {
            out.insert(GuidanceEngine.missingKind(for: area, among: input.nearbyMissing))
        }
        if let since = lowCoverageSince, input.time - since >= GuidanceEngine.lowViewCoverageHoldSeconds {
            out.insert(.needsAnotherPass)
        }
        if input.overallComplete && input.nearbyMissing.isEmpty {
            out.insert(.roomLooksComplete)
        }
        return out
    }

    /// Message for one missing area: ceiling -> scanCeiling, floor -> pointAtFloor,
    /// door -> scanDoorwayBothSides, wall -> scanCorner when near a corner else needsAnotherPass,
    /// anything else -> needsAnotherPass.
    static func missingKind(for area: MissingArea, among areas: [MissingArea]) -> GuidanceKind {
        switch area.surface {
        case .ceiling: return .scanCeiling
        case .floor: return .pointAtFloor
        case .door: return .scanDoorwayBothSides
        case .wall: return isNearCorner(area, among: areas) ? .scanCorner : .needsAnotherPass
        case .none, .table, .seat, .window: return .needsAnotherPass
        }
    }

    /// True when `area` (a wall hole) lies within `cornerRadius` of where two walls meet.
    /// The engine has no wall list, so a corner is inferred from a second missing wall area
    /// whose normal differs by more than about 45 degrees: the corner is the intersection of
    /// the two vertical wall planes on the floor plan. Each area's reach to the corner is its
    /// centroid distance minus half the side of an equal-area square (its approximate
    /// half-extent), clamped at 0; both must be within `cornerRadius`. Limitation: a hole in
    /// one wall next to a fully scanned adjacent wall is reported as needsAnotherPass.
    static func isNearCorner(_ area: MissingArea, among areas: [MissingArea]) -> Bool {
        guard let a = gvHorizontalUnit(area.normal) else { return false }
        let ca = SIMD2<Float>(area.centroid.x, area.centroid.z)
        for other in areas where other.surface == .wall {
            guard let b = gvHorizontalUnit(other.normal) else { continue }
            // Parallel normals (including `area` itself) are the same or opposite walls.
            if abs(simd_dot(a, b)) > cornerMaxNormalCosine { continue }
            let det = a.x * b.y - a.y * b.x
            if abs(det) < 1e-4 { continue }
            let cb = SIMD2<Float>(other.centroid.x, other.centroid.z)
            let ra = simd_dot(a, ca)
            let rb = simd_dot(b, cb)
            // Solve a . p = ra, b . p = rb (Cramer's rule) for the corner point p.
            let corner = SIMD2<Float>((ra * b.y - a.y * rb) / det, (a.x * rb - b.x * ra) / det)
            let reachA = max(0, simd_length(ca - corner) - 0.5 * max(area.area, 0).squareRoot())
            let reachB = max(0, simd_length(cb - corner) - 0.5 * max(other.area, 0).squareRoot())
            if reachA <= cornerRadius && reachB <= cornerRadius { return true }
        }
        return false
    }

    /// Sort key: tier first, then position in `priorityOrder`.
    static func rank(_ kind: GuidanceKind) -> (Int, Int) {
        (kind.message.tier, priorityOrder.firstIndex(of: kind) ?? Int.max)
    }

    // MARK: Helpers

    /// Tracks how long tracking has been initializing and how long view coverage has been low.
    private mutating func updateTimers(_ input: GuidanceInput) {
        if input.tracking == .initializing {
            if initializingSince == nil { initializingSince = input.time }
        } else {
            initializingSince = nil
        }
        let limit = GuidanceEngine.lowViewCoverage
            * (current == .needsAnotherPass ? 1 + GuidanceEngine.hysteresis : 1)
        if input.tracking == .normal, let v = input.viewCoverage, v.isFinite, v < limit {
            if lowCoverageSince == nil { lowCoverageSince = input.time }
        } else {
            lowCoverageSince = nil
        }
    }

    /// Adds or refreshes pending detection events from the new-object counts.
    private mutating func enqueueEvents(_ input: GuidanceInput) {
        let counts: [(Int, GuidanceKind)] = [
            (input.newWindows, .windowDetected), (input.newDoors, .doorDetected), (input.newWalls, .wallDetected),
        ]
        let expiry = input.time + GuidanceEngine.eventExpirySeconds
        for (count, kind) in counts where count > 0 {
            if let i = pendingEvents.firstIndex(where: { $0.kind == kind }) {
                pendingEvents[i].expiresAt = expiry
            } else {
                pendingEvents.append(PendingEvent(kind: kind, expiresAt: expiry))
            }
        }
    }

    /// True while tier 3 messages are dropped: within the quiet time after tier 1, or when
    /// the rolling-minute cap is reached (display rule 8).
    private func tier3Blocked(_ now: Double) -> Bool {
        if let t = lastTier1At, now - t < GuidancePolicy.tier3QuietAfterTier1Seconds { return true }
        return tier3ShownTimes.count >= GuidancePolicy.maxTier3PerMinute
    }

    /// Whether `kind` may be shown now: not already on screen, outside its repeat cooldown
    /// (display rule 7, measured from when it was last visible), and tier 3 not blocked.
    private func isEligible(_ kind: GuidanceKind, now: Double) -> Bool {
        if kind == current { return false }
        if let last = lastVisibleAt[kind], now - last < GuidancePolicy.repeatCooldownSeconds { return false }
        if kind.message.tier >= 3 && tier3Blocked(now) { return false }
        return true
    }

    /// Puts `kind` on screen and returns whether to fire a haptic: only for a haptic
    /// (tier 1) message newly appearing, at most once per `hapticCooldownSeconds` (rule 10).
    private mutating func show(_ kind: GuidanceKind, isEvent: Bool, now: Double) -> Bool {
        let msg = kind.message
        current = kind
        currentShownAt = now
        currentIsEvent = isEvent
        pendingEvents.removeAll { $0.kind == kind }
        if msg.tier == 1 {
            lastTier1At = now
            pendingEvents.removeAll()  // tier 3 events are dropped, not queued, after tier 1
        }
        if msg.tier >= 3 { tier3ShownTimes.append(now) }
        if msg.tier >= 3 && !isEvent { shownThisRun.insert(kind) }
        guard msg.haptic && msg.tier == 1 else { return false }
        if let last = lastHapticAt, now - last < GuidancePolicy.hapticCooldownSeconds { return false }
        lastHapticAt = now
        return true
    }
}

/// Unit vector of the horizontal (x, z) part of `v`, or nil when `v` is near vertical.
private func gvHorizontalUnit(_ v: SIMD3<Float>) -> SIMD2<Float>? {
    let h = SIMD2<Float>(v.x, v.z)
    let len = simd_length(h)
    guard len.isFinite, len > 1e-3 else { return nil }
    return h / len
}
