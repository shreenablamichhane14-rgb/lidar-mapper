import SwiftUI
import UIKit
import simd

/// Canvas of all room outlines, walls and doors through FloorPlan's `PlanViewport`; the moving
/// room highlighted; DragGesture moves it, RotateGesture turns it about its centroid,
/// MagnifyGesture zooms the view; Turn Left and Turn Right buttons; Cancel and Save.
struct AlignRoomsScreen: View {
    /// The alignment state of the room.
    @StateObject private var model: AlignRoomsModel
    /// Called once with true after a save, false after Cancel.
    private let onDone: (_ saved: Bool) -> Void

    /// View zoom (1 fits every room) and the zoom when the pinch began.
    @State private var zoom: CGFloat = 1
    /// The magnification of the pinch at the previous change.
    @State private var lastMagnification: CGFloat = 1
    /// The drag translation at the previous change, points.
    @State private var lastDrag: CGSize = .zero
    /// The rotation of the two-finger turn at the previous change, radians.
    @State private var lastRotation: Double = 0
    /// Save failed (alert).
    @State private var saveFailed = false
    /// "Rooms joined" shows after a save.
    @State private var showsDone = false
    /// True once Save or Cancel was used (ignores a second tap).
    @State private var finished = false

    /// Margin around the rooms when the view fits them, points.
    private static let fitMargin: CGFloat = 32
    /// Allowed zoom range.
    private static let zoomRange: ClosedRange<CGFloat> = 0.5...6

    /// Creates the screen for one room of a house.
    init(projectID: UUID, roomID: UUID, onDone: @escaping (_ saved: Bool) -> Void) {
        _model = StateObject(wrappedValue: AlignRoomsModel(projectID: projectID, roomID: roomID))
        self.onDone = onDone
    }

    /// Top bar, the canvas (or the not-ready note) and the turn buttons.
    var body: some View {
        VStack(spacing: 0) {
            topBar
            if !model.hasLoaded {
                Spacer(minLength: 0)
                ProgressView()
                Spacer(minLength: 0)
            } else if !model.isReady {
                Spacer(minLength: 0)
                Text(Copy.HouseUI.alignNotReady)
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .padding(24)
                Spacer(minLength: 0)
            } else {
                Text(Copy.HouseUI.lineUpHint)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
                canvas
                turnButtons
            }
        }
        .overlay(alignment: .top) { notes }
        .task { await model.load() }
        .alert(Copy.Errors.saveFailed.title, isPresented: $saveFailed) {
            Button(Copy.Errors.ok, role: .cancel) {}
        } message: {
            Text(Copy.Errors.saveFailed.body)
        }
    }

    // MARK: - Parts

    /// Cancel, title and Save.
    private var topBar: some View {
        HStack {
            Button(Copy.Project.cancel) { cancel() }
            Spacer(minLength: 8)
            Text(Copy.HouseUI.lineUpTitle)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            Button(Copy.Measure.save) { save() }
                .font(.body.weight(.semibold))
                .disabled(!model.isReady || finished)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// The snap note, then "Rooms joined" after a save.
    @ViewBuilder private var notes: some View {
        if showsDone {
            ScanHUDPill(text: Copy.House.alignDone)
                .padding(.top, 60)
        } else if let text = model.snapText {
            ScanHUDPill(text: text)
                .padding(.top, 60)
                .transition(.opacity)
        }
    }

    /// Turn Left and Turn Right (also VoiceOver's way to turn the room).
    private var turnButtons: some View {
        HStack(spacing: 12) {
            Button {
                model.turn(clockwise: false)
            } label: {
                Label(Copy.HouseUI.turnLeft, systemImage: "rotate.left")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            Button {
                model.turn(clockwise: true)
            } label: {
                Label(Copy.HouseUI.turnRight, systemImage: "rotate.right")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// The rooms drawn through the viewport, with the three gestures.
    private var canvas: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let port = viewport(in: size)
            let others = model.others
            let companions = model.movedCompanions
            let moving = model.movedShape
            Canvas { context, _ in
                for shape in others {
                    AlignRoomsDrawing.draw(shape, in: &context, port: port, fill: Color.secondary.opacity(0.18),
                                          stroke: Color.secondary)
                }
                for shape in companions {
                    AlignRoomsDrawing.draw(shape, in: &context, port: port, fill: Color.accentColor.opacity(0.12),
                                          stroke: Color.accentColor.opacity(0.7))
                }
                if let shape = moving {
                    AlignRoomsDrawing.draw(shape, in: &context, port: port, fill: Color.accentColor.opacity(0.25),
                                          stroke: Color.accentColor)
                }
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(port: port))
            .simultaneousGesture(rotateGesture)
            .simultaneousGesture(magnifyGesture)
            .accessibilityElement()
            .accessibilityLabel(Copy.HouseUI.lineUpTitle)
            .accessibilityHint(Copy.HouseUI.a11yMoveRoomHint)
        }
    }

    // MARK: - Gestures

    /// One finger moves the room: screen points to plan meters (plan +y is screen up).
    private func dragGesture(port: PlanViewport) -> some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .local)
            .onChanged { value in
                let dx = value.translation.width - lastDrag.width
                let dy = value.translation.height - lastDrag.height
                lastDrag = value.translation
                let k = port.pointsPerMeter > 0 && port.pointsPerMeter.isFinite ? port.pointsPerMeter : 1
                let planX = Float(dx / k)
                let planY = Float(-dy / k)
                model.drag(by: SIMD2<Float>(planX, planY))
            }
            .onEnded { _ in
                lastDrag = .zero
            }
    }

    /// Two fingers turn the room about its centroid (a clockwise turn on screen is clockwise in
    /// plan, a negative plan angle).
    private var rotateGesture: some Gesture {
        RotateGesture(minimumAngleDelta: .degrees(1))
            .onChanged { value in
                let angle = value.rotation.radians
                let delta = angle - lastRotation
                lastRotation = angle
                model.rotate(by: Float(-delta))
            }
            .onEnded { _ in
                lastRotation = 0
            }
    }

    /// Pinch zooms the view (not the room).
    private var magnifyGesture: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.01)
            .onChanged { value in
                let ratio = value.magnification / Swift.max(lastMagnification, 0.001)
                lastMagnification = value.magnification
                guard ratio.isFinite, ratio > 0 else { return }
                let range = AlignRoomsScreen.zoomRange
                zoom = Swift.min(Swift.max(zoom * ratio, range.lowerBound), range.upperBound)
            }
            .onEnded { _ in
                lastMagnification = 1
            }
    }

    // MARK: - Drawing

    /// The viewport fitted to every room as loaded (so the view does not follow the drag), then
    /// the user's zoom about the center.
    private func viewport(in size: CGSize) -> PlanViewport {
        var shapes = model.others + model.companions
        if let moving = model.moving { shapes.append(moving) }
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        guard let bounds = AlignRoomsDrawing.bounds(of: shapes) else {
            return PlanViewport(pointsPerMeter: 40, origin: center)
        }
        let fitted = PlanViewport.fitting(min: bounds.lower, max: bounds.upper, in: size, margin: AlignRoomsScreen.fitMargin)
        return fitted.zoomed(by: zoom, about: center)
    }

    // MARK: - Actions

    /// Cancel: nothing is written.
    private func cancel() {
        guard !finished else { return }
        finished = true
        onDone(false)
    }

    /// Save: one edit log entry, "Rooms joined", then `onDone(true)` (AppShell re-enqueues
    /// processing).
    private func save() {
        guard !finished else { return }
        do {
            try model.save()
        } catch {
            LogStore.shared.write("manual alignment not saved: \(StoreFiles.describe(error))",
                                  category: HouseRelocalization.logCategory)
            saveFailed = true
            return
        }
        finished = true
        showsDone = true
        UIAccessibility.post(notification: .announcement, argument: Copy.House.alignDone)
        let done = onDone
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            done(true)
        }
    }
}

/// Drawing helpers of the alignment canvas (plain functions, safe inside the Canvas renderer).
enum AlignRoomsDrawing {
    /// Plan bounds of the shapes' outlines and walls, nil without points.
    static func bounds(of shapes: [AlignShape]) -> (lower: SIMD2<Double>, upper: SIMD2<Double>)? {
        var points: [SIMD2<Float>] = []
        for shape in shapes {
            points.append(contentsOf: shape.outline)
            for wall in shape.walls {
                points.append(wall.start)
                points.append(wall.end)
            }
        }
        let finite = points.filter { $0.x.isFinite && $0.y.isFinite }
        guard var lower = finite.first else { return nil }
        var upper = lower
        for point in finite {
            lower = simd_min(lower, point)
            upper = simd_max(upper, point)
        }
        return (lower: SIMD2<Double>(Double(lower.x), Double(lower.y)), upper: SIMD2<Double>(Double(upper.x), Double(upper.y)))
    }

    /// One room: filled outline, walls as thick lines, doors as dots.
    static func draw(_ shape: AlignShape, in context: inout GraphicsContext, port: PlanViewport, fill: Color, stroke: Color) {
        if shape.outline.count >= 3 {
            var outline = Path()
            outline.move(to: screen(shape.outline[0], port))
            for point in shape.outline.dropFirst() { outline.addLine(to: screen(point, port)) }
            outline.closeSubpath()
            context.fill(outline, with: .color(fill))
        }
        var walls = Path()
        for wall in shape.walls {
            walls.move(to: screen(wall.start, port))
            walls.addLine(to: screen(wall.end, port))
        }
        context.stroke(walls, with: .color(stroke), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        for door in shape.doors {
            let center = screen(door, port)
            let dot = Path(ellipseIn: CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10))
            context.fill(dot, with: .color(stroke))
        }
    }

    /// Screen point of a plan point.
    static func screen(_ point: SIMD2<Float>, _ port: PlanViewport) -> CGPoint {
        port.toScreen(SIMD2<Double>(Double(point.x), Double(point.y)))
    }
}
