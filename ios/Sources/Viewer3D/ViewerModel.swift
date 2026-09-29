import Foundation
import Combine
import RealityKit
import UIKit
import simd

/// Main actor. Owns the ARView scene, camera and picking structures.
///
/// The model keeps the whole entity graph (a root `AnchorEntity(world:)` with the
/// `PerspectiveCamera`, a headlight and one parent entity per `ViewerLayer`) independent of any
/// view: `ViewerContainer` creates the `ARView` and attaches it, so content survives the
/// container being rebuilt. Layer visibility persists across loads; every layer starts
/// visible except `.cleanOccluded` (shown with Hide Furniture). On a memory warning the parts
/// of hidden layers are released and uploaded again when their layer is shown. Models from
/// `loadModel` (ViewerModelFiles.swift) follow `setVisible`, are never evicted, and go on `load`.
@MainActor final class ViewerModel: ObservableObject {
    /// True while `load` is uploading parts.
    @Published private(set) var isLoading: Bool = false
    /// Bumps on every camera change (for label overlays), including view size changes.
    @Published private(set) var cameraRevision: Int = 0

    /// Parts uploaded between yields.
    static let uploadBatchSize = 16
    /// Camera near plane in meters.
    static let nearPlane: Float = 0.01
    /// Camera far plane in meters.
    static let farPlane: Float = 1000
    /// Vertical field of view in degrees.
    static let fieldOfView: Float = ViewerOrbitMath.defaultFieldOfViewDegrees
    /// Closest eye distance in meters.
    static let minimumDistance: Float = 0.05
    /// Width over height assumed before the view has a size (a portrait iPhone).
    static let assumedAspect: Float = 0.46
    /// Intensity of the light that follows the camera, in lux.
    static let headlightIntensity: Float = 1500

    /// Root anchor at the world origin; holds the camera and the content.
    private let root: AnchorEntity
    /// The viewer camera, posed from `orbitState`.
    private let camera: PerspectiveCamera
    /// Parent of the layer entities; replaced on every load.
    private var contentRoot: Entity
    /// One parent per layer under `contentRoot`.
    private var layerRoots: [ViewerLayer: Entity]
    /// Layers currently shown.
    private(set) var visibleLayers: Set<ViewerLayer> = ViewerLayer.defaultVisible
    /// The content of the last load (kept for re-uploading evicted layers and framing).
    private(set) var content: ViewerContent = .empty
    /// Pick structures of the current content.
    private(set) var pickEntries: [ViewerPickEntry] = []
    /// Texture resources of the current content by page URL.
    private var textures: [URL: TextureResource] = [:]
    /// Pages that failed to load during the current content.
    private var failedTextures: Set<URL> = []
    /// Hidden layers whose parts were released after a memory warning.
    private var evictedLayers: Set<ViewerLayer> = []
    /// Layers being uploaded again after eviction.
    private var reuploading: Set<ViewerLayer> = []
    /// Model files added by `loadModel`, their layer parents and pick entries.
    let models: ViewerLoadedModels
    /// Incremented by every load and unload; older uploads stop when it changes.
    private var generation = 0
    /// Orbit camera state.
    private(set) var orbitState = ViewerOrbitState()
    /// Bounds the camera was last framed on.
    private var framedBounds: AABB3?
    /// True once the user moved the camera since the last framing.
    private var userMovedCamera = false
    /// The attached view, if any.
    private(set) weak var arView: ARView?
    /// Size of the attached view in points.
    private(set) var viewSize: CGSize = .zero
    /// Notification subscriptions.
    private var cancellables: Set<AnyCancellable> = []

    /// Counters of one upload pass.
    private struct UploadStats {
        var parts = 0
        var triangles = 0
        var meshSeconds: Double = 0
        var completed = true
    }

    /// Creates an empty scene with the camera at the home view.
    init() {
        let anchor = AnchorEntity(world: SIMD3<Float>(0, 0, 0))
        let cameraEntity = PerspectiveCamera()
        cameraEntity.camera = PerspectiveCameraComponent(near: ViewerModel.nearPlane, far: ViewerModel.farPlane,
                                                         fieldOfViewInDegrees: ViewerModel.fieldOfView)
        let headlight = DirectionalLight()
        headlight.light.intensity = ViewerModel.headlightIntensity
        cameraEntity.addChild(headlight)
        anchor.addChild(cameraEntity)
        let made = ViewerModel.makeContentRoot(visible: ViewerLayer.defaultVisible)
        anchor.addChild(made.root)
        let loadedModels = ViewerLoadedModels(visible: ViewerLayer.defaultVisible)
        anchor.addChild(loadedModels.root)
        root = anchor
        camera = cameraEntity
        contentRoot = made.root
        layerRoots = made.layers
        models = loadedModels
        applyCamera()
        NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let model = self else { return }
                    model.handleMemoryWarning()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - View attachment

    /// Shows the scene in `view` (called by `ViewerContainer`). Moves the scene out of any
    /// previously attached view.
    func attach(_ view: ARView) {
        if arView === view { return }
        if let previous = root.scene {
            previous.removeAnchor(root)
        }
        arView = view
        view.scene.addAnchor(root)
        updateViewSize(view.bounds.size)
    }

    /// Removes the scene from `view` when it is the attached one.
    func detach(_ view: ARView) {
        guard arView === view else { return }
        view.scene.removeAnchor(root)
        arView = nil
    }

    /// Records the view size; re-frames when the user has not moved the camera yet (the
    /// framing depends on the aspect ratio) and bumps `cameraRevision` so labels move.
    func updateViewSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0, size != viewSize else { return }
        viewSize = size
        let bounds = sceneBounds
        if !userMovedCamera && !bounds.isEmpty {
            frame(bounds)
        } else {
            cameraRevision &+= 1
        }
    }

    // MARK: - Content

    /// Replaces the scene. Uploads parts in batches of 16 with `await Task.yield()` between batches;
    /// builds a MeshBVH per pickable part off main.
    ///
    /// A second call cancels this one: the older upload stops at its next suspension and
    /// leaves the scene to the newer call. Cancelling the calling task stops the upload and
    /// clears `isLoading`. The camera is framed on the new bounds unless they match the bounds
    /// already framed (switching styles of the same model keeps the view). Parts that are
    /// empty or have out-of-range indices are skipped. Models added by `loadModel` are
    /// removed first (a model file still loading ends with `ViewerModelError.superseded`).
    func load(_ content: ViewerContent) async {
        generation &+= 1
        let token = generation
        let started = ProcessInfo.processInfo.systemUptime
        models.removeAll()
        isLoading = true
        self.content = content
        pickEntries = []
        textures = [:]
        failedTextures = []
        evictedLayers = []
        reuploading = []
        replaceContentRoot()
        frameIfNeeded(content.bounds)

        let pickable = content.parts.filter { $0.pickTag != nil }
        let pickTask = Task.detached(priority: .userInitiated) { () -> [ViewerPickEntry] in
            ViewerPicking.entries(for: pickable)
        }
        let stats = await upload(content.parts, token: token)
        guard token == generation else {
            pickTask.cancel()
            return
        }
        guard stats.completed else {
            pickTask.cancel()
            isLoading = false
            LogStore.shared.write("load stopped after \(stats.parts) of \(content.parts.count) parts", category: "viewer")
            return
        }
        let entries = await pickTask.value
        guard token == generation else { return }
        pickEntries = entries
        isLoading = false
        let seconds = ProcessInfo.processInfo.systemUptime - started
        let perPart = stats.parts > 0 ? stats.meshSeconds * 1000 / Double(stats.parts) : 0
        let secondsText = String(format: "%.2f", seconds)
        let perPartText = String(format: "%.1f", perPart)
        let message = "loaded \(stats.parts) parts, \(stats.triangles) triangles in \(secondsText) s, mesh resource \(perPartText) ms per part, \(entries.count) pickable"
        LogStore.shared.write(message, category: "viewer")
    }

    /// Removes all content and models (for example while a memory-heavy step runs) and stops
    /// any upload or model load.
    func unload() {
        generation &+= 1
        models.removeAll()
        content = .empty
        pickEntries = []
        textures = [:]
        failedTextures = []
        evictedLayers = []
        reuploading = []
        framedBounds = nil
        replaceContentRoot()
        isLoading = false
    }

    /// Shows or hides every part and model of `layer` (parent `isEnabled`); hidden layers are
    /// not pickable. The choice persists across loads.
    func setVisible(_ layer: ViewerLayer, _ visible: Bool) {
        if visible {
            visibleLayers.insert(layer)
        } else {
            visibleLayers.remove(layer)
        }
        layerRoots[layer]?.isEnabled = visible
        models.setVisible(layer, visible)
        guard visible, evictedLayers.contains(layer), !reuploading.contains(layer) else { return }
        evictedLayers.remove(layer)
        reuploading.insert(layer)
        let token = generation
        let parts = content.parts.filter { $0.layer == layer }
        Task { [weak self] in
            await self?.reupload(parts, layer: layer, token: token)
        }
    }

    /// True when `layer` is shown.
    func isVisible(_ layer: ViewerLayer) -> Bool {
        visibleLayers.contains(layer)
    }

    // MARK: - Camera

    /// Frames the current content and models, keeping the current yaw and pitch (double tap).
    func frameAll() {
        userMovedCamera = false
        let bounds = sceneBounds
        if bounds.isEmpty {
            orbitState.target = SIMD3<Float>(0, 0, 0)
            orbitState.distance = ViewerOrbitMath.emptyDistance
            framedBounds = nil
            applyCamera()
        } else {
            frame(bounds)
        }
    }

    /// Union of the content bounds and the loaded models' bounds: what framing, the dolly
    /// limit and double tap use.
    var sceneBounds: AABB3 {
        ViewerBoundsMath.union(content.bounds, models.bounds)
    }

    /// Frames `sceneBounds` after a model was added, unless the user moved the camera since
    /// the last framing.
    func frameSceneUnlessMoved() {
        let bounds = sceneBounds
        guard !userMovedCamera, !bounds.isEmpty else { return }
        frame(bounds)
    }

    /// Returns to the home view: default yaw and pitch, framed on content and models (Reset View).
    func resetView() {
        orbitState.yaw = ViewerOrbitMath.defaultYaw
        orbitState.pitch = ViewerOrbitMath.defaultPitch
        frameAll()
    }

    /// One-finger drag by `delta` points: orbits around the target.
    func orbitCamera(by delta: CGPoint) {
        orbitState.orbit(dx: Float(delta.x), dy: Float(delta.y))
        userMovedCamera = true
        applyCamera()
    }

    /// Two-finger drag by `delta` points: moves the target with the fingers.
    func panCamera(by delta: CGPoint) {
        let height = viewSize.height > 0 ? Float(viewSize.height) : 800
        orbitState.pan(dx: Float(delta.x), dy: Float(delta.y), viewHeight: height,
                       verticalFieldOfViewDegrees: ViewerModel.fieldOfView)
        userMovedCamera = true
        applyCamera()
    }

    /// Pinch by `scale` (above 1 spreads the fingers and moves closer).
    func dollyCamera(scale: CGFloat) {
        let bounds = sceneBounds
        let radius = bounds.isEmpty ? 1 : simd_length(bounds.size) * 0.5
        let farthest = Swift.max(50, radius * 10)
        orbitState.dolly(scale: Float(scale), minDistance: ViewerModel.minimumDistance, maxDistance: farthest)
        userMovedCamera = true
        applyCamera()
    }

    // MARK: - Private

    /// A fresh content root with one parent per layer (enabled per `visible`).
    private static func makeContentRoot(visible: Set<ViewerLayer>) -> (root: Entity, layers: [ViewerLayer: Entity]) {
        let fresh = Entity()
        fresh.name = "viewer.content"
        var layers: [ViewerLayer: Entity] = [:]
        for layer in ViewerLayer.allCases {
            let parent = Entity()
            parent.name = "viewer.layer.\(layer.rawValue)"
            parent.isEnabled = visible.contains(layer)
            fresh.addChild(parent)
            layers[layer] = parent
        }
        return (fresh, layers)
    }

    /// Drops the current content entities and installs empty layer parents.
    private func replaceContentRoot() {
        contentRoot.removeFromParent()
        let made = ViewerModel.makeContentRoot(visible: visibleLayers)
        root.addChild(made.root)
        contentRoot = made.root
        layerRoots = made.layers
    }

    /// True while the upload that got `token` is still wanted.
    private func isCurrent(_ token: Int) -> Bool {
        token == generation && !Task.isCancelled
    }

    /// Packs parts off main in batches of 16, loads their texture pages, creates one entity per
    /// part on main and yields between batches. Stops when `token` is no longer current.
    private func upload(_ parts: [ViewerPart], token: Int) async -> UploadStats {
        var stats = UploadStats()
        var index = 0
        while index < parts.count {
            let end = Swift.min(index + ViewerModel.uploadBatchSize, parts.count)
            let batch = Array(parts[index..<end])
            index = end
            let packed = await Task.detached(priority: .userInitiated) { () -> [ViewerPackedPart] in
                batch.compactMap { ViewerRenderMesh.packedPart($0) }
            }.value
            guard isCurrent(token) else { stats.completed = false; return stats }
            await loadTextures(for: packed, token: token)
            guard isCurrent(token) else { stats.completed = false; return stats }
            for item in packed {
                // A memory warning during the upload evicted this hidden layer; its parts are
                // uploaded again (all of them) when the layer is shown.
                if evictedLayers.contains(item.layer) { continue }
                let material = ViewerRenderMesh.makeMaterial(item.material, textures: textures)
                let before = ProcessInfo.processInfo.systemUptime
                do {
                    let entity = try await ViewerRenderMesh.makeEntity(item, material: material)
                    stats.meshSeconds += ProcessInfo.processInfo.systemUptime - before
                    guard isCurrent(token) else { stats.completed = false; return stats }
                    layerRoots[item.layer]?.addChild(entity)
                    stats.parts += 1
                    stats.triangles += item.indices.count / 3
                } catch {
                    LogStore.shared.write("part \(item.id) failed: \(error)", category: "viewer")
                }
            }
            await Task.yield()
        }
        return stats
    }

    /// Loads the texture pages the batch needs that are not cached yet.
    private func loadTextures(for packed: [ViewerPackedPart], token: Int) async {
        for item in packed {
            guard case .texture(let url) = item.material, textures[url] == nil, !failedTextures.contains(url) else { continue }
            let texture = await ViewerRenderMesh.loadTexture(url)
            guard isCurrent(token) else { return }
            if let texture = texture {
                textures[url] = texture
            } else {
                failedTextures.insert(url)
            }
        }
    }

    /// Uploads the parts of an evicted layer again when it is shown.
    private func reupload(_ parts: [ViewerPart], layer: ViewerLayer, token: Int) async {
        let stats = await upload(parts, token: token)
        reuploading.remove(layer)
        guard token == generation else { return }
        LogStore.shared.write("layer \(layer.rawValue) restored: \(stats.parts) parts", category: "viewer")
    }

    /// Releases the parts of hidden layers (ARCHITECTURE 12.1) and the texture cache. Models
    /// stay (Object Capture output is under 50k triangles, RESEARCH 3.3).
    private func handleMemoryWarning() {
        var released = 0
        for layer in ViewerLayer.allCases where !visibleLayers.contains(layer) && !reuploading.contains(layer) {
            guard let parent = layerRoots[layer] else { continue }
            let children = Array(parent.children)
            guard !children.isEmpty else { continue }
            for child in children {
                child.removeFromParent()
            }
            released += children.count
            evictedLayers.insert(layer)
        }
        textures = [:]
        LogStore.shared.write("memory warning: released \(released) parts of hidden layers, kept \(models.count) models",
                              category: "viewer")
    }

    /// Frames `bounds` unless they match the bounds already framed.
    private func frameIfNeeded(_ bounds: AABB3) {
        guard !bounds.isEmpty else { return }
        if let previous = framedBounds, ViewerModel.similar(previous, bounds) { return }
        userMovedCamera = false
        frame(bounds)
    }

    /// Points the camera at `bounds` for the attached view's aspect ratio.
    private func frame(_ bounds: AABB3) {
        let aspect = viewSize.width > 0 && viewSize.height > 0
            ? Float(viewSize.width / viewSize.height) : ViewerModel.assumedAspect
        let fov = ViewerOrbitMath.effectiveFieldOfView(verticalDegrees: ViewerModel.fieldOfView, aspect: aspect)
        let framing = ViewerOrbitMath.framing(bounds, fieldOfViewDegrees: fov)
        orbitState.target = framing.target
        orbitState.distance = framing.distance
        framedBounds = bounds
        applyCamera()
    }

    /// True when two boxes have about the same center and size (within a quarter of the
    /// larger bounding radius).
    nonisolated static func similar(_ a: AABB3, _ b: AABB3) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        let radiusA = simd_length(a.size) * 0.5
        let radiusB = simd_length(b.size) * 0.5
        let tolerance = 0.25 * Swift.max(Swift.max(radiusA, radiusB), ViewerOrbitMath.minimumRadius)
        return simd_distance(a.center, b.center) <= tolerance && abs(radiusA - radiusB) <= tolerance
    }

    /// Poses the camera entity from `orbitState` and bumps `cameraRevision`.
    private func applyCamera() {
        camera.transform = Transform(matrix: orbitState.cameraToWorld)
        cameraRevision &+= 1
    }
}
