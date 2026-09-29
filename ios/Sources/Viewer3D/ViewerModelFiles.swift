import Foundation
import RealityKit
import simd

/// Errors of `ViewerModel.loadModel`.
enum ViewerModelError: Error, Equatable {
    /// The model file does not exist (or the URL names a folder).
    case missingFile
    /// A newer `load`, `unload` or `removeModels` replaced the content while the file loaded;
    /// the entity was discarded.
    case superseded
}

/// Pure bounds helpers (any queue).
enum ViewerBoundsMath {
    /// True when `box` holds points and every corner coordinate is finite.
    static func isUsable(_ box: AABB3) -> Bool {
        guard !box.isEmpty else { return false }
        let low = box.min
        let high = box.max
        let lowFinite = low.x.isFinite && low.y.isFinite && low.z.isFinite
        let highFinite = high.x.isFinite && high.y.isFinite && high.z.isFinite
        return lowFinite && highFinite
    }

    /// Smallest box containing both boxes. An empty box (or one with a non-finite corner) is
    /// ignored; two of them give `AABB3.empty`.
    static func union(_ a: AABB3, _ b: AABB3) -> AABB3 {
        let useA = isUsable(a)
        let useB = isUsable(b)
        if useA && useB { return a.union(b) }
        if useA { return a }
        if useB { return b }
        return .empty
    }

    /// Bounds of the 8 corners of `box` moved by `matrix`, an affine transform (the bottom
    /// row is ignored). An unusable box gives `AABB3.empty`; corners that become non-finite
    /// are left out.
    static func transformed(_ box: AABB3, by matrix: simd_float4x4) -> AABB3 {
        guard isUsable(box) else { return .empty }
        var result = AABB3.empty
        for corner in corners(of: box) {
            let moved = simd_mul(matrix, SIMD4<Float>(corner, 1))
            let point = SIMD3<Float>(moved.x, moved.y, moved.z)
            guard point.x.isFinite, point.y.isFinite, point.z.isFinite else { continue }
            result.expand(point)
        }
        return result
    }

    /// The 8 corners of `box`: bit 0 of the index picks max x, bit 1 max y, bit 2 max z.
    static func corners(of box: AABB3) -> [SIMD3<Float>] {
        (0..<8).map { i -> SIMD3<Float> in
            let x: Float = (i & 1) == 0 ? box.min.x : box.max.x
            let y: Float = (i & 2) == 0 ? box.min.y : box.max.y
            let z: Float = (i & 4) == 0 ? box.min.z : box.max.z
            return SIMD3<Float>(x, y, z)
        }
    }

    /// The box between `low` and `high` (for example a RealityKit `BoundingBox`), or
    /// `AABB3.empty` when it is empty or not finite.
    static func box(min low: SIMD3<Float>, max high: SIMD3<Float>) -> AABB3 {
        let box = AABB3(min: low, max: high)
        return isUsable(box) ? box : .empty
    }

    /// Log text of a box in meters, or "empty".
    static func logText(_ box: AABB3) -> String {
        guard isUsable(box) else { return "empty" }
        return "min \(logText(box.min)) max \(logText(box.max))"
    }

    /// Log text of a vector in meters with millimeter digits.
    static func logText(_ v: SIMD3<Float>) -> String {
        String(format: "(%.3f, %.3f, %.3f)", Double(v.x), Double(v.y), Double(v.z))
    }
}

/// The model files `ViewerModel.loadModel` added: one parent entity per layer under `root`
/// (enabled with its layer), one holder entity per file carrying the caller's transform,
/// their world bounds and the pick entries of their pick meshes. Owned by `ViewerModel`,
/// whose root anchor holds `root` for its whole life; models are never evicted on a memory
/// warning (Object Capture output is under 50k triangles, RESEARCH 3.3).
@MainActor final class ViewerLoadedModels {
    /// One loaded model file.
    struct Record {
        /// Pick part id ("model.<n>.<file name>"), also the holder entity's name.
        let partID: String
        /// Layer whose parent holds the model.
        let layer: ViewerLayer
        /// Entity carrying the caller's transform; the loaded file's entity is its only child.
        let holder: Entity
        /// World bounds after the transform; `AABB3.empty` when the file had no geometry.
        let bounds: AABB3
    }

    /// Prefix of every model part id.
    static let partIDPrefix = "model."

    /// Parent of the per-layer model parents; a child of the viewer's root anchor.
    let root: Entity
    /// One parent per layer; `isEnabled` follows the layer's visibility.
    private let layerRoots: [ViewerLayer: Entity]
    /// Loaded models in load order.
    private(set) var records: [Record] = []
    /// Pick entries of the models that were given a pick mesh.
    private(set) var entries: [ViewerPickEntry] = []
    /// Bumped by `removeAll`; a model load that started under an older value is superseded.
    private(set) var generation = 0
    /// Counter for part ids.
    private var serial = 0

    /// Creates the empty model tree with one parent per layer, enabled per `visible`.
    init(visible: Set<ViewerLayer>) {
        let fresh = Entity()
        fresh.name = "viewer.models"
        var layers: [ViewerLayer: Entity] = [:]
        for layer in ViewerLayer.allCases {
            let parent = Entity()
            parent.name = "viewer.models.\(layer.rawValue)"
            parent.isEnabled = visible.contains(layer)
            fresh.addChild(parent)
            layers[layer] = parent
        }
        root = fresh
        layerRoots = layers
    }

    /// Number of loaded models.
    var count: Int { records.count }

    /// Union of the loaded models' world bounds; `AABB3.empty` when none.
    var bounds: AABB3 {
        records.reduce(AABB3.empty) { ViewerBoundsMath.union($0, $1.bounds) }
    }

    /// Shows or hides the models of `layer`.
    func setVisible(_ layer: ViewerLayer, _ visible: Bool) {
        layerRoots[layer]?.isEnabled = visible
    }

    /// A new unique part id for a model file.
    func makePartID(fileName: String) -> String {
        serial &+= 1
        return "\(ViewerLoadedModels.partIDPrefix)\(serial).\(fileName)"
    }

    /// Hangs `holder` under the parent of `layer`, so it shows and hides with the layer.
    func attach(_ holder: Entity, layer: ViewerLayer) {
        (layerRoots[layer] ?? root).addChild(holder)
    }

    /// Records a model whose holder is attached.
    func record(_ record: Record) {
        records.append(record)
    }

    /// Adds the pick entry of a recorded model.
    func addEntry(_ entry: ViewerPickEntry) {
        entries.append(entry)
    }

    /// Removes every model entity and pick entry, and supersedes model loads in flight.
    func removeAll() {
        generation &+= 1
        for parent in layerRoots.values {
            for child in Array(parent.children) {
                child.removeFromParent()
            }
        }
        for model in records where model.holder.parent != nil {
            model.holder.removeFromParent()
        }
        records = []
        entries = []
    }

    /// Size in bytes of the regular file at `url`; nil when it is missing, a folder or not a
    /// file URL. Any queue.
    nonisolated static func fileSize(of url: URL) -> Int64? {
        guard url.isFileURL else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return nil }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = attributes?[.size] as? NSNumber
        return size?.int64Value ?? 0
    }
}

/// Model files (build 5): the Object Capture USDZ shown with its own PBR materials next to
/// ordinary parts, pickable through a pick mesh and framed with the content.
@MainActor extension ViewerModel {
    /// Adds a USDZ model file under `layer` (its own parent entity per layer, enabled with the
    /// layer) with `try await Entity(contentsOf: url)`, sets the entity's transform to
    /// `transform` (ObjectUI passes the uniform scale correction), and returns its world bounds
    /// (`visualBounds(recursive: true, relativeTo: nil)`). When `pickMesh` is given (the same
    /// geometry in world coordinates, already placed like the entity after `transform`, for
    /// example ObjectModel's scale-corrected mesh.mchk), a `MeshBVH` of it is built off main and
    /// hits report `pickTag` while `layer` is visible. The camera frames
    /// the union of the content and model bounds unless the user moved it. Call after `load(_:)`
    /// returned; `load`, `unload` and `removeModels` remove models.
    ///
    /// Details: the transform goes on a holder entity whose only child is the loaded entity,
    /// so the file's own root transform is kept and its materials and texture coordinates are
    /// never touched. A nil `pickTag` leaves the model unpickable, as for `ViewerPart`. When
    /// the entity has no visual bounds the pick mesh's bounds are used. Throws
    /// `ViewerModelError.missingFile` before loading, `.superseded` (and keeps no entity) when a
    /// newer `load`, `unload` or `removeModels` ran meanwhile, `CancellationError` when the
    /// calling task was cancelled before the entity was added, and RealityKit's error when the
    /// file cannot be read. Logs file size, entity bounds, load time and the pick mesh.
    @discardableResult
    func loadModel(_ url: URL, layer: ViewerLayer = .realistic, transform: simd_float4x4 = matrix_identity_float4x4,
                   pickMesh: TriangleMesh? = nil, pickTag: ViewerPickTag? = .rawMesh) async throws -> AABB3 {
        let started = ProcessInfo.processInfo.systemUptime
        let fileName = url.lastPathComponent
        guard let bytes = ViewerLoadedModels.fileSize(of: url) else {
            LogStore.shared.write("model \(fileName): file missing", category: "viewer")
            throw ViewerModelError.missingFile
        }
        let token = models.generation
        let loaded: Entity
        do {
            loaded = try await Entity(contentsOf: url)
        } catch {
            guard token == models.generation else {
                logModelSuperseded(fileName)
                throw ViewerModelError.superseded
            }
            LogStore.shared.write("model \(fileName): load failed after \(bytes) bytes: \(error)", category: "viewer")
            throw error
        }
        guard token == models.generation else {
            logModelSuperseded(fileName)
            throw ViewerModelError.superseded
        }
        guard !Task.isCancelled else {
            LogStore.shared.write("model \(fileName): load cancelled, entity discarded", category: "viewer")
            throw CancellationError()
        }
        let loadSeconds = ProcessInfo.processInfo.systemUptime - started

        let partID = models.makePartID(fileName: fileName)
        let holder = Entity()
        holder.name = partID
        holder.transform = Transform(matrix: transform)
        holder.addChild(loaded)
        models.attach(holder, layer: layer)
        let visual = holder.visualBounds(recursive: true, relativeTo: nil)
        var bounds = ViewerBoundsMath.box(min: visual.min, max: visual.max)
        if !ViewerBoundsMath.isUsable(bounds), let mesh = pickMesh {
            bounds = ViewerBoundsMath.union(.empty, mesh.boundingBox)
        }
        models.record(ViewerLoadedModels.Record(partID: partID, layer: layer, holder: holder, bounds: bounds))
        frameSceneUnlessMoved()

        var pickText = "none"
        if let mesh = pickMesh, let tag = pickTag {
            let entry = await Task.detached(priority: .userInitiated) { () -> ViewerPickEntry in
                ViewerPicking.entry(for: mesh, partID: partID, pickTag: tag, layer: layer)
            }.value
            guard token == models.generation else {
                logModelSuperseded(fileName)
                throw ViewerModelError.superseded
            }
            models.addEntry(entry)
            pickText = "\(entry.bvh.triangleCount) triangles"
        } else if pickMesh != nil {
            pickText = "given without a pick tag (not pickable)"
        }
        let totalSeconds = ProcessInfo.processInfo.systemUptime - started
        let loadText = String(format: "%.2f", loadSeconds)
        let totalText = String(format: "%.2f", totalSeconds)
        let boundsText = ViewerBoundsMath.logText(bounds)
        let extentsText = ViewerBoundsMath.logText(visual.extents)
        let fields: [String] = [
            "\(bytes) bytes", "layer \(layer.rawValue)", "bounds \(boundsText)", "entity extents \(extentsText)",
            "loaded in \(loadText) s", "ready in \(totalText) s", "pick mesh \(pickText)",
        ]
        LogStore.shared.write("model \(fileName): " + fields.joined(separator: ", "), category: "viewer")
        return bounds
    }

    /// Removes every model added by `loadModel`; a model file still loading ends with
    /// `ViewerModelError.superseded`. Content, layer visibility and the camera stay.
    func removeModels() {
        let removed = models.count
        models.removeAll()
        LogStore.shared.write("removed \(removed) models", category: "viewer")
    }

    /// Union of the loaded models' world bounds; `AABB3.empty` when none.
    var modelBounds: AABB3 {
        models.bounds
    }

    /// Logs that a model load lost to a newer load, unload or removeModels.
    private func logModelSuperseded(_ fileName: String) {
        LogStore.shared.write("model \(fileName): superseded by a newer load, entity discarded", category: "viewer")
    }
}
