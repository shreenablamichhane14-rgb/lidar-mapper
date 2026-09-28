import CoreGraphics
import Foundation
import ImageIO
import simd

/// Loads recorded keyframes as baker input (ARCHITECTURE 5.5): reads `keyframes.jsonl`
/// through Store's `RawScanReader`, keeps records with normal tracking and usable intrinsics
/// and pose, subsamples them evenly (raw keeps every keyframe, D6) and opens each image
/// lazily with ImageIO. Images are never decoded here: `CGImageSourceCreateImageAtIndex`
/// with `kCGImageSourceShouldCache: false` only reads the JPEG header, and the baker decodes
/// one keyframe at a time when it draws. Stateless and safe on any thread.
enum KeyframeLoader {
    /// Most keyframes TextureLowStep bakes with.
    static let defaultMaxCount = 150
    /// Largest relative difference accepted between the image aspect ratio and the aspect
    /// ratio its intrinsics refer to (the baker rescales the camera to the image size).
    static let maxAspectMismatch: Float = 0.02
    /// Largest image side accepted in intrinsics, pixels (sanity cap for untrusted records).
    static let maxImageSide = 16384
    /// Log category.
    static let logCategory = "texture"

    /// What `load(inFolders:maxCount:)` found, for the step's log.
    struct Report {
        /// The keyframes, in capture order.
        var keyframes: [TXKeyframe]
        /// Usable records with an image file, before subsampling.
        var candidates: Int
        /// Selected records whose image could not be opened or had the wrong aspect ratio.
        var unreadable: Int
        /// Folders whose keyframes.jsonl could not be read.
        var failedFolders: Int
    }

    /// One usable record with its image file.
    private struct Entry {
        /// The record.
        var record: KeyframeRecord
        /// Its image file (inside the scan folder).
        var imageURL: URL
    }

    /// Lazily decoded CGImages (CGImageSourceCreateImageAtIndex, no cache) for keyframes with
    /// trackingNormal, evenly subsampled to at most `maxCount`.
    /// Throws when `keyframes.jsonl` is too large or unreadable; a missing log reads as empty.
    static func keyframes(in folder: RawScanFolder, maxCount: Int) throws -> [TXKeyframe] {
        let entries = try usableEntries(in: folder)
        return select(entries, maxCount: maxCount).keyframes
    }

    /// Keyframes of several folders (a room and its mesh passes, one ARKit world frame),
    /// subsampled together to at most `maxCount`; a folder that cannot be read is skipped
    /// and logged.
    static func keyframes(inFolders folders: [RawScanFolder], maxCount: Int) -> [TXKeyframe] {
        load(inFolders: folders, maxCount: maxCount).keyframes
    }

    /// `keyframes(inFolders:maxCount:)` with the counts for the log.
    static func load(inFolders folders: [RawScanFolder], maxCount: Int) -> Report {
        var entries: [Entry] = []
        var failedFolders = 0
        for folder in folders {
            do {
                entries.append(contentsOf: try usableEntries(in: folder))
            } catch {
                failedFolders += 1
                LogStore.shared.write("texture: keyframes of \(folder.url.lastPathComponent) unreadable (\(error))",
                                      category: logCategory)
            }
        }
        var report = select(entries, maxCount: maxCount)
        report.failedFolders = failedFolders
        return report
    }

    /// Evenly spaced indices into `0 ..< count`, at most `max` of them, strictly increasing,
    /// first 0 and last `count - 1` when more than one is picked: index i is
    /// `round(i * (count - 1) / (max - 1))`. All indices when `count <= max`; empty when either
    /// is not positive; the middle index when `max` is 1.
    static func subsample(count: Int, max: Int) -> [Int] {
        guard count > 0, max > 0 else { return [] }
        if count <= max { return Array(0..<count) }
        if max == 1 { return [(count - 1) / 2] }
        let span = count - 1
        let steps = max - 1
        var out: [Int] = []
        out.reserveCapacity(max)
        for i in 0..<max {
            let scaled = i * span
            out.append((scaled + steps / 2) / steps)
        }
        return out
    }

    /// Records usable for texturing, in keyframe index order: normal tracking, positive
    /// finite focal lengths, a finite principal point, image sizes in 1...maxImageSide, a
    /// finite pose and a finite timestamp.
    static func candidates(_ records: [KeyframeRecord]) -> [KeyframeRecord] {
        let usable = records.filter { $0.trackingNormal && isUsable($0) }
        return usable.enumerated().sorted { (a, b) -> Bool in
            if a.element.index != b.element.index { return a.element.index < b.element.index }
            return a.offset < b.offset
        }.map { $0.element }
    }

    /// True when a record's intrinsics, pose and timestamp can drive the baker.
    static func isUsable(_ record: KeyframeRecord) -> Bool {
        let k = record.intrinsics
        guard k.width > 0, k.height > 0, k.width <= maxImageSide, k.height <= maxImageSide else { return false }
        guard k.fx.isFinite, k.fy.isFinite, k.fx > 0, k.fy > 0 else { return false }
        guard k.cx.isFinite, k.cy.isFinite, record.timestamp.isFinite else { return false }
        return record.transform.m.count == 16 && record.transform.m.allSatisfy { $0.isFinite }
    }

    /// True when an image of `imageWidth` x `imageHeight` has the aspect ratio of
    /// `resolution` within `maxAspectMismatch` (relative).
    static func aspectMatches(imageWidth: Int, imageHeight: Int, resolution: SIMD2<Float>) -> Bool {
        guard imageWidth > 0, imageHeight > 0, resolution.x > 0, resolution.y > 0 else { return false }
        let imageAspect = Float(imageWidth) / Float(imageHeight)
        let expected = resolution.x / resolution.y
        return abs(imageAspect - expected) <= maxAspectMismatch * expected
    }

    /// The baker keyframe of one record: the lazily opened image, intrinsics from
    /// `record.intrinsics.matrix` for its width and height, `cameraToWorld` from
    /// `record.transform.simd`, and the exposure offset when finite. Nil when the image
    /// cannot be opened or its aspect ratio does not match the intrinsics.
    static func makeKeyframe(_ record: KeyframeRecord, imageURL: URL) -> TXKeyframe? {
        guard let image = lazyImage(at: imageURL) else { return nil }
        let resolution = SIMD2<Float>(Float(record.intrinsics.width), Float(record.intrinsics.height))
        guard aspectMatches(imageWidth: image.width, imageHeight: image.height, resolution: resolution) else { return nil }
        let offset: Float? = record.exposureOffset.isFinite ? record.exposureOffset : nil
        return TXKeyframe(image: image, intrinsics: record.intrinsics.matrix, imageResolution: resolution,
                          cameraToWorld: record.transform.simd, timestamp: record.timestamp, exposureOffset: offset)
    }

    /// A CGImage for the first image of the file at `url` that is decoded only when drawn and
    /// never cached (`kCGImageSourceShouldCache: false` on the source and the image), or nil
    /// when the file is missing or not an image.
    static func lazyImage(at url: URL) -> CGImage? {
        let noCache = [kCGImageSourceShouldCache as String: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, noCache) else { return nil }
        guard CGImageSourceGetCount(source) > 0 else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, noCache)
    }

    /// Usable records of one folder whose image path resolves inside the folder and exists.
    private static func usableEntries(in folder: RawScanFolder) throws -> [Entry] {
        let reader = RawScanReader(folder: folder)
        let records = try reader.keyframes()
        var entries: [Entry] = []
        var missing = 0
        for record in candidates(records) {
            guard let url = reader.imageURL(for: record), FileManager.default.fileExists(atPath: url.path) else {
                missing += 1
                continue
            }
            entries.append(Entry(record: record, imageURL: url))
        }
        if missing > 0 {
            LogStore.shared.write("texture: \(missing) keyframe image(s) missing in \(folder.url.lastPathComponent)",
                                  category: logCategory)
        }
        return entries
    }

    /// Subsamples `entries` to at most `maxCount` and opens their images.
    private static func select(_ entries: [Entry], maxCount: Int) -> Report {
        var keyframes: [TXKeyframe] = []
        var unreadable = 0
        let picks = subsample(count: entries.count, max: maxCount)
        keyframes.reserveCapacity(picks.count)
        for i in picks {
            let entry = entries[i]
            if let keyframe = makeKeyframe(entry.record, imageURL: entry.imageURL) {
                keyframes.append(keyframe)
            } else {
                unreadable += 1
            }
        }
        if unreadable > 0 {
            LogStore.shared.write("texture: \(unreadable) keyframe image(s) unreadable or with the wrong aspect ratio",
                                  category: logCategory)
        }
        return Report(keyframes: keyframes, candidates: entries.count, unreadable: unreadable, failedFolders: 0)
    }
}

/// Loads the mesh TextureLowStep bakes (ARCHITECTURE 5.5): the room's view mesh
/// (`mesh_view.mchk`, measured faces only), else the measured mesh simplified to the
/// fallback budget. Stateless and safe on any thread.
enum TextureMeshLoader {
    /// Where the baked mesh came from, for the log.
    enum Source: String, Equatable {
        /// `mesh_view.mchk` as written by MeshModel.
        case view
        /// `mesh_view.mchk` simplified further (reduced variant).
        case viewSimplified
        /// `mesh.mchk`, small enough to use as is.
        case measured
        /// `mesh.mchk` simplified to the budget.
        case measuredSimplified
    }

    /// The mesh to bake, or nil when the room has neither a view nor a measured mesh with
    /// faces. `viewTarget` caps the view mesh (nil keeps it as is); the measured fallback is
    /// capped at `min(fallbackTarget, viewTarget)`. An unreadable view mesh is logged and
    /// the measured mesh used; an unreadable measured mesh (after that) throws.
    static func load(_ package: ProjectPackage, room: UUID, viewTarget: Int?,
                     fallbackTarget: Int) throws -> (mesh: MeshWithAttributes, source: Source)? {
        var view: MeshWithAttributes?
        do {
            view = try MeshModelStore.loadView(package, room: room)
        } catch {
            LogStore.shared.write("texture room \(room.uuidString): view mesh unreadable (\(error)), trying the measured mesh",
                                  category: KeyframeLoader.logCategory)
        }
        if let mesh = view, mesh.triangleCount > 0 {
            if let target = viewTarget, mesh.triangleCount > target {
                return (simplified(mesh, target: target), .viewSimplified)
            }
            return (mesh, .view)
        }
        guard let measured = try MeshModelStore.loadMeasured(package, room: room), measured.triangleCount > 0 else {
            return nil
        }
        let target = Swift.min(fallbackTarget, viewTarget ?? fallbackTarget)
        if measured.triangleCount > target {
            return (simplified(measured, target: target), .measuredSimplified)
        }
        return (measured, .measured)
    }

    /// `mesh` simplified with `MeshSimplify` to at most about `target` triangles (class
    /// boundaries kept); the mesh itself when it is already small enough.
    static func simplified(_ mesh: MeshWithAttributes, target: Int) -> MeshWithAttributes {
        guard target > 0, mesh.triangleCount > target else { return mesh }
        let options = MeshSimplify.Options(targetTriangleCount: target)
        return MeshSimplify.simplify(mesh, options: options).mesh
    }
}
