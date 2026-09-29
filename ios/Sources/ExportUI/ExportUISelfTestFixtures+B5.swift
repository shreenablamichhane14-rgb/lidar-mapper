import Foundation
import simd

/// Build 5 fixtures for `ExportUISelfTest` (docs/MODULES.md 3.43d): House, Object and Quick
/// Measure inputs, measurements, a two-level plan and temporary packages of each kind. Fixed
/// identifiers and dates, no RoomPlan, files only under the temporary directory.
extension ExportUISelfTestFixtures {
    /// Session of the temporary House, its superseded room and the project identifiers.
    static let houseSession = uuid(910), supersededRoom = uuid(911)
    static let houseProjectID = uuid(912), objectProjectID = uuid(913), quickProjectID = uuid(916)
    /// The large object of the Object package and a small object with a stand-in model file.
    static let largeObjectID = uuid(914), smallObjectID = uuid(915)
    /// Bytes standing in for Object Capture's model.usdz (the export copies them unchanged).
    static let fakeModelBytes = Data([0x50, 0x4B, 0x03, 0x04, 0x6D, 0x61, 0x70, 0x70, 0x65, 0x72])

    /// Inputs of a processed House with two plan levels: everything available.
    static func houseInputs() -> ExportInputs {
        var inputs = demoInputs()
        inputs.kind = .house
        inputs.levelCount = 2
        inputs.allRoomsTextured = true
        inputs.roomTriangles = [1000, 1000]
        return inputs
    }

    /// Two saved measurements: a 2 m distance and a 2.4 m height, both with a sigma.
    static func measurements() -> [MeasurementRecord] {
        let distance = MeasurementRecord(id: uuid(960), kind: .distance,
                                         points: [Vec3(x: 0, y: 0, z: 0), Vec3(x: 2, y: 0, z: 0)], snaps: [.corner, .edge],
                                         result: MeasuredValue(value: 2, sigma: 0.01, provenance: .measured),
                                         source: .live, name: "Couch", roomID: nil, createdAt: date)
        let height = MeasurementRecord(id: uuid(961), kind: .height,
                                       points: [Vec3(x: 0, y: 0, z: 0), Vec3(x: 0, y: 2.4, z: 0)], snaps: [.plane, .plane],
                                       result: MeasuredValue(value: 2.4, sigma: 0.02, provenance: .measured),
                                       source: .live, name: "", roomID: nil, createdAt: date)
        return [distance, height]
    }

    /// The demo level plus a copy of it as level 1 named "Upstairs".
    static func twoLevelPlan() -> PlanModel {
        var plan = demoPlan()
        if var upper = plan.levels.first {
            upper.id = 1
            upper.name = "Upstairs"
            upper.elevation = 3
            plan.levels.append(upper)
        }
        return plan
    }

    /// The measurements of a 1 x 0.5 x 0.8 m open (not watertight) large object.
    static func dimensions(_ objectID: UUID) -> ObjectDimensionsRecord {
        let box = OrientedBox(center: SIMD3<Float>(0, 0.25, 0), axes: matrix_identity_float3x3,
                              halfExtents: SIMD3<Float>(0.5, 0.25, 0.4))
        return ObjectDimensionsRecord(objectID: objectID, source: .large, width: 1, height: 0.5, depth: 0.8,
                                      surfaceArea: 2.6, volume: nil, volumeUnavailableReason: .notWatertight,
                                      box: OrientedBoxRecord(box), isWatertight: false, triangleCount: 4,
                                      scaleCorrection: 1, provenance: .estimated, inputHash: "selftest", measuredAt: date)
    }

    /// A fresh folder for the build 5 checks under the temporary directory.
    static func scratchFolderB5() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExportUISelfTestB5-\(uuid(905).uuidString)", isDirectory: true)
        if FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// An empty package (raw, derived, edits and exports folders) named after `id` in `folder`.
    static func emptyPackage(in folder: URL, id: UUID) throws -> ProjectPackage {
        let root = folder.appendingPathComponent("\(id.uuidString).\(ProjectPackage.fileExtension)", isDirectory: true)
        let package = ProjectPackage(root: root)
        for url in [package.rawURL, package.derivedURL, package.editsURL, package.exportsURL] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return package
    }

    /// A House "Maple House" with one session: the demo room (active) and a superseded room, both
    /// with the consolidated mesh of `consolidation()`; the demo clean model (the active room) and
    /// the two-level plan. No structure files, so the clean USDZ uses Mapper's writer.
    static func makeHousePackage(in folder: URL) throws -> (package: ProjectPackage, manifest: ProjectManifest) {
        let package = try emptyPackage(in: folder, id: houseProjectID)
        var manifest = ProjectManifest.new(kind: .house, name: "Maple House", now: date)
        manifest.id = houseProjectID
        manifest.status = .ready
        manifest.sessions = [CaptureSessionRef(id: houseSession, startedAt: date,
                                               frameLink: .projectFrame(sessionID: houseSession), worldMapFile: nil)]
        let active = RoomRecord(id: roomID.uuid, name: "", sessionID: houseSession, floorIndex: 0, status: .processed,
                                capturedRoomID: nil, quality: nil, hasMeshPass: false, keyframeCount: 0,
                                capturedAt: date, frameLink: .projectFrame(sessionID: houseSession))
        var replaced = active
        replaced.id = supersededRoom
        replaced.supersededBy = roomID.uuid
        manifest.rooms = [replaced, active]
        try ProjectStore.writeManifest(manifest, to: package)
        try CleanModelStore.save(demoModel(), to: package)
        try PlanModelStore.save(twoLevelPlan(), to: package)
        try MeshModelStore.save(consolidation(), package: package, room: roomID.uuid)
        try MeshModelStore.save(consolidation(), package: package, room: supersededRoom)
        return (package, manifest)
    }

    /// An Object project "Chair" with one large object (mesh.mchk of a 2-quad strip and
    /// dims.json), plus a stand-in model.usdz of `smallObjectID` (not in the manifest).
    static func makeObjectPackage(in folder: URL) throws -> (package: ProjectPackage, manifest: ProjectManifest) {
        let package = try emptyPackage(in: folder, id: objectProjectID)
        var manifest = ProjectManifest.new(kind: .object, name: "Chair", now: date)
        manifest.id = objectProjectID
        manifest.status = .ready
        manifest.objects = [ObjectRecord(id: largeObjectID, name: "Chair", size: .large, status: .processed,
                                         imageCount: 0, modelFile: nil)]
        try ProjectStore.writeManifest(manifest, to: package)
        try ObjectModelStore.saveMesh(strip(quads: 2), package: package, object: largeObjectID)
        try ObjectModelStore.saveDimensions(dimensions(largeObjectID), to: package)
        _ = try ProjectStore.ensureDirectory(package.derivedObjectURL(smallObjectID), inside: package.root)
        try ProjectStore.writeData(fakeModelBytes, to: PhotogrammetryStore.modelURL(package, object: smallObjectID),
                                   createParents: false)
        return (package, manifest)
    }

    /// A Quick Measure project "Hall" whose sealed raw/measure/quick.json holds `measurements()`.
    static func makeQuickMeasurePackage(in folder: URL) throws -> (package: ProjectPackage, manifest: ProjectManifest) {
        let package = try emptyPackage(in: folder, id: quickProjectID)
        var manifest = ProjectManifest.new(kind: .quickMeasure, name: "Hall", now: date)
        manifest.id = quickProjectID
        manifest.status = .ready
        try ProjectStore.writeManifest(manifest, to: package)
        try QuickMeasureStore.save(measurements(), to: package, now: date)
        return (package, manifest)
    }
}
