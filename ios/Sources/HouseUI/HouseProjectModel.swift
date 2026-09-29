import Foundation
import Combine

// State of the project room screen (docs/MODULES.md 3.41): rows from the manifest, the Structure
// report and the user alignments of the edit log, read off main; the "These rooms didn't line up"
// alert once per placements report and the "Rooms weren't joined automatically" alert once per
// crashed merge; Join Rooms Again clears the crashed attempt (`StructureStore.clearCrashedAttempt`).

/// What the project room screen shows, read off the main thread.
struct HouseProjectState: Equatable, Sendable {
    /// Room rows (`HousePresentation.rows`).
    var rows: [HouseRoomRow]
    /// True after a crashed merge: `report.hasCrashedAttempt` or merge outcome `crashedBefore`.
    var mergeCrashed: Bool
    /// `placements.json` input hash ("-" without placements), the key of the line-up alert.
    var placementsHash: String
}

/// Main actor model of `HouseProjectScreen`.
@MainActor final class HouseProjectModel: ObservableObject {
    /// Room rows, floor then capture order.
    @Published private(set) var rows: [HouseRoomRow] = []
    /// "3 of 4 rooms done".
    @Published private(set) var progressText = ""
    /// Join Rooms Again is offered.
    @Published private(set) var showsJoinAgain = false
    /// The alert to show.
    @Published var alert: HouseAlert?
    /// The project.
    let projectID: UUID
    /// Increases for every load, so an older result is not published.
    private var loadToken = 0
    /// Alert keys already shown in this run ("<project>|align|<hash>", "<project>|merge").
    private static var shownAlerts: Set<String> = []

    /// Creates the model; nothing is read until `load()`.
    init(projectID: UUID) {
        self.projectID = projectID
    }

    /// Binding target of the alert: true while an alert is set; closing it clears the alert.
    var alertPresented: Bool {
        get { alert != nil }
        set { if !newValue { alert = nil } }
    }

    /// Reads the rows and the report off main, then publishes them and the one-time alerts.
    func load() {
        loadToken += 1
        let token = loadToken
        let id = projectID
        Task.detached(priority: .userInitiated) { [weak self] in
            let state = HouseProjectModel.loadState(projectID: id)
            await self?.apply(state, token: token)
        }
    }

    /// The screen state of a project; nil when its manifest cannot be read.
    nonisolated static func loadState(projectID: UUID) -> HouseProjectState? {
        guard let package = try? ProjectStore.package(for: projectID),
              let manifest = try? ProjectStore.readManifest(package) else { return nil }
        let report = StructureStore.loadReport(package)
        let aligned = Set(StructureStore.userAlignments(EditStore.load(package)).keys)
        let rows = HousePresentation.rows(manifest: manifest, report: report, userAligned: aligned)
        let crashed = report.hasCrashedAttempt || report.merge?.outcome == .crashedBefore
        return HouseProjectState(rows: rows, mergeCrashed: crashed, placementsHash: report.placements?.inputHash ?? "-")
    }

    /// Publishes a loaded state (unless a newer load was started) and shows each alert once.
    func apply(_ state: HouseProjectState?, token: Int) {
        guard token == loadToken, let state else { return }
        rows = state.rows
        progressText = HousePresentation.progressText(state.rows)
        showsJoinAgain = state.mergeCrashed
        guard alert == nil else { return }
        if state.mergeCrashed {
            let key = projectID.uuidString + "|merge"
            if HouseProjectModel.shownAlerts.insert(key).inserted { alert = HouseAlert.mergeFailed() }
            return
        }
        guard let room = state.rows.first(where: { $0.status == .needsLineUp }) else { return }
        let key = projectID.uuidString + "|align|" + state.placementsHash
        if HouseProjectModel.shownAlerts.insert(key).inserted { alert = HouseAlert.alignFailed(room: room.id) }
    }

    /// Join Rooms Again: removes the crashed attempt so the next job calls the builder again.
    /// False (logged) when it could not be removed.
    func clearCrashedAttempt() -> Bool {
        do {
            let package = try ProjectStore.package(for: projectID)
            try StructureStore.clearCrashedAttempt(package)
            HouseProjectModel.shownAlerts.remove(projectID.uuidString + "|merge")
            showsJoinAgain = false
            LogStore.shared.write("join rooms again for \(projectID)", category: HouseRelocalization.logCategory)
            return true
        } catch {
            LogStore.shared.write("crashed attempt of \(projectID) not cleared: \(StoreFiles.describe(error))",
                                  category: HouseRelocalization.logCategory)
            return false
        }
    }
}
