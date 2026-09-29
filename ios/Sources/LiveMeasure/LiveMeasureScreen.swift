import SwiftUI

/// Reticle, segment lines and labels (value plus accuracy), live label, "Snapped to" tag, hint
/// (aim or next), guidance banner, Undo, Add Point, Save, Clear All, Close; forced dark.
///
/// The camera fills the screen; the drawing layer (`LiveMeasureOverlay`) uses the same full
/// screen coordinate space as the `ARView`, so the model's projected points land on the camera
/// image. Controls sit at the bottom for one-hand reach (RESEARCH 3.10 measurement tool). The
/// screen calls `model.start()` on appear (idempotent, AppShell may already have called it).
struct LiveMeasureScreen: View {
    /// The Quick Measure model.
    @ObservedObject private var model: LiveMeasureModel
    /// The measurement list sheet is showing.
    @State private var showsList = false
    /// Diameter of the Add Point button, scaled with Dynamic Type.
    @ScaledMetric(relativeTo: .largeTitle) private var addButtonSize: CGFloat = 76

    /// Creates the screen for `model`.
    init(model: LiveMeasureModel) {
        _model = ObservedObject(wrappedValue: model)
    }

    /// Camera, drawing layer, chrome, and the saving and failure covers.
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            LiveMeasureContainer(model: model)
                .ignoresSafeArea()
            LiveMeasureOverlay(model: model)
                .ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                GuidanceBanner(kind: model.guidance)
                bottomPanel
            }
            if model.phase == .saving {
                savingCover
            }
            if let message = failureMessage {
                failureCard(message)
            }
        }
        .environment(\.colorScheme, .dark)
        .persistentSystemOverlays(.hidden)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .alert(model.alert ?? "", isPresented: $model.isAlertShown) {
            Button(Copy.Errors.ok) { model.dismissAlert() }
        } message: {
            if let text = model.alertMessage {
                Text(text)
            }
        }
        .sheet(isPresented: $showsList) {
            LiveMeasureListSheet(model: model)
        }
        .onAppear { model.start() }
    }

    // MARK: Chrome

    /// Close, title and Save; the discard confirmation hangs here.
    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                model.close()
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color.black.opacity(0.45)))
            }
            .accessibilityLabel(Copy.A11y.close)
            .disabled(model.phase == .saving)
            Spacer(minLength: 8)
            Text(Copy.Modes.quickMeasure)
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .shadow(color: Color.black.opacity(0.6), radius: 2)
            Spacer(minLength: 8)
            Button(Copy.Measure.save) { model.save() }
                .font(.body.weight(.semibold))
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
        }
        .foregroundStyle(Color.white)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .alert(Copy.LiveMeasure.discardTitle, isPresented: $model.showsDiscardConfirmation) {
            Button(Copy.LiveMeasure.discardConfirm, role: .destructive) { model.confirmDiscard() }
            Button(Copy.Scanning.cancelConfirmKeep, role: .cancel) {}
        } message: {
            Text(Copy.LiveMeasure.discardBody)
        }
    }

    /// List button, hint, snapping toggle, and Undo, Add Point, Clear All.
    private var bottomPanel: some View {
        VStack(spacing: 12) {
            if !model.segments.isEmpty {
                listButton
            }
            Text(hintText)
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color.black.opacity(0.55)))
            Toggle(Copy.Measure.snapToggle, isOn: $model.snappingEnabled)
                .font(.footnote.weight(.semibold))
                .tint(Color.yellow)
                .fixedSize()
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.black.opacity(0.45)))
            HStack {
                Button(Copy.Measure.undoPoint) { model.undo() }
                    .frame(minWidth: 88, minHeight: 44)
                    .disabled(!canEdit)
                Spacer()
                addButton
                Spacer()
                Button(Copy.Measure.clearAll) { model.clearAll() }
                    .frame(minWidth: 88, minHeight: 44)
                    .disabled(!canEdit)
            }
            .font(.body.weight(.semibold))
            .padding(.horizontal, 20)
        }
        .foregroundStyle(Color.white)
        .padding(.bottom, 16)
    }

    /// Opens the measurement list ("Measurements" and the count).
    private var listButton: some View {
        Button {
            showsList = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "list.bullet")
                    .accessibilityHidden(true)
                Text(Copy.LiveMeasure.listTitle)
                Text(String(model.segments.count))
                    .monospacedDigit()
            }
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color.black.opacity(0.55)))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    /// The big round Add Point button.
    private var addButton: some View {
        Button {
            model.addPoint()
        } label: {
            ZStack {
                Circle().fill(Color.white)
                Circle().stroke(Color.black.opacity(0.25), lineWidth: 2)
                Image(systemName: "plus")
                    .font(.system(size: addButtonSize * 0.4, weight: .bold))
                    .foregroundStyle(Color.black)
            }
            .frame(width: addButtonSize, height: addButtonSize)
        }
        .buttonStyle(.plain)
        .disabled(!canAdd)
        .opacity(canAdd ? 1 : 0.4)
        .accessibilityLabel(Copy.Measure.addPoint)
    }

    /// Dimmed cover with a spinner while the project is created.
    private var savingCover: some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                    .tint(Color.white)
                Text(Copy.LiveMeasure.saving)
                    .font(.headline)
                    .foregroundStyle(Color.white)
            }
            .padding(24)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.black.opacity(0.75)))
            .accessibilityElement(children: .combine)
        }
    }

    /// The reason Quick Measure cannot run, with OK to close.
    private func failureCard(_ message: String) -> some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            VStack(spacing: 16) {
                Text(message)
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color.white)
                Button(Copy.Errors.ok) { model.close() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(24)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.black.opacity(0.8)))
            .padding(32)
        }
    }

    // MARK: State

    /// True while measuring.
    private var isMeasuring: Bool { model.phase == .measuring }
    /// Save needs at least one distance.
    private var canSave: Bool { isMeasuring && !model.segments.isEmpty }
    /// Add Point needs a surface under the reticle.
    private var canAdd: Bool { isMeasuring && model.reticle != nil }
    /// Undo and Clear All need a point or a distance.
    private var canEdit: Bool { isMeasuring && (model.pending != nil || !model.segments.isEmpty) }

    /// The message of a `.failed` phase.
    private var failureMessage: String? {
        if case .failed(let message) = model.phase { return message }
        return nil
    }

    /// Aim or next when a surface is under the reticle, else the surface hints.
    private var hintText: String {
        if model.reticle == nil {
            return model.hasFoundSurfaces ? Copy.LiveMeasure.noSurface : Copy.LiveMeasure.findingSurfaces
        }
        return model.pending == nil ? Copy.Measure.aimHint : Copy.Measure.nextHint
    }
}
