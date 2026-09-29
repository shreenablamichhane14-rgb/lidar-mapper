import RealityKit
import SwiftUI

// The large-object capture screen (docs/MODULES.md 3.39, UX_COPY section 4): LiveMeshView's
// `LiveMeshScreen` (camera, guidance banner, starting, paused and saving cards) with the model's
// tap and view hooks, and the HUD on top: `LiveMeshTopBar` (Done once a box exists), the seed hint
// or the sides progress and box size, Choose Again, the Cancel confirmation and alerts. All text
// comes from Copy; sizes go through Units (the model's `boxSizeText`).

/// The large-object capture screen.
struct LargeObjectScreen: View {
    /// The flow (owned by the host).
    @ObservedObject var model: LargeObjectModel
    /// Extra view hook of the host (AppShell attaches the coverage overlay here).
    let extra: (@MainActor (ARView) -> Void)?

    /// `LiveMeshScreen` with `onViewReady` = `{ model.attach($0); extra?($0) }` and `onTap` = `model.handleTap`,
    /// plus the HUD: `LiveMeshTopBar` (Done enabled with a box), the hint or the sides progress, the box
    /// size, Choose Again, the cancel confirmation and alerts.
    init(model: LargeObjectModel, onViewReady extra: (@MainActor (ARView) -> Void)? = nil) {
        self.model = model
        self.extra = extra
    }

    /// Camera shell and HUD, with the alert and the Cancel confirmation.
    var body: some View {
        let flow = model
        let hostHook = extra
        LiveMeshScreen(model: flow.scan,
                       onViewReady: { view in
                           flow.attach(view)
                           hostHook?(view)
                       },
                       onTap: { point, view in
                           flow.handleTap(point, in: view)
                       }) {
            LargeObjectHUD(model: flow, scan: flow.scan)
        }
        .alert(model.alert?.title ?? "", isPresented: $model.isAlertPresented, presenting: model.alert) { current in
            alertButtons(current)
        } message: { current in
            Text(current.body)
        }
        .confirmationDialog(Copy.Scanning.cancelConfirmTitle, isPresented: $model.showsCancelConfirmation,
                            titleVisibility: .visible) {
            Button(Copy.Scanning.cancelConfirmDiscard, role: .destructive) {
                flow.confirmCancel()
            }
            Button(Copy.Scanning.cancelConfirmKeep, role: .cancel) {
                flow.keepScanning()
            }
        } message: {
            Text(Copy.Scanning.cancelConfirmBody)
        }
        .onDisappear {
            flow.teardown()
        }
    }

    /// Up to two buttons of an alert, mapped to Copy; OK is the cancel button when there are two.
    @ViewBuilder private func alertButtons(_ current: ScanAlert) -> some View {
        if let first = current.actions.first {
            alertButton(first, in: current)
        }
        if current.actions.count > 1 {
            alertButton(current.actions[1], in: current)
        }
    }

    /// One alert button.
    private func alertButton(_ action: ScanAlertAction, in current: ScanAlert) -> some View {
        let role: ButtonRole? = action == .ok && current.actions.count > 1 ? .cancel : nil
        let flow = model
        return Button(ScanErrorCopy.title(for: action), role: role) {
            flow.alertAction(action)
        }
    }
}

/// The controls over the camera: top bar, then the hint or the progress, the size and Choose Again at the bottom.
struct LargeObjectHUD: View {
    /// The flow.
    @ObservedObject var model: LargeObjectModel
    /// The pass (for the timer and the engine state).
    @ObservedObject var scan: MeshScanModel

    /// Top bar and bottom panel.
    var body: some View {
        let flow = model
        VStack(spacing: 0) {
            LiveMeshTopBar(elapsed: scan.elapsedText, doneEnabled: flow.canFinish,
                           onCancel: { flow.requestCancel() },
                           onDone: { flow.finish() })
            Spacer(minLength: 0)
            bottomPanel
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
        }
    }

    /// The hint while choosing; the sides progress, the size and Choose Again while capturing.
    private var bottomPanel: some View {
        let flow = model
        return VStack(spacing: 10) {
            if let hint = model.hint {
                HStack(spacing: 8) {
                    if model.phase == .locating {
                        ProgressView()
                            .tint(Color.white)
                    }
                    LiveMeshPill(text: hint)
                }
                .accessibilityElement(children: .combine)
            }
            if model.phase == .capturing {
                if model.sidesRequired > 0 {
                    let progress = Copy.LargeObject.sidesProgress(model.sidesCovered, of: model.sidesRequired)
                    LiveMeshPill(text: progress)
                        .accessibilityLabel(Copy.Quality.objectSides)
                        .accessibilityValue(progress)
                }
                if let size = model.boxSizeText {
                    LiveMeshPill(text: size)
                        .accessibilityLabel(Copy.LargeObject.a11yBox)
                        .accessibilityValue(size)
                }
                LiveMeshBarButton(title: Copy.LargeObject.chooseAgain, prominent: false, enabled: true) {
                    flow.chooseAgain()
                }
            }
            // After the seal the shell's saving card is gone; the object is still being saved.
            if model.phase == .finishing && scan.state != .stopping {
                HStack(spacing: 8) {
                    ProgressView()
                        .tint(Color.white)
                    LiveMeshPill(text: Copy.LiveMeshView.saving)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.phase)
    }
}
