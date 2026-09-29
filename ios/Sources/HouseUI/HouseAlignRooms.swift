import Foundation
import Combine
import simd

// Manual alignment of a House room (docs/MODULES.md 3.41, D9, RESEARCH 3.10 recommended 13):
// the room's outline, walls and doors are dragged and turned over the other rooms of its floor in
// the structure frame; Structure's `StructureSnapping.snap` turns the raw gesture into the placement
// shown (parallel walls, wall gap, doorway); Save writes ONE edit log entry holding a
// `setRoomAlignment` edit for every room of the moved room's frame group (a `.batch` when there is
// more than one), so one Undo reverts the whole move. Raw data never moves. The screen is in
// HouseAlignRoomsScreen.swift.

/// What the alignment screen needs, read off the main thread.
struct AlignRoomsInputs: Equatable, Sendable {
    /// The project's package.
    var package: ProjectPackage
    /// The room being moved, as clean.json places it now.
    var moving: AlignShape
    /// Rooms of the same floor outside the moving room's frame group (snap targets).
    var others: [AlignShape]
    /// Other rooms of the moving room's frame group on its floor (they move along).
    var companions: [AlignShape]
    /// Every room of the moving room's frame group (`StructureEligibility.frameGroups`).
    var group: [UUID]
    /// The placement clean.json was built with for each group room (the base each edit composes on).
    var base: [UUID: RoomAlignmentRecord]
}

/// Main actor. Works in the structure frame on the edited clean model.
@MainActor final class AlignRoomsModel: ObservableObject {
    /// Snap targets: the other rooms of the floor.
    @Published private(set) var others: [AlignShape] = []
    /// The room being moved, where clean.json has it (before the gesture).
    @Published private(set) var moving: AlignShape?
    /// The snapped placement of the current gesture (nil before the first gesture).
    @Published private(set) var placement: AlignPlacement?
    /// `Copy.HouseUI.snappedDoorway` / `snappedWall` while a snap holds.
    @Published private(set) var snapText: String?
    /// False until clean.json holds the room.
    @Published private(set) var isReady = false
    /// True once `load()` finished (ready or not).
    @Published private(set) var hasLoaded = false
    /// Rooms of the moving room's frame group on its floor, drawn moving along.
    @Published private(set) var companions: [AlignShape] = []

    /// The project.
    let projectID: UUID
    /// The room being lined up.
    let roomID: UUID
    /// The loaded inputs.
    private var inputs: AlignRoomsInputs?
    /// Accumulated raw rotation (radians, counter-clockwise in plan) and translation (plan meters).
    private var rawRotation: Float = 0, rawTranslation = SIMD2<Float>(0, 0)

    /// Creates the model; nothing is read until `load()`.
    init(projectID: UUID, roomID: UUID) {
        self.projectID = projectID
        self.roomID = roomID
    }

    /// `CleanModelStore.loadEdited` (off main): shapes of the moving room's floor, its frame group
    /// and the base placements.
    func load() async {
        let project = projectID
        let room = roomID
        let loaded = await Task.detached(priority: .userInitiated) { () -> AlignRoomsInputs? in
            AlignRoomsModel.loadInputs(projectID: project, roomID: room)
        }.value
        inputs = loaded
        moving = loaded?.moving
        others = loaded?.others ?? []
        companions = loaded?.companions ?? []
        isReady = loaded != nil
        hasLoaded = true
        rawRotation = 0
        rawTranslation = SIMD2<Float>(0, 0)
        placement = nil
        snapText = nil
        let count = loaded?.group.count ?? 0
        LogStore.shared.write("line up room \(room): ready \(loaded != nil), \(others.count) other rooms, group of \(count)",
                              category: HouseRelocalization.logCategory)
    }

    /// Accumulates a plan move and re-snaps with `StructureSnapping.snap`.
    func drag(by planDelta: SIMD2<Float>) {
        guard planDelta.x.isFinite, planDelta.y.isFinite else { return }
        rawTranslation += planDelta
        resnap()
    }

    /// Accumulates a turn (radians, counter-clockwise in plan) and re-snaps.
    func rotate(by radians: Float) {
        guard radians.isFinite else { return }
        rawRotation += radians
        resnap()
    }

    /// 90 degree steps (VoiceOver and buttons).
    func turn(clockwise: Bool) {
        rotate(by: clockwise ? -Float.pi / 2 : Float.pi / 2)
    }

    /// Back to where clean.json has the room.
    func reset() {
        rawRotation = 0
        rawTranslation = SIMD2<Float>(0, 0)
        placement = nil
        snapText = nil
    }

    /// Appends one log entry: the `setRoomAlignment` edit (source `.user`,
    /// `StructureAlignment.compose(delta, after: effective record)`) of every room of the moved
    /// room's frame group, as one `.batch(operations:)` when the group has more than one room
    /// (CR-1: one Undo reverts the whole move). Without a gesture the delta is the identity, which
    /// confirms the current placement as the user's. The effective record is the placement the
    /// shapes were drawn with (clean.json's), so what is saved is what the screen shows.
    func save() throws {
        guard let inputs else { throw MapperError.ioFailed("line up: nothing loaded") }
        let delta = placement?.delta ?? StructureAlignment.identity(roomID: roomID, source: .user)
        guard let operation = AlignRoomsModel.alignmentOperation(delta: delta, group: inputs.group, base: inputs.base) else {
            throw MapperError.ioFailed("line up: empty group")
        }
        try EditStore.append(operation, to: inputs.package)
        Haptics.success()
        let degrees = Int((delta.yaw * 180 / Float.pi).rounded())
        LogStore.shared.write("manual alignment of room \(roomID) saved: yaw \(degrees) degrees, translation "
                              + "\(delta.translation.simd), \(inputs.group.count) rooms moved together",
                              category: HouseRelocalization.logCategory)
    }

    /// The moving room where the current placement puts it.
    var movedShape: AlignShape? {
        guard let moving else { return nil }
        guard let delta = placement?.delta else { return moving }
        return moving.moved(by: delta)
    }

    /// The companions where the current placement puts them.
    var movedCompanions: [AlignShape] {
        guard let delta = placement?.delta else { return companions }
        return companions.map { $0.moved(by: delta) }
    }

    /// Re-snaps the accumulated gesture; a new snap fires `Haptics.selection()` once.
    private func resnap() {
        guard let moving else { return }
        let next = StructureSnapping.snap(moving, rotation: rawRotation, translation: rawTranslation, others: others)
        let previous = placement?.snap ?? AlignSnapKind.none
        placement = next
        snapText = AlignRoomsModel.snapText(for: next.snap)
        if next.snap != previous && next.snap != .none { Haptics.selection() }
    }

    // MARK: - Pure helpers (self-tested)

    /// The snap note of a snap kind (nil without a snap).
    nonisolated static func snapText(for kind: AlignSnapKind) -> String? {
        switch kind {
        case .none: return nil
        case .doorway: return Copy.HouseUI.snappedDoorway
        case .parallel, .wallGap: return Copy.HouseUI.snappedWall
        }
    }

    /// The one edit of a move: `.setRoomAlignment(compose(delta, after: base))` for each group room
    /// (identity base when a room has none), a `.batch` for more than one. Nil for an empty group.
    nonisolated static func alignmentOperation(delta: RoomAlignmentRecord, group: [UUID],
                                               base: [UUID: RoomAlignmentRecord]) -> EditOperation? {
        var operations: [EditOperation] = []
        for id in group {
            let inner = base[id] ?? StructureAlignment.identity(roomID: id, source: .measured)
            operations.append(.setRoomAlignment(StructureAlignment.compose(delta, after: inner, source: .user)))
        }
        guard let first = operations.first else { return nil }
        return operations.count == 1 ? first : .batch(operations: operations)
    }

    /// Reads the edited clean model and the placements of a project. Nil when the project or
    /// clean.json cannot be read or clean.json does not hold the room yet.
    nonisolated static func loadInputs(projectID: UUID, roomID: UUID) -> AlignRoomsInputs? {
        guard let package = try? ProjectStore.package(for: projectID),
              let manifest = try? ProjectStore.readManifest(package),
              let edited = try? CleanModelStore.loadEdited(package).model,
              let target = edited.rooms.first(where: { $0.recordID == roomID }) else { return nil }
        let groups = StructureEligibility.frameGroups(rooms: manifest.rooms, sessions: manifest.sessions)
        var group = StructureEligibility.group(of: roomID, in: groups)?.rooms ?? []
        if !group.contains(roomID) { group.append(roomID) }
        let members = Set(group)
        let floorRooms = edited.rooms.filter { $0.floorIndex == target.floorIndex && $0.recordID != roomID }
        let others = floorRooms.filter { !members.contains($0.recordID) }.map { AlignShape.from($0) }
        let companions = floorRooms.filter { members.contains($0.recordID) }.map { AlignShape.from($0) }
        return AlignRoomsInputs(package: package, moving: AlignShape.from(target), others: others, companions: companions,
                                group: group, base: baseRecords(package: package, rooms: group))
    }

    /// The placement each room's clean room was built with: HouseCleanModelStep's
    /// `appliedAlignments` (connections.json), else `StructureStore.effectiveAlignments`, else
    /// identity.
    nonisolated static func baseRecords(package: ProjectPackage, rooms: [UUID]) -> [UUID: RoomAlignmentRecord] {
        var applied: [UUID: RoomAlignmentRecord] = [:]
        for record in StructureStore.loadConnections(package)?.appliedAlignments ?? [] { applied[record.roomID] = record }
        let effective = StructureStore.effectiveAlignments(package)
        var result: [UUID: RoomAlignmentRecord] = [:]
        for id in rooms {
            result[id] = applied[id] ?? effective[id] ?? StructureAlignment.identity(roomID: id, source: .measured)
        }
        return result
    }
}
