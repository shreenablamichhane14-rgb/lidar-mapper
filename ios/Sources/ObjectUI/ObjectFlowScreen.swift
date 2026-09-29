import SwiftUI

/// Chooser, permission screen, tips (ScanUI's ScanTipsSheet(mode: .object)), the capture
/// (ObjectCapture's ObjectScanScreen) and the saving state; forced dark while capturing,
/// holds an IdleTimerGuard token while capturing or saving.
///
/// The whole cover is dark (ScanUI's permission and tips pages are drawn for a dark
/// background, and the capture is dark by design). The flow's alerts (blocking preflight
/// issues, warnings, start failures) are shown here; capture-time alerts belong to
/// ObjectScanScreen. AppShell owns the model, sets its callbacks and presents this screen in
/// its object cover; the screen calls `begin()` itself.
struct ObjectFlowScreen: View {
    /// The flow (owned by AppShell's object coordinator).
    @ObservedObject private var model: ObjectFlowModel
    /// Idle timer hold while capturing or saving.
    @State private var idleToken: UUID?

    /// The screen for one flow.
    init(model: ObjectFlowModel) {
        _model = ObservedObject(wrappedValue: model)
    }

    /// The page for the current phase on black, with the flow's alert.
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            phaseContent
        }
        .environment(\.colorScheme, .dark)
        .onAppear {
            model.begin()
            syncIdleTimer(model.phase)
        }
        .onChange(of: model.phase) { _, newPhase in
            syncIdleTimer(newPhase)
        }
        .onDisappear {
            releaseIdleTimer()
            model.viewDisappeared()
        }
        .alert(alertTitle, isPresented: alertBinding, presenting: model.alert) { shown in
            if shown.actions.contains(.openSettings) {
                Button(Copy.Permissions.openSettings) { model.respond(to: .openSettings) }
            }
            Button(Copy.Errors.ok, role: .cancel) { model.respond(to: .ok) }
        } message: { shown in
            Text(shown.body)
        }
    }

    // MARK: - Phases

    /// Chooser, checks, permission, tips, capture, saving, or black while the cover closes.
    @ViewBuilder private var phaseContent: some View {
        switch model.phase {
        case .chooser:
            ObjectSizeChooser(onPick: { size in model.choose(size) }, onCancel: { model.cancel() })
        case .preflight:
            statusView(Copy.ScanUI.preparing, showsCancel: true)
        case .permission:
            ScanPermissionScreen(isRequesting: model.isRequestingPermission,
                                 onContinue: { Task { await model.permissionContinue() } },
                                 onCancel: { model.cancel() })
        case .tips:
            ScanTipsSheet(mode: .object, onStart: { dontShowAgain in model.tipsFinished(dontShowAgain: dontShowAgain) },
                          onCancel: { model.cancel() })
        case .capturing:
            if let scan = model.scanModel {
                ObjectScanScreen(model: scan)
            } else {
                statusView(Copy.ScanUI.preparing, showsCancel: false)
            }
        case .saving:
            statusView(Copy.ObjectCapture.saving, showsCancel: false)
        case .done, .largeChosen, .failed, .cancelled:
            Color.black.ignoresSafeArea()
        }
    }

    /// A spinner with a status line; Cancel at the top while the checks run.
    private func statusView(_ text: String, showsCancel: Bool) -> some View {
        VStack(spacing: 0) {
            HStack {
                if showsCancel {
                    Button(Copy.Scanning.cancel) { model.cancel() }
                        .font(.body.weight(.semibold))
                        .padding(.vertical, 12)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            Spacer()
            VStack(spacing: 14) {
                ProgressView()
                    .tint(Color.white)
                Text(text)
                    .font(.headline)
                    .foregroundStyle(Color.white)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 32)
            .accessibilityElement(children: .combine)
            Spacer()
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    // MARK: - Alert

    /// Title of the current alert (empty while none is shown).
    private var alertTitle: String {
        model.alert?.title ?? ""
    }

    /// Shown while the model has an alert; closing clears it (the button runs the follow-up).
    private var alertBinding: Binding<Bool> {
        Binding(get: { model.alert != nil },
                set: { shown in
                    if !shown { model.alert = nil }
                })
    }

    // MARK: - Idle timer

    /// Holds the idle timer while capturing or saving, releases it otherwise.
    private func syncIdleTimer(_ phase: ObjectFlowPhase) {
        let holds = phase == .capturing || phase == .saving
        if holds {
            guard idleToken == nil else { return }
            idleToken = IdleTimerGuard.acquire("object capture")
        } else {
            releaseIdleTimer()
        }
    }

    /// Gives the idle timer token back.
    private func releaseIdleTimer() {
        guard let token = idleToken else { return }
        IdleTimerGuard.release(token)
        idleToken = nil
    }
}
