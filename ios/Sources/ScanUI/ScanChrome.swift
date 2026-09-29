import SwiftUI

/// Mapper's controls over the camera during a scan (docs/MODULES.md 3.24, UX_COPY section 4):
/// the guidance banner at the top (Apple's coaching shows in the middle of RoomCaptureView),
/// the paused card, the time limit card and short hints in the middle, and at the bottom, where
/// one thumb reaches, the timer, the live counts and Cancel, Take Photo and Done (Cancel, Finish
/// Now and Resume while paused). While saving it shows "Saving your scan..." with Cancel; over
/// the quality sheet only an alert notice card. Forced dark and clamped to .xxxLarge by
/// `RoomScanScreen` and here.
struct ScanChrome: View {
    /// The scan flow.
    @ObservedObject var model: ScanFlowModel
    /// The guidance announcer of the flow (its `current` kind drives the banner).
    @ObservedObject var announcer: GuidanceAnnouncer

    /// Creates the chrome for `model`; pass `model.announcer`.
    init(model: ScanFlowModel, announcer: GuidanceAnnouncer) {
        self.model = model
        self.announcer = announcer
    }

    /// The layers of the current phase.
    var body: some View {
        ZStack {
            if showsBanner {
                GuidanceBanner(kind: announcer.current)
            }
            if model.phase == .capturing {
                capturingLayer
            } else if model.phase == .stopping {
                stoppingLayer
            } else if model.isDiscarding {
                centeredCard(text: Copy.ScanUI.discarding)
            }
            if model.showsAlertAsNotice, let notice = model.alert {
                noticeLayer(notice)
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    /// The guidance banner shows while scanning, not while paused or behind the time limit card.
    private var showsBanner: Bool {
        model.phase == .capturing && !model.isPaused && !model.showsTimeLimitSheet
    }

    // MARK: - Capturing

    /// Middle cards, hints, status and the bottom controls.
    private var capturingLayer: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 0)
            middleCard
            Spacer(minLength: 0)
            hints
            statusRow
            if model.isPaused {
                pausedControls
            } else {
                scanningControls
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    /// The time limit card, the paused card or the photo note.
    @ViewBuilder private var middleCard: some View {
        if model.showsTimeLimitSheet {
            timeLimitCard
        } else if model.isPaused {
            ScanHUDCard {
                VStack(spacing: 10) {
                    Image(systemName: "pause.circle.fill")
                        .font(.largeTitle)
                        .accessibilityHidden(true)
                    Text(Copy.Scanning.paused)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                }
            }
        } else if model.showsPhotoNote {
            ScanHUDPill(text: Copy.Scanning.photoSaved)
                .transition(.opacity)
        }
    }

    /// The 5 minute card: Keep Scanning or Done (never an automatic stop).
    private var timeLimitCard: some View {
        ScanHUDCard {
            VStack(spacing: 12) {
                Text(Copy.ScanUI.timeLimitTitle)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text(Copy.ScanUI.timeLimitBody)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    ScanHUDButton(title: Copy.Errors.keepScanning) { model.dismissTimeLimit() }
                    ScanHUDButton(title: Copy.Scanning.done, weight: .primary) { model.done() }
                        .accessibilityLabel(Copy.A11y.doneScanning)
                        .accessibilityHint(Copy.A11y.doneScanningHint)
                }
            }
        }
    }

    /// "Getting ready", the 4 minute hint and the Demo Mode banner.
    @ViewBuilder private var hints: some View {
        if model.engineState == .starting || model.engineState == .idle {
            ScanHUDPill(text: Copy.Scanning.startingUp)
        } else if model.showsTimeHint {
            ScanHUDPill(text: Copy.ScanUI.timeHint)
                .transition(.opacity)
        }
        if model.isDemo {
            ScanHUDPill(text: Copy.ScanUI.demoBanner)
        }
    }

    /// Timer and live counts.
    private var statusRow: some View {
        HStack(spacing: 8) {
            ScanHUDPill(text: elapsedText, monospaced: true)
                .accessibilityLabel(Copy.ScanUI.elapsedLabel)
                .accessibilityValue(elapsedText)
            Spacer(minLength: 0)
            ScanHUDPill(text: countsText)
                .accessibilityLabel(Copy.ScanUI.countsLabel)
                .accessibilityValue(countsText)
        }
    }

    /// Cancel, Take Photo and Done.
    private var scanningControls: some View {
        HStack(alignment: .bottom, spacing: 12) {
            ScanHUDButton(title: Copy.Scanning.cancel) { model.requestCancel() }
            Spacer(minLength: 0)
            ScanHUDButton(title: Copy.Scanning.addPhoto, systemImage: "camera") { model.takePhoto() }
            Spacer(minLength: 0)
            ScanHUDButton(title: Copy.Scanning.done, systemImage: "checkmark", weight: .primary) { model.done() }
                .accessibilityLabel(Copy.A11y.doneScanning)
                .accessibilityHint(Copy.A11y.doneScanningHint)
        }
    }

    /// Cancel, Finish Now and Resume while paused.
    private var pausedControls: some View {
        HStack(alignment: .bottom, spacing: 12) {
            ScanHUDButton(title: Copy.Scanning.cancel) { model.requestCancel() }
            Spacer(minLength: 0)
            ScanHUDButton(title: Copy.ScanUI.finishNow, systemImage: "checkmark") { model.finishNow() }
            Spacer(minLength: 0)
            ScanHUDButton(title: Copy.Scanning.resume, systemImage: "play.fill", weight: .primary) { model.resume() }
        }
    }

    /// The timer text from the snapshot's scan time.
    private var elapsedText: String {
        let parts = ScanFlowModel.elapsedParts(model.snapshot.elapsed)
        return Copy.ScanUI.elapsed(minutes: parts.minutes, seconds: parts.seconds)
    }

    /// The live counts text.
    private var countsText: String {
        let s = model.snapshot
        return Copy.ScanUI.counts(walls: s.wallCount, doors: s.doorCount, windows: s.windowCount)
    }

    // MARK: - Saving, discarding, notices

    /// "Saving your scan..." with Cancel still reachable.
    private var stoppingLayer: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 0)
            ScanHUDCard { ScanProgressLine(text: Copy.ScanUI.saving) }
            Spacer(minLength: 0)
            HStack {
                ScanHUDButton(title: Copy.Scanning.cancel) { model.requestCancel() }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    /// A progress card in the middle of the screen.
    private func centeredCard(text: String) -> some View {
        VStack {
            Spacer(minLength: 0)
            ScanHUDCard { ScanProgressLine(text: text) }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
    }

    /// An alert as a card at the top while the quality sheet covers the bottom half.
    private func noticeLayer(_ notice: ScanAlert) -> some View {
        VStack {
            ScanNoticeCard(notice: notice) { action in
                model.alertAction(action)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }
}
