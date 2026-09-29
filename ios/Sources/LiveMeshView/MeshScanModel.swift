import Foundation
import Combine

// Main-actor facade of a mesh-only pass (docs/MODULES.md 3.32) for the screens built on it:
// MissingAreas, LargeObject, ScanUI's detail pass and the build 6 space scan. It forwards the
// ScanEngine calls, mirrors the engine's state, snapshot, result and failure as published
// values, feeds the guidance announcer (VoiceOver and the tier 1 haptic), holds the idle timer
// through Pipeline's `IdleTimerGuard` from `start()` to `teardown()`, and serves Take Photo.

/// Main-actor facade for mesh-only screens (MissingAreas, LargeObject, build 6 space scans).
@MainActor final class MeshScanModel: ObservableObject {
    /// The engine's lifecycle state (synced on every engine event).
    @Published private(set) var state: ScanEngineState
    /// The latest live snapshot.
    @Published private(set) var snapshot = LiveScanSnapshot()
    /// The finished pass, after `.roomFinished`.
    @Published private(set) var result: MeshScanResult?
    /// Latest `.failed` error, for the owner's alert (ScanUI's `ScanErrorCopy.alert(for:)`).
    @Published private(set) var failure: MapperError?
    /// True while the engine is paused (the screen shows the paused card with Resume).
    @Published private(set) var isPaused = false
    /// True for a moment after a photo was saved (`Copy.Scanning.photoSaved`).
    @Published private(set) var showsPhotoNote = false

    /// The mesh-only engine.
    let engine: MeshScanEngine
    /// The pass's photo recorder, when the screen offers Take Photo.
    let photos: PhotoRecorder?
    /// VoiceOver announcements and warning haptics of the guidance shown.
    let announcer: GuidanceAnnouncer

    /// After `.roomFinished` (the pass is sealed).
    var onFinished: ((MeshScanResult) -> Void)?
    /// After cancel or discard completed (`.stateChanged(.idle)`).
    var onIdle: (() -> Void)?

    /// Idle timer holder token between `start()` and `teardown()`.
    private var idleToken: UUID?
    /// True once `teardown()` ran.
    private var tornDown = false
    /// Increases for every photo note, so an older note's timer does not hide a newer one.
    private var photoNoteSerial = 0

    /// Seconds the photo note stays on screen.
    static let photoNoteSeconds: Double = 2

    /// Connects to `engine` (its `onEvent` is replaced) and to `photos.onPhotoSaved`.
    init(engine: MeshScanEngine, photos: PhotoRecorder? = nil) {
        self.engine = engine
        self.photos = photos
        announcer = GuidanceAnnouncer()
        state = engine.state
        engine.onEvent = { [weak self] event in
            self?.handle(event)
        }
        photos?.onPhotoSaved = { [weak self] _ in
            guard let model = self else { return }
            Task { @MainActor in model.photoSaved() }
        }
    }

    // MARK: - Engine calls

    /// `engine.start()`, an `IdleTimerGuard` token, `GuidanceAnnouncer` reset. Throws what the
    /// engine throws (nothing is held then).
    func start() throws {
        guard !tornDown else {
            LogStore.shared.write("mesh scan model: start after teardown ignored", category: MeshScanEngine.logCategory)
            return
        }
        announcer.reset()
        try engine.start()
        if idleToken == nil { idleToken = IdleTimerGuard.acquire("mesh scan") }
        syncState()
    }

    /// Finishes and seals the pass; `attachments` are small extra files for the folder root.
    func finish(attachments: [String: Data] = [:]) {
        announcer.present(nil, now: snapshot.timestamp)
        engine.finish(attachments: attachments)
    }

    /// Pauses (keyframes stop; the session keeps running).
    func pause() {
        engine.pause()
    }

    /// Back to scanning after a pause or an interruption.
    func resume() {
        engine.resume()
    }

    /// Stops without sealing; raw stays in InProgress for recovery.
    func cancel() {
        announcer.present(nil, now: snapshot.timestamp)
        engine.cancel()
    }

    /// Stops and deletes the pass's InProgress folder.
    func discard() {
        announcer.present(nil, now: snapshot.timestamp)
        engine.discard()
    }

    /// `engine.teardown()` and the token released; idempotent. Events that are still under way
    /// (the idle of a cancel the teardown started) keep arriving and still call `onIdle`.
    func teardown() {
        guard !tornDown else { return }
        tornDown = true
        engine.teardown()
        if let token = idleToken {
            idleToken = nil
            IdleTimerGuard.release(token)
        }
        announcer.reset()
        photos?.onPhotoSaved = nil
    }

    /// Take Photo: the next frame with normal tracking is saved as a photo pinned to this spot.
    func takePhoto() {
        guard state == .scanning, let photos else { return }
        Haptics.selection()
        photos.requestPhoto()
    }

    /// `Copy.ScanUI.elapsed(minutes:seconds:)` of `snapshot.elapsed`.
    var elapsedText: String {
        let parts = MeshScanModel.elapsedParts(snapshot.elapsed)
        return Copy.ScanUI.elapsed(minutes: parts.minutes, seconds: parts.seconds)
    }

    /// The guidance the banner shows: the snapshot's kind while scanning, nothing otherwise.
    var bannerKind: GuidanceKind? {
        state == .scanning ? snapshot.guidance : nil
    }

    /// Whole minutes and seconds of a duration (negative and non-finite count as 0). Pure.
    nonisolated static func elapsedParts(_ seconds: Double) -> (minutes: Int, seconds: Int) {
        let clamped = seconds.isFinite ? max(0, seconds) : 0
        let total = Int(clamped.rounded(.down))
        return (minutes: total / 60, seconds: total % 60)
    }

    // MARK: - Engine events (always on main)

    /// Routes one engine event, then mirrors the engine's state.
    private func handle(_ event: ScanEngineEvent) {
        switch event {
        case .snapshot(let newSnapshot):
            snapshot = newSnapshot
            let shown: GuidanceKind? = engine.state == .scanning ? newSnapshot.guidance : nil
            announcer.present(shown, now: newSnapshot.timestamp)
        case .stateChanged(let newState):
            syncState()
            if newState == .idle { onIdle?() }
            return
        case .roomFinished:
            syncState()
            if let finished = engine.lastResult {
                result = finished
                onFinished?(finished)
            } else {
                LogStore.shared.write("mesh scan model: roomFinished without a result", category: MeshScanEngine.logCategory)
            }
            return
        case .failed(let error):
            failure = error
            LogStore.shared.write("mesh scan model: failed \(error.copyKey)", category: MeshScanEngine.logCategory)
        }
        syncState()
    }

    /// Copies the engine's state (written in the same main hop as the event) and hides the
    /// announced guidance whenever the engine is not scanning (`.roomFinished` and `.failed`
    /// change the state without a `.stateChanged` event).
    private func syncState() {
        let current = engine.state
        if current != .scanning { announcer.present(nil, now: snapshot.timestamp) }
        if state != current { state = current }
        let paused = current == .paused
        if isPaused != paused { isPaused = paused }
    }

    /// A photo was written: shows the note for `photoNoteSeconds`.
    private func photoSaved() {
        photoNoteSerial += 1
        let serial = photoNoteSerial
        showsPhotoNote = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(MeshScanModel.photoNoteSeconds * 1_000_000_000))
            guard let self, self.photoNoteSerial == serial else { return }
            self.showsPhotoNote = false
        }
    }
}
