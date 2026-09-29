import Foundation

/// What an exported file shows (the export sheet groups formats by it, docs/ARCHITECTURE.md 9).
enum ExportRepresentation: String, CaseIterable, Identifiable, Sendable {
    /// The textured room (TextureJob), clean architectural model (RoomModel), the scan as captured
    /// (MeshModel), the 2D plan (FloorPlan), the room data (JSON) and, in build 5, a scanned
    /// object's model (`.object`, Object projects only).
    case realistic, clean, raw, floorPlan, data, object

    /// Stable identifier (the raw value).
    var id: String { rawValue }
}

/// File formats the sheet offers. Raw values are stable (option ids, logs).
enum ExportFileFormat: String, CaseIterable, Identifiable, Sendable {
    /// 3D formats, then plan formats, then data.
    case usdz, obj, ply, stl, glb, pdf, svg, dxf, png, json

    /// Stable identifier (the raw value).
    var id: String { rawValue }

    /// File extension of the written file (OBJ is shared inside a zip, see `ExportCatalog.zipFileName`).
    var fileExtension: String { rawValue }
}

/// What a project has on disk, as far as the export sheet cares (`ExportCatalog.inputs`).
struct ExportInputs: Equatable, Sendable {
    /// A baked texture exists for at least one room (`TextureStore.exists`).
    var hasTexture = false
    /// At least one room recorded keyframes (color was captured).
    var hasKeyframes = false
    /// The project still waits for or runs its processing job (status `.needsProcessing` or
    /// `.processing`), so missing color may still come.
    var isProcessing = false
    /// `derived/clean.json` exists and has at least one room.
    var hasClean = false
    /// `derived/plan.json` exists and has a level with a room or a wall.
    var hasPlan = false
    /// A consolidated measured mesh exists for at least one room.
    var hasMesh = false
    /// A final (raw or rebuilt) RoomPlan `CapturedRoom` exists for at least one room.
    var hasCapturedRoom = false
    /// The edit log has active operations.
    var hasEdits = false
    /// Measured triangles of the largest room's consolidated mesh (`mesh_stats.json`), 0 when unknown.
    var meshTriangles = 0

    // Build 5 (docs/MODULES.md 3.43d).

    /// What the project scans (the manifest's kind); picks the catalog layout.
    var kind: ScanMode = .room
    /// Plan levels with rooms or walls.
    var levelCount = 1
    /// House: a merged structure (merge.json outcome `merged`, structure.json present) and no active edit.
    var structureExportable = false
    /// House: every active room has `TextureStore.exists`.
    var allRoomsTextured = false
    /// Object: model.usdz (small and medium) or the object mesh (large) exists.
    var hasObjectModel = false
    /// Object: dims.json of the first object exists.
    var hasObjectDimensions = false
    /// Saved measurements (measurements.json, or Quick Measure's raw file).
    var measurementCount = 0
    /// House: measured triangles of each active room with a consolidated mesh (manifest order),
    /// for the simplified note of the whole-house budget.
    var roomTriangles: [Int] = []

    /// Nothing available.
    init() {}
}

/// One format of one representation, with its availability.
struct ExportOption: Identifiable, Equatable, Sendable {
    /// What the file shows.
    var representation: ExportRepresentation
    /// The file format.
    var format: ExportFileFormat
    /// True when the project has what this export needs.
    var isAvailable: Bool
    /// Why it is not available (Copy text), nil when available.
    var reason: String?

    /// "<representation>.<format>", unique in the catalog.
    var id: String { "\(representation.rawValue).\(format.rawValue)" }
}

/// Options of one export. `unitsOverride` nil uses the app's UnitPreferences for PDF, SVG, DXF
/// and PNG labels (Copy.Export.units).
struct ExportSettings: Equatable, Sendable {
    /// Realistic formats: embed the color images (off gives the textured shape in white).
    var includeTextures = true
    /// Clean 3D and plan formats: include hidden objects and furniture that Hide Furniture hides.
    var includeHidden = false
    /// Plan formats: keep dimension lines; Data: include the saved measurements.
    var includeMeasurements = true
    /// PDF paper size.
    var paper: PDFPlanWriter.Paper = .usLetter
    /// Unit system of plan labels, nil for the app setting.
    var unitsOverride: UnitSystem? = nil

    /// Defaults: textures on, hidden objects off, measurements on, US Letter, app units.
    init() {}

    /// The paper the sheet starts with for a unit system: A4 for metric, US Letter for feet.
    static func defaultPaper(for system: UnitSystem) -> PDFPlanWriter.Paper {
        system == .metric ? .a4 : .usLetter
    }
}

/// The formats per representation, their availability, labels and file names. Pure and
/// nonisolated, except `inputs(package:manifest:)` and `loadInputs(projectID:)` which read
/// small files (call them off main).
enum ExportCatalog {
    /// Text formats (OBJ, USDZ) take the full measured mesh up to this many triangles and the
    /// view mesh above it (docs/ARCHITECTURE.md 9, memory).
    static let textTriangleLimit = 600_000

    /// Formats per representation, in sheet order.
    static let layout: [(representation: ExportRepresentation, formats: [ExportFileFormat])] = [
        (.realistic, [.usdz, .obj, .glb]),
        (.clean, [.usdz, .obj, .glb]),
        (.raw, [.usdz, .obj, .ply, .stl, .glb]),
        (.floorPlan, [.pdf, .svg, .dxf, .png]),
        (.data, [.json])
    ]

    /// Object projects: the object's model, then its dimensions.
    static let objectLayout: [(representation: ExportRepresentation, formats: [ExportFileFormat])] = [
        (.object, [.usdz]),
        (.data, [.json])
    ]

    /// Quick Measure projects: the measurements only.
    static let quickMeasureLayout: [(representation: ExportRepresentation, formats: [ExportFileFormat])] = [
        (.data, [.json])
    ]

    /// The formats a project kind offers: Room, Advanced Space and House use `layout`, Object
    /// and Advanced Object `objectLayout`, Quick Measure `quickMeasureLayout`.
    static func sheetLayout(for kind: ScanMode) -> [(representation: ExportRepresentation, formats: [ExportFileFormat])] {
        switch kind {
        case .room, .advancedSpace, .house: return layout
        case .object, .advancedObject: return objectLayout
        case .quickMeasure: return quickMeasureLayout
        }
    }

    /// By `inputs.kind`. Room and advancedSpace: as build 4 (realistic: usdz, obj (zip), glb;
    /// clean: usdz, obj, glb; raw: usdz, obj, ply, stl, glb; floorPlan: pdf, svg, dxf, png; data:
    /// json; reasons Copy.Export.noColor when no keyframes were captured, Copy.ExportUI.colorNotReady
    /// while processing, Copy.ExportUI.colorMissing after processing ended without a texture,
    /// Copy.Export.noFloorPlan, Copy.ExportUI.noWalls and Copy.ExportUI.noRawScan). House: the same
    /// formats, realistic only when `allRoomsTextured`. Object and advancedObject: object usdz
    /// (Copy.ExportUI.objectNotReady until `hasObjectModel`), data json (same reason until
    /// `hasObjectDimensions`). Quick Measure: data json only (Copy.Empty.noMeasurements.title with
    /// no measurement).
    static func options(for inputs: ExportInputs) -> [ExportOption] {
        var result: [ExportOption] = []
        for entry in sheetLayout(for: inputs.kind) {
            let reason = unavailableReason(entry.representation, inputs: inputs)
            for format in entry.formats {
                result.append(ExportOption(representation: entry.representation, format: format,
                                           isAvailable: reason == nil, reason: reason))
            }
        }
        return result
    }

    /// Why a representation cannot be exported with `inputs`, nil when it can.
    static func unavailableReason(_ representation: ExportRepresentation, inputs: ExportInputs) -> String? {
        switch representation {
        case .realistic:
            let textured = inputs.kind == .house ? inputs.allRoomsTextured : inputs.hasTexture
            if textured { return nil }
            guard inputs.hasKeyframes else { return Copy.Export.noColor }
            return inputs.isProcessing ? Copy.ExportUI.colorNotReady : Copy.ExportUI.colorMissing
        case .clean:
            return inputs.hasClean ? nil : Copy.ExportUI.noWalls
        case .data:
            return dataUnavailableReason(inputs)
        case .raw:
            return inputs.hasMesh ? nil : Copy.ExportUI.noRawScan
        case .floorPlan:
            return inputs.hasPlan ? nil : Copy.Export.noFloorPlan
        case .object:
            return inputs.hasObjectModel ? nil : Copy.ExportUI.objectNotReady
        }
    }

    /// The data JSON's reason by kind: the clean model for rooms and houses, the dimensions for
    /// objects, at least one measurement for Quick Measure.
    private static func dataUnavailableReason(_ inputs: ExportInputs) -> String? {
        switch inputs.kind {
        case .room, .advancedSpace, .house:
            return inputs.hasClean ? nil : Copy.ExportUI.noWalls
        case .object, .advancedObject:
            return inputs.hasObjectDimensions ? nil : Copy.ExportUI.objectNotReady
        case .quickMeasure:
            return inputs.measurementCount > 0 ? nil : Copy.Empty.noMeasurements.title
        }
    }

    /// Section title of a representation on the sheet; `Copy.Modes.object` for `.object`.
    static func sectionTitle(_ representation: ExportRepresentation) -> String {
        switch representation {
        case .realistic: return Copy.ExportUI.realisticSection
        case .clean: return Copy.ExportUI.cleanSection
        case .raw: return Copy.ExportUI.rawSection
        case .floorPlan: return Copy.ExportUI.planSection
        case .data: return Copy.ExportUI.dataSection
        case .object: return Copy.Modes.object
        }
    }

    /// The (label, detail) of an option: the object USDZ explains itself with
    /// Copy.ExportUI.objectDetail, everything else uses `label(for:)` of its format.
    static func label(for option: ExportOption) -> (label: String, detail: String) {
        let base = label(for: option.format)
        guard option.representation == .object else { return base }
        return (base.label, Copy.ExportUI.objectDetail)
    }

    /// Explicit switch over ExportFileFormat to its (label, detail), never an index into
    /// Copy.Export.formats: usdz, obj, stl, glb, pdf, svg, json, png ("Images") come from
    /// Copy.Export.formats by label; ply uses Copy.ExportUI.plyDetail in build 4 (class colors,
    /// not photo color); dxf uses Copy.ExportUI.dxfDetail (always drawn in millimeters, D23).
    static func label(for format: ExportFileFormat) -> (label: String, detail: String) {
        switch format {
        case .usdz: return formatEntry("USDZ")
        case .obj: return formatEntry("OBJ")
        case .ply: return (formatEntry("PLY").label, Copy.ExportUI.plyDetail)
        case .stl: return formatEntry("STL")
        case .glb: return formatEntry("glTF")
        case .pdf: return formatEntry("PDF Floor Plan")
        case .svg: return formatEntry("SVG")
        case .dxf: return (formatEntry("DXF").label, Copy.ExportUI.dxfDetail)
        case .png: return formatEntry("Images")
        case .json: return formatEntry("JSON")
        }
    }

    /// The Copy.Export.formats entry whose label is `key`; the key itself with no detail when the
    /// catalog lacks it (a Copy change the self-test reports).
    private static func formatEntry(_ key: String) -> (label: String, detail: String) {
        Copy.Export.formats.first(where: { $0.label == key }) ?? (label: key, detail: "")
    }

    /// True when a raw export uses a simplified view mesh, so the sheet shows
    /// Copy.ExportUI.simplifiedNote: for rooms, a text format (OBJ, USDZ) above
    /// `textTriangleLimit`; for a House, any room above its share of the whole-house budget
    /// (`ExportHouse.perRoomLimit` of `rawBudget(for:)`), in every raw format.
    static func isSimplified(_ option: ExportOption, inputs: ExportInputs) -> Bool {
        guard option.representation == .raw else { return false }
        if inputs.kind == .house {
            let limit = ExportHouse.perRoomLimit(total: rawBudget(for: option.format), rooms: inputs.roomTriangles.count)
            return inputs.roomTriangles.contains { $0 > limit }
        }
        return isTextFormat(option.format) && inputs.meshTriangles > textTriangleLimit
    }

    /// Whole-house triangle budget of a raw format: `textTriangleLimit` for OBJ and USDZ,
    /// `ExportHouse.maxBinaryTriangles` for PLY, STL and GLB.
    static func rawBudget(for format: ExportFileFormat) -> Int {
        isTextFormat(format) ? textTriangleLimit : ExportHouse.maxBinaryTriangles
    }

    /// OBJ and USDZ, whose writers build large text in memory.
    static func isTextFormat(_ format: ExportFileFormat) -> Bool {
        format == .obj || format == .usdz
    }

    // MARK: - File names

    /// "<Project>_<Representation>_<yyyy-MM-dd>.<ext>" in ASCII letters, digits, "-" and "_".
    /// Always starts with a letter (Copy.ExportUI.fileNamePrefix is put in front otherwise,
    /// RESEARCH 3.7 gotcha 7); DXF gets "_mm" before the extension (D23).
    static func fileName(project: String, option: ExportOption, date: Date) -> String {
        fileName(project: project, option: option, date: date, level: nil)
    }

    /// As `fileName(project:option:date:)`; `level` (1-based) adds `Copy.ExportUI.levelSuffix(level)`
    /// before the extension of plan files of a multi-level plan; DXF keeps "_mm" last.
    static func fileName(project: String, option: ExportOption, date: Date, level: Int?) -> String {
        var parts = [sanitized(project, maxLength: 60), sanitized(representationName(option.representation), maxLength: 40),
                     dayStamp(date)]
        if let level {
            parts.append(sanitized(Copy.ExportUI.levelSuffix(level), maxLength: 20))
        }
        parts = parts.filter { !$0.isEmpty }
        if option.format == .dxf { parts.append("mm") }
        var stem = parts.joined(separator: "_")
        if !startsWithLetter(stem) {
            stem = sanitized(Copy.ExportUI.fileNamePrefix, maxLength: 20) + "_" + stem
        }
        return "\(stem).\(option.format.fileExtension)"
    }

    /// The zip that carries a multi-file result: "<stem>_<ext>.zip" ("..._obj.zip").
    static func zipFileName(for fileName: String) -> String {
        let url = URL(fileURLWithPath: fileName)
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        return ext.isEmpty ? "\(stem).zip" : "\(stem)_\(ext).zip"
    }

    /// The name without its extension.
    static func stem(of fileName: String) -> String {
        URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
    }

    /// Name of a representation inside file names (the result screen's tab names).
    static func representationName(_ representation: ExportRepresentation) -> String {
        switch representation {
        case .realistic: return Copy.Viewer.realistic
        case .clean: return Copy.Viewer.clean
        case .raw: return Copy.Viewer.raw
        case .floorPlan: return Copy.Viewer.floorPlan
        case .data: return Copy.ExportUI.dataSection
        case .object: return Copy.Modes.object
        }
    }

    /// ASCII letters and digits kept, "-" kept, every other run of characters becomes one "_",
    /// no leading or trailing "_", at most `maxLength` characters.
    static func sanitized(_ text: String, maxLength: Int) -> String {
        var out = ""
        var pendingSeparator = false
        for scalar in text.unicodeScalars {
            let v = scalar.value
            let isLetter = (v >= 65 && v <= 90) || (v >= 97 && v <= 122)
            let isDigit = v >= 48 && v <= 57
            if isLetter || isDigit || v == 45 {
                if pendingSeparator && !out.isEmpty { out.append("_") }
                pendingSeparator = false
                out.unicodeScalars.append(scalar)
            } else {
                pendingSeparator = true
            }
        }
        if out.count > maxLength { out = String(out.prefix(maxLength)) }
        while out.hasSuffix("_") || out.hasSuffix("-") { out.removeLast() }
        return out
    }

    /// True when the first character is an ASCII letter.
    static func startsWithLetter(_ text: String) -> Bool {
        guard let first = text.unicodeScalars.first else { return false }
        let v = first.value
        return (v >= 65 && v <= 90) || (v >= 97 && v <= 122)
    }

    /// "yyyy-MM-dd" in the current time zone (POSIX locale, Gregorian calendar).
    static func dayStamp(_ date: Date) -> String {
        posixFormatter("yyyy-MM-dd").string(from: date)
    }

    /// A POSIX-locale Gregorian formatter in the current time zone.
    static func posixFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = format
        return formatter
    }
}
