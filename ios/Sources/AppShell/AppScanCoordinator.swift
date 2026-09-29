import SwiftUI

/// The content of the scan cover (docs/MODULES.md 3.29, ARCHITECTURE 10.1 and 10.3): one
/// `ScanFlowModel` for the whole cover, `RoomScanScreen(model:)`, and the QualityUI sheet over
/// the live camera while the model is checking or showing the quality (`isSheetPhase`).
///
/// The sheet uses `.presentationDetents([.medium, .large])`, cannot be swiped away, and lets
/// taps reach the scan screen's notice cards above the medium detent. Finish calls
/// `model.finish()`; Discard asks "Stop this scan?" inside the sheet (an alert attached under a
/// presented sheet would never appear), then `model.discardScan()` removes only the scan just
/// saved. When the flow ends, `onFinished` receives the project (Finish, after it was enqueued
/// at the front of processing) or nil (cancel, discard, failure).
struct AppScanCoordinator: View {
    /// What this cover scans.
    let request: ScanRequest
    /// Called once when the flow ends.
    private let onFinished: (UUID?) -> Void

    /// The flow of this cover, created once with its callbacks wired.
    @StateObject private var model: ScanFlowModel
    /// The Discard confirmation on the quality sheet is showing.
    @State private var confirmsDiscard = false
    /// Mirrors `model.phase.isSheetPhase`; the sheet cannot be dismissed interactively, so it
    /// closes only when the phase moves on.
    @State private var showsQualitySheet = false

    /// Creates the cover content for a request.
    init(request: ScanRequest, onFinished: @escaping (UUID?) -> Void) {
        self.request = request
        self.onFinished = onFinished
        _model = StateObject(wrappedValue: AppScanCoordinator.makeModel(request: request, onFinished: onFinished))
    }

    /// The scan screen with the quality sheet attached.
    var body: some View {
        RoomScanScreen(model: model)
            .sheet(isPresented: $showsQualitySheet) {
                qualitySheet
            }
            .onChange(of: model.phase, initial: true) { _, phase in
                let shows = phase.isSheetPhase
                if showsQualitySheet != shows { showsQualitySheet = shows }
                if !shows { confirmsDiscard = false }
            }
    }

    // MARK: - Quality sheet

    /// QualitySheet with the Discard confirmation attached inside the sheet content.
    private var qualitySheet: some View {
        let flow = model
        return QualitySheet(evaluation: flow.evaluation, onFinish: {
            flow.finish()
        }, onDiscard: {
            confirmsDiscard = true
        })
        .confirmationDialog(Copy.Scanning.cancelConfirmTitle, isPresented: $confirmsDiscard, titleVisibility: .visible) {
            Button(Copy.Scanning.cancelConfirmDiscard, role: .destructive) {
                AppScanCoordinator.log("quality sheet: discard confirmed")
                flow.discardScan()
            }
            Button(Copy.Scanning.cancelConfirmKeep, role: .cancel) {}
        } message: {
            Text(Copy.Scanning.cancelConfirmBody)
        }
        .presentationDetents([.medium, .large])
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        .interactiveDismissDisabled()
    }

    // MARK: - Model

    /// The flow of one cover: Finish enqueues the project at the front of processing (the runner
    /// stays suspended until the cover closes) and hands it over; the other endings hand over nil.
    static func makeModel(request: ScanRequest, onFinished: @escaping (UUID?) -> Void) -> ScanFlowModel {
        let flow = ScanFlowModel(mode: request.mode, isDemo: request.isDemo)
        var ended = false
        flow.onComplete = { projectID in
            guard !ended else { return }
            ended = true
            ProcessingPlans.enqueue(projectID: projectID, atFront: true)
            onFinished(projectID)
        }
        flow.onDismiss = {
            guard !ended else { return }
            ended = true
            onFinished(nil)
        }
        log("scan flow created: \(request.mode.rawValue), demo \(request.isDemo)")
        return flow
    }

    /// Writes one line to the app log.
    static func log(_ message: String) {
        LogStore.shared.write(message, category: AppRouter.logCategory)
    }
}
