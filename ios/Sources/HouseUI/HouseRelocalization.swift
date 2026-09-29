import Foundation
import ARKit
import RealityKit
import SwiftUI
import UIKit

// Returning to a house another day (docs/MODULES.md 3.41, ARCHITECTURE 4.3, D9, RESEARCH 3.1
// recommended 7 and 3.10 recommended 13): which saved room map to relocalize against, the pure
// decision "relocalized, keep waiting or give up", the tracking read on the hub queue, the map
// loader, and the camera shown while ARKit looks for the saved room (`ARView` on the hub's session
// with Apple's coaching overlay). The session is marked `.relocalized` only after tracking stayed
// `.normal` against the map (D9); the decision itself is `decide`.

/// What the relocalization poll decided.
enum HouseRelocalizationDecision: Equatable, Sendable { case keepWaiting, relocalized, timedOut }

/// Relocalization rules and helpers.
enum HouseRelocalization {
    /// Seconds before Start Fresh Here is offered.
    static let timeoutSeconds: Double = 30
    /// Tracking must stay `.normal` this long before the session counts as relocalized.
    static let normalHoldSeconds: Double = 1
    /// Seconds between two tracking reads.
    static let pollSeconds: Double = 0.5
    /// A `sceneTooLarge` within this many seconds of starting a relocalized room means RoomPlan
    /// cannot work in this session (RESEARCH 3.2 disputed 7).
    static let lostWindowSeconds: Double = 15
    /// Largest world map file read, bytes (package files are untrusted input).
    static let maxWorldMapBytes: Int64 = 128 * 1024 * 1024
    /// Log category of the house flow.
    static let logCategory = "house"

    /// Pure: relocalized when tracking has been `.normal` since `normalSince` for at least
    /// `normalHoldSeconds`; timedOut at `timeoutSeconds` without that; else keepWaiting. Times are
    /// seconds since the relocalization (or Keep Looking) started.
    nonisolated static func decide(elapsed: Double, tracking: TrackingSummary, normalSince: Double?) -> HouseRelocalizationDecision {
        if tracking == .normal, let since = normalSince, elapsed.isFinite, since.isFinite,
           elapsed - since >= normalHoldSeconds {
            return .relocalized
        }
        if elapsed.isFinite && elapsed >= timeoutSeconds { return .timedOut }
        return .keepWaiting
    }

    /// The map to relocalize against: for a rescan the room's own `worldmap.arworldmap` when it
    /// exists and the room is in the anchor frame group (Structure `StructureEligibility`), else
    /// the most recently captured active anchor-group room with a map. Rooms whose own frame link
    /// or whose session's link cannot share a frame (`.unaligned`, `.manual`) are skipped, so an
    /// unaligned room's map is never used. Nil when there is none (the flow then goes straight to
    /// Start Fresh Here with `Copy.HouseUI.noMapTitle`).
    static func sourceMap(manifest: ProjectManifest, package: ProjectPackage, preferRoom: UUID?) -> (session: UUID, room: UUID, url: URL)? {
        let anchor = StructureEligibility.anchorRoomIDs(rooms: manifest.rooms, sessions: manifest.sessions)
        var links: [UUID: FrameLink] = [:]
        for session in manifest.sessions where links[session.id] == nil { links[session.id] = session.frameLink }
        /// The room's map file when the room may be used as a relocalization source.
        func mapURL(_ room: RoomRecord) -> URL? {
            guard anchor.contains(room.id), room.frameLink.mayShareFrame,
                  links[room.sessionID]?.mayShareFrame ?? false else { return nil }
            let sessionFolder = RawScanFolder(url: package.sessionURL(room.sessionID))
            guard let url = sessionFolder.resolve(worldMapPath(room: room.id)),
                  FileManager.default.fileExists(atPath: url.path) else { return nil }
            return url
        }
        if let prefer = preferRoom, let room = manifest.rooms.first(where: { $0.id == prefer }), let url = mapURL(room) {
            return (session: room.sessionID, room: room.id, url: url)
        }
        var best: (record: RoomRecord, url: URL)?
        for room in StructureEligibility.activeRooms(manifest) {
            guard let url = mapURL(room) else { continue }
            if let current = best, current.record.capturedAt > room.capturedAt { continue }
            best = (record: room, url: url)
        }
        guard let chosen = best else { return nil }
        return (session: chosen.record.sessionID, room: chosen.record.id, url: chosen.url)
    }

    /// `CaptureSessionRef.worldMapFile` text for a room's map: "rooms/<id>/worldmap.arworldmap"
    /// (relative to the session folder; readers resolve it with `RawScanFolder.resolve`).
    static func worldMapPath(room: UUID) -> String {
        "rooms/" + room.uuidString + "/worldmap.arworldmap"
    }

    /// Tracking read on the hub queue (`hub.tracking.summary` is hub-queue only).
    static func trackingSummary(of hub: ARSessionHub) async -> TrackingSummary {
        let queue = hub.queue
        return await withCheckedContinuation { (continuation: CheckedContinuation<TrackingSummary, Never>) in
            queue.async { continuation.resume(returning: hub.tracking.summary) }
        }
    }

    /// Main actor. Reads the map file off the main thread (size-capped) and unarchives it here
    /// with `NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from:)`. Nil (logged)
    /// when the file is missing, too large or not a world map.
    @MainActor static func loadWorldMap(from url: URL) async -> ARWorldMap? {
        let limit = maxWorldMapBytes
        let data = await Task.detached(priority: .userInitiated) { () -> Data? in
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            guard size > 0, size <= limit else { return nil }
            return try? Data(contentsOf: url)
        }.value
        guard let data else {
            log("world map \(url.lastPathComponent) unreadable or over the size cap")
            return nil
        }
        do {
            let map = try NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data)
            if map == nil { log("world map file held no ARWorldMap") }
            return map
        } catch {
            log("world map not unarchived: \(error.localizedDescription)")
            return nil
        }
    }

    /// Writes one line to the app log (category "house").
    static func log(_ message: String) {
        LogStore.shared.write(message, category: logCategory)
    }
}

/// UIViewRepresentable: `ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)`,
/// `arView.session = hub.session`, then `hub.install()` at once (whoever assigns the delegate last
/// wins), plus an `ARCoachingOverlayView` with goal `.tracking` on the same session. Dismantling
/// gives the ARView a fresh idle `ARSession()` before it goes away, then calls `hub.install()`
/// again, so the hub's session is never paused by the view.
struct HouseRelocalizationView: UIViewRepresentable {
    /// The session owner whose session the view shows (the new engine's hub).
    let hub: ARSessionHub

    /// Creates the view for `hub`.
    init(hub: ARSessionHub) {
        self.hub = hub
    }

    /// The coordinator keeps the hub (weakly) and the coaching overlay.
    func makeCoordinator() -> HouseRelocalizationCoordinator {
        HouseRelocalizationCoordinator(hub: hub)
    }

    /// Builds the ARView on the hub's session with the coaching overlay on top.
    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        arView.session = hub.session
        hub.install()
        arView.environment.sceneUnderstanding.options = []
        let overlay = ARCoachingOverlayView(frame: .zero)
        overlay.session = hub.session
        overlay.goal = .tracking
        overlay.activatesAutomatically = true
        // Start Over would run the session with `.resetTracking` and drop the world map.
        overlay.delegate = context.coordinator
        overlay.translatesAutoresizingMaskIntoConstraints = false
        arView.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: arView.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: arView.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: arView.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: arView.bottomAnchor),
        ])
        context.coordinator.coachingOverlay = overlay
        HouseRelocalizationView.logIdentity("relocalization view took the session", hub: hub)
        return arView
    }

    /// Moves the view to another hub when SwiftUI reuses it for a new engine; otherwise nothing.
    func updateUIView(_ uiView: ARView, context: Context) {
        let coordinator = context.coordinator
        guard coordinator.hub !== hub else { return }
        uiView.session = hub.session
        hub.install()
        coordinator.coachingOverlay?.session = hub.session
        coordinator.hub = hub
        HouseRelocalizationView.logIdentity("relocalization view moved to another hub", hub: hub)
    }

    /// Removes the overlay, hands the view a fresh idle session and re-asserts the hub as the
    /// delegate of its own session. Never pauses the hub's session.
    static func dismantleUIView(_ uiView: ARView, coordinator: HouseRelocalizationCoordinator) {
        if let overlay = coordinator.coachingOverlay {
            overlay.setActive(false, animated: false)
            overlay.delegate = nil
            overlay.session = nil
            overlay.removeFromSuperview()
            coordinator.coachingOverlay = nil
        }
        uiView.session = ARSession()
        guard let hub = coordinator.hub else {
            HouseRelocalization.log("relocalization view dismantled; the hub was already released")
            return
        }
        hub.install()
        logIdentity("relocalization view dismantled", hub: hub)
    }

    /// Logs the delegate identity and whether the hub's session runs.
    static func logIdentity(_ label: String, hub: ARSessionHub) {
        let delegateIsHub = hub.session.delegate === hub
        HouseRelocalization.log("\(label): delegate === hub \(delegateIsHub), hub running \(hub.isRunning)")
    }
}

/// Coordinator of `HouseRelocalizationView`: the hub and the overlay `dismantleUIView` removes.
@MainActor final class HouseRelocalizationCoordinator: NSObject {
    /// The session owner (weak: the engine owns it).
    weak var hub: ARSessionHub?
    /// The coaching overlay added on top of the ARView.
    var coachingOverlay: ARCoachingOverlayView?

    /// Creates a coordinator for `hub`.
    init(hub: ARSessionHub) {
        self.hub = hub
        super.init()
    }
}

/// The coaching overlay's delegate (RESEARCH 3.10: `coachingOverlayViewDidRequestSessionReset(_:)`).
/// ARKit's protocol is not actor-isolated, so the witness is `nonisolated` and touches only the log.
extension HouseRelocalizationCoordinator: ARCoachingOverlayViewDelegate {
    /// The user tapped Start Over. Implementing this stops the overlay from resetting the session
    /// itself (a run with `.resetTracking` would drop the world map); ARKit keeps relocalizing.
    nonisolated func coachingOverlayViewDidRequestSessionReset(_ coachingOverlayView: ARCoachingOverlayView) {
        HouseRelocalization.log("coaching overlay Start Over ignored while relocalizing")
    }
}
