import Foundation

/// Runs one export off main: loads the edited models, applies the result screen's view state,
/// calls the Export writers and stages the file (or a zip for multi-file results) in
/// `exports/<yyyyMMdd-HHmmss>/` of the package (docs/MODULES.md 3.27 and 3.43d, ARCHITECTURE 9).
/// Never writes outside `exports/`, never reads outside the package, never logs file contents.
/// Build 5 adds House, Object and Quick Measure outputs (`ExportRunner+Kinds.swift`), multi-floor
/// plans and progress.
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
        /// Progress sink (0...1), called on the export's thread.
        var report: (Double) -> Void = { _ in }
        /// Cancellation probe; the running task's `Task.isCancelled` unless a test injects one.
        var cancelled: () -> Bool = { Task.isCancelled }

        /// Reports `value` clamped to 0...1.
        func progress(_ value: Double) {
            report(Swift.min(1, Swift.max(0, value.isFinite ? value : 0)))
        }

        /// Throws `CancellationError` when the export was cancelled.
        func checkCancelled() throws {
            if cancelled() { throw CancellationError() }
        }

        /// Progress of step `n` of `count` inside the build stage (0.1 to 0.7).
        func buildProgress(_ n: Int, of count: Int) {
            let fraction = count > 0 ? Double(n) / Double(count) : 0
            progress(0.1 + 0.6 * fraction)
        }
    }

    /// As build 4 plus `progress` (0...1, called on main at each stage: load, build, write, zip;
    /// the default ignores it, so build 4 call sites compile). Writes into exports/<yyyyMMdd-HHmmss>/
    /// and returns the file (or zip) URL. Cancelling the calling task stops the export at the next
    /// stage (between rooms and between plan levels too), removes its staging folder and throws
    /// `CancellationError`.
    static func run(_ option: ExportOption, settings: ExportSettings, viewState: ExportViewState, projectID: UUID,
                    package: ProjectPackage, prefs: UnitPreferences,
                    progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        let task = Task.detached(priority: .userInitiated) { () throws -> URL in
            try ExportRunner.perform(option, settings: settings, viewState: viewState, projectID: projectID,
                                     package: package, prefs: prefs, now: Date(),
                                     progress: { value in DispatchQueue.main.async { progress(value) } })
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// The synchronous export (any thread except main). A failure or a cancellation removes the
    /// staging folder and is logged without file contents or user text; the error is rethrown.
    /// `progress` receives 0...1 on this thread; `isCancelled` defaults to the running task's
    /// cancellation (the self-test injects its own).
    static func perform(_ option: ExportOption, settings: ExportSettings, viewState: ExportViewState, projectID: UUID,
                        package: ProjectPackage, prefs: UnitPreferences, now: Date,
                        progress: @escaping (Double) -> Void = { _ in },
                        isCancelled: @escaping () -> Bool = { Task.isCancelled }) throws -> URL {
        let started = ProcessInfo.processInfo.systemUptime
        do {
            let manifest = try ProjectStore.readManifest(package)
            guard manifest.id == projectID else { throw CoreError.corruptFile("project.json") }
            if isCancelled() { throw CancellationError() }
            let folder = try makeStagingFolder(package, now: now)
            let name = ExportCatalog.fileName(project: manifest.name, option: option, date: now)
            var job = Job(option: option, settings: settings, viewState: viewState, package: package, manifest: manifest,
                          prefs: prefs, now: now, folder: folder, fileName: name)
            job.report = progress
            job.cancelled = isCancelled
            job.progress(0.05)
            do {
                let url = try write(job)
                try job.checkCancelled()
                job.progress(1)
                let milliseconds = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
                LogStore.shared.write("export \(option.id) (\(manifest.kind.rawValue)): \(fileSize(url)) bytes in \(milliseconds) ms, project \(projectID.uuidString)",
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

    /// Dispatches to the representation's writer, by project kind where they differ.
    static func write(_ job: Job) throws -> URL {
        let house = job.manifest.kind == .house
        switch job.option.representation {
        case .realistic: return house ? try writeHouseRealistic(job) : try writeRealistic(job)
        case .clean: return try writeClean(job)
        case .raw: return house ? try writeHouseRaw(job) : try writeRaw(job)
        case .floorPlan: return try writePlan(job)
        case .data: return try writeData(job)
        case .object: return try writeObject(job)
        }
    }

    /// Textured rooms (TextureStore) as USDZ, OBJ zip or GLB (Room and Advanced Space projects).
    private static func writeRealistic(_ job: Job) throws -> URL {
        var scenes: [ExportScene] = []
        let rooms = ExportCatalog.exportRooms(job.manifest)
        for (n, room) in rooms.enumerated() {
            try job.checkCancelled()
            job.buildProgress(n, of: rooms.count)
            guard let mesh = try TextureStore.load(job.package, room: room.id) else { continue }
            scenes.append(try ExportAdapters.texturedScene(mesh, includeTextures: job.settings.includeTextures))
        }
        guard !scenes.isEmpty else { throw ExportError.emptyScene }
        return try writeScene(ExportAdapters.merged(scenes), job: job)
    }

    /// The edited clean model: RoomPlan's own USDZ (a room's `CapturedRoom`, or a House's merged
    /// `CapturedStructure`) when it shows what the result screen shows, else our writers on
    /// `cleanScene` (Hide Furniture follows the result screen; House projects use the edited
    /// House clean model).
    private static func writeClean(_ job: Job) throws -> URL {
        let model = try CleanModelStore.loadEdited(job.package).model
        try job.checkCancelled()
        job.progress(0.3)
        if job.option.format == .usdz, let url = try nativeCleanUSDZ(job, model: model) {
            return url
        }
        let scene = ExportAdapters.cleanScene(model, includeHidden: job.settings.includeHidden,
                                              includeMovable: !job.viewState.hideFurniture)
        return try writeScene(scene, job: job)
    }

    /// RoomPlan's USDZ of the project when `usesRoomPlanUSDZ` allows it: a House's structure
    /// (`ExportHouse.structureUSDZ`, which checks the merge and the edits itself), or the only
    /// room's `CapturedRoom`. Nil when our writer must be used.
    private static func nativeCleanUSDZ(_ job: Job, model: CleanModel) throws -> URL? {
        let hasHidden = model.rooms.contains { $0.objects.contains { $0.isHidden } }
        let rooms = ExportCatalog.exportRooms(job.manifest)
        if job.manifest.kind == .house {
            let native = usesRoomPlanUSDZ(roomCount: 1, hasFinalCapturedRoom: true, hasActiveEdits: false,
                                          keepsFurniture: job.manifest.settings.findFurniture,
                                          hideFurniture: job.viewState.hideFurniture,
                                          includeHidden: job.settings.includeHidden, hasHiddenObjects: hasHidden)
            guard native else { return nil }
            return try ExportHouse.structureUSDZ(job.package, into: job.folder, fileName: job.fileName)
        }
        guard let room = rooms.first else { return nil }
        let native = usesRoomPlanUSDZ(roomCount: rooms.count,
                                      hasFinalCapturedRoom: CapturedRoomStore.hasFinalRoom(job.package, room: room),
                                      hasActiveEdits: !EditStore.load(job.package).active.isEmpty,
                                      keepsFurniture: job.manifest.settings.findFurniture,
                                      hideFurniture: job.viewState.hideFurniture,
                                      includeHidden: job.settings.includeHidden, hasHiddenObjects: hasHidden)
        guard native else { return nil }
        let url = job.folder.appendingPathComponent(job.fileName, isDirectory: false)
        let metadata = job.folder.appendingPathComponent(ExportCatalog.stem(of: job.fileName) + "_metadata.plist",
                                                         isDirectory: false)
        guard ExportAdapters.writeRoomPlanUSDZ(job.package, room: room, to: url, metadataURL: metadata) else { return nil }
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUnlessOpen], ofItemAtPath: url.path)
        return url
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
        let rooms = ExportCatalog.exportRooms(job.manifest).filter { room in
            fm.fileExists(atPath: MeshModelStore.measuredURL(job.package, room: room.id).path)
        }
        for (n, room) in rooms.enumerated() {
            try job.checkCancelled()
            job.buildProgress(n, of: rooms.count)
            scenes.append(try ExportAdapters.rawScene(job.package, room: room.id, maxTextTriangles: limit))
        }
        guard !scenes.isEmpty else { throw CoreError.missingFile(MeshModelStore.measuredFileName) }
        return try writeScene(ExportAdapters.merged(scenes), job: job)
    }

    /// Writes a 3D scene in the option's format: USDZ, OBJ (zipped with its MTL and textures),
    /// PLY, STL (millimeters, Z up) or GLB.
    static func writeScene(_ source: ExportScene, job: Job) throws -> URL {
        var scene = source
        scene.metadata["project"] = job.manifest.name
        try job.checkCancelled()
        job.progress(0.75)
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
    static func save(_ data: Data, name: String, job: Job) throws -> URL {
        try job.checkCancelled()
        job.progress(0.95)
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
