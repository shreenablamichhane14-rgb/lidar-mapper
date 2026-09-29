import Foundation
import RoomPlan

/// Size and modification time of the files each piece of content comes from, so the result
/// screen rebuilds only what changed ("-" before the first read).
struct ResultFileStamps: Equatable, Sendable {
    var clean = "-", plan = "-", edits = "-", quality = "-"
    var view = "-", inferred = "-", floaters = "-", texture = "-"

    /// Nothing read yet.
    init() {}
}

/// Everything the result screen reads from disk in one pass, off the main actor.
struct ResultLoadSnapshot: Sendable {
    /// The project's manifest and package.
    var manifest: ProjectManifest
    var package: ProjectPackage
    /// What exists on disk.
    var files: ResultFiles
    /// Raw truth of the capture streams (roomlog.json), with the RoomPlan override.
    var degraded: DegradedMode
    /// The edited clean model and plan, when their files exist and decode.
    var clean: CleanModel?
    var plan: PlanModel?
    /// Room titles for the plan drawing.
    var roomTitles: [ElementID: String]
    /// Capture evidence per `RoomRecord.id` (from quality.json).
    var evidence: [UUID: RoomEvidence]
    /// Missing areas of every room (from quality.json).
    var missingAreas: [MissingAreaRecord]
    /// Every dimension row of every room with walls.
    var rows: [DimensionRow]
    /// File stamps of the content sources.
    var stamps: ResultFileStamps
    /// PackageCheck problems (empty when not verified).
    var problems: [String]
}

/// What one tab's viewer content is built from: made on main, built off main.
struct ResultContentRequest: Sendable {
    /// The tab and the content key it was made for.
    var tab: ResultTab
    var key: String
    /// The effective display style (Realistic and Raw Scan).
    var style: ViewerDisplayStyle
    /// Where the meshes are.
    var package: ProjectPackage
    var roomIDs: [UUID]
    /// Realistic: load the textured mesh (else the view mesh in Solid Color or Wireframe).
    var useTexture: Bool
    /// 3D Clean: the edited clean model, the selection to highlight and cached base parts.
    var clean: CleanModel?
    var selection: ElementID?
    var cleanBase: [ViewerPart]?
    /// 3D Clean and Raw Scan: missing areas drawn as red squares.
    var missingAreas: [MissingAreaRecord]
}

/// Built viewer content plus the 3D Clean base parts (for highlight rebuilds).
struct ResultBuiltContent: Sendable {
    var content: ViewerContent
    var cleanBase: [ViewerPart]?
}

/// File reads and content builds of the result screen. Stateless; call from detached tasks.
enum ResultLoader {
    /// Log category of the Results module.
    static let logCategory = "results"
    /// Quick Look copy of RoomPlan's model: `exports/simple/SimpleModel.usdz` (starts with a letter).
    static let simpleFolderName = "simple", simpleFileName = "SimpleModel.usdz"

    // MARK: - Snapshot

    /// Reads the manifest and every file the screen shows. With `verify` it also runs
    /// `PackageCheck.verify` and marks the project `.needsAttention` when problems are found.
    /// `jobActive` tells whether a processing job is queued or running (the RoomPlan override
    /// applies only after the job finished). Nil when the manifest cannot be read.
    static func readSnapshot(projectID: UUID, verify: Bool, jobActive: Bool) -> ResultLoadSnapshot? {
        let package: ProjectPackage
        let manifest: ProjectManifest
        do {
            package = try ProjectStore.package(for: projectID)
            manifest = try ProjectStore.readManifest(package)
        } catch {
            LogStore.shared.write("project \(projectID): manifest unreadable (\(error))", category: logCategory)
            return nil
        }
        var problems: [String] = []
        if verify {
            problems = PackageCheck.verify(package, manifest: manifest)
            if !problems.isEmpty && manifest.status != .needsAttention {
                markNeedsAttention(package, problems: problems.count)
            }
        }
        var files = ResultFiles()
        let clean = loadClean(package)
        if let model = clean {
            let hasWalls = model.rooms.contains { !$0.walls.isEmpty }
            files.hasClean = hasWalls
            files.hasEmptyClean = !hasWalls
        }
        let plan = loadPlan(package)
        files.hasPlan = plan != nil

        let fm = FileManager.default
        var modes: [DegradedMode?] = []
        var evidence: [UUID: RoomEvidence] = [:]
        var missing: [MissingAreaRecord] = []
        var demoRooms = 0
        for room in manifest.rooms {
            let folder = CapturedRoomStore.rawFolder(package, room: room)
            modes.append(RawScanReader(folder: folder).roomLog()?.degraded)
            if fm.fileExists(atPath: MeshModelStore.viewURL(package, room: room.id).path) { files.hasMeshView = true }
            if TextureStore.exists(package, room: room.id) { files.hasTexture = true }
            let hasLive = fm.fileExists(atPath: folder.liveCapturedRoomURL.path)
            if CapturedRoomStore.hasFinalRoom(package, room: room) || hasLive { files.hasCapturedRoom = true }
            if isDemoRoom(folder) { demoRooms += 1 }
            if room.keyframeCount > 0 { files.hasKeyframes = true }
            if let evaluation = QualityStore.load(package, room: room.id) {
                evidence[room.id] = evaluation.evidence
                missing.append(contentsOf: evaluation.missingAreas)
            }
        }
        files.isDemo = !manifest.rooms.isEmpty && demoRooms == manifest.rooms.count
        var degraded = ResultAvailability.combinedDegraded(modes)
        let logSaysRoomPlanFailed: Bool = degraded == .roomPlanFailed
        let mayOverride: Bool = !jobActive && !files.hasClean && !files.isDemo
        if mayOverride && !logSaysRoomPlanFailed && !manifest.rooms.isEmpty {
            let loadable = manifest.rooms.contains { (try? CapturedRoomStore.loadInput(package, room: $0)) != nil }
            if !loadable {
                degraded = .roomPlanFailed
                LogStore.shared.write("project \(projectID): no room has a RoomPlan model; walls unavailable", category: logCategory)
            }
        }
        var titles: [ElementID: String] = [:]
        if let plan {
            titles = RoomTitles.titles(for: plan, clean: clean)
        } else if let clean {
            titles = RoomTitles.titles(for: clean)
        }
        return ResultLoadSnapshot(manifest: manifest, package: package, files: files, degraded: degraded, clean: clean,
                                  plan: plan, roomTitles: titles, evidence: evidence, missingAreas: missing,
                                  rows: dimensionRows(clean, evidence: evidence), stamps: stamps(package, manifest: manifest),
                                  problems: problems)
    }

    /// Rows of every room that has walls, in room order; ids get a room prefix when the model
    /// has several rooms, so they stay unique.
    static func dimensionRows(_ clean: CleanModel?, evidence: [UUID: RoomEvidence]) -> [DimensionRow] {
        guard let model = clean else { return [] }
        let multiple = model.rooms.count > 1
        var rows: [DimensionRow] = []
        for (index, room) in model.rooms.enumerated() where !room.walls.isEmpty {
            var roomRows = RoomDimensions.rows(for: room, evidence: evidence[room.recordID] ?? .unknown)
            if multiple {
                for k in roomRows.indices { roomRows[k].id = "r\(index)." + roomRows[k].id }
            }
            rows.append(contentsOf: roomRows)
        }
        return rows
    }

    /// True for a Demo Mode room: no RoomPlan file and no (or an empty) keyframe log.
    static func isDemoRoom(_ folder: RawScanFolder) -> Bool {
        let fm = FileManager.default
        let roomPlanFiles = [folder.capturedRoomDataURL, folder.capturedRoomURL, folder.liveCapturedRoomURL]
        if roomPlanFiles.contains(where: { fm.fileExists(atPath: $0.path) }) { return false }
        return fileSize(folder.keyframesLogURL) == 0
    }

    /// Size of a file in bytes, 0 when it does not exist.
    static func fileSize(_ url: URL) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return 0 }
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// "size@mtime" of each file ("none" when absent), joined by commas.
    static func stamp(_ urls: [URL]) -> String {
        let fm = FileManager.default
        return urls.map { url -> String in
            guard let attributes = try? fm.attributesOfItem(atPath: url.path) else { return "none" }
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return "\(size)@\(modified)"
        }.joined(separator: ",")
    }

    /// The stamps of every content source of the project.
    static func stamps(_ package: ProjectPackage, manifest: ProjectManifest) -> ResultFileStamps {
        let ids = manifest.rooms.map { $0.id }
        var result = ResultFileStamps()
        result.clean = stamp([package.cleanModelURL])
        result.plan = stamp([package.planModelURL])
        result.edits = stamp([package.editLogURL])
        result.quality = stamp(ids.map { QualityStore.url(package, room: $0) })
        result.view = stamp(ids.map { MeshModelStore.viewURL(package, room: $0) })
        result.inferred = stamp(ids.map { MeshModelStore.inferredURL(package, room: $0) })
        result.floaters = stamp(ids.map { MeshModelStore.floatersURL(package, room: $0) })
        result.texture = stamp(ids.flatMap { [TextureStore.uvURL(package, room: $0), TextureStore.meshURL(package, room: $0)] })
        return result
    }

    /// The edited clean model, nil when absent or unreadable (unreadable is logged).
    private static func loadClean(_ package: ProjectPackage) -> CleanModel? {
        guard FileManager.default.fileExists(atPath: package.cleanModelURL.path) else { return nil }
        do {
            return try CleanModelStore.loadEdited(package).model
        } catch {
            LogStore.shared.write("clean.json unreadable (\(error))", category: logCategory)
            return nil
        }
    }

    /// The edited plan, nil when absent or unreadable (unreadable is logged).
    private static func loadPlan(_ package: ProjectPackage) -> PlanModel? {
        guard FileManager.default.fileExists(atPath: package.planModelURL.path) else { return nil }
        do {
            return try PlanModelStore.loadEdited(package).plan
        } catch {
            LogStore.shared.write("plan.json unreadable (\(error))", category: logCategory)
            return nil
        }
    }

    /// Sets the project `.needsAttention` after PackageCheck found problems (logged).
    private static func markNeedsAttention(_ package: ProjectPackage, problems: Int) {
        do {
            try ManifestWriter.update(package) { manifest in
                manifest.status = .needsAttention
            }
            LogStore.shared.write("package check found \(problems) problems; project marked needsAttention", category: logCategory)
        } catch {
            LogStore.shared.write("could not mark project needsAttention (\(error))", category: logCategory)
        }
    }

    // MARK: - Content

    /// Builds the viewer content of one tab. Unreadable meshes are logged and left out.
    static func buildContent(_ request: ResultContentRequest) -> ResultBuiltContent {
        switch request.tab {
        case .clean:
            let base = request.cleanBase ?? request.clean.map { ResultContentBuilder.cleanParts($0) } ?? []
            var parts = base
            parts.append(contentsOf: ResultContentBuilder.missingAreaParts(request.missingAreas))
            if let selection = request.selection {
                parts.append(contentsOf: ResultContentBuilder.highlightParts(for: selection, in: base))
            }
            return ResultBuiltContent(content: ViewerContent(parts: parts), cleanBase: base)
        case .raw:
            var parts = rawParts(request)
            parts.append(contentsOf: ResultContentBuilder.missingAreaParts(request.missingAreas))
            return ResultBuiltContent(content: ViewerContent(parts: parts), cleanBase: nil)
        case .realistic:
            return ResultBuiltContent(content: ViewerContent(parts: realisticParts(request)), cleanBase: nil)
        case .floorPlan:
            return ResultBuiltContent(content: .empty, cleanBase: nil)
        }
    }

    /// Raw Scan: the view mesh (measured), the inferred hole fills and the floaters cleanup
    /// removed, per room, in the request's style with the class palette.
    private static func rawParts(_ request: ResultContentRequest) -> [ViewerPart] {
        var parts: [ViewerPart] = []
        for (index, room) in request.roomIDs.enumerated() {
            let prefix = "raw.r\(index)"
            let sources: [(name: String, layer: ViewerLayer, load: () throws -> MeshWithAttributes?)] = [
                ("view", .raw, { try MeshModelStore.loadView(request.package, room: room) }),
                ("inferred", .rawInferred, { try MeshModelStore.loadInferred(request.package, room: room) }),
                ("floaters", .raw, { try MeshModelStore.loadFloaters(request.package, room: room) }),
            ]
            for source in sources {
                guard let mesh = loadMesh(source.name, room: room, source.load) else { continue }
                parts.append(contentsOf: ViewerContentBuilder.meshParts(mesh, style: request.style, palette: MeshClassPalette.all,
                                                                        inferredColor: MeshClassPalette.inferred,
                                                                        layer: source.layer, idPrefix: prefix + "." + source.name))
            }
        }
        return parts
    }

    /// Realistic: the textured pages (plus untextured faces in gray); without a texture, or
    /// in Solid Color and Wireframe, the view mesh in that style.
    private static func realisticParts(_ request: ResultContentRequest) -> [ViewerPart] {
        var parts: [ViewerPart] = []
        if request.useTexture {
            for (index, room) in request.roomIDs.enumerated() {
                do {
                    if let mesh = try TextureStore.load(request.package, room: room) {
                        parts.append(contentsOf: ResultContentBuilder.texturedParts(mesh, idPrefix: "realistic.r\(index)"))
                    }
                } catch {
                    LogStore.shared.write("room \(room): texture unreadable (\(error)); showing Solid Color", category: logCategory)
                }
            }
            if !parts.isEmpty { return parts }
        }
        let style: ViewerDisplayStyle = request.style == .wireframe ? .wireframe : .solidColor
        for (index, room) in request.roomIDs.enumerated() {
            guard let view = loadMesh("view", room: room, { try MeshModelStore.loadView(request.package, room: room) }) else { continue }
            parts.append(contentsOf: ViewerContentBuilder.meshParts(view, style: style, palette: MeshClassPalette.all,
                                                                    inferredColor: MeshClassPalette.inferred,
                                                                    layer: .realistic, idPrefix: "realistic.r\(index).view"))
        }
        return parts
    }

    /// Runs a mesh loader; errors are logged and give nil.
    private static func loadMesh(_ name: String, room: UUID, _ load: () throws -> MeshWithAttributes?) -> MeshWithAttributes? {
        do {
            return try load()
        } catch {
            LogStore.shared.write("room \(room): \(name) mesh unreadable (\(error))", category: logCategory)
            return nil
        }
    }

    // MARK: - Simple model

    /// Exports RoomPlan's model of the first room that has one with
    /// `export(to:metadataURL:modelProvider:exportOptions: [.mesh])` into
    /// `exports/simple/SimpleModel.usdz` (replaced each time), through a temporary folder.
    /// Nil (logged) when no room has a model or the export fails.
    static func exportSimpleModel(projectID: UUID) -> URL? {
        let fm = FileManager.default
        do {
            let package = try ProjectStore.package(for: projectID)
            let manifest = try ProjectStore.readManifest(package)
            for room in manifest.rooms {
                let captured: CapturedRoom
                do {
                    captured = try CapturedRoomStore.loadCapturedRoom(package, room: room)
                } catch {
                    continue
                }
                let folder = package.exportsURL.appendingPathComponent(simpleFolderName, isDirectory: true)
                try ProjectStore.ensureDirectory(folder, inside: package.root)
                let staging = fm.temporaryDirectory.appendingPathComponent("ResultsSimple-" + UUID().uuidString, isDirectory: true)
                try fm.createDirectory(at: staging, withIntermediateDirectories: true)
                defer { try? fm.removeItem(at: staging) }
                let staged = staging.appendingPathComponent(simpleFileName, isDirectory: false)
                try captured.export(to: staged, metadataURL: nil, modelProvider: nil, exportOptions: [.mesh])
                let target = folder.appendingPathComponent(simpleFileName, isDirectory: false)
                if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                do {
                    try fm.moveItem(at: staged, to: target)
                } catch {
                    try fm.copyItem(at: staged, to: target)
                }
                try? fm.setAttributes([.protectionKey: FileProtectionType.completeUnlessOpen], ofItemAtPath: target.path)
                LogStore.shared.write("simple model exported for room \(room.id) (\(fileSize(target)) bytes)", category: logCategory)
                return target
            }
            LogStore.shared.write("simple model: no room has a RoomPlan model", category: logCategory)
            return nil
        } catch {
            LogStore.shared.write("simple model export failed (\(error))", category: logCategory)
            return nil
        }
    }
}
