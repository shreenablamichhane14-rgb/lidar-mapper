import SwiftUI
import UIKit

/// The scan quality sheet (SPEC SCAN QUALITY SYSTEM, D19, docs/MODULES.md 3.25): Shape, Walls,
/// Floor, Ceiling and Color and texture as percentages with bars, the missing area count, a
/// plain summary line, the degraded-mode and light notes, Finish or Finish Anyway, and Discard.
/// AppShell presents it over the live scan screen with `.presentationDetents([.medium, .large])`
/// and `.interactiveDismissDisabled()`; the sheet never presents itself.
///
/// A nil `evaluation` shows "Checking your scan...". If the check runs longer than
/// `QualityPresentation.checkingSlowAfterSeconds`, Finish Anyway and Discard appear under it so
/// the user is never stuck. `onDiscard` runs when Discard Scan is tapped; the caller asks for
/// the confirmation (docs/MODULES.md 3.29: AppShell's `onDiscard` confirms, then calls
/// `ScanFlowModel.discardScan`, which removes only the scan just captured, lead decision 4).
/// `onShowMissingAreas` nil hides Show Missing Areas (build 4; build 5 passes it only while the
/// room's session is still running); the button also stays hidden when nothing is missing.
///
/// Layout: the report scrolls and the buttons stay pinned on a bar at the bottom, so Finish is
/// always reachable at the medium detent. Dynamic Type: system text styles, rows stack their
/// title and value at accessibility sizes, and the two buttons stack when they do not fit side
/// by side. VoiceOver: each row reads "Walls, 94 percent", the missing row "Missing areas, 3",
/// and the summary is announced when the result arrives. Dark mode: semantic colors only, and
/// every tint also has its own symbol so color is never the only signal.
struct QualitySheet: View {
    /// The evaluation to show; nil while the check at Done is running.
    private let evaluation: QualityEvaluation?
    /// Finish or Finish Anyway.
    private let onFinish: () -> Void
    /// Discard Scan tapped; the caller confirms, then discards.
    private let onDiscard: () -> Void
    /// Show Missing Areas (build 5); nil hides the button.
    private let onShowMissingAreas: (() -> Void)?

    /// True once the check has run longer than `QualityPresentation.checkingSlowAfterSeconds`.
    @State private var checkingIsSlow = false
    /// When the last button action ran, to ignore an accidental double tap.
    @State private var lastActionAt: Date? = nil

    /// Creates the sheet. See the type comment for what each closure means.
    init(evaluation: QualityEvaluation?, onFinish: @escaping () -> Void, onDiscard: @escaping () -> Void,
         onShowMissingAreas: (() -> Void)? = nil) {
        self.evaluation = evaluation
        self.onFinish = onFinish
        self.onDiscard = onDiscard
        self.onShowMissingAreas = onShowMissingAreas
    }

    /// The title, the report (or the checking state), and the pinned action bar.
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(Copy.Quality.title)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.primary)
                    .accessibilityAddTraits(.isHeader)
                if let evaluation = evaluation {
                    QualityReportContent(evaluation: evaluation)
                } else {
                    checkingView
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if showsActions {
                actionBar
            }
        }
        .presentationDragIndicator(.visible)
        .task(id: evaluation == nil) {
            await watchCheckingTime()
        }
        .onAppear {
            logShown()
        }
        .onChange(of: evaluation) { oldValue, newValue in
            evaluationChanged(from: oldValue, to: newValue)
        }
    }

    // MARK: Checking state

    /// Spinner and "Checking your scan...", plus the slow-check line once it applies.
    private var checkingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text(Copy.Quality.checking)
                .font(.headline)
                .multilineTextAlignment(.center)
            if checkingIsSlow {
                Text(Copy.Quality.checkingSlow)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(checkingAccessibility))
    }

    /// VoiceOver label of the checking state: the checking line, plus the slow line once shown.
    private var checkingAccessibility: String {
        guard checkingIsSlow else { return Copy.Quality.checking }
        return Copy.Quality.checking + " " + Copy.Quality.checkingSlow
    }

    /// True when the action bar shows: always with a result, and after the slow delay without one.
    private var showsActions: Bool {
        evaluation != nil || checkingIsSlow
    }

    // MARK: Actions

    /// Show Missing Areas (when offered), then Discard and Finish side by side, or stacked with
    /// Finish on top when they do not fit (large text).
    private var actionBar: some View {
        VStack(spacing: 10) {
            if QualityPresentation.showsMissingAreasButton(evaluation: evaluation,
                                                           actionAvailable: onShowMissingAreas != nil) {
                Button {
                    showMissingAreasTapped()
                } label: {
                    Text(Copy.Quality.showMissingAreas)
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    discardButton
                    finishButton
                }
                VStack(spacing: 10) {
                    finishButton
                    discardButton
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    /// Finish or Finish Anyway, the prominent button.
    private var finishButton: some View {
        Button {
            finishTapped()
        } label: {
            Text(QualityPresentation.finishTitle(for: evaluation))
                .font(.headline)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    /// Discard Scan (the caller asks for the confirmation).
    private var discardButton: some View {
        Button(role: .destructive) {
            discardTapped()
        } label: {
            Text(Copy.Scanning.cancelConfirmDiscard)
                .font(.headline)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    /// Runs Finish or Finish Anyway.
    private func finishTapped() {
        guard acceptAction() else { return }
        let title = QualityPresentation.finishTitle(for: evaluation)
        if let evaluation = evaluation {
            log("\(title) tapped, \(QualityPresentation.logLine(evaluation))")
        } else {
            log("\(title) tapped before the check finished")
        }
        onFinish()
    }

    /// Runs Discard Scan; the caller confirms before anything is deleted.
    private func discardTapped() {
        guard acceptAction() else { return }
        log("discard tapped")
        onDiscard()
    }

    /// Starts the build 5 missing-areas tour.
    private func showMissingAreasTapped() {
        guard acceptAction(), let action = onShowMissingAreas else { return }
        let count = evaluation.map { QualityPresentation.missingCount($0) } ?? 0
        log("show missing areas tapped, \(count) areas")
        action()
    }

    /// False when another action ran less than a second ago (a double tap on Finish must not
    /// call `onFinish` twice); otherwise records this action and returns true.
    private func acceptAction() -> Bool {
        let now = Date()
        if let last = lastActionAt, now.timeIntervalSince(last) < 1 {
            return false
        }
        lastActionAt = now
        return true
    }

    // MARK: Checking timer, announcements and log

    /// While there is no result, waits `checkingSlowAfterSeconds` and then offers Finish Anyway
    /// and Discard. The task restarts (and this wait is cancelled) when the result arrives.
    private func watchCheckingTime() async {
        guard evaluation == nil else { return }
        checkingIsSlow = false
        let nanoseconds = UInt64(QualityPresentation.checkingSlowAfterSeconds * 1_000_000_000)
        do {
            try await Task.sleep(nanoseconds: nanoseconds)
        } catch {
            return
        }
        guard !Task.isCancelled, evaluation == nil else { return }
        checkingIsSlow = true
        log("check still running after \(Int(QualityPresentation.checkingSlowAfterSeconds)) s; Finish Anyway and Discard offered")
    }

    /// Logs a new or changed result and announces its summary to VoiceOver.
    private func evaluationChanged(from oldValue: QualityEvaluation?, to newValue: QualityEvaluation?) {
        guard let newValue = newValue else {
            log("checking again")
            return
        }
        log("result, \(QualityPresentation.logLine(newValue))")
        if oldValue?.summary != newValue.summary {
            UIAccessibility.post(notification: .announcement, argument: QualityPresentation.summaryText(for: newValue))
        }
    }

    /// Logs what the sheet shows when it appears (TEST_PLAN QUAL-01: the same numbers in the log).
    private func logShown() {
        if let evaluation = evaluation {
            log("shown, \(QualityPresentation.logLine(evaluation))")
        } else {
            log("shown, checking")
        }
    }

    /// Writes one line to the app log under the Quality category.
    private func log(_ message: String) {
        LogStore.shared.write("sheet: " + message, category: QualityEvaluator.logCategory)
    }
}
