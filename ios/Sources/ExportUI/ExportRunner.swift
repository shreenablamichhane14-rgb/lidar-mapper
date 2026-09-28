import Foundation

/// Runs one export off main: loads the edited models, applies the result screen's view state,
/// calls the Export writers and stages the file (or a zip for multi-file results) in
/// `exports/<yyyyMMdd-HHmmss>/` of the package (docs/MODULES.md 3.27, ARCHITECTURE 9). Never
/// writes outside `exports/`, never reads outside the package, never logs file contents.
enum ExportRunner {
    /// Log category of the module.
    static let logCategory = "export"
    /// Staging folder name format under `exports/`.
    static let stampFormat = "yyyyMMdd-HHmmss"
    /// Pixel width of PNG floor plans.
    static let pngPixelWidth = 3000

    /// Everything one export needs, gathered once.
    struct Job {
        /// What to write.
        var option: ExportOption
        /// Sheet options.
        var settings: ExportSettings
        /// The result screen's view state.
        var viewState: ExportViewState
        /// The project package.
        var package: ProjectPackage
        /// The project manifest.
        var manifest: ProjectManifest
        /// App unit preferences.
        var prefs: UnitPreferences
        /// Time of the export (file names, PDF date).
        var now: Date
        /// The staging folder.
        var folder: URL
        /// Output file name from `ExportCatalog.fileName`.
        var fileName: String
    }

    /// Off main. Writes into exports/<yyyyMMdd-HHmmss>/ and returns the file (or zip) URL.
    /// Cancelling the calling task stops the export at the next stage and removes its folder.
    static func run(_ option: ExportOption, settings: ExportSettings, viewState: ExportViewState, projectID: UUID,
                    package: ProjectPackage, prefs: UnitPreferences) async throws -> URL {
        let task = Task.detached(priority: .userInitiated) { () throws -> URL in
            try perform(option, settings: settings, viewState: viewState, projectID: projectID, package: package,
                        prefs: prefs, now: Date())
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// The synchronous export (any thread except main). A failure removes the staging folder
    /// and is logged without file contents or user text; the error is rethrown.
    static func perform(_ option: ExportOption, settings: ExportSettings, viewState: ExportViewState, projectID: UUID,
                        package: ProjectPackage, prefs: UnitPreferences, now: Date) throws -> URL {
        let started = ProcessInfo.processInfo.systemUptime
        do {
            let manifest = try ProjectStore.readManifest(package)
            guard manifest.id == projectID else { throw CoreError.corruptFile("project.json") }
            try checkCancelled()
            let folder = try makeStagingFolder(package, now: now)
            let name = ExportCatalog.fileName(project: manifest.name, option: option, date: now)
            let job = Job(option: option, settings: settings, viewState: viewState, package: package, manifest: manifest,
                          prefs: prefs, now: now, folder: folder, fileName: name)
            do {
                let url = try write(job)
                let milliseconds = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
                LogStore.shared.write("export \(option.id): \(fileSize(url)) bytes in \(milliseconds) ms, project \(projectID.uuidString)",
                                      category: logCategory)
                return url
            } catch {
                removeStagingFolder(folder)
                throw error
            }
        } catch {
            LogStore.shared.write("export \(option.id) failed for project \(projectID.uuidString): \(logDescription(error))",
                                  category: logCategory)
            throw error
        }
    }

    // MARK: - Writers per representation

    /// Dispatches to the representation's writer.
    static func write(_ job: Job) throws -> URL {
        switch job.option.representation {
        case .realistic: return try writeRealistic(job)
        case .clean: return try writeClean(job)
        case .raw: return try writeRaw(job)
        case .floorPlan: return try writePlan(job)
        case .data: return try writeData(job)
        }
    }

    /// Textured rooms (TextureStore) as USDZ, OBJ zip or GLB.
    private static func writeRealistic(_ job: Job) throws -> URL {
        var scenes: [ExportScene] = []
        for room in job.manifest.rooms {
            try checkCancelled()
            guard let mesh = try TextureStore.load(job.package, room: room.id) else { continue }
            scenes.append(try ExportAdapters.texturedScene(mesh, includeTextures: job.settings.includeTextures))
        }
        guard !scenes.isEmpty else { throw ExportError.emptyScene }
        return try writeScene(ExportAdapters.merged(scenes), job: job)
    }

    /// The edited clean model: RoomPlan's own USDZ when `usesRoomPlanUSDZ` allows it, else our
    /// writers on `cleanScene` (Hide Furniture follows the result screen).
    private static func writeClean(_ job: Job) throws -> URL {
        let model = try CleanModelStore.loadEdited(job.package).model
        try checkCancelled()
        if job.option.format == .usdz, let room = job.manifest.rooms.first {
            let hasHidden = model.rooms.contains { $0.objects.contains { $0.isHidden } }
            let native = usesRoomPlanUSDZ(roomCount: job.manifest.rooms.count,
                                          hasFinalCapturedRoom: CapturedRoomStore.hasFinalRoom(job.package, room: room),
                                          hasActiveEdits: !EditStore.load(job.package).active.isEmpty,
                                          keepsFurniture: job.manifest.settings.findFurniture,
                                          hideFurniture: job.viewState.hideFurniture,
                                          includeHidden: job.settings.includeHidden, hasHiddenObjects: hasHidden)
            if native {
                let url = job.folder.appendingPathComponent(job.fileName, isDirectory: false)
                let metadata = job.folder.appendingPathComponent(ExportCatalog.stem(of: job.fileName) + "_metadata.plist",
                                                                 isDirectory: false)
                if ExportAdapters.writeRoomPlanUSDZ(job.package, room: room, to: url, metadataURL: metadata) {
                    try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUnlessOpen],
                                                           ofItemAtPath: url.path)
                    return url
                }
            }
        }
        let scene = ExportAdapters.cleanScene(model, includeHidden: job.settings.includeHidden,
                                              includeMovable: !job.viewState.hideFurniture)
        return try writeScene(scene, job: job)
    }

    /// RoomPlan's own USDZ is used only when it shows exactly what the result screen shows: one
    /// room with a final CapturedRoom, no active edits, furniture detection on, and every object
    /// visible (Hide Furniture off and nothing hidden) unless Include hidden objects is on.
    static func usesRoomPlanUSDZ(roomCount: Int, hasFinalCapturedRoom: Bool, hasActiveEdits: Bool, keepsFurniture: Bool,
                                 hideFurniture: Bool, includeHidden: Bool, hasHiddenObjects: Bool) -> Bool {
        guard roomCount == 1, hasFinalCapturedRoom, !hasActiveEdits, keepsFurniture else { return false }
        return includeHidden || (!hideFurniture && !hasHiddenObjects)
    }

    /// The consolidated scan: text formats use the full mesh up to the limit, else the view mesh
    /// plus the inferred mesh; PLY, STL and GLB always use the full measured mesh.
    private static func writeRaw(_ job: Job) throws -> URL {
        let limit = ExportCatalog.isTextFormat(job.option.format) ? ExportCatalog.textTriangleLimit : Int.max
        var scenes: [ExportScene] = []
        let fm = FileManager.default
        for room in job.manifest.rooms where fm.fileExists(atPath: MeshModelStore.measuredURL(job.package, room: room.id).path) {
            try checkCancelled()
            scenes.append(try ExportAdapters.rawScene(job.package, room: room.id, maxTextTriangles: limit))
        }
        guard !scenes.isEmpty else { throw CoreError.missingFile(MeshModelStore.measuredFileName) }
        return try writeScene(ExportAdapters.merged(scenes), job: job)
    }

    /// Writes a 3D scene in the option's format: USDZ, OBJ (zipped with its MTL and textures),
    /// PLY, STL (millimeters, Z up) or GLB.
    private static func writeScene(_ source: ExportScene, job: Job) throws -> URL {
        var scene = source
        scene.metadata["project"] = job.manifest.name
        try checkCancelled()
        let stem = ExportCatalog.stem(of: job.fileName)
        switch job.option.format {
        case .usdz:
            return try save(try USDZWriter.data(for: scene, layerName: "\(stem).usda", modified: job.now), name: job.fileName, job: job)
        case .obj:
            let zip = try OBJWriter.zipBundle(for: scene, baseName: stem)
            return try save(zip, name: ExportCatalog.zipFileName(for: job.fileName), job: job)
        case .ply:
            return try save(try PLYWriter.data(for: scene), name: job.fileName, job: job)
        case .stl:
            return try save(try STLWriter.binary(for: scene, options: .printing), name: job.fileName, job: job)
        case .glb:
            return try save(try GLBWriter.data(for: scene), name: job.fileName, job: job)
        case .pdf, .svg, .dxf, .png, .json:
            throw ExportError.encodingFailed(format: job.option.format.rawValue)
        }
    }

    /// The edited plan with the export toggles and units: PDF (scale caption, north angle),
    /// SVG, DXF in millimeters with the units note, or a 3000 px PNG.
    private static func writePlan(_ job: Job) throws -> URL {
        let toggles = ExportAdapters.planToggles(viewState: job.viewState, settings: job.settings)
        let prefs = ExportAdapters.planPrefs(job.prefs, settings: job.settings)
        let drawing = try ExportAdapters.planExport(job.package, prefs: prefs, toggles: toggles,
                                                    includeHidden: job.settings.includeHidden)
        try checkCancelled()
        let data: Data
        switch job.option.format {
        case .pdf:
            let north: Double = Double.pi / 2 + Double(drawing.northAngle)
            let options = PDFPlanWriter.Options(paper: job.settings.paper, date: job.now, northAngle: north,
                                                scaleCaption: Copy.ExportUI.scaleCaption)
            data = try PDFPlanWriter.data(for: drawing.plan, options: options)
        case .svg:
            data = try SVGWriter.data(for: drawing.plan)
        case .dxf:
            data = try DXFWriter.data(for: drawing.plan, millimeters: true, unitsNote: Copy.ExportUI.dxfUnitsNote)
        case .png:
            guard let png = PlanRenderer.pngData(drawing.plan, pixelWidth: pngPixelWidth) else { throw ExportError.emptyPlan }
            data = png
        case .usdz, .obj, .ply, .stl, .glb, .json:
            throw ExportError.encodingFailed(format: job.option.format.rawValue)
        }
        return try save(data, name: job.fileName, job: job)
    }

    /// The summary JSON; zipped with each room's final `capturedroom.json` when one exists.
    private static func writeData(_ job: Job) throws -> URL {
        let model = try CleanModelStore.loadEdited(job.package).model
        var evidence: [UUID: RoomEvidence] = [:]
        for room in model.rooms {
            evidence[room.recordID] = QualityStore.load(job.package, room: room.recordID)?.evidence
        }
        let measurements = job.settings.includeMeasurements ? EditStore.loadMeasurements(job.package) : []
        let json = try ExportSummaryJSON.data(model: model, evidence: evidence, manifest: job.manifest,
                                              measurements: measurements)
        try checkCancelled()
        var entries: [(name: String, data: Data)] = [(name: job.fileName, data: json)]
        let rooms = job.manifest.rooms
        for (n, room) in rooms.enumerated() {
            guard let raw = capturedRoomJSON(job.package, room: room) else { continue }
            let name = rooms.count == 1 ? "capturedroom.json" : "capturedroom_room\(n + 1).json"
            entries.append((name: name, data: raw))
        }
        if entries.count == 1 { return try save(json, name: job.fileName, job: job) }
        let zip = try ZipWriter.archive(entries, modified: job.now)
        return try save(zip, name: ExportCatalog.zipFileName(for: job.fileName), job: job)
    }

    /// The bytes of a room's final RoomPlan JSON (raw first, then the rebuilt one), nil when
    /// neither exists or it is larger than RoomModel's cap. Never the provisional live file.
    static func capturedRoomJSON(_ package: ProjectPackage, room: RoomRecord) -> Data? {
        let candidates = [CapturedRoomStore.rawFolder(package, room: room).capturedRoomURL,
                          CapturedRoomStore.rebuiltURL(package, roomID: room.id)]
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            let size = fileSize(url)
            guard size > 0, size <= CapturedRoomStore.maxCapturedRoomBytes else { continue }
            if let data = try? Data(contentsOf: url) { return data }
        }
        return nil
    }

    /// Writes one output file into the staging folder (atomic, exports protection) and returns it.
    private static func save(_ data: Data, name: String, job: Job) throws -> URL {
        try checkCancelled()
        let url = job.folder.appendingPathComponent(name, isDirectory: false)
        try ProjectStore.writeData(data, to: url, createParents: false)
        return url
    }

    /// Throws `CancellationError` when the running task was cancelled.
    static func checkCancelled() throws {
        if Task.isCancelled { throw CancellationError() }
    }

    /// Size of a file in bytes, 0 when unreadable.
    static func fileSize(_ url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// A log-safe description of an error: the case name for Export errors (their payloads can
    /// hold file names made from the project name), Core and Mapper error keys, else the
    /// NSError domain and code. Never user text or file contents.
    static func logDescription(_ error: Error) -> String {
        switch error {
        case let exportError as ExportError:
            return "ExportError.\(exportErrorKey(exportError))"
        case let coreError as CoreError:
            switch coreError {
            case .corruptFile(let what): return "CoreError.corruptFile(\(what))"
            case .missingFile(let what): return "CoreError.missingFile(\(what))"
            case .unsupportedSchema(let version): return "CoreError.unsupportedSchema(\(version))"
            case .fileTooLarge(let name, let bytes): return "CoreError.fileTooLarge(\(name), \(bytes))"
            }
        case let mapperError as MapperError:
            return mapperError.copyKey
        case is CancellationError:
            return "cancelled"
        default:
            let ns = error as NSError
            return "\(ns.domain) \(ns.code)"
        }
    }

    /// The case name of an Export error, without its payload.
    static func exportErrorKey(_ error: ExportError) -> String {
        switch error {
        case .indexCountNotMultipleOfThree: return "indexCountNotMultipleOfThree"
        case .indexOutOfRange: return "indexOutOfRange"
        case .attributeCountMismatch: return "attributeCountMismatch"
        case .invalidMaterialIndex: return "invalidMaterialIndex"
        case .nonFiniteValue: return "nonFiniteValue"
        case .emptyScene: return "emptyScene"
        case .emptyPlan: return "emptyPlan"
        case .tooLarge: return "tooLarge"
        case .invalidArchiveEntry: return "invalidArchiveEntry"
        case .encodingFailed: return "encodingFailed"
        case .writeFailed: return "writeFailed"
        }
    }
}
