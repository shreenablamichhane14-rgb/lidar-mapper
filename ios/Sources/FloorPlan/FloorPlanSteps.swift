import Foundation
import CoreGraphics
import ImageIO

/// Builds `derived/plan.json` from `derived/clean.json` (pipeline step `.floorPlan`, D11).
/// The plan is written from the base clean model; edits are applied when it is loaded
/// (`PlanModelStore.loadEdited`). The input hash is the `cleanModel` stamp plus the floors.
final class FloorPlanStep: ProcessingStep {
    /// Step identity and memory budget (50 MB, no reduced variant).
    let id: PipelineStepID = .floorPlan
    let memoryBudgetBytes: UInt64 = 50 * 1024 * 1024

    /// Floors of the project (the manifest's floors are used when empty).
    private let floors: [FloorRecord]

    /// Creates the step for a project's floors.
    init(floors: [FloorRecord]) {
        self.floors = floors
    }

    /// Floors to build levels for.
    private func effectiveFloors(_ ctx: StepContext) -> [FloorRecord] {
        floors.isEmpty ? ctx.manifest.floors : floors
    }

    /// Hash of the `cleanModel` stamp and the floor list (no raw seals, no edits).
    func inputHash(_ ctx: StepContext) throws -> String {
        let clean = FloorPlanStepSupport.upstreamHash(ctx.package, step: .cleanModel)
        let floorList = effectiveFloors(ctx).map { "\($0.id):\($0.elevation):\($0.name)" }.joined(separator: ",")
        return InputHasher.hash(seals: [], editRevision: nil, extra: ["clean=\(clean)", "floors=\(floorList)"])
    }

    /// Reads clean.json, builds the plan and writes plan.json atomically.
    func run(_ ctx: StepContext) async throws {
        try ctx.checkCancelled()
        let started = Date()
        let model: CleanModel
        do {
            model = try ProjectStore.readJSON(CleanModel.self, from: ctx.package.cleanModelURL)
        } catch {
            throw MapperError.processingFailed(step: .floorPlan, reason: "clean.json unreadable: \(error)")
        }
        ctx.progress(0.3)
        var plan = PlanBuilder.build(from: model, floors: effectiveFloors(ctx))
        let hash = (try? inputHash(ctx)) ?? "-"
        plan.stamp = DerivedStamp(step: .floorPlan, subject: nil, pipelineVersion: ProjectManifest.currentPipelineVersion,
                                  inputHash: hash, createdAt: Date())
        try ctx.checkCancelled()
        ctx.progress(0.7)
        try PlanModelStore.save(plan, to: ctx.package)
        let rooms = plan.levels.reduce(0) { $0 + $1.rooms.count }
        let milliseconds = Int(Date().timeIntervalSince(started) * 1000)
        LogStore.shared.write("floorPlan: \(plan.levels.count) levels, \(rooms) rooms in \(milliseconds) ms", category: "floorplan")
        ctx.progress(1)
    }
}

/// Writes `thumbnail.jpg` (512 px) at the package root (pipeline step `.thumbnail`): the
/// edited plan's level 0, else the first keyframe of a room, else the first object image.
/// Completes without output when there is nothing to draw. Reads edits, so the input hash
/// includes `EditLog.revision`.
final class ThumbnailStep: ProcessingStep {
    /// Step identity and memory budget (50 MB, no reduced variant).
    let id: PipelineStepID = .thumbnail
    let memoryBudgetBytes: UInt64 = 50 * 1024 * 1024

    /// Thumbnail side in pixels.
    static let pixelSize = 512
    /// Layers on the thumbnail: no dimensions, grid or scale bar at this size.
    static let toggles = PlanToggles(furniture: true, measurements: false, roomNames: true, doorsWindows: true,
                                     fixtures: true, grid: false, scale: false)

    /// Creates the step.
    init() {}

    /// Hash of the `floorPlan` stamp, the edit revision, the unit system (labels) and the
    /// rooms and objects that the image fallback can use.
    func inputHash(_ ctx: StepContext) throws -> String {
        let plan = FloorPlanStepSupport.upstreamHash(ctx.package, step: .floorPlan)
        let revision = (try? PlanModelStore.editLog(ctx.package))?.revision
        let prefs = UnitPreferences.load()
        let rooms = ctx.manifest.rooms.map { "\($0.id.uuidString):\($0.keyframeCount)" }.joined(separator: ",")
        let objects = ctx.manifest.objects.map { "\($0.id.uuidString):\($0.imageCount)" }.joined(separator: ",")
        return InputHasher.hash(seals: [], editRevision: revision ?? 0,
                                extra: ["plan=\(plan)", "units=\(prefs.system.rawValue)-\(prefs.fraction.rawValue)",
                                        "rooms=\(rooms)", "objects=\(objects)"])
    }

    /// Renders and writes the thumbnail. The write never recreates a deleted package.
    func run(_ ctx: StepContext) async throws {
        try ctx.checkCancelled()
        var data = try planThumbnail(ctx)
        ctx.progress(0.5)
        if data == nil {
            try ctx.checkCancelled()
            data = imageThumbnail(ctx)
        }
        guard let jpeg = data else {
            LogStore.shared.write("thumbnail: nothing to draw", category: "floorplan")
            ctx.progress(1)
            return
        }
        try ProjectStore.writeData(jpeg, to: ctx.package.thumbnailURL, createParents: false)
        ctx.progress(1)
    }

    /// JPEG of the edited plan's level 0 (or its first level), nil when there is no plan or
    /// the level is empty.
    private func planThumbnail(_ ctx: StepContext) throws -> Data? {
        guard FileManager.default.fileExists(atPath: ctx.package.planModelURL.path) else { return nil }
        let edited = try PlanModelStore.loadEdited(ctx.package)
        let levels = edited.plan.levels
        guard let level = levels.first(where: { $0.id == 0 }) ?? levels.first,
              !(level.rooms.isEmpty && level.walls.isEmpty) else { return nil }
        let clean = try? ProjectStore.readJSON(CleanModel.self, from: ctx.package.cleanModelURL)
        let titles = RoomTitles.titles(for: edited.plan, clean: clean)
        let drawing = PlanDrawing.make(level: level, toggles: ThumbnailStep.toggles, prefs: UnitPreferences.load(),
                                       roomTitles: titles, name: ctx.manifest.name)
        return PlanRenderer.jpegThumbnail(drawing.plan, pixelSize: ThumbnailStep.pixelSize)
    }

    /// JPEG of the first keyframe of the first room that has one, else of the first object image.
    private func imageThumbnail(_ ctx: StepContext) -> Data? {
        for room in ctx.manifest.rooms {
            let folder = RawScanFolder(url: ctx.package.rawRoomURL(session: room.sessionID, room: room.id))
            if let url = FloorPlanStepSupport.firstKeyframeImage(in: folder),
               let data = FloorPlanStepSupport.jpegThumbnail(of: url, maxPixelSize: ThumbnailStep.pixelSize) {
                return data
            }
        }
        for object in ctx.manifest.objects {
            let images = ctx.package.rawObjectURL(object.id).appendingPathComponent("Images", isDirectory: true)
            if let url = FloorPlanStepSupport.firstImage(in: images),
               let data = FloorPlanStepSupport.jpegThumbnail(of: url, maxPixelSize: ThumbnailStep.pixelSize) {
                return data
            }
        }
        return nil
    }
}

/// File helpers of the FloorPlan steps (upstream stamps, image fallback).
enum FloorPlanStepSupport {
    /// Bytes read from the start of `keyframes.jsonl` to find its first record.
    static let firstLineLimit = 64 * 1024

    /// The current stamp input hash of an upstream step from `derived/index.json`, "-" when
    /// there is none (MODULES 3.1).
    static func upstreamHash(_ package: ProjectPackage, step: PipelineStepID) -> String {
        guard let index = try? ProjectStore.readJSON(DerivedIndex.self, from: package.derivedIndexURL) else { return "-" }
        return index.stamp(step: step)?.inputHash ?? "-"
    }

    /// Image of the first record of a scan's `keyframes.jsonl`, when the record is readable,
    /// its path is safe (`RawScanFolder.resolve`) and the file exists.
    static func firstKeyframeImage(in folder: RawScanFolder) -> URL? {
        guard let handle = try? FileHandle(forReadingFrom: folder.keyframesLogURL) else { return nil }
        defer { try? handle.close() }
        guard let chunk = try? handle.read(upToCount: firstLineLimit), !chunk.isEmpty,
              let line = chunk.split(separator: 0x0A, maxSplits: 1, omittingEmptySubsequences: true).first,
              let record = try? ProjectStore.decoder.decode(KeyframeRecord.self, from: Data(line)),
              let url = folder.resolve(record.imageFile),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// First image file (by name) in a folder: jpg, jpeg, heic or png.
    static func firstImage(in folder: URL) -> URL? {
        guard let children = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else {
            return nil
        }
        let images = children.filter { ["jpg", "jpeg", "heic", "png"].contains($0.pathExtension.lowercased()) }
        return images.sorted { $0.lastPathComponent < $1.lastPathComponent }.first
    }

    /// A JPEG (quality 0.8) of an image file downscaled to at most `maxPixelSize` on its long
    /// side, through ImageIO without caching the full image.
    static func jpegThumbnail(of url: URL, maxPixelSize: Int) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCache: false
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, "public.jpeg" as CFString, 1, nil) else {
            return nil
        }
        let properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.8]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
