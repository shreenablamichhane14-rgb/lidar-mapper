import Foundation

/// Writers that differ by project kind (docs/MODULES.md 3.43d): House raw and realistic scenes
/// placed room by room inside one budget, floor plans with one page or file per floor, the data
/// JSON of rooms, houses, objects and Quick Measure projects, and the object's USDZ. Each checks
/// cancellation between rooms and between plan levels and reports progress through the job.
extension ExportRunner {
    // MARK: - House

    /// Every active room's measured mesh placed with its alignment (`ExportHouse.rawScene`), inside
    /// `ExportCatalog.textTriangleLimit` for OBJ and USDZ and `ExportHouse.maxBinaryTriangles` for
    /// PLY, STL and GLB, both for the whole house.
    static func writeHouseRaw(_ job: Job) throws -> URL {
        let alignments = StructureStore.effectiveAlignments(job.package)
        let budget = ExportCatalog.rawBudget(for: job.option.format)
        let scene = try ExportHouse.rawScene(job.package, manifest: job.manifest, alignments: alignments,
                                             maxTextTriangles: budget) { n, count in
            try job.checkCancelled()
            job.buildProgress(n, of: count)
        }
        return try writeScene(scene, job: job)
    }

    /// Every active room's textured mesh placed with its alignment (`ExportHouse.texturedScene`).
    static func writeHouseRealistic(_ job: Job) throws -> URL {
        let alignments = StructureStore.effectiveAlignments(job.package)
        let scene = try ExportHouse.texturedScene(job.package, manifest: job.manifest, alignments: alignments,
                                                  includeTextures: job.settings.includeTextures) { n, count in
            try job.checkCancelled()
            job.buildProgress(n, of: count)
        }
        return try writeScene(scene, job: job)
    }

    // MARK: - Floor plan

    /// The edited plan with the export toggles and units. One level exports as build 4 (PDF with
    /// scale caption and north angle, SVG, DXF in millimeters with the units note, or a 3000 px
    /// PNG). Several levels: PDF writes one page per level and joins them with
    /// `ExportPDFPages.merge`; SVG, DXF and PNG write one file per level
    /// (`ExportCatalog.fileName(... level:)`) and zip them with `ZipWriter.archive`.
    static func writePlan(_ job: Job) throws -> URL {
        let toggles = ExportAdapters.planToggles(viewState: job.viewState, settings: job.settings)
        let prefs = ExportAdapters.planPrefs(job.prefs, settings: job.settings)
        let set = try ExportHouse.planExport(job.package, prefs: prefs, toggles: toggles,
                                             includeHidden: job.settings.includeHidden)
        try job.checkCancelled()
        job.progress(0.1)
        if set.drawings.count == 1, let only = set.drawings.first {
            let data = try planData(only.plan, northAngle: set.northAngle, prefs: prefs, job: job)
            job.progress(0.8)
            return try save(data, name: job.fileName, job: job)
        }
        var pages: [Data] = []
        var entries: [(name: String, data: Data)] = []
        for (n, drawing) in set.drawings.enumerated() {
            try job.checkCancelled()
            job.buildProgress(n, of: set.drawings.count)
            let data = try planData(drawing.plan, northAngle: set.northAngle, prefs: prefs, job: job)
            if job.option.format == .pdf {
                pages.append(data)
            } else {
                let name = ExportCatalog.fileName(project: job.manifest.name, option: job.option, date: job.now,
                                                  level: drawing.level)
                entries.append((name: name, data: data))
            }
        }
        try job.checkCancelled()
        job.progress(0.85)
        if job.option.format == .pdf {
            return try save(try ExportPDFPages.merge(pages), name: job.fileName, job: job)
        }
        let zip = try ZipWriter.archive(entries, modified: job.now)
        return try save(zip, name: ExportCatalog.zipFileName(for: job.fileName), job: job)
    }

    /// One plan drawing in the option's format: PDF (paper, date, north angle converted from the
    /// PlanModel convention, scale caption, units), SVG, DXF (millimeters, units note) or PNG.
    static func planData(_ plan: Plan2D, northAngle: Float, prefs: UnitPreferences, job: Job) throws -> Data {
        switch job.option.format {
        case .pdf:
            let north: Double = Double.pi / 2 + Double(northAngle)
            let options = PDFPlanWriter.Options(paper: job.settings.paper, date: job.now, northAngle: north,
                                                scaleCaption: Copy.ExportUI.scaleCaption, metric: prefs.system == .metric)
            return try PDFPlanWriter.data(for: plan, options: options)
        case .svg:
            return try SVGWriter.data(for: plan)
        case .dxf:
            return try DXFWriter.data(for: plan, millimeters: true, unitsNote: Copy.ExportUI.dxfUnitsNote)
        case .png:
            guard let png = PlanRenderer.pngData(plan, pixelWidth: pngPixelWidth) else { throw ExportError.emptyPlan }
            return png
        case .usdz, .obj, .ply, .stl, .glb, .json:
            throw ExportError.encodingFailed(format: job.option.format.rawValue)
        }
    }

    // MARK: - Data

    /// The data JSON by kind: the room or House summary, the object's dimensions, or the Quick
    /// Measure measurements.
    static func writeData(_ job: Job) throws -> URL {
        switch job.manifest.kind {
        case .room, .advancedSpace, .house: return try writeSummaryData(job)
        case .object, .advancedObject: return try writeObjectData(job)
        case .quickMeasure: return try writeMeasurementsData(job)
        }
    }

    /// The summary JSON of the edited clean model (House projects: the edited House model) with
    /// the saved measurements when Include measurements is on; zipped with each exported room's
    /// final `capturedroom.json` when one exists. Superseded rooms are left out.
    static func writeSummaryData(_ job: Job) throws -> URL {
        let model = try CleanModelStore.loadEdited(job.package).model
        job.progress(0.2)
        var evidence: [UUID: RoomEvidence] = [:]
        for room in model.rooms {
            evidence[room.recordID] = QualityStore.load(job.package, room: room.recordID)?.evidence
        }
        let measurements = job.settings.includeMeasurements ? ExportObject.effectiveMeasurements(job.package) : []
        let json = try ExportSummaryJSON.data(model: model, evidence: evidence, manifest: job.manifest,
                                              measurements: measurements)
        try job.checkCancelled()
        job.progress(0.6)
        var entries: [(name: String, data: Data)] = [(name: job.fileName, data: json)]
        let rooms = ExportCatalog.exportRooms(job.manifest)
        for (n, room) in rooms.enumerated() {
            guard let raw = capturedRoomJSON(job.package, room: room) else { continue }
            let name = rooms.count == 1 ? "capturedroom.json" : "capturedroom_room\(n + 1).json"
            entries.append((name: name, data: raw))
        }
        if entries.count == 1 { return try save(json, name: job.fileName, job: job) }
        try job.checkCancelled()
        job.progress(0.85)
        let zip = try ZipWriter.archive(entries, modified: job.now)
        return try save(zip, name: ExportCatalog.zipFileName(for: job.fileName), job: job)
    }

    /// Object projects: the first object's dimensions (`ExportSummaryJSON.objectData`).
    static func writeObjectData(_ job: Job) throws -> URL {
        guard let object = ExportObject.firstObject(job.manifest),
              let record = ObjectModelStore.loadDimensions(job.package, object: object.id) else {
            throw CoreError.missingFile(ObjectModelStore.dimensionsFileName)
        }
        job.progress(0.5)
        let json = try ExportSummaryJSON.objectData([object.id: record], manifest: job.manifest)
        return try save(json, name: job.fileName, job: job)
    }

    /// Quick Measure projects: the effective measurements (`measurements.json` once written,
    /// else `raw/measure/quick.json`).
    static func writeMeasurementsData(_ job: Job) throws -> URL {
        let records = ExportObject.effectiveMeasurements(job.package)
        guard !records.isEmpty else { throw CoreError.missingFile("quick.json") }
        job.progress(0.5)
        let json = try ExportSummaryJSON.measurementsData(records, manifest: job.manifest)
        return try save(json, name: job.fileName, job: job)
    }

    // MARK: - Object

    /// The first object's USDZ (`ExportObject.objectUSDZ`): Object Capture's file as produced, or
    /// the untextured mesh of a large object.
    static func writeObject(_ job: Job) throws -> URL {
        guard job.option.format == .usdz else { throw ExportError.encodingFailed(format: job.option.format.rawValue) }
        guard let object = ExportObject.firstObject(job.manifest) else {
            throw CoreError.missingFile(PhotogrammetryStore.modelFileName)
        }
        try job.checkCancelled()
        job.progress(0.3)
        let url = try ExportObject.objectUSDZ(job.package, object: object, into: job.folder, fileName: job.fileName,
                                              modified: job.now)
        try job.checkCancelled()
        return url
    }
}
