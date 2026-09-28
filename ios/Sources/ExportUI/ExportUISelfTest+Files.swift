import Foundation

/// ExportUI self-test checks that need JSON parsing or files: the summary JSON, the textured
/// scene, and a temporary package for inputs, raw scenes, plan loading, end-to-end exports and
/// staging cleanup. Everything lives in one folder under the temporary directory, removed at the end.
extension ExportUISelfTest {
    // MARK: - Summary JSON

    /// The summary parses with JSONSerialization and has rooms[0].metrics.floorArea, walls,
    /// openings, objects, quality and saved measurements.
    static func summaryChecks(_ log: inout ExportUISelfTestLog) {
        typealias F = ExportUISelfTestFixtures
        let model = F.demoModel()
        var manifest = ProjectManifest.new(kind: .room, name: "Demo", now: F.date)
        manifest.id = F.projectID
        let session = F.uuid(902)
        let quality = QualitySummary(shape: 0.9, walls: 0.95, floor: 0.9, ceiling: 0.8, texture: 0.7, missingAreas: 1)
        manifest.rooms = [RoomRecord(id: F.roomID.uuid, name: "", sessionID: session, floorIndex: 0, status: .processed,
                                     capturedRoomID: nil, quality: quality, hasMeshPass: false, keyframeCount: 10,
                                     capturedAt: F.date, frameLink: .projectFrame(sessionID: session))]
        let measurement = MeasurementRecord(id: F.uuid(950), kind: .distance,
                                            points: [Vec3(x: 0, y: 0, z: 0), Vec3(x: 1, y: 0, z: 0)], snaps: [.corner, .corner],
                                            result: MeasuredValue(value: 1, sigma: 0.01, provenance: .measured),
                                            source: .viewer, name: "Test", roomID: nil, createdAt: F.date)
        do {
            let data = try ExportSummaryJSON.data(model: model, evidence: [:], manifest: manifest, measurements: [measurement])
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let rooms = root?["rooms"] as? [[String: Any]]
            let room = rooms?.first
            let metrics = room?["metrics"] as? [String: Any]
            let floorArea = metrics?["floorArea"] as? [String: Any]
            let value = (floorArea?["value"] as? NSNumber)?.doubleValue
            log.expect("summary.floorArea", value.map { abs($0 - 20) < 0.01 } ?? false, "got \(String(describing: value))")
            let keys = ["length", "width", "perimeter", "ceilingHeight", "wallArea", "volume"]
            log.expect("summary.metricKeys", keys.allSatisfy { metrics?[$0] != nil })
            log.expect("summary.provenance", floorArea?["provenance"] as? String != nil)
            log.expect("summary.format", root?["format"] as? String == ExportSummaryJSON.formatName)
            log.expect("summary.walls", (room?["walls"] as? [[String: Any]])?.count == 4)
            log.expect("summary.openings", (room?["openings"] as? [[String: Any]])?.count == 2)
            let objects = room?["objects"] as? [[String: Any]] ?? []
            let hiddenFlags = objects.compactMap { $0["isHidden"] as? Bool }
            log.expect("summary.objects", objects.count == 3 && hiddenFlags.filter { $0 }.count == 1)
            let verdict = (room?["quality"] as? [String: Any])?["verdict"] as? String
            log.expect("summary.quality", verdict == QualityVerdict.okay.rawValue, "got \(verdict ?? "nil")")
            log.expect("summary.measurements", (root?["measurements"] as? [[String: Any]])?.count == 1)
            log.expect("summary.title", room?["title"] as? String == Copy.FloorPlan.sectionKitchen)
        } catch {
            log.fail("summary.parses", error)
        }
        var broken = model
        broken.rooms[0].walls[0].thickness = .infinity
        broken.rooms[0].objects[0].dimensions = Vec3(x: .nan, y: 0.8, z: 0.9)
        do {
            let data = try ExportSummaryJSON.data(model: broken, evidence: [:], manifest: manifest)
            log.expect("summary.nonFiniteSafe", (try? JSONSerialization.jsonObject(with: data)) != nil)
        } catch {
            log.fail("summary.nonFiniteSafe", error)
        }
    }

    // MARK: - Files

    /// Textured scene, package inputs, raw scenes, plan loading, end-to-end exports and cleanup.
    static func fileChecks(_ log: inout ExportUISelfTestLog) {
        let folder: URL
        do {
            folder = try ExportUISelfTestFixtures.scratchFolder()
        } catch {
            log.fail("files.scratchFolder", error)
            return
        }
        defer { try? FileManager.default.removeItem(at: folder) }
        texturedChecks(&log, folder: folder)
        do {
            let made = try ExportUISelfTestFixtures.makePackage(in: folder)
            packageChecks(&log, package: made.package, manifest: made.manifest)
            runnerChecks(&log, package: made.package)
        } catch {
            log.fail("files.package", error)
        }
    }

    /// A 2-face textured mesh gives one material with JPEG data and unchanged bottom-left
    /// texture coordinates; without textures the material is plain.
    private static func texturedChecks(_ log: inout ExportUISelfTestLog, folder: URL) {
        let pageURL = folder.appendingPathComponent("page_0.jpg", isDirectory: false)
        do {
            try ExportUISelfTestFixtures.jpegBytes.write(to: pageURL)
            let quad = ExportUISelfTestFixtures.texturedQuad(pageURL: pageURL)
            let scene = try ExportAdapters.texturedScene(quad)
            log.expect("textured.oneMaterial", scene.materials.count == 1 && scene.meshes.count == 1)
            let prefix = scene.materials.first?.textureJPEG?.prefix(2)
            log.expect("textured.jpegData", prefix == Data([0xFF, 0xD8]))
            log.expect("textured.texcoordsUnchanged", scene.meshes.first?.texcoords == quad.texcoords)
            log.expect("textured.twoFaces", scene.meshes.first?.triangleCount == 2)
            try scene.validate()
            let plain = try ExportAdapters.texturedScene(quad, includeTextures: false)
            log.expect("textured.withoutTextures", plain.materials.first?.hasTexture == false)
        } catch {
            log.fail("textured.scene", error)
        }
    }

    /// Inputs from disk, raw scene full and simplified, and the plan drawn from the package.
    private static func packageChecks(_ log: inout ExportUISelfTestLog, package: ProjectPackage, manifest: ProjectManifest) {
        typealias F = ExportUISelfTestFixtures
        let inputs = ExportCatalog.inputs(package: package, manifest: manifest)
        let present: Bool = inputs.hasClean && inputs.hasPlan && inputs.hasMesh
        let absent: Bool = !inputs.hasTexture && !inputs.hasKeyframes && !inputs.hasCapturedRoom && !inputs.hasEdits
        log.expect("inputs.fromDisk", present && absent, "\(inputs)")
        log.expect("inputs.meshTriangles", inputs.meshTriangles == 8, "got \(inputs.meshTriangles)")
        let room = F.roomID.uuid
        do {
            let full = try ExportAdapters.rawScene(package, room: room, maxTextTriangles: ExportCatalog.textTriangleLimit)
            log.expect("raw.fullMesh", full.meshes.first?.triangleCount == 8 && full.metadata["note"] == nil)
            log.expect("raw.inferredSeparate", full.meshes.count == 2 && full.meshes.last?.name == MeshExportAdapter.inferredName)
            log.expect("raw.classColors", full.meshes.first?.colors != nil)
            let view = try ExportAdapters.rawScene(package, room: room, maxTextTriangles: 4)
            let viewTriangles: Int = view.meshes.first?.triangleCount ?? -1
            let viewNote: String = view.metadata["note"] ?? ""
            log.expect("raw.viewAboveLimit", viewTriangles == 2 && viewNote == Copy.ExportUI.simplifiedNote
                       && view.meshes.count == 2)
        } catch {
            log.fail("raw.scene", error)
        }
        let limit = ExportCatalog.textTriangleLimit
        log.expect("raw.threshold", ExportAdapters.rawSource(measuredTriangles: limit + 1, maxTextTriangles: limit) == .view
                   && ExportAdapters.rawSource(measuredTriangles: limit, maxTextTriangles: limit) == .full)
        var off = PlanToggles.standard
        off.furniture = false
        do {
            let drawing = try ExportAdapters.planDrawing(package, prefs: .standard, toggles: off)
            log.expect("plan.fromPackage", !drawing.entities.isEmpty && drawing.name == manifest.name
                       && F.count(drawing, layer: PlanLayers.furniture) == 0)
        } catch {
            log.fail("plan.fromPackage", error)
        }
    }

    /// End-to-end exports into `exports/<stamp>/`, a failing export leaving nothing behind,
    /// share cleanup and stale staging removal (Results' `exports/simple/` kept).
    private static func runnerChecks(_ log: inout ExportUISelfTestLog, package: ProjectPackage) {
        typealias F = ExportUISelfTestFixtures
        /// One export of the temporary package with default settings at the fixed date.
        func export(_ representation: ExportRepresentation, _ format: ExportFileFormat) throws -> URL {
            try ExportRunner.perform(option(representation, format), settings: ExportSettings(), viewState: .standard,
                                     projectID: F.projectID, package: package, prefs: .standard, now: F.date)
        }
        /// The first `count` bytes of a file as text (empty when unreadable).
        func head(_ url: URL, _ count: Int) -> String {
            let data = (try? Data(contentsOf: url)) ?? Data()
            return String(decoding: data.prefix(count), as: UTF8.self)
        }
        var urls: [URL] = []
        do {
            let dxf = try export(.floorPlan, .dxf)
            urls.append(dxf)
            let name = dxf.lastPathComponent
            log.expect("run.dxfName", name.hasPrefix("Mapper_3rd_floor_Floor_Plan_") && name.hasSuffix("_mm.dxf"), name)
            let staging = dxf.deletingLastPathComponent()
            log.expect("run.staged", staging.deletingLastPathComponent().lastPathComponent == "exports"
                       && staging.lastPathComponent == ExportRunner.stagingName(for: F.date), staging.lastPathComponent)
            let text = String(decoding: (try? Data(contentsOf: dxf)) ?? Data(), as: UTF8.self)
            log.expect("run.dxfUnitsNote", text.contains(Copy.ExportUI.dxfUnitsNote))
            let json = try export(.data, .json)
            urls.append(json)
            let parsed = (try? JSONSerialization.jsonObject(with: Data(contentsOf: json))) as? [String: Any]
            log.expect("run.json", json.pathExtension == "json" && (parsed?["rooms"] as? [Any])?.count == 1)
            let ply = try export(.raw, .ply)
            urls.append(ply)
            log.expect("run.ply", head(ply, 3) == "ply")
            let usdz = try export(.clean, .usdz)
            urls.append(usdz)
            log.expect("run.cleanUSDZ", head(usdz, 2) == "PK" && usdz.pathExtension == "usdz")
            let obj = try export(.raw, .obj)
            urls.append(obj)
            log.expect("run.objZip", head(obj, 2) == "PK" && obj.lastPathComponent.hasSuffix("_obj.zip"), obj.lastPathComponent)
            let stl = try export(.raw, .stl)
            urls.append(stl)
            log.expect("run.stl", ExportRunner.fileSize(stl) == 84 + 50 * 9, "got \(ExportRunner.fileSize(stl))")
            let pdf = try export(.floorPlan, .pdf)
            urls.append(pdf)
            log.expect("run.pdf", head(pdf, 4) == "%PDF")
        } catch {
            log.fail("run.export", error)
        }
        let folders = Set(urls.map { $0.deletingLastPathComponent().lastPathComponent })
        log.expect("run.uniqueFolders", folders.count == urls.count, "\(folders.count) of \(urls.count)")

        let before = stagingFolders(package)
        do {
            _ = try export(.realistic, .usdz)
            log.expect("run.realisticNeedsTexture", false)
        } catch {
            log.expect("run.realisticNeedsTexture", true)
        }
        log.expect("run.failureLeavesNothing", stagingFolders(package) == before)

        if let first = urls.first {
            let staging = first.deletingLastPathComponent()
            ExportRunner.removeStagingFolder(staging)
            log.expect("share.folderRemoved", !FileManager.default.fileExists(atPath: staging.path))
        }
        ExportRunner.removeStagingFolder(package.root)
        log.expect("share.refusesOtherFolders", FileManager.default.fileExists(atPath: package.root.path))

        let simple = package.exportsURL.appendingPathComponent("simple", isDirectory: true)
        try? FileManager.default.createDirectory(at: simple, withIntermediateDirectories: true)
        let removed = ExportRunner.removeStaleStaging(inExports: package.exportsURL, olderThan: 86_400,
                                                      now: F.date.addingTimeInterval(2 * 86_400))
        let alreadyRemoved: Int = urls.isEmpty ? 0 : 1
        let expectedRemoved: Int = before.count - alreadyRemoved
        let noneLeft: Bool = stagingFolders(package).isEmpty
        log.expect("staging.staleRemoved", removed == expectedRemoved && noneLeft, "removed \(removed)")
        log.expect("staging.simpleKept", FileManager.default.fileExists(atPath: simple.path))
    }

    /// Names of the staging folders in the package's `exports/`.
    private static func stagingFolders(_ package: ProjectPackage) -> Set<String> {
        let children = (try? FileManager.default.contentsOfDirectory(atPath: package.exportsURL.path)) ?? []
        return Set(children.filter { ExportRunner.stagingDate(folderName: $0) != nil })
    }
}
