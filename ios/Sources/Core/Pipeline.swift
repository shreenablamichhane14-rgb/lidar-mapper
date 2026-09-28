import Foundation

/// Processing steps (D11, D24). Raw values are persisted in stamps.
enum PipelineStepID: String, CaseIterable, Codable, Sendable {
    case buildRoom, consolidateMesh, cleanModel, floorPlan, quality, mergeStructure, alignRooms,
         textureLow, textureHigh, reconstructObject, objectMetrics, thumbnail
}

/// Record that a derived product is current (D11).
struct DerivedStamp: Codable, Equatable, Sendable {
    /// Step that produced it.
    var step: PipelineStepID
    /// Room or object the product belongs to; nil for project-wide products.
    var subject: UUID?
    /// `ProjectManifest.currentPipelineVersion` at the time.
    var pipelineVersion: Int
    /// Hash of the step's inputs (see `InputHasher`).
    var inputHash: String
    /// When it was produced.
    var createdAt: Date

    /// Creates a stamp.
    init(step: PipelineStepID, subject: UUID? = nil, pipelineVersion: Int, inputHash: String, createdAt: Date) {
        self.step = step
        self.subject = subject
        self.pipelineVersion = pipelineVersion
        self.inputHash = inputHash
        self.createdAt = createdAt
    }
}

/// Contents of `derived/index.json`: the stamps of all derived products.
struct DerivedIndex: Codable, Equatable, Sendable {
    /// One stamp per (step, subject).
    var stamps: [DerivedStamp]

    /// An empty index.
    init(stamps: [DerivedStamp] = []) {
        self.stamps = stamps
    }

    /// The stamp for a step and subject, if any.
    func stamp(step: PipelineStepID, subject: UUID? = nil) -> DerivedStamp? {
        stamps.first { $0.step == step && $0.subject == subject }
    }

    /// True when a stamp exists with the same version and input hash (the step can be skipped).
    func isFresh(step: PipelineStepID, subject: UUID? = nil, version: Int, inputHash: String) -> Bool {
        guard let existing = stamp(step: step, subject: subject) else { return false }
        return existing.pipelineVersion == version && existing.inputHash == inputHash
    }

    /// Stores a stamp, replacing any stamp for the same step and subject.
    mutating func record(_ stamp: DerivedStamp) {
        stamps.removeAll { $0.step == stamp.step && $0.subject == stamp.subject }
        stamps.append(stamp)
    }

    /// Removes the stamps of a step (all subjects), forcing it to rerun.
    mutating func invalidate(step: PipelineStepID) {
        stamps.removeAll { $0.step == step }
    }
}

/// Deterministic input hash (D11): 64-bit FNV-1a over the seal file sizes of the raw
/// inputs, the edit log revision when the step reads edits, and any extra strings.
/// Rendered as 16 lowercase hex digits. Not cryptographic; only detects changes.
enum InputHasher {
    /// Hashes the given inputs.
    static func hash(seals: [SealFile], editRevision: Int?, extra: [String] = []) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        func mix(_ s: String) {
            for byte in s.utf8 {
                h ^= UInt64(byte)
                h = h &* 0x0000_0100_0000_01b3
            }
            h ^= 0xff
            h = h &* 0x0000_0100_0000_01b3
        }
        for seal in seals {
            for entry in seal.files { mix("\(entry.path)=\(entry.size)") }
        }
        mix("edits=\(editRevision.map { String($0) } ?? "none")")
        for s in extra { mix(s) }
        let hex = String(h, radix: 16)
        return String(repeating: "0", count: Swift.max(0, 16 - hex.count)) + hex
    }
}

/// Everything a step needs to run. Not Sendable (it holds closures); a runner creates one
/// per step invocation.
struct StepContext {
    /// The project package.
    var package: ProjectPackage
    /// The manifest at the time the step started.
    var manifest: ProjectManifest
    /// `os_proc_available_memory()` when the step started, bytes.
    var availableMemory: UInt64
    /// Returns true when the user or the system cancelled; steps check it between chunks.
    var isCancelled: () -> Bool
    /// Reports progress 0...1; may be called from any thread.
    var progress: (Double) -> Void

    /// Creates a context.
    init(package: ProjectPackage, manifest: ProjectManifest, availableMemory: UInt64,
         isCancelled: @escaping () -> Bool, progress: @escaping (Double) -> Void) {
        self.package = package
        self.manifest = manifest
        self.availableMemory = availableMemory
        self.isCancelled = isCancelled
        self.progress = progress
    }

    /// Throws `MapperError.cancelled` when cancelled.
    func checkCancelled() throws {
        if isCancelled() { throw MapperError.cancelled }
    }
}

/// One processing step (D11, D17). Steps read raw and derived files, write derived files
/// atomically and are skipped when their stamp is fresh. The runner calls `run` off the
/// main thread, one step at a time.
protocol ProcessingStep: AnyObject {
    /// Which step this is.
    var id: PipelineStepID { get }
    /// Peak memory the full variant needs, bytes.
    var memoryBudgetBytes: UInt64 { get }
    /// Peak memory of the reduced variant, bytes, or nil when there is none (D17).
    var reducedMemoryBudgetBytes: UInt64? { get }
    /// Hash of this step's inputs for the stamp.
    func inputHash(_ ctx: StepContext) throws -> String
    /// Does the work. Chooses the reduced variant when `ctx.availableMemory` is below
    /// `memoryBudgetBytes`; throws `MapperError.outOfMemory` when even that does not fit.
    func run(_ ctx: StepContext) async throws
}

extension ProcessingStep {
    /// Default: no reduced variant.
    var reducedMemoryBudgetBytes: UInt64? { nil }
}
