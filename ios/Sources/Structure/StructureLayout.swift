import Foundation
import simd

// The placement plan of a house (D9, docs/MODULES.md 3.30): every active room of the anchor
// frame group gets a placement in the structure frame (solved, group median or identity), rooms
// of other frames are parked beside the building until the user lines them up, and rooms that
// land on top of each other are flagged. Pure functions, nonisolated, deterministic.

/// A room's outline in its own capture frame, from RoomModel `RoomOutline.build(_:).polygon`,
/// and its floor height (the lowest `WallSegment.baseY`).
struct RoomFootprint: Equatable, Sendable {
    /// Our `RoomRecord.id`.
    var roomID: UUID
    /// Outline, plan meters, counter-clockwise, capture frame.
    var outline: [SIMD2<Float>]
    /// Floor height, world y meters, capture frame.
    var floorElevation: Float

    /// Nil when the loop has fewer than 3 points. Without walls the floor height is the first
    /// RoomPlan floor's y, else 0.
    static func from(_ input: RoomInput, roomID: UUID) -> RoomFootprint? {
        let outline = RoomOutline.build(input)
        guard outline.polygon.count >= 3 else { return nil }
        let bases = (outline.walls + outline.strayWalls).map { $0.baseY }.filter { $0.isFinite }
        let floorY = input.floors.first?.transform.translation.y
        let elevation = bases.min() ?? ((floorY?.isFinite ?? false) ? (floorY ?? 0) : 0)
        return RoomFootprint(roomID: roomID, outline: outline.polygon, floorElevation: elevation)
    }

    /// The footprint moved into the structure frame by `record` (outline by
    /// `StructureAlignment.planTransform`, elevation plus translation.y).
    func placed(by record: RoomAlignmentRecord) -> RoomFootprint {
        RoomFootprint(roomID: roomID, outline: outline.map { StructureAlignment.planTransform($0, by: record) },
                      floorElevation: floorElevation + record.translation.y)
    }
}

/// How a room got its placement. Raw values are persisted in placements.json.
enum AlignmentMethod: String, Codable, CaseIterable, Sendable {
    /// Same ARKit frame as the structure, no trusted merge solve: identity.
    case sharedFrame
    /// Solved from the StructureBuilder merge (trusted).
    case structureMerge
    /// Anchor-group room without a trusted solve while others have one: their median.
    case groupMedian
    /// Room from another frame: laid out beside the building until the user lines it up.
    case parked
    /// A `setRoomAlignment` edit (source `.user`) overrides the derived placement.
    case user
}

/// What AlignRoomsStep decided for one room (placements.json).
struct RoomPlacementReport: Codable, Equatable, Sendable {
    /// Our `RoomRecord.id`.
    var roomID: UUID
    /// How the placement was found.
    var method: AlignmentMethod
    /// Segment pairs of the room's own solve (0 without one).
    var matches: Int
    /// Rms of the room's own solve, meters, trusted or not (nil without one).
    var rms: Float?
    /// The earlier room this one overlaps by more than 30 percent on the same floor.
    var stackedWith: UUID?
    /// True for parked and stacked rooms (HouseUI shows "needs lining up" until a user edit).
    var needsManualAlignment: Bool
}

/// Records and reports for every active room.
struct StructurePlacementPlan: Equatable, Sendable {
    /// One record per placed or parked room (source `.measured` for sharedFrame,
    /// structureMerge and groupMedian, `.estimated` for parked).
    var records: [RoomAlignmentRecord]
    /// One report per record, same order (manifest order).
    var reports: [RoomPlacementReport]
    /// Active rooms that got no record (another frame and no loadable outline).
    var unplaced: [UUID]
}

/// Builds the placement plan, parking layout and stacked flags.
enum StructureLayout {
    /// Space between the building and a parked group, and between parked groups, meters.
    static let parkingGap: Float = 1.0
    /// Overlap ratio above which a room counts as stacked on an earlier one.
    static let stackedOverlap: Float = 0.3
    /// Rooms whose floors are closer than this in height are on the same floor for the
    /// stacked check, meters.
    static let sameFloorHeight: Float = 1.2

    /// The whole placement plan (used by AlignRoomsStep, and by HouseCleanModelStep when
    /// alignment.json is missing): anchor-group rooms take their trusted solve
    /// (structureMerge), else the median of the trusted solves (groupMedian), else identity
    /// (sharedFrame); rooms of other groups are parked with `parking`; then `stacked` flags.
    ///
    /// Only active rooms of `rooms` are placed; untrusted solutions are ignored for placement
    /// but their matches and rms are reported. Anchor-group rooms always get a record, with or
    /// without a footprint.
    static func plan(rooms: [RoomRecord], sessions: [CaptureSessionRef], footprints: [UUID: RoomFootprint],
                     solutions: [UUID: AlignmentSolution]) -> StructurePlacementPlan {
        let active = rooms.filter(StructureEligibility.isActive)
        let groups = StructureEligibility.frameGroups(rooms: active, sessions: sessions)
        let anchor = StructureEligibility.anchorGroup(groups, sessions: sessions)
        let anchorIDs = Set(anchor?.rooms ?? [])
        let trusted = active.filter { anchorIDs.contains($0.id) }.compactMap { room -> AlignmentSolution? in
            guard let solution = solutions[room.id], solution.isTrusted else { return nil }
            return solution
        }
        let median = StructureAlignment.median(trusted)

        var records: [UUID: RoomAlignmentRecord] = [:]
        var methods: [UUID: AlignmentMethod] = [:]
        var placed: [RoomFootprint] = []
        for room in active where anchorIDs.contains(room.id) {
            let record: RoomAlignmentRecord
            if let solution = solutions[room.id], solution.isTrusted {
                record = solution.record(roomID: room.id, source: .measured)
                methods[room.id] = .structureMerge
            } else if let median {
                record = median.record(roomID: room.id, source: .measured)
                methods[room.id] = .groupMedian
            } else {
                record = StructureAlignment.identity(roomID: room.id, source: .measured)
                methods[room.id] = .sharedFrame
            }
            records[room.id] = record
            if let footprint = footprints[room.id] { placed.append(footprint.placed(by: record)) }
        }

        var parkedGroups: [[RoomFootprint]] = []
        for group in groups where group != anchor {
            let members = group.rooms.compactMap { footprints[$0] }
            if !members.isEmpty { parkedGroups.append(members) }
        }
        for (id, record) in parking(parkedGroups, placed: placed) {
            records[id] = record
            methods[id] = .parked
        }

        let order = active.map { $0.id }
        let stackedWith = stacked(Array(footprints.values), records: records, order: order)
        var planRecords: [RoomAlignmentRecord] = []
        var reports: [RoomPlacementReport] = []
        var unplaced: [UUID] = []
        for room in active {
            guard let record = records[room.id], let method = methods[room.id] else {
                unplaced.append(room.id)
                continue
            }
            let own = solutions[room.id]
            let stack = stackedWith[room.id]
            let manual = method == .parked || stack != nil
            planRecords.append(record)
            reports.append(RoomPlacementReport(roomID: room.id, method: method, matches: own?.matches ?? 0, rms: own?.rms,
                                               stackedWith: stack, needsManualAlignment: manual))
        }
        return StructurePlacementPlan(records: planRecords, reports: reports, unplaced: unplaced)
    }

    /// Parked placements, one translation per frame group so the rooms of a group keep their
    /// relative layout (they share an ARKit frame): each group's union bounds in a row to the +x
    /// side of the placed footprints' plan bounds, 1 m apart, bottom edges aligned, never
    /// overlapping, in `groups` order. Without placed footprints the first group stays where it
    /// is and the rest follow to its right.
    ///
    /// Records have yaw 0, world y translation 0 and source `.estimated`. Footprints must be in
    /// their capture frames; `placed` must already be in the structure frame.
    static func parking(_ groups: [[RoomFootprint]], placed: [RoomFootprint]) -> [UUID: RoomAlignmentRecord] {
        var result: [UUID: RoomAlignmentRecord] = [:]
        var cursorX: Float = 0
        var bottom: Float = 0
        var remaining = groups
        if let building = bounds(placed) {
            cursorX = building.max.x + parkingGap
            bottom = building.min.y
        } else {
            while let first = remaining.first {
                remaining.removeFirst()
                guard let box = bounds(first) else { continue }
                for footprint in first {
                    result[footprint.roomID] = StructureAlignment.identity(roomID: footprint.roomID, source: .estimated)
                }
                cursorX = box.max.x + parkingGap
                bottom = box.min.y
                break
            }
        }
        for group in remaining {
            guard let box = bounds(group) else { continue }
            let dx = cursorX - box.min.x
            let dy = bottom - box.min.y
            for footprint in group {
                result[footprint.roomID] = RoomAlignmentRecord(roomID: footprint.roomID, yaw: 0,
                                                               translation: Vec3(x: dx, y: 0, z: -dy), source: .estimated)
            }
            cursorX += (box.max.x - box.min.x) + parkingGap
        }
        return result
    }

    /// Later room to earlier room for placed pairs on the same floor whose placed outlines
    /// overlap by more than `stackedOverlap` (`StructureAlignment.overlapRatio`).
    ///
    /// "Earlier" follows `order` (manifest order); each later room points at the first earlier
    /// room it overlaps. Rooms without a footprint or a record are skipped. Same floor: placed
    /// floor elevations closer than `sameFloorHeight`.
    static func stacked(_ footprints: [RoomFootprint], records: [UUID: RoomAlignmentRecord], order: [UUID]) -> [UUID: UUID] {
        var byID: [UUID: RoomFootprint] = [:]
        for footprint in footprints where byID[footprint.roomID] == nil { byID[footprint.roomID] = footprint }
        var placed: [RoomFootprint] = []
        for id in order {
            guard let footprint = byID[id], let record = records[id] else { continue }
            placed.append(footprint.placed(by: record))
        }
        var result: [UUID: UUID] = [:]
        for j in placed.indices {
            for i in 0..<j {
                let heightDifference = abs(placed[i].floorElevation - placed[j].floorElevation)
                guard heightDifference < sameFloorHeight else { continue }
                let ratio = StructureAlignment.overlapRatio(placed[i].outline, placed[j].outline)
                if ratio > stackedOverlap {
                    result[placed[j].roomID] = placed[i].roomID
                    break
                }
            }
        }
        return result
    }

    /// Union plan bounds of the footprints' outlines; nil when there is no point.
    static func bounds(_ footprints: [RoomFootprint]) -> (min: SIMD2<Float>, max: SIMD2<Float>)? {
        Polygon2D(points: footprints.flatMap { $0.outline }).boundingBox
    }
}
