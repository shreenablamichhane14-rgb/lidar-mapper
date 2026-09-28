import Foundation
import RoomPlan
import ModelIO

/// One saved scan on disk: Documents/Projects/<folder>/ with room.usdz, report.json,
/// floorplan.pdf, floorplan.dxf and floorplan.svg. Files are never modified after saving.
struct SavedProject: Identifiable, Hashable {
    let folder: URL
    let report: RoomReport
    var id: String { folder.lastPathComponent }

    var modelURL: URL { folder.appendingPathComponent("room.usdz") }
    var pdfURL: URL { folder.appendingPathComponent("floorplan.pdf") }
    var dxfURL: URL { folder.appendingPathComponent("floorplan.dxf") }
    var svgURL: URL { folder.appendingPathComponent("floorplan.svg") }
    var objectModelURL: URL { folder.appendingPathComponent("object.usdz") }
    var objectCleanModelURL: URL { folder.appendingPathComponent("object-clean.usdz") }
    /// The cleaned model when it exists, else Apple's original.
    var objectViewURL: URL {
        FileManager.default.fileExists(atPath: objectCleanModelURL.path) ? objectCleanModelURL : objectModelURL
    }

    static func == (lhs: SavedProject, rhs: SavedProject) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Saves and lists projects in the app's Documents folder (visible in the Files app).
enum ProjectStore {
    static var root: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Projects", isDirectory: true)
    }

    /// Writes the model, report and floor plan files. Each file is written atomically.
    static func save(room: CapturedRoom) throws -> SavedProject {
        let date = Date()
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd HHmmss"
        let title = DateFormatter()
        title.dateStyle = .medium
        title.timeStyle = .short
        let name = "Room \(title.string(from: date))"
        let folder = root.appendingPathComponent("\(stamp.string(from: date)) Room", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let report = RoomReport(room: room, name: name, date: date)
        let project = SavedProject(folder: folder, report: report)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        try encoder.encode(report).write(to: folder.appendingPathComponent("report.json"), options: .atomic)

        do {
            try room.export(to: project.modelURL, exportOptions: .parametric)
        } catch {
            LogStore.shared.write("USDZ export failed: \(error.localizedDescription)", category: "project")
        }

        let plan = report.plan(prefs: UnitPreferences.load())
        for (url, make) in [(project.pdfURL, { try PDFPlanWriter.data(for: plan) }),
                            (project.dxfURL, { try DXFWriter.data(for: plan) }),
                            (project.svgURL, { try SVGWriter.data(for: plan) })] as [(URL, () throws -> Data)] {
            do {
                try make().write(to: url, options: .atomic)
            } catch {
                LogStore.shared.write("floor plan export failed for \(url.lastPathComponent): \(error.localizedDescription)", category: "project")
            }
        }
        LogStore.shared.write("saved project \(folder.lastPathComponent): walls \(report.walls.count), area \(report.floorArea ?? -1)", category: "project")
        return project
    }

    /// Saves an object scan whose photos and model are already in `folder`: measures the
    /// model's bounding box, writes OBJ and STL copies (best effort) and report.json.
    static func saveObject(folder: URL, modelURL: URL) throws -> SavedProject {
        var size: [Double]
        var notes: [String] = []
        if let polished = ObjectPolish.polish(modelURL: modelURL, folder: folder) {
            size = [polished.width, polished.height, polished.depth]
            if polished.removedTriangles > 0 {
                notes.append("Removed \(polished.removedTriangles) stray surface triangles (reflections or background) so the size is measured on the object only.")
            }
        } else {
            let box = MDLAsset(url: modelURL).boundingBox
            let extent = box.maxBounds - box.minBounds
            size = [Double(extent.x), Double(extent.y), Double(extent.z)]
            notes.append("Automatic cleanup was not possible; the size includes everything in the model.")
        }
        let title = DateFormatter()
        title.dateStyle = .medium
        title.timeStyle = .short
        let date = Date()
        var report = RoomReport(objectName: "Object \(title.string(from: date))", date: date, size: size)
        report.notes = notes
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        try encoder.encode(report).write(to: folder.appendingPathComponent("report.json"), options: .atomic)
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("Checkpoint", isDirectory: true))
        if (size.max() ?? 0) > 1.0 {
            report.notes = (report.notes ?? []) + ["This model is larger than 1 m, so part of the table or room was probably included. Use a plain background and keep the object in the middle."]
            try encoder.encode(report).write(to: folder.appendingPathComponent("report.json"), options: .atomic)
        }
        LogStore.shared.write("saved object \(folder.lastPathComponent): size \(size)", category: "project")
        return SavedProject(folder: folder, report: report)
    }

    /// All saved projects, newest first. Folders without a readable report are skipped.
    static func list() -> [SavedProject] {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("report.json")),
                  let report = try? decoder.decode(RoomReport.self, from: data) else { return nil }
            return SavedProject(folder: folder, report: report)
        }
        .sorted { $0.report.date > $1.report.date }
    }

    /// Moves a project folder to the app's trash folder instead of deleting it outright.
    static func archive(_ project: SavedProject) {
        let trash = root.deletingLastPathComponent().appendingPathComponent("Archived", isDirectory: true)
        try? FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try? FileManager.default.moveItem(at: project.folder, to: trash.appendingPathComponent(project.folder.lastPathComponent))
    }
}
