import SwiftUI
// `ObjectCaptureView` and `ObjectCapturePointCloudView` live in the RealityKit + SwiftUI
// cross-import overlay (rule 0.2.13).
import RealityKit

/// ZStack of `ObjectCaptureView(session:)` with `.id(session.id)` and Mapper's controls
/// (Cancel with the `Copy.Scanning.cancelConfirm*` dialog, instruction, shot counter, Continue,
/// Reset Box, Start Capture, Done), the guidance banner, and the review sheet (its content is
/// `ObjectCapturePointCloudView(session:).showShotLocations()` plus the review text and choices).
/// Controls hide while `!trackingNormal || isPaused` (RESEARCH 3.10 gotcha 14). Capture-time
/// alerts (too few photos, failure with Use These Photos or Discard) are shown here.
/// `ObjectCaptureView` is in the hierarchy only while `model.session` is non-nil: after completion
/// the saving text replaces it, so the view's own reference to the session goes with it. The
/// view stays mounted for the whole scan; sheets, the discard dialog and the background pause
/// the session instead (D17; RESEARCH 3.3 gotcha 5, 3.10 gotcha 13).
struct ObjectScanScreen: View {
    /// The capture model (owned by the host flow, which also calls `start()` and `teardown()`).
    @ObservedObject private var model: ObjectScanModel
    /// App foreground state: background pauses the session, active resumes it.
    @Environment(\.scenePhase) private var scenePhase
    /// The discard confirmation is up (it holds one overlay pause).
    @State private var confirmingCancel = false
    /// The session was paused because the app went to the background.
    @State private var pausedForBackground = false
    /// Mirror of `model.reviewPresented` for the sheet.
    @State private var showsReview = false
    /// The too-few-photos alert over the camera, or over the review sheet.
    @State private var tooFewOnScreen = false
    @State private var tooFewInReview = false

    /// The screen for one capture model.
    init(model: ObjectScanModel) {
        _model = ObservedObject(wrappedValue: model)
    }

    /// The capture view, the guidance banner, the controls or the saving and failure panels.
    var body: some View {
        ZStack {
            captureLayer
            if showsLiveControls {
                ObjectScanGuidanceLayer(announcer: model.announcer)
            }
            overlay
        }
        .background(Color.black.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .persistentSystemOverlays(.hidden)
        .sheet(isPresented: $showsReview, onDismiss: { model.reviewDismissed() }) {
            reviewSheet
        }
        .alert(Copy.ObjectCapture.tooFewPhotos.title, isPresented: $tooFewOnScreen) {
            Button(Copy.Errors.ok) { model.showsTooFewPhotos = false }
        } message: {
            Text(Copy.ObjectCapture.tooFewPhotos.body)
        }
        .alert(Copy.Scanning.cancelConfirmTitle, isPresented: $confirmingCancel) {
            Button(Copy.Scanning.cancelConfirmDiscard, role: .destructive) { model.cancel() }
            Button(Copy.Scanning.cancelConfirmKeep, role: .cancel) { model.resumeFromOverlay() }
        } message: {
            Text(Copy.Scanning.cancelConfirmBody)
        }
        .onChange(of: model.reviewPresented) { _, shown in
            if showsReview != shown { showsReview = shown }
        }
        .onChange(of: model.showsTooFewPhotos) { _, shows in
            guard shows else { return }
            if model.reviewPresented {
                tooFewInReview = true
            } else {
                tooFewOnScreen = true
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            handleScenePhase(newPhase)
        }
    }

    // MARK: Layers

    /// Apple's capture view while a session exists, else black.
    @ViewBuilder private var captureLayer: some View {
        if let session = model.session {
            ObjectCaptureView(session: session)
                .id(session.id)
                .ignoresSafeArea()
                .accessibilityLabel(Copy.ObjectCapture.a11yCaptureView)
        } else {
            Color.black.ignoresSafeArea()
        }
    }

    /// Mapper's controls are shown only while tracking is normal and the session runs (Apple's
    /// coaching overlay shows otherwise).
    private var showsLiveControls: Bool {
        guard model.session != nil, model.trackingNormal, !model.isPaused else { return false }
        return model.phase == .capturing || model.phase == .idle
    }

    /// The overlay for the current phase.
    @ViewBuilder private var overlay: some View {
        switch model.phase {
        case .failed(let failure, let count):
            failurePanel(failure, imageCount: count)
        case .finishing, .sealing, .done:
            savingPanel
        case .cancelled:
            EmptyView()
        case .idle, .capturing, .reviewing:
            liveControls
        }
    }

    /// Cancel and the shot counter on top, the instruction, and the stage buttons at the bottom.
    private var liveControls: some View {
        VStack(spacing: 12) {
            HStack(alignment: .center) {
                Button(Copy.Scanning.cancel) { requestCancel() }
                    .buttonStyle(.bordered)
                Spacer()
                if showsLiveControls && model.stage == .capturing {
                    shotCounter
                }
            }
            if showsLiveControls, let text = instructionText {
                Text(text)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.55), in: Capsule())
            }
            Spacer()
            if showsLiveControls {
                bottomButtons
            }
        }
        .padding()
    }

    /// The instruction for the current stage and lap.
    private var instructionText: String? {
        ObjectOnboarding.overlayInstruction(stage: model.stage, onboarding: model.onboarding,
                                            detectionFailed: model.detectionFailed)
    }

    /// "n of m photos", red while the session over-captures.
    private var shotCounter: some View {
        Text(Copy.ObjectCapture.shotCount(taken: model.shotCount, limit: model.shotLimit))
            .font(.subheadline.monospacedDigit().weight(.semibold))
            .foregroundStyle(model.overCapturing ? Color.red : Color.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.55), in: Capsule())
            .accessibilityLabel(Copy.ObjectCapture.a11yShotCount(taken: model.shotCount, limit: model.shotLimit))
    }

    /// Continue when ready; Reset Box and Start Capture while detecting; Done (and Continue to
    /// reopen a closed review) while capturing.
    @ViewBuilder private var bottomButtons: some View {
        switch model.stage {
        case .ready:
            primaryButton(Copy.ObjectCapture.continueButton) { model.continueTapped() }
        case .detecting:
            HStack(spacing: 12) {
                secondaryButton(Copy.ObjectCapture.resetBox) { model.resetBox() }
                primaryButton(Copy.ObjectCapture.startCapture) { model.startCapture() }
            }
        case .capturing:
            HStack(spacing: 12) {
                if ObjectOnboarding.isReview(model.onboarding) && !model.reviewPresented {
                    secondaryButton(Copy.ObjectCapture.continueButton) { model.reopenReview() }
                }
                primaryButton(Copy.Scanning.done) { model.finish() }
                    .accessibilityLabel(Copy.A11y.doneScanning)
            }
        case .initializing, .finishing, .completed, .failed:
            EmptyView()
        }
    }

    /// Spinner and `Copy.ObjectCapture.saving` while the session finishes and the photos are sealed.
    private var savingPanel: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(Copy.ObjectCapture.saving)
                .font(.headline)
                .foregroundStyle(Color.white)
        }
        .padding(24)
        .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 16))
    }

    /// The failure: Use These Photos when enough were taken, and Discard (or OK, which discards).
    private func failurePanel(_ failure: ObjectScanFailure, imageCount: Int) -> some View {
        let copy = ObjectCaptureSignals.failureCopy(failure, imageCount: imageCount)
        let discardTitle = copy.canUsePhotos ? Copy.Scanning.cancelConfirmDiscard : Copy.Errors.ok
        return VStack(spacing: 14) {
            Text(copy.title)
                .font(.title3.weight(.bold))
                .multilineTextAlignment(.center)
            Text(copy.body)
                .font(.body)
                .multilineTextAlignment(.center)
            if copy.canUsePhotos {
                primaryButton(Copy.ObjectCapture.usePhotos) { model.useCapturedPhotos() }
            }
            secondaryButton(discardTitle) { model.discardAfterFailure() }
        }
        .foregroundStyle(Color.white)
        .padding(24)
        .background(Color.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 16))
        .padding()
    }

    // MARK: Review sheet

    /// The point cloud with shot locations, the lap title and text, the flip warning and the
    /// choices. The too-few-photos alert is attached here too, so it shows over the sheet.
    private var reviewSheet: some View {
        VStack(spacing: 16) {
            if let session = model.session {
                ObjectCapturePointCloudView(session: session)
                    .showShotLocations()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Spacer()
            }
            if let title = ObjectOnboarding.reviewTitle(for: model.onboarding) {
                Text(title)
                    .font(.title2.weight(.bold))
            }
            if let text = ObjectOnboarding.reviewBody(for: model.onboarding) {
                Text(text)
                    .font(.body)
                    .multilineTextAlignment(.center)
            }
            if ObjectOnboarding.showsFlipWarning(for: model.onboarding, flipRecommended: model.flipRecommended) {
                Text(Copy.ObjectCapture.flipWarning)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            VStack(spacing: 10) {
                ForEach(reviewChoices, id: \.title) { choice in
                    if choice.isPrimary {
                        primaryButton(choice.title) { model.choose(choice.event) }
                    } else {
                        secondaryButton(choice.title) { model.choose(choice.event) }
                    }
                }
            }
        }
        .padding()
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .alert(Copy.ObjectCapture.tooFewPhotos.title, isPresented: $tooFewInReview) {
            Button(Copy.Errors.ok) { model.showsTooFewPhotos = false }
        } message: {
            Text(Copy.ObjectCapture.tooFewPhotos.body)
        }
    }

    /// The review's buttons for the current lap.
    private var reviewChoices: [ObjectReviewChoice] {
        ObjectOnboarding.reviewChoices(for: model.onboarding, flipRecommended: model.flipRecommended)
    }

    // MARK: Buttons and actions

    /// A prominent button with `title`.
    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .frame(minWidth: 120)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
    }

    /// A plain bordered button with `title`.
    private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .frame(minWidth: 120)
                .padding(.vertical, 6)
        }
        .buttonStyle(.bordered)
    }

    /// Cancel: pauses the session and asks before discarding.
    private func requestCancel() {
        guard !confirmingCancel else { return }
        model.pauseForOverlay()
        confirmingCancel = true
    }

    /// Background pauses the session once; active resumes it (RESEARCH 3.3 gotcha 5).
    private func handleScenePhase(_ newPhase: ScenePhase) {
        switch newPhase {
        case .background:
            guard !pausedForBackground else { return }
            pausedForBackground = true
            model.pauseForOverlay()
        case .active:
            guard pausedForBackground else { return }
            pausedForBackground = false
            model.resumeFromOverlay()
        case .inactive:
            break
        @unknown default:
            break
        }
    }
}

/// The guidance banner, observing the model's quiet announcer.
private struct ObjectScanGuidanceLayer: View {
    /// The announcer whose `current` kind is shown.
    @ObservedObject var announcer: GuidanceAnnouncer

    /// `GuidanceBanner` below the top controls; it never takes touches.
    var body: some View {
        GuidanceBanner(kind: announcer.current)
            .padding(.top, 72)
            .allowsHitTesting(false)
    }
}
