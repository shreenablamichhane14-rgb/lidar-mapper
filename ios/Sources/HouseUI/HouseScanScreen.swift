import SwiftUI

/// Camera (relocalization view, then `RoomCaptureContainer` mounted once for the rest of the
/// visit, or the demo placeholder). The container carries `.id(ObjectIdentifier(engine))`: its
/// coordinator is the engine it was made with and `updateUIView` ignores a new one, so a new
/// engine (a new session after a system stop, or Start Fresh Here after `sceneTooLarge`) must get
/// a new container, never the old view. Chrome (Cancel, room title and floor, timer, counts, Take
/// Photo, Done, paused overlay with Resume and Finish Now), guidance banner, and the sheets:
/// quality (`QualitySheet`, detents medium and large, not dismissable, not presented while
/// `isTourActive`), naming, room list.
/// Forced dark, `.persistentSystemOverlays(.hidden)`, holds an `IdleTimerGuard` token while visible.
struct HouseScanScreen: View {
    /// The house flow (owned by AppShell).
    @ObservedObject var model: HouseFlowModel
    /// Foreground or background (Demo Mode pauses its engine in the background; the interrupted
    /// alert shows on return).
    @Environment(\.scenePhase) private var scenePhase
    /// Mirrors `model.presentedSheet`; the sheets cannot be dismissed interactively, so they close
    /// only when the phase moves on.
    @State private var sheet: HouseSheetKind?

    /// Creates the screen for `model`.
    init(model: HouseFlowModel) {
        self.model = model
    }

    /// Camera (stable position) under the phase's foreground, with alerts, the Cancel dialog and
    /// the sheets.
    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()
            if model.showsCamera {
                cameraLayer
            }
            foreground
        }
        .environment(\.colorScheme, .dark)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            model.screenAppeared()
            model.begin()
        }
        .onDisappear {
            model.screenDisappeared()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background { model.appDidEnterBackground() }
            if newPhase == .active { model.appDidBecomeActive() }
        }
        .onChange(of: model.presentedSheet, initial: true) { _, kind in
            if sheet != kind { sheet = kind }
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
        .sheet(item: $sheet) { kind in
            sheetContent(kind)
        }
    }

    // MARK: - Layers

    /// RoomPlan's view keyed by its engine, the relocalization camera of a new engine's hub, or
    /// the Demo Mode backdrop. Nothing once the engine was torn down.
    @ViewBuilder private var cameraLayer: some View {
        if let engine = model.roomEngine, !model.cameraReleased {
            if model.isCaptureViewMounted {
                RoomCaptureContainer(engine: engine)
                    .id(ObjectIdentifier(engine))
                    .ignoresSafeArea()
                    .accessibilityLabel(Copy.A11y.scanView)
            } else {
                HouseRelocalizationView(hub: engine.hub)
                    .id(ObjectIdentifier(engine.hub))
                    .ignoresSafeArea()
                    .accessibilityLabel(Copy.A11y.scanView)
            }
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
                ScanTipsSheet(mode: .house, onStart: tipsStarted, onCancel: cancelTapped)
            } else {
                statusView
            }
        case .relocalizing:
            HouseRelocalizationChrome(model: model)
        case .capturing, .stopping, .checking, .quality, .naming, .roomList, .finishing, .cancelled:
            HouseScanChrome(model: model, announcer: model.announcer)
        case .done, .failed:
            Color.clear
        }
    }

    /// "Getting ready..." with a spinner.
    private var statusView: some View {
        ScanProgressLine(text: Copy.ScanUI.preparing)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    // MARK: - Sheets

    /// The sheet of the current phase.
    @ViewBuilder private func sheetContent(_ kind: HouseSheetKind) -> some View {
        switch kind {
        case .quality:
            HouseQualitySheetHost(model: model)
        case .naming:
            HouseNamingSheet(model: model)
        case .rooms:
            HouseRoomListView(model: model)
                .presentationDetents([.medium, .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                .interactiveDismissDisabled()
        }
    }

    // MARK: - Alerts

    /// Up to three buttons of an alert, mapped to Copy; OK and Cancel take the cancel role.
    @ViewBuilder private func alertButtons(_ current: HouseAlert) -> some View {
        if let first = current.actions.first {
            alertButton(first)
        }
        if current.actions.count > 1 {
            alertButton(current.actions[1])
        }
        if current.actions.count > 2 {
            alertButton(current.actions[2])
        }
    }

    /// One alert button.
    private func alertButton(_ action: HouseAlertAction) -> some View {
        let role: ButtonRole? = HouseAlert.isDismissal(action) ? .cancel : nil
        let flow = model
        return Button(HouseAlert.title(for: action), role: role) {
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

/// QualityUI's sheet over the live camera with the Discard confirmation attached inside the
/// sheet content (an alert attached to the screen under a presented sheet never appears). Show
/// Missing Areas is offered only when AppShell set `onShowMissingAreas` and
/// `canShowMissingAreas` holds.
struct HouseQualitySheetHost: View {
    /// The house flow.
    @ObservedObject var model: HouseFlowModel
    /// The Discard confirmation is showing.
    @State private var confirmsDiscard = false

    /// The sheet, its confirmation and its presentation.
    var body: some View {
        let flow = model
        let offersMissingAreas = flow.onShowMissingAreas != nil && flow.canShowMissingAreas
        let showMissing: (() -> Void)? = offersMissingAreas ? { flow.showMissingAreas() } : nil
        return QualitySheet(evaluation: flow.evaluation, onFinish: {
            flow.finishRoom()
        }, onDiscard: {
            confirmsDiscard = true
        }, onShowMissingAreas: showMissing)
        .confirmationDialog(Copy.Scanning.cancelConfirmTitle, isPresented: $confirmsDiscard, titleVisibility: .visible) {
            Button(Copy.Scanning.cancelConfirmDiscard, role: .destructive) {
                flow.discardRoom()
            }
            Button(Copy.Scanning.cancelConfirmKeep, role: .cancel) {}
        } message: {
            Text(Copy.Scanning.cancelConfirmBody)
        }
        .presentationDetents([.medium, .large])
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        .interactiveDismissDisabled()
    }
}
