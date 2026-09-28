import Foundation
import simd

/// Summary JSON: rooms with metrics (meters, square meters, provenance, sigma), walls, openings,
/// objects (category, label, box), quality summary and, when asked, the saved measurements. The
/// runner zips it with capturedroom.json when present. Never Apple's private CapturedRoom schema
/// as the interchange format (RESEARCH 3.2 gotcha 16). Non-finite numbers are written as 0 (or
/// left out for sigma), so encoding never fails on them. Pure; any thread.
enum ExportSummaryJSON {
    /// Value of the top-level "format" key.
    static let formatName = "mapper-summary"
    /// Value of the top-level "version" key.
    static let formatVersion = 1

    /// The summary of a project's edited clean model; `evidence` is keyed by `CleanRoom.recordID`
    /// (rooms without evidence use `RoomEvidence.unknown`).
    static func data(model: CleanModel, evidence: [UUID: RoomEvidence], manifest: ProjectManifest) throws -> Data {
        try data(model: model, evidence: evidence, manifest: manifest, measurements: [])
    }

    /// As `data(model:evidence:manifest:)` plus the saved measurements (`edits/measurements.json`).
    static func data(model: CleanModel, evidence: [UUID: RoomEvidence], manifest: ProjectManifest,
                     measurements: [MeasurementRecord]) throws -> Data {
        let rooms = model.rooms.enumerated().map { index, room in
            roomEntry(room, index: index, evidence: evidence[room.recordID] ?? RoomEvidence.unknown, manifest: manifest)
        }
        let project = ProjectEntry(id: manifest.id.uuidString, name: manifest.name, kind: manifest.kind.rawValue,
                                   createdAt: manifest.createdAt, modifiedAt: manifest.modifiedAt, roomCount: rooms.count)
        let document = Document(format: formatName, version: formatVersion, project: project, units: UnitsEntry(),
                                rooms: rooms, measurements: measurements.map(measurementEntry))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(document)
    }

    // MARK: - Document types

    /// The whole file.
    struct Document: Encodable {
        var format: String
        var version: Int
        var project: ProjectEntry
        var units: UnitsEntry
        var rooms: [RoomEntry]
        var measurements: [MeasurementEntry]
    }

    /// Project identity and dates.
    struct ProjectEntry: Encodable {
        var id: String
        var name: String
        var kind: String
        var createdAt: Date
        var modifiedAt: Date
        var roomCount: Int
    }

    /// The units and axes every number uses (fixed, machine-readable).
    struct UnitsEntry: Encodable {
        var length = "meters"
        var area = "square meters"
        var volume = "cubic meters"
        var angle = "radians"
        var axes = "world: meters, +Y up; plan: x = world x, y = -world z"
    }

    /// A measured number with its one-sigma uncertainty and where it came from.
    struct ValueEntry: Encodable {
        var value: Double
        var sigma: Double?
        var provenance: String
        var lowConfidence: Bool
    }

    /// One room.
    struct RoomEntry: Encodable {
        var id: String
        var recordID: String
        var title: String
        var name: String
        var sectionLabel: String?
        var floorIndex: Int
        var metrics: [String: ValueEntry]
        var floor: FloorEntry
        var walls: [WallEntry]
        var openings: [OpeningEntry]
        var objects: [ObjectEntry]
        var quality: QualityEntry?
    }

    /// Floor outline (plan meters) and elevation.
    struct FloorEntry: Encodable {
        var outline: [[Double]]
        var elevation: Double
        var occludedArea: Double
        var provenance: String
    }

    /// One wall: base line, thickness and its three measurements.
    struct WallEntry: Encodable {
        var id: String
        var start: [Double]
        var end: [Double]
        var thickness: Double
        var thicknessSource: String
        var curved: Bool
        var confidence: String
        var provenance: String
        var length: ValueEntry
        var height: ValueEntry
        var area: ValueEntry
    }

    /// One door, window or opening.
    struct OpeningEntry: Encodable {
        var id: String
        var kind: String
        var wallID: String?
        var offsetAlongWall: Double
        var sillHeight: Double
        var headHeight: Double
        var width: ValueEntry
        var height: ValueEntry
        var swing: SwingEntry?
        var provenance: String
    }

    /// Door swing.
    struct SwingEntry: Encodable {
        var hingeAtStart: Bool
        var opensToNormalSide: Bool
        var source: String
    }

    /// One detected object as an oriented box.
    struct ObjectEntry: Encodable {
        var id: String
        var category: String
        var categoryName: String
        var label: String
        var center: [Double]
        var size: [Double]
        var yaw: Double
        var isMovable: Bool
        var isHidden: Bool
        var confidence: String
        var provenance: String
        var width: ValueEntry
        var height: ValueEntry
        var depth: ValueEntry
    }

    /// Scan quality scores (0...1) of the room.
    struct QualityEntry: Encodable {
        var shape: Double
        var walls: Double
        var floor: Double
        var ceiling: Double
        var texture: Double
        var missingAreas: Int
        var verdict: String
    }

    /// One saved measurement.
    struct MeasurementEntry: Encodable {
        var id: String
        var name: String
        var kind: String
        var value: ValueEntry
        var source: String
        var roomID: String?
        var points: [[Double]]
        var createdAt: Date
    }

    // MARK: - Builders

    /// A room with its metrics and elements, values from `RoomDimensions.rows`.
    static func roomEntry(_ room: CleanRoom, index: Int, evidence: RoomEvidence, manifest: ProjectManifest) -> RoomEntry {
        let rows = RoomDimensions.rows(for: room, evidence: evidence)
        var byID: [String: DimensionRow] = [:]
        for row in rows { byID[row.id] = row }
        var metrics: [String: ValueEntry] = [:]
        for row in rows where row.id.hasPrefix("room.") {
            metrics[String(row.id.dropFirst("room.".count))] = valueEntry(row)
        }
        let walls = room.walls.map { wall -> WallEntry in
            let key = "wall.\(wall.id.uuid.uuidString)"
            return WallEntry(id: wall.id.uuid.uuidString, start: numbers(wall.start.simd), end: numbers(wall.end.simd),
                             thickness: finite(wall.thickness), thicknessSource: wall.thicknessSource.rawValue,
                             curved: wall.arc != nil, confidence: wall.confidence.rawValue, provenance: wall.provenance.rawValue,
                             length: entry(byID["\(key).length"], fallback: wall.length, provenance: wall.provenance),
                             height: entry(byID["\(key).height"], fallback: wall.height, provenance: wall.provenance),
                             area: entry(byID["\(key).area"], fallback: wall.length * wall.height, provenance: wall.provenance))
        }
        let openings = room.openings.map { opening -> OpeningEntry in
            let key = "\(openingPrefix(opening.kind)).\(opening.id.uuid.uuidString)"
            let swing = opening.swing.map { SwingEntry(hingeAtStart: $0.hingeAtStart, opensToNormalSide: $0.opensToNormalSide,
                                                       source: $0.source.rawValue) }
            return OpeningEntry(id: opening.id.uuid.uuidString, kind: opening.kind.rawValue, wallID: opening.wallID?.uuid.uuidString,
                                offsetAlongWall: finite(opening.offsetAlongWall), sillHeight: finite(opening.sillHeight),
                                headHeight: finite(opening.headHeight),
                                width: entry(byID["\(key).width"], fallback: opening.width, provenance: opening.provenance),
                                height: entry(byID["\(key).height"], fallback: opening.headHeight - opening.sillHeight,
                                              provenance: opening.provenance),
                                swing: swing, provenance: opening.provenance.rawValue)
        }
        let objects = room.objects.map { objectEntry($0, evidence: evidence) }
        let floor = FloorEntry(outline: room.floor.outline.map { [finite($0.x), finite($0.y)] },
                               elevation: finite(room.floor.elevation), occludedArea: finite(room.floor.occludedArea),
                               provenance: room.floor.provenance.rawValue)
        let record = manifest.rooms.first(where: { $0.id == room.recordID })
        let summary: QualitySummary? = record?.quality
        let quality: QualityEntry? = summary.map { s in
            QualityEntry(shape: finite(s.shape), walls: finite(s.walls), floor: finite(s.floor),
                         ceiling: finite(s.ceiling), texture: finite(s.texture),
                         missingAreas: s.missingAreas, verdict: s.verdict.rawValue)
        }
        let title = RoomTitles.title(name: room.name, sectionLabel: room.sectionLabel, index: index)
        return RoomEntry(id: room.id.uuid.uuidString, recordID: room.recordID.uuidString, title: title, name: room.name,
                         sectionLabel: room.sectionLabel, floorIndex: room.floorIndex, metrics: metrics, floor: floor,
                         walls: walls, openings: openings, objects: objects, quality: quality)
    }

    /// Row id prefix of an opening kind (MeasureCore's ids).
    static func openingPrefix(_ kind: OpeningKind) -> String {
        switch kind {
        case .door, .openDoor: return "door"
        case .window: return "window"
        case .opening: return "opening"
        }
    }

    /// One object: box center, size, plan yaw and its three measurements.
    static func objectEntry(_ object: DetectedObject, evidence: RoomEvidence) -> ObjectEntry {
        var byID: [String: DimensionRow] = [:]
        for row in RoomDimensions.objectRows(for: object, evidence: evidence) { byID[row.id] = row }
        let key = "object.\(object.id.uuid.uuidString)"
        let column = object.transform.simd.columns.0
        let axis = PlanAxes.toPlan(SIMD3<Float>(column.x, column.y, column.z))
        let yaw = Double(atan2(axis.y, axis.x))
        let size = object.dimensions
        return ObjectEntry(id: object.id.uuid.uuidString, category: object.category.rawValue,
                           categoryName: Copy.FloorPlan.categoryName(object.category), label: object.label,
                           center: numbers(object.transform.translation), size: numbers(size.simd),
                           yaw: yaw.isFinite ? yaw : 0, isMovable: object.isMovable, isHidden: object.isHidden,
                           confidence: object.confidence.rawValue, provenance: object.provenance.rawValue,
                           width: entry(byID["\(key).width"], fallback: size.x, provenance: object.provenance),
                           height: entry(byID["\(key).height"], fallback: size.y, provenance: object.provenance),
                           depth: entry(byID["\(key).depth"], fallback: size.z, provenance: object.provenance))
    }

    /// One saved measurement with its value, sigma and points.
    static func measurementEntry(_ record: MeasurementRecord) -> MeasurementEntry {
        let value = ValueEntry(value: finite(record.result.value), sigma: finiteOrNil(record.result.sigma),
                               provenance: record.result.provenance.rawValue,
                               lowConfidence: record.result.isLowConfidence(kind: record.kind))
        return MeasurementEntry(id: record.id.uuidString, name: record.name, kind: record.kind.rawValue, value: value,
                                source: record.source.rawValue, roomID: record.roomID?.uuid.uuidString,
                                points: record.points.map { numbers($0.simd) }, createdAt: record.createdAt)
    }

    /// The value of a dimension row.
    static func valueEntry(_ row: DimensionRow) -> ValueEntry {
        ValueEntry(value: finite(row.value.value), sigma: finiteOrNil(row.value.sigma),
                   provenance: row.value.provenance.rawValue, lowConfidence: row.isLowConfidence)
    }

    /// The row's value, or the plain geometric value without sigma when the row is missing.
    static func entry(_ row: DimensionRow?, fallback: Float, provenance: Provenance) -> ValueEntry {
        if let row { return valueEntry(row) }
        return ValueEntry(value: finite(fallback), sigma: nil, provenance: provenance.rawValue, lowConfidence: false)
    }

    /// x, y, z as finite doubles.
    static func numbers(_ v: SIMD3<Float>) -> [Double] {
        [finite(v.x), finite(v.y), finite(v.z)]
    }

    /// The value, or 0 when not finite.
    static func finite(_ value: Float) -> Double {
        value.isFinite ? Double(value) : 0
    }

    /// The value, or 0 when not finite.
    static func finite(_ value: Double) -> Double {
        value.isFinite ? value : 0
    }

    /// The value, or nil when absent or not finite.
    static func finiteOrNil(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return value
    }
}
