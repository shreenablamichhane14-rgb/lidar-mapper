import Foundation
import simd

/// Build 5 ExportUI checks on temporary packages (docs/MODULES.md 3.43d): a House with a
/// superseded room and two plan levels, an Object project with a large object, and a Quick
/// Measure project. Everything lives in one folder under the temporary directory, removed at the end.
extension ExportUISelfTest {
    /// Creates the scratch folder and runs the package checks of every build 5 kind.
    static func b5FileChecks(_ log: inout ExportUISelfTestLog) {
        typealias F = ExportUISelfTestFixtures
        let folder: URL
        do {
            folder = try F.scratchFolderB5()
        } catch {
            log.fail("b5.files.scratchFolder", error)
            return
        }
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            let house = try F.makeHousePackage(in: folder)
            b5HouseChecks(&log, package: house.package, manifest: house.manifest)
            b5HouseRunnerChecks(&log, package: house.package, manifest: house.manifest)
        } catch {
            log.fail("b5.files.housePackage", error)
        }
        do {
            let object = try F.makeObjectPackage(in: folder)
            b5ObjectChecks(&log, package: object.package, manifest: object.manifest, folder: folder)
        } catch {
            log.fail("b5.files.objectPackage", error)
        }
        do {
            let quick = try F.makeQuickMeasurePackage(in: folder)
            b5QuickChecks(&log, package: quick.package, manifest: quick.manifest)
        } catch {
            log.fail("b5.files.quickPackage", error)
        }
    }

    /// One export of a temporary package with default settings at the fixed date.
    static func b5Export(_ package: ProjectPackage, manifest: ProjectManifest, _ representation: ExportRepresentation,
                         _ format: ExportFileFormat) throws -> URL {
        try ExportRunner.perform(option(representation, format), settings: ExportSettings(), viewState: .standard,
                                 projectID: manifest.id, package: package, prefs: .standard,
                                 now: ExportUISelfTestFixtures.date)
    }

    /// The first `count` bytes of a file as text (empty when unreadable).
    static func b5Head(_ url: URL, _ count: Int) -> String {
        let data = (try? Data(contentsOf: url)) ?? Data()
        return String(decoding: data.prefix(count), as: UTF8.self)
    }

    /// Names of the staging folders in a package's `exports/`.
    static func b5StagingFolders(_ package: ProjectPackage) -> Set<String> {
        let children = (try? FileManager.default.contentsOfDirectory(atPath: package.exportsURL.path)) ?? []
        return Set(children.filter { ExportRunner.stagingDate(folderName: $0) != nil })
    }

    // MARK: - House

    /// Inputs of the House, the superseded room left out of the raw scene, and placement by an
    /// alignment record.
    private static func b5HouseChecks(_ log: inout ExportUISelfTestLog, package: ProjectPackage, manifest: ProjectManifest) {
        typealias F = ExportUISelfTestFixtures
        let inputs = ExportCatalog.inputs(package: package, manifest: manifest)
        let shapeOK: Bool = inputs.kind == .house && inputs.levelCount == 2 && inputs.hasMesh && inputs.hasPlan
        let houseOK: Bool = inputs.roomTriangles == [8] && !inputs.structureExportable && !inputs.allRoomsTextured
        log.expect("b5.house.inputs", shapeOK && houseOK, "\(inputs)")
        log.expect("b5.house.exportRooms", ExportCatalog.exportRooms(manifest).map { $0.id } == [F.roomID.uuid])
        do {
            let scene = try ExportHouse.rawScene(package, manifest: manifest, alignments: [:],
                                                 maxTextTriangles: ExportCatalog.textTriangleLimit)
            let first = scene.meshes.first
            let nameOK: Bool = first?.name == Copy.FloorPlan.sectionKitchen
            log.expect("b5.house.rawOneMesh", scene.meshes.count == 1 && first?.triangleCount == 9 && nameOK,
                       "\(scene.meshes.count) meshes, \(first?.name ?? "nil")")
            log.expect("b5.house.rawColors", first?.colors?.count == first?.positions.count && scene.metadata["note"] == nil)
            try scene.validate()
            let shift = RoomAlignmentRecord(roomID: F.roomID.uuid, yaw: 0, translation: Vec3(x: 10, y: 0, z: 0), source: .user)
            let placed = try ExportHouse.rawScene(package, manifest: manifest, alignments: [F.roomID.uuid: shift],
                                                  maxTextTriangles: ExportCatalog.textTriangleLimit)
            let xs = placed.meshes.first?.positions.map { $0.x } ?? []
            let minX = xs.min() ?? 0
            log.expect("b5.house.rawPlaced", !xs.isEmpty && minX > 9.99, "min x \(minX)")
        } catch {
            log.fail("b5.house.rawScene", error)
        }
    }

    /// End-to-end House exports: a two-page PDF, zipped SVGs per floor, an STL of the active room
    /// only, our clean USDZ without a merged structure, progress to 1, and a cancelled run that
    /// leaves no staging folder.
    private static func b5HouseRunnerChecks(_ log: inout ExportUISelfTestLog, package: ProjectPackage,
                                            manifest: ProjectManifest) {
        typealias F = ExportUISelfTestFixtures
        do {
            var values: [Double] = []
            let pdf = try ExportRunner.perform(option(.floorPlan, .pdf), settings: ExportSettings(), viewState: .standard,
                                               projectID: manifest.id, package: package, prefs: .standard, now: F.date,
                                               progress: { values.append($0) })
            let pages = ExportPDFPages.pageCount((try? Data(contentsOf: pdf)) ?? Data())
            log.expect("b5.run.housePDFPages", pages == 2 && pdf.pathExtension == "pdf", "\(pages) pages")
            let sorted: Bool = zip(values, values.dropFirst()).allSatisfy { $0.0 <= $0.1 }
            log.expect("b5.run.progress", values.last == 1 && values.count >= 3 && sorted, "\(values)")
            let svg = try b5Export(package, manifest: manifest, .floorPlan, .svg)
            log.expect("b5.run.houseSVGZip", b5Head(svg, 2) == "PK" && svg.lastPathComponent.hasSuffix("_svg.zip"),
                       svg.lastPathComponent)
            let stl = try b5Export(package, manifest: manifest, .raw, .stl)
            log.expect("b5.run.houseSTLActiveOnly", ExportRunner.fileSize(stl) == 84 + 50 * 9, "\(ExportRunner.fileSize(stl))")
            let usdz = try b5Export(package, manifest: manifest, .clean, .usdz)
            log.expect("b5.run.houseCleanUSDZ", b5Head(usdz, 2) == "PK" && usdz.pathExtension == "usdz")
            let json = try b5Export(package, manifest: manifest, .data, .json)
            let parsed = (try? JSONSerialization.jsonObject(with: Data(contentsOf: json))) as? [String: Any]
            log.expect("b5.run.houseJSON", (parsed?["rooms"] as? [Any])?.count == 1)
        } catch {
            log.fail("b5.run.house", error)
        }
        let before = b5StagingFolders(package)
        var calls = 0
        do {
            _ = try ExportRunner.perform(option(.floorPlan, .pdf), settings: ExportSettings(), viewState: .standard,
                                         projectID: manifest.id, package: package, prefs: .standard, now: F.date,
                                         isCancelled: {
                                             calls += 1
                                             return calls >= 2
                                         })
            log.expect("b5.run.cancelLeavesNothing", false, "the export was not cancelled")
        } catch is CancellationError {
            let after = b5StagingFolders(package)
            log.expect("b5.run.cancelLeavesNothing", after == before && calls >= 2, "\(after.count) folders")
        } catch {
            log.fail("b5.run.cancelLeavesNothing", error)
        }
    }

    // MARK: - Object

    /// Object inputs, the large object's USDZ and dimensions JSON, and a small object's model
    /// copied byte for byte.
    private static func b5ObjectChecks(_ log: inout ExportUISelfTestLog, package: ProjectPackage, manifest: ProjectManifest,
                                       folder: URL) {
        typealias F = ExportUISelfTestFixtures
        let inputs = ExportCatalog.inputs(package: package, manifest: manifest)
        let options = ExportCatalog.options(for: inputs)
        let objectReady: Bool = inputs.kind == .object && inputs.hasObjectModel && inputs.hasObjectDimensions
        let allAvailable: Bool = options.count == 2 && options.allSatisfy { $0.isAvailable }
        log.expect("b5.object.inputs", objectReady && allAvailable, "\(inputs)")
        do {
            let usdz = try b5Export(package, manifest: manifest, .object, .usdz)
            log.expect("b5.run.objectUSDZ", b5Head(usdz, 2) == "PK" && usdz.lastPathComponent.hasPrefix("Chair_Object_"),
                       usdz.lastPathComponent)
            let json = try b5Export(package, manifest: manifest, .data, .json)
            let parsed = (try? JSONSerialization.jsonObject(with: Data(contentsOf: json))) as? [String: Any]
            let objects = parsed?["objects"] as? [[String: Any]] ?? []
            let format = parsed?["format"] as? String
            log.expect("b5.run.objectJSON", objects.count == 1 && format == ExportSummaryJSON.objectFormatName)
            let small = ObjectRecord(id: F.smallObjectID, name: "", size: .smallMedium, status: .processed, imageCount: 20,
                                     modelFile: PhotogrammetryStore.modelFileName)
            let out = folder.appendingPathComponent("objectcopy", isDirectory: true)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let copied = try ExportObject.objectUSDZ(package, object: small, into: out, fileName: "Small.usdz")
            log.expect("b5.object.copyAsProduced", (try? Data(contentsOf: copied)) == F.fakeModelBytes)
            var missing = small
            missing.id = F.uuid(917)
            let smallHasModel = ExportObject.hasModel(package, object: small)
            log.expect("b5.object.noModel", !ExportObject.hasModel(package, object: missing) && smallHasModel)
        } catch {
            log.fail("b5.run.object", error)
        }
    }

    // MARK: - Quick Measure

    /// Quick Measure inputs, the measurements JSON, and measurements.json superseding quick.json.
    private static func b5QuickChecks(_ log: inout ExportUISelfTestLog, package: ProjectPackage, manifest: ProjectManifest) {
        let inputs = ExportCatalog.inputs(package: package, manifest: manifest)
        let options = ExportCatalog.options(for: inputs)
        let ids = options.map { $0.id }
        let available: Bool = options.first?.isAvailable == true
        log.expect("b5.quick.inputs", inputs.measurementCount == 2 && ids == ["data.json"] && available,
                   "\(inputs.measurementCount)")
        do {
            let json = try b5Export(package, manifest: manifest, .data, .json)
            let parsed = (try? JSONSerialization.jsonObject(with: Data(contentsOf: json))) as? [String: Any]
            let entries = parsed?["measurements"] as? [[String: Any]] ?? []
            let firstName = entries.first?["name"] as? String
            log.expect("b5.run.quickJSON", entries.count == 2 && firstName == "Couch")
            let kept = Array(ExportUISelfTestFixtures.measurements().prefix(1))
            try ProjectStore.writeJSON(kept, to: package.measurementsURL, createParents: false)
            log.expect("b5.quick.editsSupersedeRaw", ExportObject.effectiveMeasurements(package).count == 1)
        } catch {
            log.fail("b5.run.quick", error)
        }
    }
}
