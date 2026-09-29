import Foundation
import simd

/// Object and Quick Measure outputs (docs/MODULES.md 3.43d): the object's USDZ (Object Capture's
/// file as produced for small and medium objects, the untextured object mesh for large ones) and
/// the measurements every kind shares. Object projects export their first object; a second one
/// is logged and left out in build 5. Reads inside the package only; nonisolated, call off main.
enum ExportObject {
    /// Small and medium: a copy of `PhotogrammetryStore.modelURL(_:object:)` named `fileName` in `folder`.
    /// Large: `USDZWriter.data(for: ObjectExportAdapter.scene(mesh, name:))` of `ObjectModelStore.loadMesh`.
    /// Throws `CoreError.missingFile` when the model or mesh is not there.
    static func objectUSDZ(_ package: ProjectPackage, object: ObjectRecord, into folder: URL, fileName: String) throws -> URL {
        try objectUSDZ(package, object: object, into: folder, fileName: fileName, modified: Date())
    }

    /// As `objectUSDZ(_:object:into:fileName:)` with the archive time of a written USDZ.
    static func objectUSDZ(_ package: ProjectPackage, object: ObjectRecord, into folder: URL, fileName: String,
                           modified: Date) throws -> URL {
        let url = folder.appendingPathComponent(fileName, isDirectory: false)
        switch object.size {
        case .smallMedium:
            guard let model = PhotogrammetryStore.modelURLIfPresent(package, object: object.id) else {
                throw CoreError.missingFile(PhotogrammetryStore.modelFileName)
            }
            try FileManager.default.copyItem(at: model, to: url)
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUnlessOpen],
                                                   ofItemAtPath: url.path)
        case .large:
            guard let mesh = try ObjectModelStore.loadMesh(package, object: object.id) else {
                throw CoreError.missingFile(ObjectModelStore.meshFileName)
            }
            let scene = ObjectExportAdapter.scene(mesh, name: meshName(object))
            let data = try USDZWriter.data(for: scene, layerName: "\(ExportCatalog.stem(of: fileName)).usda", modified: modified)
            try ProjectStore.writeData(data, to: url, createParents: false)
        }
        return url
    }

    /// Name of the object's mesh inside the file: its name, else the material name ("object").
    static func meshName(_ object: ObjectRecord) -> String {
        let trimmed = object.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? ObjectExportAdapter.materialName : trimmed
    }

    /// True when the object's model exists: model.usdz for small and medium, mesh.mchk for large.
    static func hasModel(_ package: ProjectPackage, object: ObjectRecord) -> Bool {
        switch object.size {
        case .smallMedium:
            return PhotogrammetryStore.modelURLIfPresent(package, object: object.id) != nil
        case .large:
            return FileManager.default.fileExists(atPath: ObjectModelStore.meshURL(package, object: object.id).path)
        }
    }

    /// The object an Object project exports: the first one. More than one is logged (build 5
    /// exports one object per project).
    static func firstObject(_ manifest: ProjectManifest) -> ObjectRecord? {
        if manifest.objects.count > 1 {
            LogStore.shared.write("export: project has \(manifest.objects.count) objects, only the first is exported",
                                  category: ExportRunner.logCategory)
        }
        return manifest.objects.first
    }

    /// The saved measurements: `edits/measurements.json` when it exists (it supersedes Quick
    /// Measure's raw file once written), else `raw/measure/quick.json`, else none.
    static func effectiveMeasurements(_ package: ProjectPackage) -> [MeasurementRecord] {
        if FileManager.default.fileExists(atPath: package.measurementsURL.path) {
            return EditStore.loadMeasurements(package)
        }
        return QuickMeasureStore.load(package)?.records ?? []
    }
}

/// Quick Measure and object summaries (docs/MODULES.md 3.43d). Same units, number and date rules
/// as the room summary: SI units, radians, ISO 8601 dates, non-finite numbers written as 0.
extension ExportSummaryJSON {
    /// "format" of the Quick Measure file.
    static let measurementsFormatName = "mapper-measurements"
    /// "format" of the object file.
    static let objectFormatName = "mapper-object"

    /// Quick Measure file: format, project, units and the measurements.
    struct MeasurementsDocument: Encodable {
        /// Format name and version, project identity, unit legend and measurements.
        var format: String
        var version: Int
        var project: ProjectEntry
        var units: UnitsEntry
        var measurements: [MeasurementEntry]
    }

    /// Object file: format, project, units and one entry per object.
    struct ObjectDocument: Encodable {
        /// Format name and version, project identity, unit legend and objects.
        var format: String
        var version: Int
        var project: ProjectEntry
        var units: UnitsEntry
        var objects: [ObjectDimensionsEntry]
    }

    /// One object's box and measurements.
    struct ObjectDimensionsEntry: Encodable {
        /// Identity, capture path, sides, surface area, volume or its unavailable reason, box and quality flags.
        var id: String
        var name: String
        var size: String
        var width: ValueEntry
        var height: ValueEntry
        var depth: ValueEntry
        var surfaceArea: ValueEntry
        var volume: ValueEntry?
        var volumeUnavailableReason: String?
        var isWatertight: Bool
        var triangleCount: Int
        var box: BoxEntry
        var measuredAt: Date
    }

    /// A gravity-aligned box: center, three unit axes and half sizes, meters.
    struct BoxEntry: Encodable {
        /// Center, axes (axis 1 is up) and half extents.
        var center: [Double]
        var axisX: [Double]
        var axisY: [Double]
        var axisZ: [Double]
        var halfExtents: [Double]
    }

    /// Quick Measure projects: project name and dates plus the measurements.
    static func measurementsData(_ records: [MeasurementRecord], manifest: ProjectManifest) throws -> Data {
        let document = MeasurementsDocument(format: measurementsFormatName, version: formatVersion,
                                            project: projectEntry(manifest), units: UnitsEntry(),
                                            measurements: records.map(measurementEntry))
        return try summaryEncoder().encode(document)
    }

    /// Object projects: each object's dimensions (width, height, depth, surface area, volume or the
    /// unavailable reason, box) and the project name and dates. Objects follow the manifest
    /// order, then any others by identifier.
    static func objectData(_ dimensions: [UUID: ObjectDimensionsRecord], manifest: ProjectManifest) throws -> Data {
        var order = manifest.objects.map { $0.id }.filter { dimensions[$0] != nil }
        let extra = dimensions.keys.filter { !order.contains($0) }.sorted { $0.uuidString < $1.uuidString }
        order.append(contentsOf: extra)
        let entries = order.compactMap { id -> ObjectDimensionsEntry? in
            guard let record = dimensions[id] else { return nil }
            let name = manifest.objects.first(where: { $0.id == id })?.name ?? ""
            return objectDimensionsEntry(record, name: name)
        }
        let document = ObjectDocument(format: objectFormatName, version: formatVersion, project: projectEntry(manifest),
                                      units: UnitsEntry(), objects: entries)
        return try summaryEncoder().encode(document)
    }

    /// One object's entry, values and sigmas from ObjectModel's `ObjectDimensions.measuredValues`.
    static func objectDimensionsEntry(_ record: ObjectDimensionsRecord, name: String) -> ObjectDimensionsEntry {
        let values = ObjectDimensions.measuredValues(record)
        let box = record.box
        let boxEntry = BoxEntry(center: numbers(box.center.simd), axisX: numbers(box.axisX.simd),
                                axisY: numbers(box.axisY.simd), axisZ: numbers(box.axisZ.simd),
                                halfExtents: numbers(box.halfExtents.simd))
        return ObjectDimensionsEntry(id: record.objectID.uuidString, name: name, size: record.source.rawValue,
                                     width: valueEntry(values.width, kind: .distance),
                                     height: valueEntry(values.height, kind: .distance),
                                     depth: valueEntry(values.depth, kind: .distance),
                                     surfaceArea: valueEntry(values.surfaceArea, kind: .area),
                                     volume: values.volume.map { valueEntry($0, kind: .volume) },
                                     volumeUnavailableReason: record.volumeUnavailableReason?.rawValue,
                                     isWatertight: record.isWatertight, triangleCount: record.triangleCount,
                                     box: boxEntry, measuredAt: record.measuredAt)
    }

    /// A measured value with its sigma, provenance and the CR-2 low-confidence flag of `kind`.
    static func valueEntry(_ value: MeasuredValue, kind: MeasurementKind) -> ValueEntry {
        ValueEntry(value: finite(value.value), sigma: finiteOrNil(value.sigma), provenance: value.provenance.rawValue,
                   lowConfidence: value.isLowConfidence(kind: kind))
    }

    /// The project block of the build 5 files (no rooms).
    static func projectEntry(_ manifest: ProjectManifest) -> ProjectEntry {
        ProjectEntry(id: manifest.id.uuidString, name: manifest.name, kind: manifest.kind.rawValue,
                     createdAt: manifest.createdAt, modifiedAt: manifest.modifiedAt, roomCount: 0)
    }

    /// Pretty, sorted keys, unescaped slashes, ISO 8601 dates (the room summary's settings).
    static func summaryEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
