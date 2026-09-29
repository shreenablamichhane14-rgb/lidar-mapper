import SwiftUI
import RealityKit

// The screen shell of mesh-only scans (docs/MODULES.md 3.32, UX_COPY section 4, RESEARCH 3.10
// "Capture screen basics"): the live camera in one stable position of the view tree, Mapper's
// guidance banner, the "starting up" line, the paused card with Resume, the saving card, the
// photo note and the caller's HUD on top. Forced dark, system overlays hidden, the HUD clamped
// to .xxxLarge Dynamic Type. All text comes from Copy; the idle timer is held by MeshScanModel.

/// Screen shell: camera (LiveMeshContainer), guidance banner (`GuidanceBanner(kind: snapshot.guidance)`),
/// the "starting up" line while `.starting`, the paused card (`Copy.Scanning.paused` with Resume) while
/// paused, and the caller's HUD on top. Forced dark, `.persistentSystemOverlays(.hidden)`, HUD Dynamic
/// Type clamped to xxxLarge.
struct LiveMeshScreen<HUD: View>: View {
    /// The pass being shown.
    @ObservedObject var model: MeshScanModel
    /// Whether Apple's coaching overlay is shown over the camera.
    let showsCoaching: Bool
    /// Called once the ARView took the session (RealityKit content attaches here).
    let onViewReady: (@MainActor (ARView) -> Void)?
    /// Called for every tap on the camera.
    let onTap: (@MainActor (CGPoint, ARView) -> Void)?
    /// The caller's controls (for example `LiveMeshTopBar` and hints).
    let hud: () -> HUD

    /// Room left above the banner for a top bar in the HUD.
    @ScaledMetric(relativeTo: .headline) private var bannerTopInset: CGFloat = 64

    /// Creates the screen for `model` with the caller's HUD.
    init(model: MeshScanModel, showsCoaching: Bool = true, onViewReady: (@MainActor (ARView) -> Void)? = nil,
         onTap: (@MainActor (CGPoint, ARView) -> Void)? = nil, @ViewBuilder hud: @escaping () -> HUD) {
        self.model = model
        self.showsCoaching = showsCoaching
        self.onViewReady = onViewReady
        self.onTap = onTap
        self.hud = hud
    }

    /// Camera, banner, status cards and the HUD, in that order from back to front.
    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()
            LiveMeshContainer(hub: model.engine.hub, showsCoaching: showsCoaching, onViewReady: onViewReady,
                              onTap: onTap)
                .ignoresSafeArea()
                .accessibilityLabel(Copy.A11y.scanView)
            GuidanceBanner(kind: model.bannerKind)
                .padding(.top, bannerTopInset)
            statusLayer
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            hud()
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        }
        .environment(\.colorScheme, .dark)
        .persistentSystemOverlays(.hidden)
    }

    /// The starting line, the paused card, the saving card or the photo note, centered.
    private var statusLayer: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 0)
            if model.state == .starting {
                LiveMeshPill(text: Copy.Scanning.startingUp)
            } else if model.isPaused {
                pausedCard
            } else if model.state == .stopping {
                LiveMeshCard {
                    HStack(spacing: 12) {
                        ProgressView()
                            .tint(Color.white)
                        Text(Copy.LiveMeshView.saving)
                            .font(.headline)
                    }
                }
            } else if model.showsPhotoNote {
                LiveMeshPill(text: Copy.Scanning.photoSaved)
                    .transition(.opacity)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .animation(.easeInOut(duration: 0.2), value: model.showsPhotoNote)
    }

    /// `Copy.Scanning.paused` with a Resume button.
    private var pausedCard: some View {
        LiveMeshCard {
            VStack(spacing: 12) {
                Image(systemName: "pause.circle.fill")
                    .font(.largeTitle)
                    .accessibilityHidden(true)
                Text(Copy.Scanning.paused)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                LiveMeshBarButton(title: Copy.Scanning.resume, prominent: true, enabled: true) {
                    model.resume()
                }
            }
        }
    }
}

/// Standard top bar for mesh-only screens: Cancel (left), elapsed time (center), Done (right, hidden when `onDone` is nil).
struct LiveMeshTopBar: View {
    /// The elapsed time text (`MeshScanModel.elapsedText`).
    let elapsed: String
    /// Whether Done can be tapped.
    let doneEnabled: Bool
    /// Cancel action.
    let onCancel: () -> Void
    /// Done action; nil hides the button.
    let onDone: (() -> Void)?

    /// Creates the bar.
    init(elapsed: String, doneEnabled: Bool, onCancel: @escaping () -> Void, onDone: (() -> Void)?) {
        self.elapsed = elapsed
        self.doneEnabled = doneEnabled
        self.onCancel = onCancel
        self.onDone = onDone
    }

    /// Cancel and Done at the sides, the timer centered between them.
    var body: some View {
        ZStack {
            HStack(spacing: 12) {
                LiveMeshBarButton(title: Copy.Scanning.cancel, prominent: false, enabled: true, action: onCancel)
                Spacer(minLength: 0)
                if let onDone {
                    LiveMeshBarButton(title: Copy.Scanning.done, prominent: true, enabled: doneEnabled, action: onDone)
                        .accessibilityLabel(Copy.A11y.doneScanning)
                        .accessibilityHint(Copy.A11y.doneScanningHint)
                }
            }
            LiveMeshPill(text: elapsed, monospaced: true)
                .accessibilityLabel(Copy.LiveMeshView.elapsedLabel)
                .accessibilityValue(elapsed)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }
}

/// A translucent pill with one short line of text (hints, the timer, notes).
struct LiveMeshPill: View {
    /// The text (from Copy or Units).
    let text: String
    /// Monospaced digits (the timer).
    var monospaced = false

    /// Bold white text on a dark capsule.
    var body: some View {
        Text(text)
            .font(monospaced ? Font.subheadline.weight(.semibold).monospacedDigit() : Font.subheadline.weight(.semibold))
            .foregroundStyle(Color.white)
            .multilineTextAlignment(.center)
            .lineLimit(3)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule(style: .continuous).fill(Color.black.opacity(0.6)))
    }
}

/// A rounded dark card for status messages (paused, saving).
struct LiveMeshCard<Content: View>: View {
    /// The card's content.
    let content: Content

    /// Wraps `content` in the card.
    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    /// Padded content on a translucent rounded rectangle, at most 460 points wide.
    var body: some View {
        content
            .foregroundStyle(Color.white)
            .padding(18)
            .frame(maxWidth: 460)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.black.opacity(0.74)))
            .shadow(color: Color.black.opacity(0.3), radius: 8, x: 0, y: 3)
    }
}

/// A capsule button reachable with one thumb: prominent (Done, Resume) or plain (Cancel).
struct LiveMeshBarButton: View {
    /// Button title (Copy).
    let title: String
    /// Filled accent style for the main action.
    let prominent: Bool
    /// False dims the button and ignores taps.
    let enabled: Bool
    /// Tap action.
    let action: () -> Void

    /// Scaled minimum height of the tap target.
    @ScaledMetric(relativeTo: .headline) private var minHeight: CGFloat = 44

    /// Creates a button.
    init(title: String, prominent: Bool, enabled: Bool, action: @escaping () -> Void) {
        self.title = title
        self.prominent = prominent
        self.enabled = enabled
        self.action = action
    }

    /// Headline text on a capsule; dimmed when disabled.
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .foregroundStyle(Color.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 18)
                .frame(minHeight: minHeight)
                .background(Capsule(style: .continuous).fill(background))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }

    /// Accent for the main action, dark translucent otherwise.
    private var background: Color {
        prominent ? Color.accentColor : Color.black.opacity(0.6)
    }
}
