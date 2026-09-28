import SwiftUI

/// The full-screen scan cover (docs/MODULES.md 3.24): what AppShell presents with
/// `.fullScreenCover` for a Room scan. By phase it shows "Getting ready..." (preflight), the
/// camera permission screen, the tips, then the camera (`RoomCaptureContainer`, or the demo
/// backdrop) with `ScanChrome`. The camera stays mounted, in one stable position of the view
/// tree, from capturing through the quality sheet (AppShell attaches the QualityUI sheet to this
/// view while `phase` is checking or quality), so RoomPlan's view is created once and the
/// camera stays live behind the sheet. Alerts are system alerts while scanning and notice
/// cards over the sheet; Cancel asks with a confirmation dialog at the bottom (one-hand reach).
/// Forced dark, system overlays hidden, the idle timer held while visible.
struct RoomScanScreen: View {
    /// The scan flow (owned by AppShell).
    @ObservedObject var model: ScanFlowModel
    /// Foreground or background (Demo Mode pauses its engine in the background).
    @Environment(\.scenePhase) private var scenePhase

    /// Creates the screen for `model`.
    init(model: ScanFlowModel) {
        self.model = model
    }

    /// Camera (stable position) under the phase's foreground, with alerts and the Cancel dialog.
    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()
            if model.phase.showsCapture || model.isDiscarding {
                captureBackground
            }
            foreground
        }
        .environment(\.colorScheme, .dark)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            model.scanScreenAppeared()
            model.begin()
        }
        .onDisappear {
            model.scanScreenDisappeared()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background { model.appDidEnterBackground() }
        }
        .alert(model.alert?.title ?? "", isPresented: $model.systemAlertPresented, presenting: model.alert) { current in
            alertButtons(current)
        } message: { current in
            Text(current.body)
        }
        .confirmationDialog(Copy.Scanning.cancelConfirmTitle, isPresented: $model.showsCancelConfirmation,
                            titleVisibility: .visible) {
            Button(Copy.Scanning.cancelConfirmDiscard, role: .destructive) {
                model.confirmCancel()
            }
            Button(Copy.Scanning.cancelConfirmKeep, role: .cancel) {
                model.keepScanning()
            }
        } message: {
            Text(Copy.Scanning.cancelConfirmBody)
        }
    }

    // MARK: - Layers

    /// RoomPlan's live view on the engine's session, or the Demo Mode backdrop.
    @ViewBuilder private var captureBackground: some View {
        if let engine = model.roomEngine {
            RoomCaptureContainer(engine: engine)
                .ignoresSafeArea()
                .accessibilityLabel(Copy.A11y.scanView)
        } else if model.isDemo {
            DemoScanBackdrop(snapshot: model.snapshot)
        }
    }

    /// The phase's screen over the camera.
    @ViewBuilder private var foreground: some View {
        switch model.phase {
        case .preflight:
            statusView
        case .permission:
            ScanPermissionScreen(isRequesting: model.isRequestingPermission, onContinue: continueTapped,
                                 onCancel: cancelTapped)
        case .tips:
            if model.showsTips {
                ScanTipsSheet(mode: model.mode, onStart: tipsStarted, onCancel: cancelTapped)
            } else {
                statusView
            }
        case .capturing, .stopping, .checking, .quality, .finishing, .cancelled:
            ScanChrome(model: model, announcer: model.announcer)
        case .done, .failed:
            Color.clear
        }
    }

    /// "Getting ready..." with a spinner.
    private var statusView: some View {
        ScanProgressLine(text: Copy.ScanUI.preparing)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    // MARK: - Alerts

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

    // MARK: - Actions

    /// Continue on the permission screen.
    private func continueTapped() {
        let flow = model
        Task { await flow.permissionContinue() }
    }

    /// Cancel on the permission and tips screens.
    private func cancelTapped() {
        model.requestCancel()
    }

    /// Start Scan or Skip on the tips page.
    private func tipsStarted(_ dontShowAgain: Bool) {
        model.tipsFinished(dontShowAgain: dontShowAgain)
    }
}
