import Foundation
import os
import simd

/// Pipeline step `.textureLow` for one room (ARCHITECTURE 5.2, 5.5; D24): bakes the room's
/// view mesh with up to 150 recorded keyframes at `TextureDensity.textured` and writes
/// `derived/rooms/<room>/texture/` through `TextureStore`. Optional and independent in every
/// plan: a room without a mesh or keyframes, or whose keyframes see nothing, completes with
/// no files (Realistic shows its fallback, TEST_PLAN TEX-06), removing any older texture.
///
/// Budget 600 MB full, 350 MB reduced. The step picks the reduced variant when
/// `ctx.availableMemory` is below the full budget (the runner passes `budget - 1` to force
/// it): the mesh is simplified to 150k faces and the atlases are 1024 texels. Keyframes are
/// opened lazily and the baker decodes at most a few at a time; the finished pages are
/// written one at a time and released. `ctx.isCancelled` reaches the baker through a
/// `TextureBakeWatcher` that polls it and calls `TextureBaker.cancel()`.
final class TextureLowStep: ProcessingStep {
    /// Peak memory of the full variant, bytes.
    static let fullBudgetBytes: UInt64 = 600_000_000
    /// Peak memory of the reduced variant, bytes.
    static let reducedBudgetBytes: UInt64 = 350_000_000
    /// Most keyframes baked (raw keeps all of them, D6).
    static let maxKeyframes = KeyframeLoader.defaultMaxCount
    /// Face budget of the measured-mesh fallback when the view mesh is missing.
    static let fallbackTriangleBudget = 200_000
    /// Face cap of the reduced variant.
    static let reducedTriangleBudget = 150_000
    /// Version tag of the texture settings in the input hash; bump it when the options change
    /// so every room rebakes.
    static let settingsTag = "texture-low-v1"
    /// The density this step bakes.
    static let density: TextureDensity = .textured
    /// Log category.
    static let logCategory = "texture"

    /// What one run produced (for the log and the self-test).
    enum Outcome: Equatable {
        /// Pages were written.
        case textured(pages: Int, faces: Int, coverage: Float)
        /// The room has no consolidated mesh with faces.
        case noMesh
        /// No usable keyframe was recorded (or none could be opened).
        case noKeyframes
        /// The keyframes saw none of the faces.
        case nothingTextured
    }

    /// Always `.textureLow`.
    let id: PipelineStepID = .textureLow
    /// The room this step textures (the stamp subject is its id).
    let room: RoomRecord
    /// The room folder plus its mesh passes (keyframes are read from all of them).
    let folders: [RawScanFolder]

    /// Full budget, 600 MB.
    var memoryBudgetBytes: UInt64 { TextureLowStep.fullBudgetBytes }
    /// Reduced budget, 350 MB.
    var reducedMemoryBudgetBytes: UInt64? { TextureLowStep.reducedBudgetBytes }

    /// room: the manifest record; folders: its raw folder plus its mesh passes.
    init(room: RoomRecord, folders: [RawScanFolder]) {
        self.room = room
        self.folders = folders
    }

    // MARK: - Pure rules

    /// True when the reduced variant runs for this much available memory (below the full
    /// budget, Core `ProcessingStep.run`).
    static func usesReducedVariant(availableMemory: UInt64) -> Bool {
        availableMemory < fullBudgetBytes
    }

    /// Baker options: `TextureDensity.textured.options`, or its `reducedOptions`.
    static func options(reduced: Bool) -> TXOptions {
        reduced ? density.reducedOptions : density.options
    }

    /// Options of the one retry after `TXError.imageFailed` (charts that do not fit, or an
    /// atlas bitmap that could not be made): half the texel density.
    static func retryOptions(_ options: TXOptions) -> TXOptions {
        var result = options
        result.texelsPerMeter = Swift.max(10, options.texelsPerMeter * 0.5)
        return result
    }

    /// Face cap of the view mesh: nil (as is) for the full variant, 150k for the reduced one.
    static func viewTriangleTarget(reduced: Bool) -> Int? {
        reduced ? reducedTriangleBudget : nil
    }

    /// Current stamp `inputHash` of the room's `consolidateMesh` step in `derived/index.json`,
    /// "-" when there is none or the index cannot be read.
    static func upstreamHash(_ package: ProjectPackage, room: UUID) -> String {
        guard let index = try? ProjectStore.readJSON(DerivedIndex.self, from: package.derivedIndexURL) else { return "-" }
        return index.stamp(step: .consolidateMesh, subject: room)?.inputHash ?? "-"
    }

    /// `fraction` (0...1) as a whole percentage for the log; 0 when not finite.
    static func percent(_ fraction: Float) -> Int {
        guard fraction.isFinite else { return 0 }
        return Int((Swift.min(1, Swift.max(0, fraction)) * 100).rounded())
    }

    /// Faces the baker textured (`faceSource` >= 0 on a page that exists).
    static func texturedFaceCount(_ result: TXResult) -> Int {
        let pages = TextureStore.pageIndices(for: result, faceCount: result.faceAtlas.count)
        return pages.reduce(0) { $0 + ($1 == TexturedMesh.untexturedPage ? 0 : 1) }
    }

    // MARK: - ProcessingStep

    /// `InputHasher.hash` over the seals of all folders (a folder without `SEAL.json` is
    /// listed on the fly and marked, a missing folder is marked), plus the settings tag, the
    /// density, the keyframe cap and the room's `consolidateMesh` stamp (MODULES 3.1). The
    /// variant is not hashed: the runner may cap memory after hashing.
    func inputHash(_ ctx: StepContext) throws -> String {
        var seals: [SealFile] = []
        var extra: [String] = ["step=\(TextureLowStep.settingsTag)", "density=\(TextureLowStep.density.rawValue)",
                               "keyframes=\(TextureLowStep.maxKeyframes)"]
        for folder in folders {
            let name = folder.url.lastPathComponent
            if let seal = try? ProjectStore.readJSON(SealFile.self, from: folder.sealURL) {
                seals.append(seal)
            } else if let listed = try? SealFile.make(folder: folder.url) {
                seals.append(listed)
                extra.append("unsealed=\(name)")
            } else {
                extra.append("missing=\(name)")
            }
        }
        extra.append("consolidateMesh=\(TextureLowStep.upstreamHash(ctx.package, room: room.id))")
        return InputHasher.hash(seals: seals, editRevision: nil, extra: extra)
    }

    /// Runs `execute`. Throws `MapperError.cancelled`, `.outOfMemory(step:)`,
    /// `.processingFailed(step:reason:)` (unreadable mesh, bake failure) or `.ioFailed`
    /// (the texture could not be written, for example the project was deleted).
    func run(_ ctx: StepContext) async throws {
        _ = try execute(ctx)
    }

    /// The whole step, synchronously on the calling thread (the runner calls it off main).
    @discardableResult
    func execute(_ ctx: StepContext) throws -> Outcome {
        let started = ProcessInfo.processInfo.systemUptime
        try ctx.checkCancelled()
        let reduced = TextureLowStep.usesReducedVariant(availableMemory: ctx.availableMemory)
        if reduced && ctx.availableMemory < TextureLowStep.reducedBudgetBytes {
            throw MapperError.outOfMemory(step: id)
        }
        var lastProgress: Double = 0
        let report: (Double) -> Void = { value in
            let next = Swift.min(1, Swift.max(lastProgress, value))
            lastProgress = next
            ctx.progress(next)
        }
        report(0.01)

        // Mesh.
        let loaded: (mesh: MeshWithAttributes, source: TextureMeshLoader.Source)?
        do {
            loaded = try TextureMeshLoader.load(ctx.package, room: room.id,
                                                viewTarget: TextureLowStep.viewTriangleTarget(reduced: reduced),
                                                fallbackTarget: TextureLowStep.fallbackTriangleBudget)
        } catch {
            throw MapperError.processingFailed(step: id, reason: "mesh unreadable: \(error)")
        }
        guard let source = loaded else {
            return finishWithoutTexture(ctx, outcome: .noMesh, detail: "no consolidated mesh")
        }
        try ctx.checkCancelled()
        report(0.06)

        // Keyframes.
        let found = KeyframeLoader.load(inFolders: folders, maxCount: TextureLowStep.maxKeyframes)
        guard !found.keyframes.isEmpty else {
            return finishWithoutTexture(ctx, outcome: .noKeyframes,
                                        detail: "\(found.candidates) usable keyframe(s), \(found.unreadable) unreadable")
        }
        try ctx.checkCancelled()
        report(0.1)

        // Bake.
        let faces = source.mesh.triangleCount
        let txMesh = TXMesh(positions: source.mesh.mesh.positions,
                            indices: Array(source.mesh.mesh.indices.prefix(3 * faces)))
        let bakeStarted = ProcessInfo.processInfo.systemUptime
        let memoryAtBake = TextureBakeWatcher.availableMemory()
        var lowestMemory = memoryAtBake
        let baked = try bake(mesh: txMesh, keyframes: found.keyframes, options: TextureLowStep.options(reduced: reduced),
                             ctx: ctx, report: report, lowestMemory: &lowestMemory)
        guard var result = baked else {
            return finishWithoutTexture(ctx, outcome: .noKeyframes, detail: "the baker had no keyframes")
        }
        let bakeSeconds = ProcessInfo.processInfo.systemUptime - bakeStarted
        let texturedFaces = TextureLowStep.texturedFaceCount(result)
        guard !result.atlases.isEmpty, texturedFaces > 0 else {
            return finishWithoutTexture(ctx, outcome: .nothingTextured,
                                        detail: "\(found.keyframes.count) keyframes saw none of \(faces) faces")
        }
        try ctx.checkCancelled()
        report(0.9)

        // Save: pages one at a time, then the mesh and the texture coordinates.
        let pages = result.atlases.count
        let coverage = result.coverage
        do {
            try TextureStore.saveReleasingPages(mesh: source.mesh, result: &result, package: ctx.package, room: room.id)
        } catch {
            throw MapperError.ioFailed("textureLow save failed: \(error)")
        }
        report(1)

        let seconds = ProcessInfo.processInfo.systemUptime - started
        let used = memoryAtBake > lowestMemory ? memoryAtBake - lowestMemory : 0
        let parts: [String] = [
            "textureLow room \(room.id.uuidString) \(reduced ? "reduced" : "full")",
            "\(source.source.rawValue) mesh \(faces) faces",
            "\(found.keyframes.count) of \(found.candidates) keyframes",
            "\(pages) page(s)",
            "\(texturedFaces) textured faces",
            "coverage \(TextureLowStep.percent(coverage)) percent",
            String(format: "bake %.1f s, total %.1f s", bakeSeconds, seconds),
            "available \(ctx.availableMemory / 1_000_000) MB at start",
            "\(memoryAtBake / 1_000_000) MB before the bake, lowest \(lowestMemory / 1_000_000) MB (peak about \(used / 1_000_000) MB)"
        ]
        LogStore.shared.write(parts.joined(separator: ", "), category: TextureLowStep.logCategory)
        return .textured(pages: pages, faces: texturedFaces, coverage: coverage)
    }

    // MARK: - Helpers

    /// Bakes with a watcher forwarding cancellation, retrying once at half density after
    /// `TXError.imageFailed`. Nil for `TXError.noKeyframes`. Baker progress 0...1 maps to
    /// step progress 0.1...0.9. `lowestMemory` is lowered to the lowest available memory seen.
    private func bake(mesh: TXMesh, keyframes: [TXKeyframe], options: TXOptions, ctx: StepContext,
                      report: @escaping (Double) -> Void, lowestMemory: inout UInt64) throws -> TXResult? {
        var attemptOptions = options
        for attempt in 0..<2 {
            let baker = TextureBaker(options: attemptOptions)
            let watcher = TextureBakeWatcher(baker: baker, isCancelled: ctx.isCancelled)
            watcher.start()
            defer {
                watcher.stop()
                lowestMemory = Swift.min(lowestMemory, watcher.lowestAvailableMemory)
            }
            do {
                return try baker.bake(mesh: mesh, keyframes: keyframes, progress: { (fraction: Float) in
                    watcher.poll()
                    report(0.1 + 0.8 * Double(fraction))
                })
            } catch let error as TXError {
                switch error {
                case .noKeyframes:
                    return nil
                case .cancelled:
                    throw MapperError.cancelled
                case .invalidMesh(let reason):
                    throw MapperError.processingFailed(step: id, reason: "invalid mesh: \(reason)")
                case .imageFailed(let reason):
                    try ctx.checkCancelled()
                    guard attempt == 0 else {
                        throw MapperError.processingFailed(step: id, reason: "bake failed: \(reason)")
                    }
                    LogStore.shared.write("textureLow room \(room.id.uuidString): \(reason); retrying at half density",
                                          category: TextureLowStep.logCategory)
                    attemptOptions = TextureLowStep.retryOptions(attemptOptions)
                }
            }
        }
        throw MapperError.processingFailed(step: id, reason: "bake failed after a retry")
    }

    /// Completes a run that produced no texture: removes any older texture of the room (it
    /// would not match the current inputs), logs why and reports progress 1.
    private func finishWithoutTexture(_ ctx: StepContext, outcome: Outcome, detail: String) -> Outcome {
        TextureStore.remove(ctx.package, room: room.id)
        LogStore.shared.write("textureLow room \(room.id.uuidString): no texture (\(detail)), nothing written",
                              category: TextureLowStep.logCategory)
        ctx.progress(1)
        return outcome
    }
}

/// Forwards `StepContext.isCancelled` to `TextureBaker.cancel()` while a bake runs, and
/// records the lowest available memory seen (for the step's peak memory log line). It polls
/// every 0.2 s on a utility queue until `stop()`; the step also calls `poll()` from the
/// baker's progress callback. Thread-safe.
final class TextureBakeWatcher: @unchecked Sendable {
    /// Poll interval, seconds.
    static let interval: Double = 0.2

    /// Guards `active` and `lowest`.
    private let lock = NSLock()
    /// False after `stop()` or once a cancel was forwarded.
    private var active = true
    /// Lowest available memory seen, bytes.
    private var lowest: UInt64
    /// The baker to cancel.
    private let baker: TextureBaker
    /// The step's cancel check (thread-safe in the runner).
    private let isCancelled: () -> Bool
    /// Queue of the timer polls.
    private let queue = DispatchQueue(label: "mapper.texture.watcher", qos: .utility)

    /// A watcher for `baker`; call `start()` before the bake and `stop()` after it.
    init(baker: TextureBaker, isCancelled: @escaping () -> Bool) {
        self.baker = baker
        self.isCancelled = isCancelled
        lowest = TextureBakeWatcher.availableMemory()
    }

    /// `os_proc_available_memory()` in bytes (0 when the process is already over its limit).
    static func availableMemory() -> UInt64 {
        let value = os_proc_available_memory()
        return value > 0 ? UInt64(value) : 0
    }

    /// Starts polling.
    func start() {
        scheduleTick()
    }

    /// Stops polling; pending polls do nothing.
    func stop() {
        lock.lock()
        active = false
        lock.unlock()
    }

    /// Lowest available memory seen so far, bytes.
    var lowestAvailableMemory: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return lowest
    }

    /// Samples memory and forwards a cancel request to the baker. Returns true when the step
    /// is cancelled.
    @discardableResult
    func poll() -> Bool {
        let memory = TextureBakeWatcher.availableMemory()
        lock.lock()
        if memory < lowest { lowest = memory }
        lock.unlock()
        guard isCancelled() else { return false }
        baker.cancel()
        return true
    }

    /// True until `stop()`.
    private var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    /// Schedules the next poll on `queue`.
    private func scheduleTick() {
        queue.asyncAfter(deadline: .now() + TextureBakeWatcher.interval) { [self] in
            guard self.isActive else { return }
            if self.poll() {
                self.stop()
                return
            }
            self.scheduleTick()
        }
    }
}
