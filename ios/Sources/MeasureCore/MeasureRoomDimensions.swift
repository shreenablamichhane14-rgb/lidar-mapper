import Foundation
import simd

/// Groups of the dimension list, in display order.
enum DimensionGroup: String, CaseIterable, Sendable {
    case room, walls, doors, windows, objects

    /// Heading of the group (Copy.MeasureCore).
    var title: String {
        switch self {
        case .room: return Copy.MeasureCore.roomGroup
        case .walls: return Copy.MeasureCore.wallsGroup
        case .doors: return Copy.MeasureCore.doorsGroup
        case .windows: return Copy.MeasureCore.windowsGroup
        case .objects: return Copy.MeasureCore.objectsGroup
        }
    }

    /// Note shown with the group: the Walls group says openings are not counted in wall area.
    var note: String? {
        self == .walls ? Copy.MeasureCore.wallAreaNote : nil
    }
}

/// One line of the dimension list.
///
/// `title` names the measurement ("Wall length", "Door width", "Width" for objects); `label`
/// names the element it belongs to ("Wall 3", "Door 1", "Room", the object's label). Rows of one
/// element share `element`, so a selection filters the list to that element's rows.
struct DimensionRow: Identifiable, Equatable, Sendable {
    /// Stable id: "room.length", "wall.<uuid>.length", "door.<uuid>.width", "object.<uuid>.depth".
    var id: String
    /// Group the row is listed under.
    var group: DimensionGroup
    /// Measurement name.
    var title: String
    /// Element name.
    var label: String
    /// What the value measures (drives the unit and the low-confidence variant).
    var kind: MeasurementKind
    /// The value with its sigma and provenance.
    var value: MeasuredValue
    /// The room, wall, door, window, opening or object the row belongs to.
    var element: ElementID?
    /// `MeasureDisplay.isLowConfidence` of the value (false for inferred and user values).
    var isLowConfidence: Bool

    /// Element and measurement read as one phrase: "Wall 3, Wall length".
    var spokenName: String {
        Copy.MeasureCore.rowName(element: label, measure: title)
    }

    /// Full VoiceOver text of the row (`MeasureDisplay.accessibilityText`).
    func accessibilityText(prefs: UnitPreferences) -> String {
        MeasureDisplay.accessibilityText(label: spokenName, value: value, kind: kind, prefs: prefs)
    }
}

/// The automatic room measurements (docs/ARCHITECTURE.md 8.1), deterministic and in a fixed order.
enum RoomDimensions {
    /// Room: length, width, floor area, perimeter, ceiling height, wall area, estimated volume; then
    /// per wall (length, height, area), per door (width, height), per window (width, height).
    /// Wall area row: id "wall.<uuid>.area", kind .area, value length x height minus that wall's
    /// openings, sigma from `ConfidenceAdapter.area(_:sideA:sideB:)` of the wall's length and height
    /// rows; the Walls group carries `Copy.MeasureCore.wallAreaNote`. Every row has `element` set
    /// (walls, doors and windows to their ElementID) so Results can filter by selection.
    /// Open passages (`OpeningKind.opening`) follow the doors in the Doors group as "Opening n".
    static func rows(for room: CleanRoom, evidence: RoomEvidence) -> [DimensionRow] {
        let walls = wallRowSets(room, evidence: evidence)
        var rows = roomRows(room, evidence: evidence, walls: walls)
        for wallSet in walls {
            rows.append(wallSet.length)
            rows.append(wallSet.height)
            rows.append(wallSet.area)
        }
        rows.append(contentsOf: openingRows(room, evidence: evidence))
        return rows
    }

    /// Width, height and depth of a detected object's box (ids "object.<uuid>.width" and so on,
    /// titles `Copy.Viewer.width`, `height`, `depth`, group .objects), each from
    /// `ConfidenceAdapter.roomPlanLength(_, wall: nil, room: evidence, provenance: object.provenance)`.
    static func objectRows(for object: DetectedObject, evidence: RoomEvidence) -> [DimensionRow] {
        let key = "object.\(object.id.uuid.uuidString)"
        let label = object.label.isEmpty ? Copy.MeasureCore.objectTitle : object.label
        let sizes: [(suffix: String, title: String, meters: Float, kind: MeasurementKind)] = [
            ("width", Copy.Viewer.width, object.dimensions.x, .distance),
            ("height", Copy.Viewer.height, object.dimensions.y, .height),
            ("depth", Copy.Viewer.depth, object.dimensions.z, .distance),
        ]
        return sizes.map { size in
            let value = ConfidenceAdapter.roomPlanLength(size.meters, wall: nil, room: evidence,
                                                         provenance: object.provenance)
            return makeRow(id: "\(key).\(size.suffix)", group: .objects, title: size.title, label: label,
                           kind: size.kind, value: value, element: object.id)
        }
    }

    // MARK: - Room rows

    /// The seven room rows.
    private static func roomRows(_ room: CleanRoom, evidence: RoomEvidence, walls: [WallRowSet]) -> [DimensionRow] {
        let label = room.name.isEmpty ? Copy.MeasureCore.roomGroup : room.name
        let typical = evidence.typicalWall
        let sizes = MeasureRoomSizes(room: room, wallAreas: walls.map { Float($0.area.value.value) })
        let outline = outlineProvenance(room)

        let length = ConfidenceAdapter.roomPlanLength(sizes.length, distance: typical?.distance,
                                                      observations: typical?.observations,
                                                      room: evidence, provenance: outline)
        let width = ConfidenceAdapter.roomPlanLength(sizes.width, distance: typical?.distance,
                                                     observations: typical?.observations,
                                                     room: evidence, provenance: outline)
        let floorArea = ConfidenceAdapter.area(sizes.floorArea, sideA: length, sideB: width)

        let perimeter: MeasuredValue
        if walls.isEmpty {
            perimeter = ConfidenceAdapter.roomPlanLength(sizes.perimeter, distance: typical?.distance,
                                                         observations: typical?.observations,
                                                         room: evidence, provenance: outline)
        } else {
            perimeter = replacingValue(ConfidenceAdapter.sum(walls.map { $0.length.value }), with: sizes.perimeter)
        }

        let ceiling = ceilingValue(sizes.ceilingHeight, provenance: sizes.ceilingProvenance,
                                   typical: typical, evidence: evidence)

        let wallArea: MeasuredValue
        if walls.isEmpty {
            wallArea = MeasuredValue(value: Double(sizes.wallArea), sigma: nil, provenance: .inferred)
        } else {
            wallArea = replacingValue(ConfidenceAdapter.sum(walls.map { $0.area.value }), with: sizes.wallArea)
        }

        let product = ConfidenceAdapter.area(sizes.volume, sideA: floorArea, sideB: ceiling)
        let volumeProvenance = ConfidenceAdapter.combined([product.provenance, sizes.volumeProvenance])
        let volume = MeasuredValue(value: product.value,
                                   sigma: ConfidenceAdapter.carriesSigma(volumeProvenance) ? product.sigma : nil,
                                   provenance: volumeProvenance)

        let entries: [(suffix: String, title: String, kind: MeasurementKind, value: MeasuredValue)] = [
            ("length", Copy.Measure.roomLength, .distance, length),
            ("width", Copy.Measure.roomWidth, .distance, width),
            ("floorArea", Copy.Measure.floorArea, .area, floorArea),
            ("perimeter", Copy.Measure.perimeter, .perimeter, perimeter),
            ("ceilingHeight", Copy.Measure.ceilingHeight, .height, ceiling),
            ("wallArea", Copy.Measure.wallArea, .area, wallArea),
            ("volume", Copy.Measure.volume, .volume, volume),
        ]
        return entries.map { entry in
            makeRow(id: "room.\(entry.suffix)", group: .room, title: entry.title, label: label,
                    kind: entry.kind, value: entry.value, element: room.id)
        }
    }

    /// Ceiling height by provenance: measured uses the depth model at the typical camera
    /// distance (mesh planes), estimated uses `roomPlanLength`, inferred and user carry no sigma.
    private static func ceilingValue(_ height: Float, provenance: Provenance,
                                     typical: (distance: Float, observations: Int)?,
                                     evidence: RoomEvidence) -> MeasuredValue {
        switch provenance {
        case .measured:
            return ConfidenceAdapter.meshHeight(height, distance: typical?.distance,
                                                observations: typical?.observations, room: evidence)
        case .estimated:
            return ConfidenceAdapter.roomPlanLength(height, distance: typical?.distance,
                                                    observations: typical?.observations,
                                                    room: evidence, provenance: .estimated)
        case .inferred, .user:
            return MeasuredValue(value: Double(height), sigma: nil, provenance: provenance)
        }
    }

    /// Provenance of values taken from the wall loop: estimated when there are no walls (floor
    /// polygon fallback), otherwise the weakest wall provenance.
    private static func outlineProvenance(_ room: CleanRoom) -> Provenance {
        guard !room.walls.isEmpty else { return .estimated }
        return ConfidenceAdapter.combined(room.walls.map { $0.provenance })
    }

    /// The value of a combination replaced by the model's own number (sigma and provenance kept).
    private static func replacingValue(_ combined: MeasuredValue, with value: Float) -> MeasuredValue {
        MeasuredValue(value: Double(value), sigma: combined.sigma, provenance: combined.provenance)
    }

    // MARK: - Wall rows

    /// The three rows of one wall.
    private struct WallRowSet {
        /// Length row.
        var length: DimensionRow
        /// Height row.
        var height: DimensionRow
        /// Area row (openings subtracted).
        var area: DimensionRow
    }

    /// Rows for every wall in loop order.
    private static func wallRowSets(_ room: CleanRoom, evidence: RoomEvidence) -> [WallRowSet] {
        var sets: [WallRowSet] = []
        for (index, wall) in room.walls.enumerated() {
            let label = Copy.MeasureCore.wallTitle(index + 1)
            let key = "wall.\(wall.id.uuid.uuidString)"
            let wallEvidence = evidence.wall(wall.id)
            let meters = MeasureRoomSizes.wallLength(wall)
            let length = ConfidenceAdapter.roomPlanLength(meters, wall: wallEvidence, room: evidence,
                                                          provenance: wall.provenance)
            let height = ConfidenceAdapter.roomPlanLength(wall.height, wall: wallEvidence, room: evidence,
                                                          provenance: wall.provenance)
            let netArea = MeasureRoomSizes.wallArea(wall, length: meters, openings: room.openings)
            let area = ConfidenceAdapter.area(netArea, sideA: length, sideB: height)
            sets.append(WallRowSet(
                length: makeRow(id: "\(key).length", group: .walls, title: Copy.Measure.wallLength, label: label,
                                kind: .wallLength, value: length, element: wall.id),
                height: makeRow(id: "\(key).height", group: .walls, title: Copy.Measure.wallHeight, label: label,
                                kind: .height, value: height, element: wall.id),
                area: makeRow(id: "\(key).area", group: .walls, title: Copy.Measure.wallArea, label: label,
                              kind: .area, value: area, element: wall.id)))
        }
        return sets
    }

    // MARK: - Opening rows

    /// Door rows, then open passage rows (both in the Doors group), then window rows; each kind
    /// numbered along the wall loop (wall order, then offset along the wall).
    private static func openingRows(_ room: CleanRoom, evidence: RoomEvidence) -> [DimensionRow] {
        var wallIndex: [ElementID: Int] = [:]
        for (index, wall) in room.walls.enumerated() where wallIndex[wall.id] == nil {
            wallIndex[wall.id] = index
        }
        let ordered = room.openings.enumerated().sorted { lhs, rhs in
            let wl = lhs.element.wallID.flatMap { wallIndex[$0] } ?? Int.max
            let wr = rhs.element.wallID.flatMap { wallIndex[$0] } ?? Int.max
            if wl != wr { return wl < wr }
            let offsetL = lhs.element.offsetAlongWall.isFinite ? lhs.element.offsetAlongWall : Float.greatestFiniteMagnitude
            let offsetR = rhs.element.offsetAlongWall.isFinite ? rhs.element.offsetAlongWall : Float.greatestFiniteMagnitude
            if offsetL != offsetR { return offsetL < offsetR }
            return lhs.offset < rhs.offset
        }.map { $0.element }

        var doors: [DimensionRow] = []
        var passages: [DimensionRow] = []
        var windows: [DimensionRow] = []
        for opening in ordered {
            let wallEvidence = opening.wallID.flatMap { evidence.wall($0) }
            let width = ConfidenceAdapter.roomPlanLength(opening.width, wall: wallEvidence, room: evidence,
                                                         provenance: opening.provenance)
            let height = ConfidenceAdapter.roomPlanLength(MeasureRoomSizes.openingHeight(opening), wall: wallEvidence,
                                                          room: evidence, provenance: opening.provenance)
            let uuid = opening.id.uuid.uuidString
            switch opening.kind {
            case .door, .openDoor:
                let label = Copy.MeasureCore.doorTitle(doors.count / 2 + 1)
                doors.append(makeRow(id: "door.\(uuid).width", group: .doors, title: Copy.Measure.doorWidth,
                                     label: label, kind: .distance, value: width, element: opening.id))
                doors.append(makeRow(id: "door.\(uuid).height", group: .doors, title: Copy.Measure.doorHeight,
                                     label: label, kind: .height, value: height, element: opening.id))
            case .window:
                let label = Copy.MeasureCore.windowTitle(windows.count / 2 + 1)
                windows.append(makeRow(id: "window.\(uuid).width", group: .windows,
                                       title: Copy.MeasureCore.windowWidth, label: label, kind: .distance,
                                       value: width, element: opening.id))
                windows.append(makeRow(id: "window.\(uuid).height", group: .windows,
                                       title: Copy.MeasureCore.windowHeight, label: label, kind: .height,
                                       value: height, element: opening.id))
            case .opening:
                let label = Copy.MeasureCore.openingTitle(passages.count / 2 + 1)
                passages.append(makeRow(id: "opening.\(uuid).width", group: .doors,
                                        title: Copy.MeasureCore.openingWidth, label: label, kind: .distance,
                                        value: width, element: opening.id))
                passages.append(makeRow(id: "opening.\(uuid).height", group: .doors,
                                        title: Copy.MeasureCore.openingHeight, label: label, kind: .height,
                                        value: height, element: opening.id))
            }
        }
        return doors + passages + windows
    }

    // MARK: - Helpers

    /// A row with its low-confidence flag from `MeasureDisplay` (the one rule).
    private static func makeRow(id: String, group: DimensionGroup, title: String, label: String,
                                kind: MeasurementKind, value: MeasuredValue, element: ElementID?) -> DimensionRow {
        DimensionRow(id: id, group: group, title: title, label: label, kind: kind, value: value,
                     element: element, isLowConfidence: MeasureDisplay.isLowConfidence(value, kind: kind))
    }
}
