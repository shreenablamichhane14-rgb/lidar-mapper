import Foundation

/// Stable identifier of a model element (wall, opening, object, room, plan item).
///
/// Edits reference elements only through `ElementID`, never through raw RoomPlan
/// identifiers (D3). When an element comes from RoomPlan, `roomPlanID` keeps that
/// identifier as provenance so re-derivation can find the same element again.
/// Equality and hashing use `uuid` only.
struct ElementID: Codable, Hashable, Sendable {
    /// Our identifier.
    var uuid: UUID
    /// The RoomPlan `identifier` the element was derived from, when there is one.
    var roomPlanID: UUID?

    /// Creates an identifier; a fresh UUID by default.
    init(uuid: UUID = UUID(), roomPlanID: UUID? = nil) {
        self.uuid = uuid
        self.roomPlanID = roomPlanID
    }

    /// Deterministic identifier for an element derived from a RoomPlan identifier: the same
    /// RoomPlan identifier always gives the same `uuid`, which still differs from the RoomPlan
    /// identifier itself (its bytes are mixed with a fixed mask).
    static func derived(fromRoomPlan id: UUID) -> ElementID {
        let mask: [UInt8] = [0x4D, 0x41, 0x50, 0x50, 0x45, 0x52, 0x2D, 0x45,
                             0x4C, 0x45, 0x4D, 0x45, 0x4E, 0x54, 0x49, 0x44]
        let bytes = UUIDBytes.bytes(of: id)
        var mixed = [UInt8](repeating: 0, count: 16)
        for i in 0..<16 { mixed[i] = bytes[i] ^ mask[i] }
        return ElementID(uuid: UUIDBytes.uuid(from: mixed) ?? id, roomPlanID: id)
    }

    /// Equal when the `uuid` values are equal (provenance is ignored).
    static func == (lhs: ElementID, rhs: ElementID) -> Bool {
        lhs.uuid == rhs.uuid
    }

    /// Hashes `uuid` only, consistent with `==`.
    func hash(into hasher: inout Hasher) {
        hasher.combine(uuid)
    }
}

/// Conversions between `UUID` and its 16 raw bytes (binary file headers).
enum UUIDBytes {
    /// The 16 bytes of `id` in RFC 4122 order.
    static func bytes(of id: UUID) -> [UInt8] {
        withUnsafeBytes(of: id.uuid) { Array($0) }
    }

    /// A UUID from exactly 16 bytes, or nil for any other count.
    static func uuid(from b: [UInt8]) -> UUID? {
        guard b.count == 16 else { return nil }
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}

/// Which coordinate frame a scan was captured in (D9). Rooms are merged or stacked only
/// when their frames are known to be shared.
enum FrameLink: Codable, Equatable, Hashable, Sendable {
    /// Captured in the project's shared frame of ARKit session `sessionID`.
    case projectFrame(sessionID: UUID)
    /// Captured in session `sessionID` after relocalizing against the world map of
    /// session `from`.
    case relocalized(sessionID: UUID, from: UUID)
    /// Placed by the user (alignment stored as an edit).
    case manual
    /// No known relation to the other scans; never stacked silently.
    case unaligned

    /// The ARKit session the scan belongs to, when known.
    var sessionID: UUID? {
        switch self {
        case .projectFrame(let id): return id
        case .relocalized(let id, _): return id
        case .manual, .unaligned: return nil
        }
    }

    /// True when the frame may be shared with other scans (same session, or relocalized).
    /// For `.relocalized`, callers must also check that tracking returned to normal (D9).
    var mayShareFrame: Bool {
        switch self {
        case .projectFrame, .relocalized: return true
        case .manual, .unaligned: return false
        }
    }
}
