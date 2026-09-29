import Foundation
import simd

/// The five tools, in picker order (docs/MODULES.md 3.35).
enum MeasureToolKind: String, CaseIterable, Identifiable, Sendable {
    case distance, height, wall, area, angle

    /// Stable identity for pickers and lists.
    var id: String { rawValue }

    /// Points that complete a measurement: distance 2, height 2, wall 1 (the tap on the wall),
    /// area 3 or more (closed by the user), angle 3.
    var minimumPoints: Int {
        switch self {
        case .distance, .height: return 2
        case .wall: return 1
        case .area, .angle: return 3
        }
    }

    /// The Core kind of the (first) record it makes: .distance, .height, .wallLength, .area, .angle.
    var measurementKind: MeasurementKind {
        switch self {
        case .distance: return .distance
        case .height: return .height
        case .wall: return .wallLength
        case .area: return .area
        case .angle: return .angle
        }
    }

    /// The tool that places records of a Core kind by hand (distance, height, area, angle);
    /// nil for kinds no tool re-places point by point (wall length, perimeter, volume).
    static func placing(_ kind: MeasurementKind) -> MeasureToolKind? {
        switch kind {
        case .distance: return .distance
        case .height: return .height
        case .area: return .area
        case .angle: return .angle
        case .wallLength, .perimeter, .volume: return nil
        }
    }
}

/// One placed point, world meters (the frame of the viewer content: the structure frame for House
/// projects, 3.43b).
struct MeasureToolPoint: Equatable, Sendable {
    /// World position, meters.
    var position: SIMD3<Float>
    /// Stored in `MeasurementRecord.snaps`.
    var snap: SnapKind
    /// What a SnapSet snap attached to (drives the "Snapped to" tag); nil for mesh snaps and free points.
    var feature: SnapSetFeature?
    /// The wall, opening, object or room it attached to, when known.
    var element: ElementID?

    /// Creates a point.
    init(position: SIMD3<Float>, snap: SnapKind, feature: SnapSetFeature? = nil, element: ElementID? = nil) {
        self.position = position
        self.snap = snap
        self.feature = feature
        self.element = element
    }
}

/// The measurement being placed.
struct MeasureToolDraft: Equatable, Sendable {
    /// The tool placing it.
    var kind: MeasureToolKind
    /// Points placed so far, in tap order.
    var points: [MeasureToolPoint]
    /// Live value once there are enough points to show one (area from 3 points, the others when
    /// complete); nil before.
    var value: MeasuredValue?

    /// A draft of `kind` with no points.
    static func empty(_ kind: MeasureToolKind) -> MeasureToolDraft {
        MeasureToolDraft(kind: kind, points: [], value: nil)
    }
}

/// A point that can be dragged on screen.
enum MeasureToolHandle: Hashable, Sendable {
    /// Point `index` of the draft.
    case draft(index: Int)
    /// Point `index` of the saved record `id`.
    case record(id: UUID, index: Int)
}

/// One row of the measurement list.
struct MeasureToolRow: Identifiable, Equatable, Sendable {
    /// The record's id.
    var id: UUID
    /// The record's name, else the kind title numbered per kind in createdAt order ("Distance 2").
    var title: String
    /// `MeasureDisplay.valueText`.
    var valueText: String
    /// `MeasureDisplay.accuracyText` with the row's flag.
    var accuracyText: String?
    /// The record's low-confidence flag: the CR-2 rule for lengths and angles; areas take it from
    /// their sides (lead decision E3).
    var isLowConfidence: Bool
    /// `MeasureDisplay.accessibilityText(label: title, value:, kind:, prefs:)` with the row's flag.
    var accessibility: String
    /// True when the value was not measured directly (estimated or inferred provenance, for
    /// example a wall RoomPlan filled in); the list marks such rows with a dashed circle (E5).
    var isNotMeasured: Bool = false
}

/// Everything placing a point needs, built off main from the edited clean model and the quality
/// evidence of its rooms. Never mutated after it is built.
struct MeasureToolContext {
    /// The edited clean model (`CleanModelStore.loadEdited`).
    var model: CleanModel
    /// Snap candidates of every room and merged floor part (`MeasureToolSnaps.context`).
    var snaps: SnapSet
    /// `QualityEvaluation.evidence` per `RoomRecord.id` (`CleanRoom.recordID`).
    var roomEvidence: [UUID: RoomEvidence]
    /// Every room's `WallEvidence` by wall id, so walls keep their evidence after a merge (CR-1).
    var wallEvidence: [ElementID: WallEvidence]

    /// No model, no candidates, no evidence: points snap to the scan only.
    static let empty = MeasureToolContext(model: .empty, snaps: .empty, roomEvidence: [:], wallEvidence: [:])
}

/// SnapSet holds tuple arrays and has no Sendable conformance; the context is an immutable value.
extension MeasureToolContext: @unchecked Sendable {}
