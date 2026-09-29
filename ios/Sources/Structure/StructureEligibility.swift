import Foundation

// House frames (D9, docs/MODULES.md 3.30): which rooms share one ARKit world frame, which of
// them form the structure frame, and which may be handed to RoomPlan's StructureBuilder. Pure
// functions, nonisolated, deterministic, safe on any queue.

/// Rooms captured in one ARKit world frame (D9): sessions joined by
/// `.relocalized(sessionID:from:)` links, plus the active rooms captured in them.
struct StructureFrameGroup: Equatable, Sendable {
    /// Session identifiers, in `ProjectManifest.sessions` order. Empty for the one-room group of
    /// a room whose own `frameLink` is `.manual` (it does not share its session's frame), and for
    /// rooms whose session is missing from the manifest.
    var sessions: [UUID]
    /// Active room identifiers, in `ProjectManifest.rooms` order.
    var rooms: [UUID]
}

/// Frame groups, the anchor (structure) frame and the StructureBuilder input rules (D9).
enum StructureEligibility {
    /// Rooms that belong in house models: `supersededBy == nil` (CR-7) and status `.captured`,
    /// `.processed` or `.needsRescan` (a poor room is still real data). Manifest order.
    static func activeRooms(_ manifest: ProjectManifest) -> [RoomRecord] {
        manifest.rooms.filter(isActive)
    }

    /// The `activeRooms` rule for one room.
    static func isActive(_ room: RoomRecord) -> Bool {
        guard room.supersededBy == nil else { return false }
        switch room.status {
        case .captured, .processed, .needsRescan: return true
        case .capturing, .failed: return false
        }
    }

    /// Groups sessions by relocalization links (undirected, transitive), each group with the
    /// active rooms of its sessions. A session whose `CaptureSessionRef.frameLink` is `.unaligned`
    /// or `.manual` never joins another session but keeps all its rooms in one group: Start Fresh
    /// Here continues one ARKit session with `startNextRoom`, so those rooms share a frame with
    /// each other (their own `frameLink` is `.unaligned` too, which must not split them). Only a
    /// room whose own `frameLink` is `.manual` is a group of its own (one room).
    ///
    /// Links are read from the session records and from the rooms' own `.relocalized` links; a
    /// link to a session missing from `sessions` joins nothing. Inactive rooms in `rooms` are
    /// ignored and groups without rooms are dropped. Groups are ordered by their earliest session
    /// (in `sessions` order), then by their first room (manifest order).
    static func frameGroups(rooms: [RoomRecord], sessions: [CaptureSessionRef]) -> [StructureFrameGroup] {
        let active = rooms.filter(isActive)
        var nodeOf: [UUID: Int] = [:]
        var parent: [Int] = []
        var sessionLink: [UUID: FrameLink] = [:]
        /// Node index of a session id, created on first use.
        func node(_ id: UUID) -> Int {
            if let existing = nodeOf[id] { return existing }
            let index = parent.count
            nodeOf[id] = index
            parent.append(index)
            return index
        }
        /// Root of a node with path halving.
        func find(_ start: Int) -> Int {
            var x = start
            while parent[x] != x {
                parent[x] = parent[parent[x]]
                x = parent[x]
            }
            return x
        }
        /// True when a session may be joined to another one: known and not unaligned or manual.
        func joinable(_ id: UUID) -> Bool {
            sessionLink[id]?.mayShareFrame ?? false
        }
        /// Joins two sessions when both may share a frame.
        func link(_ a: UUID, _ b: UUID) {
            guard a != b, joinable(a), joinable(b) else { return }
            let ra = find(node(a))
            let rb = find(node(b))
            if ra != rb { parent[Swift.max(ra, rb)] = Swift.min(ra, rb) }
        }
        for session in sessions {
            _ = node(session.id)
            if sessionLink[session.id] == nil { sessionLink[session.id] = session.frameLink }
        }
        for room in active where room.frameLink != .manual { _ = node(room.sessionID) }
        for session in sessions {
            if case .relocalized(_, let from) = session.frameLink { link(session.id, from) }
        }
        for room in active {
            if case .relocalized(_, let from) = room.frameLink { link(room.sessionID, from) }
        }

        var groups: [Int: GroupAccumulator] = [:]
        var finished: [GroupAccumulator] = []
        for (position, session) in sessions.enumerated() {
            let root = find(node(session.id))
            var entry = groups[root] ?? GroupAccumulator()
            if !entry.sessions.contains(session.id) { entry.sessions.append(session.id) }
            entry.firstSession = Swift.min(entry.firstSession, position)
            groups[root] = entry
        }
        for (position, room) in active.enumerated() {
            if room.frameLink == .manual {
                var single = GroupAccumulator()
                single.rooms = [room.id]
                single.firstRoom = position
                finished.append(single)
                continue
            }
            let root = find(node(room.sessionID))
            var entry = groups[root] ?? GroupAccumulator()
            entry.rooms.append(room.id)
            entry.firstRoom = Swift.min(entry.firstRoom, position)
            groups[root] = entry
        }
        for entry in groups.values where !entry.rooms.isEmpty {
            finished.append(entry)
        }
        finished.sort { lhs, rhs in
            lhs.firstSession != rhs.firstSession ? lhs.firstSession < rhs.firstSession : lhs.firstRoom < rhs.firstRoom
        }
        return finished.map { StructureFrameGroup(sessions: $0.sessions, rooms: $0.rooms) }
    }

    /// A group being collected by `frameGroups`, with its sort keys.
    private struct GroupAccumulator {
        /// Sessions of the group, manifest order.
        var sessions: [UUID] = []
        /// Active rooms of the group, manifest order.
        var rooms: [UUID] = []
        /// Position of the earliest session in `sessions` order, `Int.max` when none.
        var firstSession = Int.max
        /// Position of the first room in manifest order, `Int.max` when none.
        var firstRoom = Int.max
    }

    /// The structure frame: the group with the most rooms; ties go to the group that holds the
    /// earliest session in `sessions` order (a group without a known session loses a tie; after
    /// that the earlier group in `groups` wins). Nil when there are no rooms.
    static func anchorGroup(_ groups: [StructureFrameGroup], sessions: [CaptureSessionRef]) -> StructureFrameGroup? {
        var position: [UUID: Int] = [:]
        for (index, session) in sessions.enumerated() where position[session.id] == nil {
            position[session.id] = index
        }
        var best: StructureFrameGroup?
        var bestCount = 0
        var bestEarliest = Int.max
        for group in groups where !group.rooms.isEmpty {
            let earliest = group.sessions.compactMap { position[$0] }.min() ?? Int.max
            let larger = group.rooms.count > bestCount
            let tieWon = group.rooms.count == bestCount && earliest < bestEarliest
            if best == nil || larger || tieWon {
                best = group
                bestCount = group.rooms.count
                bestEarliest = earliest
            }
        }
        return best
    }

    /// Identifiers of the active rooms of the anchor group (empty when there is none).
    static func anchorRoomIDs(rooms: [RoomRecord], sessions: [CaptureSessionRef]) -> Set<UUID> {
        let groups = frameGroups(rooms: rooms, sessions: sessions)
        return Set(anchorGroup(groups, sessions: sessions)?.rooms ?? [])
    }

    /// The group that holds `roomID`, if any (HouseUI writes a user alignment for every room of
    /// that group).
    static func group(of roomID: UUID, in groups: [StructureFrameGroup]) -> StructureFrameGroup? {
        groups.first { $0.rooms.contains(roomID) }
    }

    /// Rooms passed to StructureBuilder: active rooms of the anchor group for which `isFinal` is
    /// true (a raw or rebuilt capturedroom.json, never the provisional live file). Everything
    /// else is `separate`. Both keep the order of `rooms`.
    ///
    /// A room is also kept out when its own `frameLink` or its session's link is `.manual` or
    /// `.unaligned` (never passed to the builder, D9), even when its unaligned session is the
    /// anchor group. `isFinal` is called only for the remaining candidates.
    static func mergeable(_ rooms: [RoomRecord], sessions: [CaptureSessionRef],
                          isFinal: (RoomRecord) -> Bool) -> (merge: [RoomRecord], separate: [RoomRecord]) {
        let anchor = anchorRoomIDs(rooms: rooms, sessions: sessions)
        var sessionLink: [UUID: FrameLink] = [:]
        for session in sessions where sessionLink[session.id] == nil {
            sessionLink[session.id] = session.frameLink
        }
        var merge: [RoomRecord] = []
        var separate: [RoomRecord] = []
        for room in rooms {
            let confirmed = isActive(room) && anchor.contains(room.id) && room.frameLink.mayShareFrame
                && (sessionLink[room.sessionID]?.mayShareFrame ?? false)
            if confirmed && isFinal(room) {
                merge.append(room)
            } else {
                separate.append(room)
            }
        }
        return (merge, separate)
    }

    /// Stable text of a frame link for input hashes ("project:<id>", "reloc:<id>:<from>",
    /// "manual", "unaligned").
    static func linkKey(_ link: FrameLink) -> String {
        switch link {
        case .projectFrame(let id): return "project:" + id.uuidString
        case .relocalized(let id, let from): return "reloc:" + id.uuidString + ":" + from.uuidString
        case .manual: return "manual"
        case .unaligned: return "unaligned"
        }
    }
}
