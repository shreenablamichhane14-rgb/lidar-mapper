import Foundation

/// What an exported file shows (the export sheet groups formats by it, docs/ARCHITECTURE.md 9).
enum ExportRepresentation: String, CaseIterable, Identifiable, Sendable {
    /// The textured room (TextureJob), clean architectural model (RoomModel), the scan as captured
    /// (MeshModel), the 2D plan (FloorPlan) and the room data (JSON).
    case realistic, clean, raw, floorPlan, data

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

    /// realistic: usdz, obj (zip), glb; clean: usdz, obj, glb; raw: usdz, obj, ply, stl, glb;
    /// floorPlan: pdf, svg, dxf, png; data: json. Unavailable ones carry a reason: Copy.Export.noColor
    /// when no keyframes were captured, Copy.ExportUI.colorNotReady when keyframes exist but
    /// `TextureStore.exists` is false (still running, failed or slipped), Copy.Export.noFloorPlan,
    /// Copy.ExportUI.noWalls (no clean model) and Copy.ExportUI.noRawScan (no consolidated mesh).
    static func options(for inputs: ExportInputs) -> [ExportOption] {
        var result: [ExportOption] = []
        for entry in layout {
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
            if inputs.hasTexture { return nil }
            return inputs.hasKeyframes ? Copy.ExportUI.colorNotReady : Copy.Export.noColor
        case .clean, .data:
            return inputs.hasClean ? nil : Copy.ExportUI.noWalls
        case .raw:
            return inputs.hasMesh ? nil : Copy.ExportUI.noRawScan
        case .floorPlan:
            return inputs.hasPlan ? nil : Copy.Export.noFloorPlan
        }
    }

    /// Section title of a representation on the sheet.
    static func sectionTitle(_ representation: ExportRepresentation) -> String {
        switch representation {
        case .realistic: return Copy.ExportUI.realisticSection
        case .clean: return Copy.ExportUI.cleanSection
        case .raw: return Copy.ExportUI.rawSection
        case .floorPlan: return Copy.ExportUI.planSection
        case .data: return Copy.ExportUI.dataSection
        }
    }

    /// Explicit switch over ExportFileFormat to its (label, detail), never an index into
    /// Copy.Export.formats: usdz, obj, stl, glb, pdf, svg, dxf, json, png ("Images") come from
    /// Copy.Export.formats by label; ply uses Copy.ExportUI.plyDetail in build 4 (class colors,
    /// not photo color).
    static func label(for format: ExportFileFormat) -> (label: String, detail: String) {
        switch format {
        case .usdz: return formatEntry("USDZ")
        case .obj: return formatEntry("OBJ")
        case .ply: return (formatEntry("PLY").label, Copy.ExportUI.plyDetail)
        case .stl: return formatEntry("STL")
        case .glb: return formatEntry("glTF")
        case .pdf: return formatEntry("PDF Floor Plan")
        case .svg: return formatEntry("SVG")
        case .dxf: return formatEntry("DXF")
        case .png: return formatEntry("Images")
        case .json: return formatEntry("JSON")
        }
    }

    /// The Copy.Export.formats entry whose label is `key`; the key itself with no detail when the
    /// catalog lacks it (a Copy change the self-test reports).
    private static func formatEntry(_ key: String) -> (label: String, detail: String) {
        Copy.Export.formats.first(where: { $0.label == key }) ?? (label: key, detail: "")
    }

    /// True when a raw text-format export (OBJ, USDZ) uses the simplified view mesh, so the sheet
    /// shows Copy.ExportUI.simplifiedNote.
    static func isSimplified(_ option: ExportOption, inputs: ExportInputs) -> Bool {
        option.representation == .raw && isTextFormat(option.format) && inputs.meshTriangles > textTriangleLimit
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
        var parts = [sanitized(project, maxLength: 60), sanitized(representationName(option.representation), maxLength: 40),
                     dayStamp(date)]
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

    // MARK: - Inputs

    /// What a project has on disk: texture, keyframes, clean model with rooms, plan with content,
    /// consolidated mesh, final CapturedRoom, active edits and the largest measured triangle count.
    /// Reads small files only (decodes clean.json and plan.json). Any thread; call it off main.
    static func inputs(package: ProjectPackage, manifest: ProjectManifest) -> ExportInputs {
        let fm = FileManager.default
        var result = ExportInputs()
        for room in manifest.rooms {
            if TextureStore.exists(package, room: room.id) { result.hasTexture = true }
            if room.keyframeCount > 0 { result.hasKeyframes = true }
            if fm.fileExists(atPath: MeshModelStore.measuredURL(package, room: room.id).path) {
                result.hasMesh = true
                let triangles = MeshModelStore.loadStats(package, room: room.id)?.triangleCount ?? 0
                result.meshTriangles = Swift.max(result.meshTriangles, triangles)
            }
            if CapturedRoomStore.hasFinalRoom(package, room: room) { result.hasCapturedRoom = true }
        }
        if fm.fileExists(atPath: package.cleanModelURL.path) {
            result.hasClean = ((try? CleanModelStore.loadBase(package))?.rooms.isEmpty == false)
        }
        if fm.fileExists(atPath: package.planModelURL.path), let plan = try? PlanModelStore.loadBase(package) {
            result.hasPlan = plan.levels.contains { !$0.rooms.isEmpty || !$0.walls.isEmpty }
        }
        result.hasEdits = !EditStore.load(package).active.isEmpty
        return result
    }

    /// `inputs(package:manifest:)` of a project id, nil when the project cannot be read. Any
    /// thread; call it off main.
    static func loadInputs(projectID: UUID) -> ExportInputs? {
        do {
            let package = try ProjectStore.package(for: projectID)
            let manifest = try ProjectStore.readManifest(package)
            return inputs(package: package, manifest: manifest)
        } catch {
            LogStore.shared.write("export: project \(projectID.uuidString) unreadable (\(ExportRunner.logDescription(error)))",
                                  category: ExportRunner.logCategory)
            return nil
        }
    }
}
