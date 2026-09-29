import Foundation
import simd

/// Values, records and low-confidence flags of the tools. Pure, any queue.
///
/// Sigmas come only from `ConfidenceAdapter`, `MeasurementConfidence` and `MeasureMath`. Lengths
/// use the CR-2 rule on their own value. Areas take their flag from their sides (lead decision
/// E3): a side is the closed polygon's edge as a `ConfidenceAdapter.distance` between its two
/// endpoints, flagged by the CR-2 length rule; when any side is flagged (which includes every
/// weak endpoint) the area sigma is raised so Core's rule flags the stored value too. Angles use
/// the CR-2 rule with the sigma raised for weak endpoints.
extension MeasureToolSnaps {
    /// Areas at or below this are degenerate and always flagged, square meters (1 cm2).
    static let minimumArea: Double = 1e-4
    /// A re-snapped stored point must land this close to itself to recover its feature, meters.
    static let reconstructTolerance: Float = 0.001

    // MARK: - Values

    /// The value of a draft, nil with too few points. Distance: `ConfidenceAdapter.distance(start:end:length:)`.
    /// Height: the same with `length` = `MeasureMath.verticalDistance`. Area: `MeasureMath.polygonArea`
    /// with `areaSigma` of the point sigmas `MeasurementConfidence.pointAccuracy(_:)` and
    /// `MeasurementConfidence.driftRate(trackingNormalFraction:)` of the lowest endpoint fraction.
    /// Angle: `MeasureMath.angle` with `angleSigma`. The area sigma is raised to
    /// `ConfidenceAdapter.lowConfidenceSigmaFactor * MeasuredValue.lowConfidenceRelative * value`
    /// when a side is flagged (E3, every weak endpoint flags its sides), the angle sigma when any
    /// endpoint `MeasurementConfidence.isWeak(_:)`, so Core's rule (CR-2) flags them. Provenance `.measured`.
    static func value(_ draft: MeasureToolDraft, context: MeasureToolContext) -> MeasuredValue? {
        let points = draft.points
        switch draft.kind {
        case .distance, .height:
            guard points.count >= 2 else { return nil }
            let a = points[0]
            let b = points[1]
            let length: Float = draft.kind == .height
                ? MeasureMath.verticalDistance(a.position, b.position)
                : simd_distance(a.position, b.position)
            return ConfidenceAdapter.distance(start: evidence(for: a, context: context),
                                              end: evidence(for: b, context: context), length: length)
        case .area:
            guard points.count >= 3 else { return nil }
            return areaValue(points, context: context)
        case .angle:
            guard points.count >= 3 else { return nil }
            return angleValue(points[0], points[1], points[2], context: context)
        case .wall:
            return nil
        }
    }

    /// Area value of a closed polygon of placed points (see `value(_:context:)`).
    static func areaValue(_ points: [MeasureToolPoint], context: MeasureToolContext) -> MeasuredValue {
        let positions = points.map { $0.position }
        let evidences = points.map { evidence(for: $0, context: context) }
        let area = MeasureMath.polygonArea(positions)
        let sigmas = evidences.map { MeasurementConfidence.pointAccuracy($0) }
        let worstTracking = evidences.map { $0.trackingNormalFraction }.min() ?? 1
        let drift = MeasurementConfidence.driftRate(trackingNormalFraction: worstTracking)
        var sigma = Double(MeasureMath.areaSigma(positions, pointSigmas: sigmas, driftRate: drift))
        if sidesLowConfidence(positions, evidences: evidences) {
            sigma = max(sigma, raisedSigma(Double(area)))
        }
        return MeasuredValue(value: Double(area), sigma: sigma, provenance: .measured)
    }

    /// Angle value at `b` (see `value(_:context:)`).
    static func angleValue(_ a: MeasureToolPoint, _ b: MeasureToolPoint, _ c: MeasureToolPoint,
                           context: MeasureToolContext) -> MeasuredValue {
        let ea = evidence(for: a, context: context)
        let eb = evidence(for: b, context: context)
        let ec = evidence(for: c, context: context)
        let angle = MeasureMath.angle(a.position, b.position, c.position)
        let raw = MeasureMath.angleSigma(a.position, b.position, c.position,
                                         sigmaA: MeasurementConfidence.pointAccuracy(ea),
                                         sigmaB: MeasurementConfidence.pointAccuracy(eb),
                                         sigmaC: MeasurementConfidence.pointAccuracy(ec))
        var sigma = Double(raw)
        let weak = MeasurementConfidence.isWeak(ea) || MeasurementConfidence.isWeak(eb) || MeasurementConfidence.isWeak(ec)
        if weak {
            sigma = max(sigma, raisedSigma(Double(angle)))
        }
        return MeasuredValue(value: Double(angle), sigma: sigma, provenance: .measured)
    }

    /// The sigma that makes an area or angle read as low confidence under CR-2 (just over the limit).
    static func raisedSigma(_ value: Double) -> Double {
        ConfidenceAdapter.lowConfidenceSigmaFactor * MeasuredValue.lowConfidenceRelative * abs(value)
    }

    /// True when any side of the closed polygon, as a `ConfidenceAdapter.distance` between its
    /// endpoints, is low confidence under the CR-2 length rule.
    static func sidesLowConfidence(_ positions: [SIMD3<Float>], evidences: [MeasurementEvidence]) -> Bool {
        let n = positions.count
        guard n >= 2, evidences.count == n else { return false }
        for i in 0..<n {
            let j = (i + 1) % n
            let length = simd_distance(positions[i], positions[j])
            let side = ConfidenceAdapter.distance(start: evidences[i], end: evidences[j], length: length)
            if MeasureDisplay.isLowConfidence(side, kind: .distance) { return true }
        }
        return false
    }

    // MARK: - Flags

    /// Low confidence of a draft's live value: areas from their sides (E3, a degenerate area is
    /// always flagged), the other tools by the CR-2 rule on the value; false without a value.
    static func isLowConfidence(draft: MeasureToolDraft, context: MeasureToolContext) -> Bool {
        guard let live = draft.value else { return false }
        if draft.kind == .area {
            let evidences = draft.points.map { evidence(for: $0, context: context) }
            let positions = draft.points.map { $0.position }
            return !(live.value > minimumArea) || sidesLowConfidence(positions, evidences: evidences)
        }
        return MeasureDisplay.isLowConfidence(live, kind: draft.kind.measurementKind)
    }

    /// Low confidence of a saved record: `.area` records made by hand from their sides (points
    /// rebuilt with `point(of:at:context:)`), everything else by the CR-2 rule on the stored
    /// value; false when the value has no sigma.
    static func isLowConfidence(record: MeasurementRecord, context: MeasureToolContext) -> Bool {
        guard let sigma = record.result.sigma, sigma.isFinite else { return false }
        guard record.kind == .area, record.points.count >= 3 else {
            return MeasureDisplay.isLowConfidence(record.result, kind: record.kind)
        }
        if !(record.result.value > minimumArea) { return true }
        let points = record.points.indices.map { point(of: record, at: $0, context: context) }
        let evidences = points.map { evidence(for: $0, context: context) }
        return sidesLowConfidence(points.map { $0.position }, evidences: evidences)
    }

    // MARK: - Records

    /// Wall-tool records: `.wallLength` (points: base start and end; value
    /// `ConfidenceAdapter.roomPlanLength(MeasureRoomSizes.wallLength(wall), wall:, room:, provenance: wall.provenance)`)
    /// and `.height` (points: base start and start + height; value of `wall.height` the same way);
    /// snaps `.edge`, source `.viewer`, empty names, roomID of the wall's room. Both records share
    /// `now`, which is how `isWallRecord(_:among:)` pairs them.
    static func wallRecords(_ wall: CleanWall, context: MeasureToolContext, now: Date) -> [MeasurementRecord] {
        let owner = room(ofWall: wall.id, in: context.model)
        let roomEvidence = owner.flatMap { context.roomEvidence[$0.recordID] } ?? RoomEvidence.unknown
        let wallEvidence = context.wallEvidence[wall.id]
        let length = ConfidenceAdapter.roomPlanLength(MeasureRoomSizes.wallLength(wall), wall: wallEvidence,
                                                      room: roomEvidence, provenance: wall.provenance)
        let height = ConfidenceAdapter.roomPlanLength(wall.height, wall: wallEvidence, room: roomEvidence,
                                                      provenance: wall.provenance)
        let start = wall.start.simd
        let top = start + SIMD3<Float>(0, max(0, wall.height), 0)
        let lengthRecord = MeasurementRecord(id: UUID(), kind: .wallLength, points: [wall.start, wall.end],
                                             snaps: [.edge, .edge], result: length, source: .viewer, name: "",
                                             roomID: owner?.id, createdAt: now)
        let heightRecord = MeasurementRecord(id: UUID(), kind: .height, points: [wall.start, Vec3(top)],
                                             snaps: [.edge, .edge], result: height, source: .viewer, name: "",
                                             roomID: owner?.id, createdAt: now)
        return [lengthRecord, heightRecord]
    }

    /// The record of a complete distance, height, area or angle draft: points, snaps, `value`, source
    /// `.viewer`, empty name, roomID of the first point's room; nil when incomplete.
    static func record(for draft: MeasureToolDraft, context: MeasureToolContext, id: UUID, now: Date) -> MeasurementRecord? {
        let count = draft.points.count
        switch draft.kind {
        case .distance, .height:
            guard count == 2 else { return nil }
        case .angle:
            guard count == 3 else { return nil }
        case .area:
            guard count >= 3 else { return nil }
        case .wall:
            return nil
        }
        guard let measured = value(draft, context: context), let first = draft.points.first else { return nil }
        let owner = room(containing: first.position, in: context.model)
        return MeasurementRecord(id: id, kind: draft.kind.measurementKind, points: draft.points.map { Vec3($0.position) },
                                 snaps: draft.points.map { $0.snap }, result: measured, source: .viewer, name: "",
                                 roomID: owner?.id, createdAt: now)
    }

    /// A saved record with point `index` moved and its value recomputed (same id, name and createdAt;
    /// the room follows the first point). `.wallLength` records, other kinds no tool places, and an
    /// index out of range are returned unchanged (they follow the wall, not the finger).
    static func moving(_ record: MeasurementRecord, index: Int, to point: MeasureToolPoint,
                       context: MeasureToolContext) -> MeasurementRecord {
        guard record.kind != .wallLength, let tool = MeasureToolKind.placing(record.kind),
              index >= 0, index < record.points.count else { return record }
        var points = record.points.indices.map { self.point(of: record, at: $0, context: context) }
        points[index] = point
        let draft = MeasureToolDraft(kind: tool, points: points, value: nil)
        guard let measured = value(draft, context: context) else { return record }
        var moved = record
        moved.points = points.map { Vec3($0.position) }
        moved.snaps = points.map { $0.snap }
        moved.result = measured
        if let first = points.first {
            moved.roomID = room(containing: first.position, in: context.model)?.id ?? record.roomID
        }
        return moved
    }

    /// Point `index` of a saved record as a placed point: its position and snap, plus the feature and
    /// element of the SnapSet candidate it lies on (re-snapping lands within 1 mm with the same kind);
    /// no feature or element otherwise.
    static func point(of record: MeasurementRecord, at index: Int, context: MeasureToolContext) -> MeasureToolPoint {
        guard index >= 0, index < record.points.count else {
            return MeasureToolPoint(position: .zero, snap: SnapKind.none)
        }
        let position = record.points[index].simd
        let snap: SnapKind = index < record.snaps.count ? record.snaps[index] : SnapKind.none
        switch snap {
        case .corner, .edge, .plane:
            let again = context.snaps.hit(position)
            if again.kind == snap, simd_distance(again.point, position) <= reconstructTolerance {
                return MeasureToolPoint(position: position, snap: snap, feature: again.feature, element: again.element)
            }
            return MeasureToolPoint(position: position, snap: snap)
        case .meshVertex, .meshSurface, .none:
            return MeasureToolPoint(position: position, snap: snap)
        }
    }

    /// True for the records a Wall tap made: every `.wallLength` record, and a `.height` record with
    /// two `.edge` snaps paired with a `.wallLength` record of the same createdAt and first point.
    /// These follow their wall and get no drag handles.
    static func isWallRecord(_ record: MeasurementRecord, among records: [MeasurementRecord]) -> Bool {
        if record.kind == .wallLength { return true }
        guard record.kind == .height, record.snaps == [.edge, .edge], let first = record.points.first else { return false }
        return records.contains { other in
            other.kind == .wallLength && other.createdAt == record.createdAt && other.points.first == first
        }
    }
}
