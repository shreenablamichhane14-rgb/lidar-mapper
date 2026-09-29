import SwiftUI

// Pieces of the Quick Measure screen: the drawing layer over the camera (lines, end dots,
// labels, the reticle, the "Snapped to" tag and the live label), the value label, and the
// measurement list sheet. Every number comes from the model's MeasureDisplay helpers (Units).

/// Drawing layer in the ARView's coordinate space (full screen, safe area ignored): distance
/// lines with end dots, value labels at their midpoints, the dashed line from the pending point
/// to the reticle, the reticle at the center, the "Snapped to" tag above it and the live label below.
struct LiveMeasureOverlay: View {
    /// The Quick Measure model.
    @ObservedObject var model: LiveMeasureModel

    /// The layer; the reticle sits at the view center, where the model raycasts.
    var body: some View {
        GeometryReader { proxy in
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
            ZStack {
                segmentLines
                pendingLine(center: center)
                segmentLabels
                LiveMeasureReticle(model: model)
                    .position(center)
                snappedTag
                    .position(x: center.x, y: center.y - 52)
                liveLabel
                    .position(x: center.x, y: center.y + 66)
            }
        }
    }

    /// Every closed distance whose two ends are on screen.
    private var visibleLines: [(start: CGPoint, end: CGPoint)] {
        var lines: [(start: CGPoint, end: CGPoint)] = []
        for segment in model.segments {
            guard let entry = model.screenPoints[segment.id], let start = entry.start, let end = entry.end else { continue }
            lines.append((start: start, end: end))
        }
        return lines
    }

    /// Outlined white lines with end dots.
    private var segmentLines: some View {
        let lines = visibleLines
        let strokes = Path { shape in
            for line in lines {
                shape.move(to: line.start)
                shape.addLine(to: line.end)
            }
        }
        let dots = Path { shape in
            for line in lines {
                for point in [line.start, line.end] {
                    shape.addEllipse(in: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10))
                }
            }
        }
        return ZStack {
            strokes.stroke(Color.black.opacity(0.45), style: StrokeStyle(lineWidth: 6, lineCap: .round))
            strokes.stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
            dots.fill(Color.white)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Dashed line from the pending point to the reticle, and the pending point's dot.
    @ViewBuilder
    private func pendingLine(center: CGPoint) -> some View {
        if let start = model.pendingScreen {
            let hasTarget = model.reticle != nil
            ZStack {
                if hasTarget {
                    Path { shape in
                        shape.move(to: start)
                        shape.addLine(to: center)
                    }
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [6, 6]))
                }
                Circle()
                    .fill(Color.white)
                    .frame(width: 10, height: 10)
                    .position(start)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// Value and accuracy at each distance's midpoint, read by VoiceOver as "Distance n, value, accuracy".
    private var segmentLabels: some View {
        ForEach(Array(model.segments.enumerated()), id: \.element.id) { pair in
            if let middle = model.screenPoints[pair.element.id]?.middle {
                LiveMeasureValueLabel(value: model.valueText(pair.element.value),
                                      accuracy: model.accuracyText(pair.element.value),
                                      lowConfidence: model.isLowConfidence(pair.element.value))
                    .position(middle)
                    .allowsHitTesting(false)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(model.accessibilityText(label: Copy.LiveMeasure.itemTitle(pair.offset + 1),
                                                                value: pair.element.value))
            }
        }
    }

    /// "Snapped to {target}" while the reticle sits on a detected plane, a plane corner or a point.
    @ViewBuilder
    private var snappedTag: some View {
        if let reticle = model.reticle, reticle.source != .estimatedPlane, let tag = reticle.tag {
            Text(Copy.Measure.snapped(to: tag.target))
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.black)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(reticle.isSnapped ? Color.yellow : Color.white.opacity(0.9)))
                .fixedSize()
                .allowsHitTesting(false)
        }
    }

    /// The pending point to the reticle, with its accuracy (spoken through the reticle).
    @ViewBuilder
    private var liveLabel: some View {
        if let value = model.liveValue {
            LiveMeasureValueLabel(value: model.valueText(value), accuracy: model.accuracyText(value),
                                  lowConfidence: model.isLowConfidence(value))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// The center reticle: a ring and a dot, yellow and smaller while snapped, dimmed without a
/// surface. VoiceOver: "Measurement point", the live distance as its value, double tap adds a point.
struct LiveMeasureReticle: View {
    /// The Quick Measure model.
    @ObservedObject var model: LiveMeasureModel

    /// Ring, dot and the accessibility element.
    var body: some View {
        let snapped = model.reticle?.isSnapped == true
        let color = snapped ? Color.yellow : Color.white
        let side: CGFloat = snapped ? 34 : 44
        ZStack {
            Circle().stroke(Color.black.opacity(0.4), lineWidth: 5)
            Circle().stroke(color, lineWidth: 2.5)
            Circle().fill(color).frame(width: 7, height: 7)
        }
        .frame(width: side, height: side)
        .opacity(model.reticle == nil ? 0.45 : 1)
        .animation(.easeOut(duration: 0.12), value: snapped)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Copy.A11y.crosshair)
        .accessibilityHint(Copy.A11y.crosshairHint)
        .accessibilityValue(spokenLiveValue)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.addPoint() }
    }

    /// "Current distance, 3 feet 2 inches" while a point is pending, else empty.
    private var spokenLiveValue: String {
        guard let value = model.liveValue else { return "" }
        return Copy.LiveMeasure.a11yLive(MeasureSpoken.text(model.valueText(value)))
    }
}

/// A value with its accuracy line (red when low confidence) on a light rounded label.
struct LiveMeasureValueLabel: View {
    /// Formatted value (Units).
    let value: String
    /// Accuracy or low-confidence line (MeasureDisplay), nil for none.
    let accuracy: String?
    /// Colors the accuracy line as a warning.
    let lowConfidence: Bool

    /// The label.
    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.headline.monospacedDigit())
                .foregroundStyle(Color.black)
            if let accuracy {
                Text(accuracy)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(lowConfidence ? Color.red : Color.black.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: 240)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.92)))
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The measurement list: "Distance n" with value and accuracy, swipe to delete, the disclaimer.
struct LiveMeasureListSheet: View {
    /// The Quick Measure model.
    @ObservedObject var model: LiveMeasureModel
    /// Closes the sheet.
    @Environment(\.dismiss) private var dismiss

    /// The list in a navigation stack with Done.
    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Array(model.segments.enumerated()), id: \.element.id) { pair in
                        row(number: pair.offset + 1, segment: pair.element)
                    }
                    .onDelete { offsets in model.removeSegments(at: offsets) }
                } footer: {
                    Text(Copy.Measure.disclaimer)
                }
            }
            .navigationTitle(Copy.LiveMeasure.listTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(Copy.Scanning.done) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// One distance row.
    private func row(number: Int, segment: LiveMeasureSegment) -> some View {
        let title = Copy.LiveMeasure.itemTitle(number)
        let accuracy = model.accuracyText(segment.value)
        let low = model.isLowConfidence(segment.value)
        return HStack(alignment: .firstTextBaseline) {
            Text(title)
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 2) {
                Text(model.valueText(segment.value))
                    .font(.body.weight(.semibold).monospacedDigit())
                if let accuracy {
                    Text(accuracy)
                        .font(.caption)
                        .foregroundStyle(low ? Color.red : Color.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.accessibilityText(label: title, value: segment.value))
    }
}
