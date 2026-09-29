import Foundation
import Metal
import RealityKit
import UIKit
import simd

/// Draws CoverageLive's anchors into an ARView. Main actor.
///
/// One `LowLevelMesh` per ARKit anchor with four parts (green, yellow, red, gray `UnlitMaterial`s,
/// transparent, `faceCulling = .none` because LiDAR winding is inconsistent), under one
/// `AnchorEntity(world:)` root. A refresh loop on main (a `Task` sleeping `refreshInterval`)
/// collects the anchors CoverageLive changed since the last tick into a pending set (latest
/// wins), picks up to `maxAnchorsPerTick` visible ones nearest first, packs them in one detached
/// task (at most one in flight) and copies the bytes into the meshes back on main. A mesh that
/// still fits is rewritten in place (the `MeshResource` shows it without a rebuild); one that does
/// not is recreated with 1.5x capacity. Nothing is rebuilt while hidden or while the thermal
/// policy turns the overlay off (serious or critical). The owner calls `detach()` when its
/// screen goes away; without it the root stays in the view's scene until the view is released.
@MainActor final class CoverageOverlayRenderer {
    /// Tunables of the refresh loop.
    struct Options: Equatable {
        /// Seconds between two ticks (at most about 3 rebuilds a second).
        var refreshInterval: Double = 0.33
        /// Most anchors packed and uploaded per tick.
        var maxAnchorsPerTick = 24
        /// Half angle of the view cone used to skip anchors outside the view, degrees.
        var halfAngleDegrees: Float = 60
        /// Anchors whose bounds are farther than this are skipped, meters.
        var maxDistance: Float = 6
        /// Colors and opacity of the four states.
        var style: CoverageOverlayStyle = .standard
        /// The defaults above.
        init() {}
    }

    /// One anchor on screen: its entity, mesh, capacities and the revision it shows.
    private struct Slot {
        var entity: ModelEntity
        var mesh: LowLevelMesh
        var vertexCapacity: Int
        var indexCapacity: Int
        var revision: UInt64
    }

    /// Timing and counters for the periodic log line.
    private struct Stats {
        var lastLog: Double = 0
        var ticks = 0
        var lastTickMilliseconds: Double = 0
        var maxTickMilliseconds: Double = 0
        var lastUploadMilliseconds: Double = 0
        var maxUploadMilliseconds: Double = 0
        var lastPackMilliseconds: Double = 0
        var uploads = 0
        var rebuilds = 0
        var packFailures = 0
        var meshFailures = 0
    }

    /// Seconds between two periodic log lines.
    static let logIntervalSeconds: Double = 30
    /// Seconds between two checks that drop anchors CoverageLive no longer has (a finished or new recording).
    static let reconcileIntervalSeconds: Double = 5
    /// Shortest and longest tick interval accepted from the options, seconds.
    static let minimumIntervalSeconds: Double = 0.05
    static let maximumIntervalSeconds: Double = 10

    /// Where the anchors and their states come from (read only).
    let source: CoverageLiveRecorder
    /// Thermal level of the capture; nil never freezes.
    let thermal: ThermalGovernor?
    /// Tunables given at creation.
    let options: Options

    /// User toggle (Show Colors / Hide Colors): the root's `isEnabled`.
    var isVisible: Bool = true {
        didSet { root?.isEnabled = isVisible }
    }
    /// True while `thermal.policy.overlayEnabled` is false (serious or critical): nothing is rebuilt.
    private(set) var isFrozen: Bool
    /// Anchor entities under the root.
    private(set) var anchorEntityCount: Int = 0

    /// The root entity while attached.
    private var root: AnchorEntity?
    /// The view the root was added to.
    private weak var arView: ARView?
    /// The refresh loop while attached.
    private var loop: Task<Void, Never>?
    /// Anchors on screen.
    private var slots: [UUID: Slot] = [:]
    /// Changed anchors waiting for a pack (latest wins) and the ones being packed.
    private var pending: [UUID: CoverageAnchorFaces] = [:]
    private var inFlight: [UUID: CoverageAnchorFaces] = [:]
    /// Newest CoverageLive revision already collected.
    private var lastRevision: UInt64 = 0
    /// A pack task is running.
    private var packInFlight = false
    /// Bumped by `detach()`, so a pack finishing after it is dropped.
    private var generation = 0
    /// Uptime of the last reconcile.
    private var lastReconcile: Double = 0
    /// The four materials in `stateOrder`.
    private let materials: [any RealityKit.Material]
    /// Periodic log values.
    private var stats = Stats()

    /// A renderer reading `source`. Nothing is drawn until `attach(to:)`.
    init(source: CoverageLiveRecorder, thermal: ThermalGovernor?, options: Options = Options()) {
        self.source = source
        self.thermal = thermal
        self.options = options
        materials = CoverageOverlayRenderer.makeMaterials(style: options.style)
        if let governor = thermal {
            isFrozen = CoverageOverlayRenderer.shouldFreeze(policy: governor.policy)
        } else {
            isFrozen = false
        }
    }

    /// Pure rule behind `isFrozen` (nonisolated so the self-test can call it off main).
    nonisolated static func shouldFreeze(policy: ThermalPolicy) -> Bool {
        !policy.overlayEnabled
    }

    // MARK: Attach and detach

    /// Adds one `AnchorEntity(world:)` root to `arView.scene` and starts the refresh loop. A second
    /// attach moves the root to the new view.
    func attach(to arView: ARView) {
        let anchor: AnchorEntity
        if let existing = root {
            anchor = existing
        } else {
            anchor = AnchorEntity(world: SIMD3<Float>(0, 0, 0))
            anchor.name = "coverage-overlay"
            root = anchor
        }
        anchor.isEnabled = isVisible
        if self.arView !== arView || anchor.scene == nil {
            if let previous = anchor.scene { previous.removeAnchor(anchor) }
            arView.scene.addAnchor(anchor)
            self.arView = arView
            CoverageOverlayPacking.log("attached (\(slots.count) anchors, frozen \(isFrozen), visible \(isVisible))")
        }
        startLoop()
    }

    /// Stops the loop and removes the root (entities and meshes released). Idempotent.
    func detach() {
        loop?.cancel()
        loop = nil
        generation += 1
        packInFlight = false
        inFlight = [:]
        pending = [:]
        lastRevision = 0
        lastReconcile = 0
        let wasAttached = root != nil
        if let anchor = root {
            if let scene = anchor.scene { scene.removeAnchor(anchor) }
            for slot in slots.values { slot.entity.removeFromParent() }
        }
        slots = [:]
        anchorEntityCount = 0
        root = nil
        arView = nil
        if wasAttached { CoverageOverlayPacking.log("detached after \(stats.ticks) ticks, \(stats.uploads) uploads") }
    }

    /// Starts the refresh loop unless it runs. The loop holds the renderer and the root weakly and
    /// ends when it is cancelled or the renderer is released; a renderer released without
    /// `detach()` has its root taken out of the scene by the loop's last pass.
    private func startLoop() {
        guard loop == nil, let anchorRef = root else { return }
        let requested = options.refreshInterval.isFinite ? options.refreshInterval : 0.33
        let interval = min(max(requested, CoverageOverlayRenderer.minimumIntervalSeconds),
                           CoverageOverlayRenderer.maximumIntervalSeconds)
        let nanoseconds = UInt64(interval * 1_000_000_000)
        loop = Task { @MainActor [weak self, weak anchorRef] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: nanoseconds)
                if Task.isCancelled { return }
                guard let self else {
                    if let orphan = anchorRef, let scene = orphan.scene { scene.removeAnchor(orphan) }
                    return
                }
                self.tick()
            }
        }
    }

    // MARK: Tick

    /// One refresh: freeze check, collect changed anchors, drop vanished ones, schedule and start
    /// one pack. Frozen or hidden skips everything but the checks.
    private func tick() {
        let started = DispatchTime.now().uptimeNanoseconds
        let now = ProcessInfo.processInfo.systemUptime
        stats.ticks += 1
        updateFrozen()
        if root != nil, now - lastReconcile >= CoverageOverlayRenderer.reconcileIntervalSeconds {
            lastReconcile = now
            reconcile()
        }
        if !isFrozen, isVisible, root != nil, let view = arView {
            collectChanges()
            if !packInFlight, !pending.isEmpty {
                let camera = view.cameraTransform.matrix
                let ids = CoverageOverlayPacking.schedule(pending, cameraToWorld: camera,
                                                          halfAngleDegrees: options.halfAngleDegrees,
                                                          maxDistance: options.maxDistance,
                                                          limit: options.maxAnchorsPerTick)
                if !ids.isEmpty { startPack(ids) }
            }
        }
        let milliseconds = Double(DispatchTime.now().uptimeNanoseconds &- started) / 1_000_000
        stats.lastTickMilliseconds = milliseconds
        stats.maxTickMilliseconds = max(stats.maxTickMilliseconds, milliseconds)
        logIfDue(now)
    }

    /// Reads the thermal policy and logs a change of `isFrozen`.
    private func updateFrozen() {
        guard let governor = thermal else { return }
        let frozen = CoverageOverlayRenderer.shouldFreeze(policy: governor.policy)
        guard frozen != isFrozen else { return }
        isFrozen = frozen
        let state = frozen ? "frozen" : "unfrozen"
        CoverageOverlayPacking.log("\(state) at thermal \(governor.level.rawValue) (\(slots.count) anchors shown)")
    }

    /// Merges the anchors changed since `lastRevision` into `pending` (latest wins).
    private func collectChanges() {
        var fetched = source.anchorFaces(changedSince: lastRevision)
        if fetched.revision < lastRevision {
            fetched = source.anchorFaces(changedSince: 0)
        }
        for anchor in fetched.anchors { pending[anchor.anchorID] = anchor }
        lastRevision = fetched.revision
    }

    /// Removes the entities, pending and in-flight entries of anchors CoverageLive no longer
    /// publishes (its recording finished or a new one began).
    private func reconcile() {
        let all = source.anchorFaces(changedSince: 0)
        var live = Set<UUID>()
        live.reserveCapacity(all.anchors.count)
        for anchor in all.anchors { live.insert(anchor.anchorID) }
        let gone = slots.keys.filter { !live.contains($0) }
        for id in gone { removeSlot(id) }
        let stale = pending.keys.filter { !live.contains($0) }
        for id in stale { pending[id] = nil }
        let leaving = inFlight.keys.filter { !live.contains($0) }
        for id in leaving { inFlight[id] = nil }
        anchorEntityCount = slots.count
        if !gone.isEmpty { CoverageOverlayPacking.log("dropped \(gone.count) anchors the source no longer has") }
    }

    // MARK: Pack and upload

    /// Moves `ids` from pending to in flight and packs them in one detached task.
    private func startPack(_ ids: [UUID]) {
        var picked: [CoverageAnchorFaces] = []
        picked.reserveCapacity(ids.count)
        for id in ids {
            guard let anchor = pending.removeValue(forKey: id) else { continue }
            picked.append(anchor)
            inFlight[id] = anchor
        }
        guard !picked.isEmpty else { return }
        packInFlight = true
        let job = CoverageOverlayPackJob(anchors: picked)
        let gen = generation
        Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> CoverageOverlayPackResult in
                CoverageOverlayPacking.packAll(job)
            }.value
            guard let self else { return }
            self.finishPack(result, generation: gen)
        }
    }

    /// Back on main: uploads every packed anchor still in flight (a reconcile may have dropped
    /// some). A pack from before `detach()` is dropped; one that lands while frozen or hidden goes
    /// back to pending (unless a newer version waits).
    private func finishPack(_ result: CoverageOverlayPackResult, generation gen: Int) {
        guard gen == generation else { return }
        packInFlight = false
        let anchors = inFlight
        inFlight = [:]
        stats.lastPackMilliseconds = result.milliseconds
        stats.packFailures += result.failed.count
        guard !isFrozen, isVisible, root != nil else {
            for (id, anchor) in anchors where pending[id] == nil { pending[id] = anchor }
            return
        }
        let started = DispatchTime.now().uptimeNanoseconds
        for buffers in result.buffers where anchors[buffers.anchorID] != nil { upload(buffers) }
        anchorEntityCount = slots.count
        let milliseconds = Double(DispatchTime.now().uptimeNanoseconds &- started) / 1_000_000
        stats.lastUploadMilliseconds = milliseconds
        stats.maxUploadMilliseconds = max(stats.maxUploadMilliseconds, milliseconds)
        stats.uploads += result.buffers.count
    }

    /// Copies one packed anchor into its mesh: in place when the capacities hold, else into a new
    /// `LowLevelMesh` and `ModelEntity` that replace the old ones under the root. An anchor with no
    /// triangle loses its entity.
    private func upload(_ buffers: CoverageOverlayBuffers) {
        guard let anchorRoot = root else { return }
        let id = buffers.anchorID
        if let slot = slots[id], slot.revision >= buffers.revision { return }
        let vertexNeeded = buffers.vertexCount
        let indexNeeded = buffers.indices.count
        let bytesNeeded = vertexNeeded * CoverageOverlayPacking.vertexStride
        guard vertexNeeded > 0, indexNeeded > 0, buffers.vertexData.count >= bytesNeeded else {
            removeSlot(id)
            return
        }
        let bounds = BoundingBox(min: buffers.boundsMin, max: buffers.boundsMax)
        let parts = CoverageOverlayPacking.parts(groupCounts: buffers.groupCounts).map { part -> LowLevelMesh.Part in
            LowLevelMesh.Part(indexOffset: part.byteOffset, indexCount: part.indexCount, topology: .triangle,
                              materialIndex: part.materialIndex, bounds: bounds)
        }
        if var slot = slots[id], slot.vertexCapacity >= vertexNeeded, slot.indexCapacity >= indexNeeded {
            CoverageOverlayRenderer.write(buffers, into: slot.mesh)
            slot.mesh.parts.replaceAll(parts)
            slot.entity.transform = Transform(matrix: buffers.transform)
            slot.revision = buffers.revision
            slots[id] = slot
            return
        }
        let previous = slots[id]
        let vertexCapacity = CoverageOverlayPacking.capacity(needed: vertexNeeded, current: previous?.vertexCapacity ?? 0)
        let indexCapacity = CoverageOverlayPacking.capacity(needed: indexNeeded, current: previous?.indexCapacity ?? 0)
        do {
            let mesh = try CoverageOverlayRenderer.makeMesh(vertexCapacity: vertexCapacity, indexCapacity: indexCapacity)
            CoverageOverlayRenderer.write(buffers, into: mesh)
            mesh.parts.replaceAll(parts)
            let resource = try MeshResource(from: mesh)
            let entity = ModelEntity(mesh: resource, materials: materials)
            entity.name = id.uuidString
            entity.transform = Transform(matrix: buffers.transform)
            previous?.entity.removeFromParent()
            anchorRoot.addChild(entity)
            slots[id] = Slot(entity: entity, mesh: mesh, vertexCapacity: vertexCapacity,
                             indexCapacity: indexCapacity, revision: buffers.revision)
            stats.rebuilds += 1
        } catch {
            stats.meshFailures += 1
            if stats.meshFailures <= 3 || stats.meshFailures % 100 == 0 {
                CoverageOverlayPacking.log("mesh failed for \(vertexNeeded) vertices, \(indexNeeded) indices "
                                           + "(\(stats.meshFailures) so far): \(error)")
            }
        }
    }

    /// Removes one anchor's entity.
    private func removeSlot(_ id: UUID) {
        guard let slot = slots.removeValue(forKey: id) else { return }
        slot.entity.removeFromParent()
    }

    /// Copies the packed vertex bytes and indices into `mesh` (capacities already checked).
    private static func write(_ buffers: CoverageOverlayBuffers, into mesh: LowLevelMesh) {
        let vertexData = buffers.vertexData
        mesh.withUnsafeMutableBytes(bufferIndex: 0) { destination in
            vertexData.withUnsafeBytes { source in
                CoverageOverlayPacking.copyRaw(from: source, to: destination)
            }
        }
        let indices = buffers.indices
        mesh.withUnsafeMutableIndices { destination in
            indices.withUnsafeBytes { source in
                CoverageOverlayPacking.copyRaw(from: source, to: destination)
            }
        }
    }

    /// A `LowLevelMesh` with the interleaved layout (position, normal, uv0, stride 32) and `UInt32` indices.
    private static func makeMesh(vertexCapacity: Int, indexCapacity: Int) throws -> LowLevelMesh {
        let attributes: [LowLevelMesh.Attribute] = [
            LowLevelMesh.Attribute(semantic: .position, format: .float3, layoutIndex: 0,
                                   offset: CoverageOverlayPacking.positionOffset),
            LowLevelMesh.Attribute(semantic: .normal, format: .float3, layoutIndex: 0,
                                   offset: CoverageOverlayPacking.normalOffset),
            LowLevelMesh.Attribute(semantic: .uv0, format: .float2, layoutIndex: 0,
                                   offset: CoverageOverlayPacking.uvOffset),
        ]
        let layouts: [LowLevelMesh.Layout] = [
            LowLevelMesh.Layout(bufferIndex: 0, bufferOffset: 0, bufferStride: CoverageOverlayPacking.vertexStride),
        ]
        let descriptor = LowLevelMesh.Descriptor(vertexCapacity: vertexCapacity, vertexAttributes: attributes,
                                                 vertexLayouts: layouts, indexCapacity: indexCapacity,
                                                 indexType: .uint32)
        return try LowLevelMesh(descriptor: descriptor)
    }

    /// The four materials in `stateOrder`: `UnlitMaterial(color:)`, transparent at the style's
    /// opacity, no face culling (LiDAR winding is inconsistent, RESEARCH 3.5).
    private static func makeMaterials(style: CoverageOverlayStyle) -> [any RealityKit.Material] {
        var out: [any RealityKit.Material] = []
        for state in CoverageOverlayPacking.stateOrder {
            let c = style.color(for: state)
            let color = UIColor(red: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1)
            var material = UnlitMaterial(color: color)
            material.blending = .transparent(opacity: .init(floatLiteral: c.w))
            material.faceCulling = .none
            out.append(material)
        }
        return out
    }

    // MARK: Log

    /// Every 30 s: entity count, pending anchors, tick and upload times (target under 8 ms of main
    /// work per tick), rebuilds and failures. The maxima restart after each line.
    private func logIfDue(_ now: Double) {
        if stats.lastLog == 0 { stats.lastLog = now }
        guard now - stats.lastLog >= CoverageOverlayRenderer.logIntervalSeconds else { return }
        stats.lastLog = now
        let tick = CoverageOverlayRenderer.rounded(stats.lastTickMilliseconds)
        let maxTick = CoverageOverlayRenderer.rounded(stats.maxTickMilliseconds)
        let upload = CoverageOverlayRenderer.rounded(stats.lastUploadMilliseconds)
        let maxUpload = CoverageOverlayRenderer.rounded(stats.maxUploadMilliseconds)
        let pack = CoverageOverlayRenderer.rounded(stats.lastPackMilliseconds)
        let failures = stats.packFailures + stats.meshFailures
        var line = "\(slots.count) entities, \(pending.count) pending, last tick \(tick) ms (max \(maxTick)), "
        line += "last upload \(upload) ms (max \(maxUpload)), pack \(pack) ms, "
        line += "\(stats.uploads) uploads, \(stats.rebuilds) rebuilds, \(failures) failures, "
        line += "frozen \(isFrozen), visible \(isVisible)"
        CoverageOverlayPacking.log(line)
        stats.maxTickMilliseconds = 0
        stats.maxUploadMilliseconds = 0
    }

    /// `value` rounded to 2 decimals (log text only).
    private static func rounded(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }
}
