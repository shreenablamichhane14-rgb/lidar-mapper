import SwiftUI
import RealityKit

// The Show Missing Areas screen (docs/MODULES.md 3.40, UX_COPY section 6): LiveMeshView's
// camera shell with the tour's HUD on top. The arrow points to the suggested place to stand,
// then at the area itself (up or down for ceilings and floors); the card below shows the step,
// the hint, the distance through Units, the notice and Next Area. All text comes from Copy.
// The pure presentation rules and the VoiceOver throttle are below, so the self-test checks them.

/// `LiveMeshScreen(model: model.scan, onViewReady: onViewReady) { MissingAreasHUD(model: model) }`.
struct MissingAreasScreen: View {
    /// The tour (not observed here, so the camera container is not rebuilt at the refresh rate).
    let model: MissingAreasModel
    /// Called once the ARView took the session (ScanUI attaches the coverage overlay here).
    let onViewReady: (@MainActor (ARView) -> Void)?

    /// Creates the screen for `model`.
    init(model: MissingAreasModel, onViewReady: (@MainActor (ARView) -> Void)? = nil) {
        self.model = model
        self.onViewReady = onViewReady
    }

    /// The camera shell with the tour HUD.
    var body: some View {
        LiveMeshScreen(model: model.scan, onViewReady: onViewReady) {
            MissingAreasHUD(model: model)
        }
    }
}

/// Arrow (rotated by `bearing`, or up and down at the viewpoint), step line, hint, distance, notice,
/// Next Area, Done (`LiveMeshTopBar`), the all-done line, cancel confirmation, VoiceOver direction
/// announcements at most every 3 s (posted by the model's refresh tick, `MissingAreasAnnouncer`).
struct MissingAreasHUD: View {
    /// The tour.
    @ObservedObject var model: MissingAreasModel

    /// Creates the HUD for `model`.
    init(model: MissingAreasModel) {
        self.model = model
    }

    /// The content, the cancel confirmation and the alert.
    var body: some View {
        MissingAreasHUDContent(model: model, scan: model.scan)
            .confirmationDialog(Copy.MissingAreas.cancelTitle, isPresented: $model.showsCancelConfirmation,
                                titleVisibility: .visible) {
                Button(Copy.MissingAreas.cancelDiscardPass, role: .destructive) {
                    model.confirmCancel()
                }
                Button(Copy.Scanning.cancelConfirmKeep, role: .cancel) {
                    model.keepScanning()
                }
            } message: {
                Text(Copy.MissingAreas.cancelBody)
            }
            .alert(model.alert?.title ?? "", isPresented: alertPresented, presenting: model.alert) { _ in
                Button(Copy.Errors.ok, role: .cancel) {
                    model.alert = nil
                }
            } message: { current in
                Text(current.body)
            }
    }

    /// True while the model has an alert; dismissing clears it.
    private var alertPresented: Binding<Bool> {
        Binding(get: { model.alert != nil }, set: { shown in
            if !shown { model.alert = nil }
        })
    }
}

/// The HUD layout; observes the tour and the pass (for the timer and the pass state).
private struct MissingAreasHUDContent: View {
    /// The tour.
    @ObservedObject var model: MissingAreasModel
    /// The pass.
    @ObservedObject var scan: MeshScanModel

    /// Size of the arrow symbol.
    @ScaledMetric(relativeTo: .largeTitle) private var arrowSize: CGFloat = 84

    /// Creates the content for the tour and its pass.
    init(model: MissingAreasModel, scan: MeshScanModel) {
        self.model = model
        self.scan = scan
    }

    /// Top bar, arrow or rechecking card, and the tour card.
    var body: some View {
        VStack(spacing: 12) {
            LiveMeshTopBar(elapsed: scan.elapsedText, doneEnabled: doneEnabled, onCancel: { model.requestCancel() },
                           onDone: { model.finishTour() })
            Spacer(minLength: 0)
            centerLayer
            Spacer(minLength: 0)
            if showsTourCard {
                tourCard
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
        }
    }

    /// Done applies while the tour runs and the pass is capturing.
    private var doneEnabled: Bool {
        let capturing = scan.state == .scanning || scan.state == .paused
        return model.phase.isActive && !model.isCancelling && capturing
    }

    /// The pass is live and not paused or saving (the shell shows those states in the middle).
    private var passIsLive: Bool {
        scan.state == .scanning && !scan.isPaused
    }

    /// The tour card is shown while touring or all done (not while preparing or saving).
    private var showsTourCard: Bool {
        let touring = model.phase == .touring || model.phase == .allDone
        return touring && !model.isCancelling && scan.state != .starting
    }

    /// The arrow while touring, or the rechecking card after Done.
    @ViewBuilder private var centerLayer: some View {
        if model.phase == .rechecking {
            LiveMeshCard {
                HStack(spacing: 12) {
                    ProgressView()
                        .tint(Color.white)
                    Text(Copy.MissingAreas.rechecking)
                        .font(.headline)
                }
            }
            .padding(.horizontal, 16)
        } else if let arrow = model.arrow, model.phase == .touring, passIsLive, !model.isCancelling {
            Image(systemName: MissingAreasPresentation.symbolName(arrow))
                .font(.system(size: arrowSize, weight: .bold))
                .foregroundStyle(Color.white)
                .rotationEffect(.radians(MissingAreasPresentation.rotationRadians(arrow)))
                .shadow(color: Color.black.opacity(0.5), radius: 6, x: 0, y: 2)
                .accessibilityLabel(MissingAreasPresentation.spokenText(MissingAreaTour.direction(arrow)))
        }
    }

    /// Step line, hint, distance, notice or all-done line, and Next Area.
    private var tourCard: some View {
        LiveMeshCard {
            VStack(spacing: 8) {
                if let step = MissingAreasPresentation.stepText(model.tour), model.phase == .touring {
                    Text(step)
                        .font(.headline)
                }
                if model.phase == .touring {
                    Text(MissingAreasPresentation.hintText(model.arrow))
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    if let distance = MissingAreasPresentation.distanceText(model.arrow, units: model.units) {
                        Text(distance)
                            .font(Font.subheadline.weight(.semibold).monospacedDigit())
                    }
                }
                if let notice = model.notice {
                    Text(notice)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                } else if model.phase == .allDone {
                    Text(Copy.Quality.allAreasDone)
                        .font(.headline)
                }
                if model.phase == .touring {
                    LiveMeshBarButton(title: Copy.Quality.nextMissingArea, prominent: false, enabled: !model.isCancelling) {
                        model.nextArea()
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.notice)
    }
}

/// Pure presentation rules of the HUD (tested off the main actor).
enum MissingAreasPresentation {
    /// `Copy.Quality.missingAreaStep`: the resolved stops plus one, of all stops; nil without a current stop.
    static func stepText(_ tour: MissingAreaTour) -> String? {
        guard tour.currentStop != nil, !tour.stops.isEmpty else { return nil }
        let index = Swift.min(tour.stops.count, tour.resolvedCount + 1)
        return Copy.Quality.missingAreaStep(index, of: tour.stops.count)
    }

    /// At the viewpoint, the `.scanCeiling` text for up and the `.pointAtFloor` text for down;
    /// otherwise `Copy.Quality.missingAreaHint`.
    static func hintText(_ arrow: MissingAreaArrow?) -> String {
        guard let arrow else { return Copy.Quality.missingAreaHint }
        switch MissingAreaTour.direction(arrow) {
        case .up: return GuidanceKind.scanCeiling.message.text
        case .down: return GuidanceKind.pointAtFloor.message.text
        case .ahead, .left, .right, .behind: return Copy.Quality.missingAreaHint
        }
    }

    /// `Copy.MissingAreas.distanceAway` with `LengthFormat.display` while walking to the viewpoint;
    /// nil at the viewpoint or without an arrow.
    static func distanceText(_ arrow: MissingAreaArrow?, units: UnitPreferences) -> String? {
        guard let arrow, !arrow.atViewpoint else { return nil }
        return Copy.MissingAreas.distanceAway(LengthFormat.display(Double(arrow.horizontalDistance), prefs: units))
    }

    /// The VoiceOver text of a direction.
    static func spokenText(_ direction: MissingAreaDirection) -> String {
        switch direction {
        case .ahead: return Copy.MissingAreas.a11yAhead
        case .left: return Copy.MissingAreas.a11yLeft
        case .right: return Copy.MissingAreas.a11yRight
        case .behind: return Copy.MissingAreas.a11yBehind
        case .up: return Copy.MissingAreas.a11yUp
        case .down: return Copy.MissingAreas.a11yDown
        }
    }

    /// SF Symbol of the arrow: a plain arrow while walking, a circled one at the viewpoint
    /// (straight up or down for ceilings and floors).
    static func symbolName(_ arrow: MissingAreaArrow) -> String {
        guard arrow.atViewpoint else { return "arrow.up" }
        switch MissingAreaTour.direction(arrow) {
        case .down: return "arrow.down.circle.fill"
        case .up, .ahead, .left, .right, .behind: return "arrow.up.circle.fill"
        }
    }

    /// Rotation of the arrow symbol: the bearing, or none when it points up or down at the viewpoint.
    static func rotationRadians(_ arrow: MissingAreaArrow) -> Double {
        switch MissingAreaTour.direction(arrow) {
        case .up, .down: return 0
        case .ahead, .left, .right, .behind: return Double(arrow.bearing)
        }
    }
}

/// VoiceOver throttle: a new direction is spoken at most every `minimumInterval` seconds, and a
/// direction that did not change is never repeated. Pure (the caller passes the time).
struct MissingAreasAnnouncer: Equatable {
    /// Least seconds between two spoken lines.
    static let minimumInterval: Double = 3
    /// The direction spoken last (nil after `reset()` or without an arrow).
    private(set) var lastDirection: MissingAreaDirection?
    /// When something was spoken last.
    private(set) var lastTime: Double?

    /// True when `direction` should be spoken now (and records it). Nil forgets the last direction.
    mutating func shouldAnnounce(_ direction: MissingAreaDirection?, now: Double) -> Bool {
        guard let direction else {
            lastDirection = nil
            return false
        }
        guard direction != lastDirection else { return false }
        if let last = lastTime, now - last < MissingAreasAnnouncer.minimumInterval { return false }
        lastDirection = direction
        lastTime = now
        return true
    }

    /// Something else was spoken (a notice): the next direction waits the full interval.
    mutating func noteSpoken(now: Double) {
        lastTime = now
    }

    /// A new area is shown: its direction is spoken even when it equals the last one.
    mutating func reset() {
        lastDirection = nil
    }
}
