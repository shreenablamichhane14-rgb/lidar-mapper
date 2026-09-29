import Foundation
import simd

// Shared walls and connecting doorways of a house clean model (docs/MODULES.md 3.30, RESEARCH
// 3.10 recommended 3): two faces of one wall from two rooms give a measured thickness, and a
// door seen from both rooms is drawn once. Everything is in the structure frame, plan meters
// (`PlanAxes`). Pure functions, nonisolated, deterministic, safe on any queue.

/// Two walls of different rooms that are the two faces of one wall.
struct SharedWallPair: Codable, Equatable, Sendable {
    /// `RoomRecord.id` of the room that comes first in `CleanModel.rooms`.
    var roomA: UUID
    /// The wall of `roomA`.
    var wallA: ElementID
    /// `RoomRecord.id` of the other room.
    var roomB: UUID
    /// The wall of `roomB`.
    var wallB: ElementID
    /// Distance between the two inner faces, meters: the measured wall thickness.
    var gap: Float
    /// Length along which the two faces overlap, meters.
    var overlap: Float
}

/// One doorway seen from both rooms; the kept opening stays a door, the other becomes a plain
/// opening so the plan and 3D Clean draw the door once (TEST_PLAN HOUSE-04).
struct DoorwayLink: Codable, Equatable, Sendable {
    /// Room of the opening that stays as it is.
    var keptRoom: UUID
    /// The opening that stays as it is.
    var kept: ElementID
    /// Room of the opening that becomes a plain opening.
    var mergedRoom: UUID
    /// The opening that becomes a plain opening.
    var merged: ElementID
    /// Distance between the two opening centers, plan meters.
    var distance: Float
}

/// Finds shared walls and doorways and applies thickness and doorway rules.
enum StructureWalls {
    /// Thinnest wall accepted as a pair, meters.
    static let minimumGap: Float = 0.05
    /// Thickest wall accepted as a pair, meters.
    static let maximumGap: Float = 0.5
    /// Largest angle between the two faces' normals and exact opposition, degrees.
    static let parallelToleranceDegrees: Float = 10
    /// Required face overlap: min(0.5 m, half the shorter wall).
    static let minimumOverlap: Float = 0.5
    /// Largest distance between the two centers of one doorway, plan meters.
    static let doorwayDistance: Float = 0.4
    /// Largest width difference between the two openings of one doorway, meters.
    static let doorwayWidthTolerance: Float = 0.25
    /// Probe distance behind a wall for the exterior test, meters.
    static let exteriorProbe: Float = 0.3

    /// A straight wall face in plan coordinates.
    struct Face: Equatable {
        /// Start, plan meters.
        var start: SIMD2<Float>
        /// End, plan meters.
        var end: SIMD2<Float>
        /// Unit plan normal pointing into the room.
        var inward: SIMD2<Float>
        /// Straight length, meters.
        var length: Float
        /// Midpoint, plan meters.
        var middle: SIMD2<Float> { (start + end) * 0.5 }
        /// Unit direction from start to end.
        var direction: SIMD2<Float> { length > 1e-6 ? (end - start) / length : .zero }
    }

    /// The plan face of a straight wall (arc nil) with a usable length and normal, else nil.
    static func face(_ wall: CleanWall) -> Face? {
        guard wall.arc == nil else { return nil }
        let a = PlanAxes.toPlan(wall.start.simd)
        let b = PlanAxes.toPlan(wall.end.simd)
        let length = simd_distance(a, b)
        let normal = PlanAxes.toPlan(wall.normal.simd)
        let normalLength = simd_length(normal)
        guard length > 1e-3, normalLength > 1e-3, length.isFinite, normalLength.isFinite else { return nil }
        return Face(start: a, end: b, inward: normal / normalLength, length: length)
    }

    /// Gap and overlap of two faces when `b` is a valid second face of `a`'s wall: normals
    /// antiparallel within `parallelToleranceDegrees`, each face behind the other (on the side
    /// opposite the other's normal), gap within `minimumGap...maximumGap` and overlap at least
    /// min(`minimumOverlap`, half the shorter wall). Nil otherwise.
    static func measure(_ a: Face, _ b: Face) -> (gap: Float, overlap: Float)? {
        let limit = cos(parallelToleranceDegrees * Float.pi / 180)
        guard simd_dot(a.inward, b.inward) <= -limit else { return nil }
        let behindA = -simd_dot(b.middle - a.start, a.inward)
        let behindB = -simd_dot(a.middle - b.start, b.inward)
        guard behindA > 0, behindB > 0 else { return nil }
        let gap = (behindA + behindB) * 0.5
        guard gap >= minimumGap, gap <= maximumGap else { return nil }
        let direction = a.direction
        let t0 = simd_dot(b.start - a.start, direction)
        let t1 = simd_dot(b.end - a.start, direction)
        let low = Swift.max(0, Swift.min(t0, t1))
        let high = Swift.min(a.length, Swift.max(t0, t1))
        let overlap = high - low
        let required = Swift.min(minimumOverlap, 0.5 * Swift.min(a.length, b.length))
        guard overlap > 0, overlap >= required else { return nil }
        return (gap: gap, overlap: overlap)
    }

    /// Mutual-best pairs of straight walls (arc nil) of different rooms on the same floor:
    /// antiparallel normals within 10 degrees, room B's wall behind room A's wall (on the side
    /// opposite A's normal), gap 0.05 to 0.5 m, overlap at least `minimumOverlap`. Each wall is
    /// in at most one pair; smaller gap, then larger overlap wins. Deterministic order.
    ///
    /// Room A is the room that comes first in `model.rooms`; pairs are returned in the order of
    /// room A, then of wall A.
    static func sharedWalls(in model: CleanModel) -> [SharedWallPair] {
        struct Candidate {
            var roomA: Int
            var wallA: Int
            var roomB: Int
            var wallB: Int
            var gap: Float
            var overlap: Float
        }
        let rooms = model.rooms
        let faces: [[Face?]] = rooms.map { room in room.walls.map { face($0) } }
        var candidates: [Candidate] = []
        for i in rooms.indices {
            for j in rooms.indices where j > i && rooms[j].floorIndex == rooms[i].floorIndex {
                for (wi, faceA) in faces[i].enumerated() {
                    guard let a = faceA else { continue }
                    for (wj, faceB) in faces[j].enumerated() {
                        guard let b = faceB, let found = measure(a, b) else { continue }
                        candidates.append(Candidate(roomA: i, wallA: wi, roomB: j, wallB: wj,
                                                    gap: found.gap, overlap: found.overlap))
                    }
                }
            }
        }
        candidates.sort { lhs, rhs in
            if lhs.gap != rhs.gap { return lhs.gap < rhs.gap }
            if lhs.overlap != rhs.overlap { return lhs.overlap > rhs.overlap }
            if lhs.roomA != rhs.roomA { return lhs.roomA < rhs.roomA }
            if lhs.wallA != rhs.wallA { return lhs.wallA < rhs.wallA }
            if lhs.roomB != rhs.roomB { return lhs.roomB < rhs.roomB }
            return lhs.wallB < rhs.wallB
        }
        var used = Set<Int>()
        var accepted: [Candidate] = []
        /// A unique key per (room, wall) position.
        func key(_ room: Int, _ wall: Int) -> Int { room * 1_000_000 + wall }
        for candidate in candidates {
            let first = key(candidate.roomA, candidate.wallA)
            let second = key(candidate.roomB, candidate.wallB)
            guard !used.contains(first), !used.contains(second) else { continue }
            used.insert(first)
            used.insert(second)
            accepted.append(candidate)
        }
        accepted.sort { lhs, rhs in lhs.roomA != rhs.roomA ? lhs.roomA < rhs.roomA : lhs.wallA < rhs.wallA }
        return accepted.map { c in
            SharedWallPair(roomA: rooms[c.roomA].recordID, wallA: rooms[c.roomA].walls[c.wallA].id,
                           roomB: rooms[c.roomB].recordID, wallB: rooms[c.roomB].walls[c.wallB].id,
                           gap: c.gap, overlap: c.overlap)
        }
    }

    /// Paired walls get `thickness = gap`, `thicknessSource = .measured`. An unpaired straight
    /// wall on a floor with at least 2 rooms whose probe point (midpoint moved `exteriorProbe`
    /// against its normal) lies inside no other room outline of that floor gets
    /// `exteriorThickness` with `.estimated`; every other wall keeps RoomModel's value.
    static func applyThickness(_ pairs: [SharedWallPair], exteriorThickness: Float, to model: inout CleanModel) {
        var measured: [String: Float] = [:]
        for pair in pairs {
            measured[wallKey(pair.roomA, pair.wallA)] = pair.gap
            measured[wallKey(pair.roomB, pair.wallB)] = pair.gap
        }
        var roomsPerFloor: [Int: Int] = [:]
        for room in model.rooms { roomsPerFloor[room.floorIndex, default: 0] += 1 }
        let snapshot = model.rooms
        for r in model.rooms.indices {
            let room = snapshot[r]
            for w in room.walls.indices {
                let wall = room.walls[w]
                if let gap = measured[wallKey(room.recordID, wall.id)] {
                    model.rooms[r].walls[w].thickness = gap
                    model.rooms[r].walls[w].thicknessSource = .measured
                    continue
                }
                guard (roomsPerFloor[room.floorIndex] ?? 0) >= 2, let plan = face(wall) else { continue }
                let probe = plan.middle - plan.inward * exteriorProbe
                var insideOther = false
                for (o, other) in snapshot.enumerated() where o != r && other.floorIndex == room.floorIndex {
                    if RoomMetricsCalculator.floorContains(other, point: probe) {
                        insideOther = true
                        break
                    }
                }
                if !insideOther {
                    model.rooms[r].walls[w].thickness = exteriorThickness
                    model.rooms[r].walls[w].thicknessSource = .estimated
                }
            }
        }
    }

    /// Openings of kind door, openDoor or opening on the two walls of a pair whose centers are
    /// within `doorwayDistance` and whose widths differ by at most `doorwayWidthTolerance`.
    /// Kept: the door when only one is a door, else the opening of the room that comes first
    /// in `model.rooms`.
    ///
    /// Each opening is in at most one link (nearest centers first); links are returned in pair
    /// order, then in the order of the first room's openings.
    static func doorwayLinks(in model: CleanModel, pairs: [SharedWallPair]) -> [DoorwayLink] {
        struct Candidate {
            var pair: Int
            var roomA: Int
            var openingA: Int
            var roomB: Int
            var openingB: Int
            var distance: Float
        }
        var roomIndex: [UUID: Int] = [:]
        for (i, room) in model.rooms.enumerated() where roomIndex[room.recordID] == nil { roomIndex[room.recordID] = i }
        var candidates: [Candidate] = []
        for (p, pair) in pairs.enumerated() {
            guard let ia = roomIndex[pair.roomA], let ib = roomIndex[pair.roomB] else { continue }
            let roomA = model.rooms[ia]
            let roomB = model.rooms[ib]
            guard let wallA = roomA.walls.first(where: { $0.id == pair.wallA }),
                  let wallB = roomB.walls.first(where: { $0.id == pair.wallB }) else { continue }
            for (oa, openingA) in roomA.openings.enumerated() where openingA.wallID == pair.wallA && isPassage(openingA.kind) {
                let centerA = openingCenter(openingA, on: wallA)
                for (ob, openingB) in roomB.openings.enumerated() where openingB.wallID == pair.wallB && isPassage(openingB.kind) {
                    let distance = simd_distance(centerA, openingCenter(openingB, on: wallB))
                    let widthDifference = abs(openingA.width - openingB.width)
                    guard distance <= doorwayDistance, widthDifference <= doorwayWidthTolerance else { continue }
                    candidates.append(Candidate(pair: p, roomA: ia, openingA: oa, roomB: ib, openingB: ob, distance: distance))
                }
            }
        }
        candidates.sort { lhs, rhs in
            if lhs.distance != rhs.distance { return lhs.distance < rhs.distance }
            if lhs.pair != rhs.pair { return lhs.pair < rhs.pair }
            if lhs.openingA != rhs.openingA { return lhs.openingA < rhs.openingA }
            return lhs.openingB < rhs.openingB
        }
        var usedOpenings = Set<String>()
        var accepted: [Candidate] = []
        for candidate in candidates {
            let first = "\(candidate.roomA)-\(candidate.openingA)"
            let second = "\(candidate.roomB)-\(candidate.openingB)"
            guard !usedOpenings.contains(first), !usedOpenings.contains(second) else { continue }
            usedOpenings.insert(first)
            usedOpenings.insert(second)
            accepted.append(candidate)
        }
        accepted.sort { lhs, rhs in lhs.pair != rhs.pair ? lhs.pair < rhs.pair : lhs.openingA < rhs.openingA }
        return accepted.map { c -> DoorwayLink in
            let a = model.rooms[c.roomA]
            let b = model.rooms[c.roomB]
            let openingA = a.openings[c.openingA]
            let openingB = b.openings[c.openingB]
            let doorA = isDoor(openingA.kind)
            let doorB = isDoor(openingB.kind)
            let keepA = doorA != doorB ? doorA : c.roomA <= c.roomB
            if keepA {
                return DoorwayLink(keptRoom: a.recordID, kept: openingA.id, mergedRoom: b.recordID, merged: openingB.id,
                                   distance: c.distance)
            }
            return DoorwayLink(keptRoom: b.recordID, kept: openingB.id, mergedRoom: a.recordID, merged: openingA.id,
                               distance: c.distance)
        }
    }

    /// The merged opening of each link becomes kind `.opening` with `swing = nil`; ids,
    /// offsets and sizes are kept, so its wall still has the gap.
    static func applyDoorways(_ links: [DoorwayLink], to model: inout CleanModel) {
        for link in links {
            guard let r = model.rooms.firstIndex(where: { $0.recordID == link.mergedRoom }),
                  let o = model.rooms[r].openings.firstIndex(where: { $0.id == link.merged }) else { continue }
            model.rooms[r].openings[o].kind = .opening
            model.rooms[r].openings[o].swing = nil
        }
    }

    // MARK: Helpers

    /// True for doors (closed or open during the scan).
    static func isDoor(_ kind: OpeningKind) -> Bool {
        kind == .door || kind == .openDoor
    }

    /// True for openings a person walks through: doors and plain openings.
    static func isPassage(_ kind: OpeningKind) -> Bool {
        kind != .window
    }

    /// Plan center of an opening on its wall: wall start plus the direction times
    /// (offset + width / 2).
    static func openingCenter(_ opening: CleanOpening, on wall: CleanWall) -> SIMD2<Float> {
        let a = PlanAxes.toPlan(wall.start.simd)
        let b = PlanAxes.toPlan(wall.end.simd)
        let direction = Segment2D(a: a, b: b).direction
        return a + direction * (opening.offsetAlongWall + opening.width * 0.5)
    }

    /// Dictionary key of a wall of a room.
    static func wallKey(_ room: UUID, _ wall: ElementID) -> String {
        room.uuidString + "/" + wall.uuid.uuidString
    }
}
