import SwiftUI

// Mapper's controls over the camera during a house visit (docs/MODULES.md 3.41, UX_COPY sections
// 4 and 5): the capture chrome (guidance banner at the top, room title and floor, timer, counts,
// Cancel, Take Photo and Done at the bottom within one thumb's reach, the paused and time limit
// cards), the relocalization chrome (what to do, Start Fresh Here and Keep Looking after 30 s),
// the naming sheet and the notice card that replaces system alerts while a sheet is up. The HUD
// pieces come from ScanUI; all text from Copy. Forced dark and clamped to .xxxLarge.

/// The capture chrome of `HouseScanScreen`.
struct HouseScanChrome: View {
    /// The house flow.
    @ObservedObject var model: HouseFlowModel
    /// The guidance announcer of the flow (its `current` kind drives the banner).
    @ObservedObject var announcer: GuidanceAnnouncer

    /// Creates the chrome for `model`; pass `model.announcer`.
    init(model: HouseFlowModel, announcer: GuidanceAnnouncer) {
        self.model = model
        self.announcer = announcer
    }

    /// The layers of the current phase.
    var body: some View {
        ZStack {
            if showsBanner {
                GuidanceBanner(kind: announcer.current)
            }
            if model.isDiscarding {
                centeredCard(text: Copy.ScanUI.discarding)
            } else if model.phase == .capturing {
                capturingLayer
            } else if model.phase == .stopping {
                centeredCard(text: Copy.ScanUI.saving)
            }
            if model.showsAlertAsNotice, let notice = model.alert {
                noticeLayer(notice)
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    /// The guidance banner shows while scanning, not while paused or behind the time limit card.
    private var showsBanner: Bool {
        model.phase == .capturing && !model.isPaused && !model.showsTimeLimitCard && !model.isDiscarding
    }

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
        if model.showsTimeLimitCard {
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

    /// "Getting ready", the next-room and time hints, the room title with its floor and the
    /// Demo Mode banner.
    @ViewBuilder private var hints: some View {
        if model.engineState == .starting || model.engineState == .idle {
            ScanHUDPill(text: Copy.Scanning.startingUp)
        } else if model.showsNextRoomHint {
            ScanHUDPill(text: Copy.HouseUI.nextRoomHint)
                .transition(.opacity)
        } else if model.showsTimeHint {
            ScanHUDPill(text: Copy.ScanUI.timeHint)
                .transition(.opacity)
        }
        if !model.roomChipText.isEmpty {
            ScanHUDPill(text: model.roomChipText)
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

    /// A progress card in the middle of the screen.
    private func centeredCard(text: String) -> some View {
        VStack {
            Spacer(minLength: 0)
            ScanHUDCard { ScanProgressLine(text: text) }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
    }

    /// An alert as a card at the top while a sheet covers the bottom half.
    private func noticeLayer(_ notice: HouseAlert) -> some View {
        VStack {
            HouseNoticeCard(notice: notice) { action in
                model.alertAction(action)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }
}

/// While relocalizing: what to do at the top (or why there is nothing to find), the searching
/// line, Start Fresh Here and Keep Looking once `showsStartFresh`, and Cancel at the bottom.
/// Apple's coaching overlay shows in the middle of the camera.
struct HouseRelocalizationChrome: View {
    /// The house flow.
    @ObservedObject var model: HouseFlowModel

    /// Creates the chrome for `model`.
    init(model: HouseFlowModel) {
        self.model = model
    }

    /// Cards at the top, buttons at the bottom.
    var body: some View {
        VStack(spacing: 12) {
            ScanHUDCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.noMapAvailable ? Copy.HouseUI.noMapTitle : Copy.HouseUI.relocalizeTitle)
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Text(bodyText)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !model.showsStartFresh {
                ScanHUDPill(text: Copy.HouseUI.relocalizeHint)
            }
            Spacer(minLength: 0)
            if model.showsStartFresh {
                HStack(spacing: 12) {
                    if !model.noMapAvailable {
                        ScanHUDButton(title: Copy.HouseUI.keepLooking) { model.keepLooking() }
                    }
                    ScanHUDButton(title: Copy.HouseUI.startFresh, systemImage: "arrow.clockwise", weight: .primary) {
                        model.startFresh()
                    }
                }
            }
            HStack {
                ScanHUDButton(title: Copy.Scanning.cancel) { model.requestCancel() }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    /// The body line: why there is no map, the Start Fresh explanation after the timeout, or
    /// what to do.
    private var bodyText: String {
        if model.noMapAvailable { return Copy.HouseUI.noMapBody }
        return model.showsStartFresh ? Copy.HouseUI.startFreshBody : Copy.HouseUI.relocalizeBody
    }
}

/// A house alert as a card at the top of the screen while a sheet is up: title, message, buttons.
struct HouseNoticeCard: View {
    /// The alert.
    let notice: HouseAlert
    /// Called with the tapped action.
    let onAction: (HouseAlertAction) -> Void

    /// Title, message and buttons in a card.
    var body: some View {
        ScanHUDCard {
            VStack(alignment: .leading, spacing: 8) {
                Text(notice.title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text(notice.body)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Spacer(minLength: 0)
                    ForEach(notice.actions, id: \.self) { action in
                        Button(HouseAlert.title(for: action)) {
                            onAction(action)
                        }
                        .buttonStyle(.bordered)
                        .tint(Color.white)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
    }
}

/// The naming prompt after a room is kept: a text field with the current name, suggestion
/// buttons (the detected section name first), Skip and Save. Save with an empty field keeps the
/// default title.
struct HouseNamingSheet: View {
    /// The house flow.
    @ObservedObject var model: HouseFlowModel
    /// The text being edited.
    @State private var text = ""
    /// The room whose name `text` was loaded for.
    @State private var loadedFor: UUID?

    /// Creates the prompt for `model`.
    init(model: HouseFlowModel) {
        self.model = model
    }

    /// Title, field, suggestions, and Skip and Save at the bottom.
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(Copy.House.nameRoomTitle)
                .font(.title2.weight(.bold))
                .accessibilityAddTraits(.isHeader)
            TextField(Copy.House.nameRoomPlaceholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.done)
                .onSubmit { save() }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(model.naming?.suggestions ?? [], id: \.self) { name in
                        Button(name) {
                            text = name
                            Haptics.selection()
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            HStack(spacing: 12) {
                Button(Copy.Onboarding.skip) {
                    model.skipNaming()
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                Spacer(minLength: 0)
                Button(Copy.Measure.save) {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding(20)
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled()
        .onAppear { syncText() }
        .onChange(of: model.naming?.id) { _, _ in syncText() }
    }

    /// Loads the current name once per room.
    private func syncText() {
        guard let request = model.naming, loadedFor != request.id else { return }
        loadedFor = request.id
        text = request.current
    }

    /// Save: the typed name (empty keeps the default title).
    private func save() {
        model.name(text)
    }
}
