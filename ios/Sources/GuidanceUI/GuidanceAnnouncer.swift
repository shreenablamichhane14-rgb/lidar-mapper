import Foundation
import UIKit
import Combine

// VoiceOver announcements and warning haptics for live guidance (UX_COPY section 4, display
// rules 10 and 11): every newly shown message is announced, tier 1 with a high-priority
// announcement; tier 1 messages fire one warning haptic when they first appear, at most once
// every `GuidancePolicy.hapticCooldownSeconds`, and only while the user's "Vibrate for warnings"
// setting (`SettingsKey.guidanceHaptics`) is on. This is the only place that posts guidance
// announcements and guidance haptics. The decisions live in the pure `GuidanceAnnouncerState`
// so the self-test checks them off the main actor without buzzing the phone.

extension SettingsKey {
    /// Bool, absent means on. "Vibrate for warnings" in Settings (AppShell writes it).
    static let guidanceHaptics = "guidanceHaptics"
}

/// Pure decision state behind `GuidanceAnnouncer`: remembers the kind on screen and the time
/// of the last haptic, and says what to do when a kind is presented. No clock, no side effects,
/// safe on any queue.
struct GuidanceAnnouncerState: Equatable, Sendable {
    /// What `present` should do for one call.
    struct Decision: Equatable, Sendable {
        /// The newly shown kind to announce, nil when nothing new appeared.
        var announce: GuidanceKind?
        /// True when the announcement uses high priority (tier 1).
        var highPriority: Bool
        /// True when a warning haptic should fire now.
        var fireHaptic: Bool

        /// Nothing to announce and no haptic.
        static let quiet = Decision(announce: nil, highPriority: false, fireHaptic: false)
    }

    /// The kind currently on screen (the last one presented), nil when the banner is hidden.
    private(set) var shown: GuidanceKind?
    /// Caller time of the last haptic that fired, nil before the first.
    private(set) var lastHaptic: Double?

    /// Creates a state with nothing shown and no haptic history.
    init() {}

    /// Records that `kind` is on screen at `now` (caller seconds, monotonic) and returns what to
    /// announce and whether to fire the haptic. Presenting the kind already on screen does
    /// nothing; presenting nil hides it, so the same kind shown again later is new again.
    mutating func present(_ kind: GuidanceKind?, now: Double, hapticsEnabled: Bool) -> Decision {
        guard kind != shown else { return .quiet }
        shown = kind
        guard let kind else { return .quiet }
        let haptic = GuidanceAnnouncerState.shouldFireHaptic(kind: kind, now: now,
                                                             lastHaptic: lastHaptic, enabled: hapticsEnabled)
        if haptic { lastHaptic = now }
        return Decision(announce: kind, highPriority: kind.message.tier == 1, fireHaptic: haptic)
    }

    /// Forgets the shown kind and the haptic history (a new scan).
    mutating func reset() {
        self = GuidanceAnnouncerState()
    }

    /// True when a newly shown `kind` should fire the warning haptic at `now`: the setting is on,
    /// the kind is tier 1, and no haptic fired in the last `GuidancePolicy.hapticCooldownSeconds`.
    /// Time running backwards (a new timeline) clears the cooldown; a non-finite time never fires.
    static func shouldFireHaptic(kind: GuidanceKind, now: Double, lastHaptic: Double?, enabled: Bool) -> Bool {
        guard enabled, now.isFinite, kind.message.tier == 1 else { return false }
        guard let last = lastHaptic, last.isFinite else { return true }
        let elapsed = now - last
        if elapsed < 0 { return true }
        return elapsed >= GuidancePolicy.hapticCooldownSeconds
    }
}

/// Main actor. Announces each newly shown message (tier 1 with high priority) and fires
/// `Haptics.warning()` for newly shown tier 1 messages at most every GuidancePolicy.hapticCooldownSeconds,
/// only when the setting is on.
///
/// Feed it the filtered message on every tick (`present(snapshot.guidance, now: snapshot.timestamp)`
/// or any monotonic seconds); repeated calls with the same kind do nothing. `current` mirrors
/// the kind on screen for views that want to observe it (for example `GuidanceBanner(kind:)`).
@MainActor final class GuidanceAnnouncer: ObservableObject {
    /// The kind on screen, nil when the banner is hidden. Published only when it changes.
    @Published private(set) var current: GuidanceKind?

    /// Settings store read for `SettingsKey.guidanceHaptics` on every new tier 1 message, so a
    /// change in Settings applies to the running scan.
    private let defaults: UserDefaults
    /// Pure decision state.
    private var state = GuidanceAnnouncerState()

    /// Creates an announcer reading the haptics setting from `defaults`.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// True unless the user turned "Vibrate for warnings" off (absent means on).
    var hapticsEnabled: Bool {
        defaults.object(forKey: SettingsKey.guidanceHaptics) as? Bool ?? true
    }

    /// Shows `kind` (nil hides it) at caller time `now` in seconds: posts the VoiceOver
    /// announcement and the warning haptic when the kind is newly shown.
    func present(_ kind: GuidanceKind?, now: Double) {
        guard kind != state.shown else { return }
        // Read the setting only when a tier 1 message could fire a haptic.
        let isTier1 = kind?.message.tier == 1
        let decision = state.present(kind, now: now, hapticsEnabled: isTier1 && hapticsEnabled)
        if current != kind { current = kind }
        guard let shown = decision.announce else { return }
        announce(shown, highPriority: decision.highPriority)
        if decision.fireHaptic { Haptics.warning() }
        LogStore.shared.write("shown \(shown.rawValue) tier \(shown.message.tier) haptic \(decision.fireHaptic)",
                              category: "guidance")
    }

    /// Hides the banner and forgets the haptic history (call when a scan starts or ends).
    func reset() {
        state.reset()
        if current != nil { current = nil }
    }

    /// Pure decision used by `present` and the self-test.
    /// Nonisolated so the self-test can call it off the main actor.
    nonisolated static func shouldFireHaptic(kind: GuidanceKind, now: Double, lastHaptic: Double?, enabled: Bool) -> Bool {
        GuidanceAnnouncerState.shouldFireHaptic(kind: kind, now: now, lastHaptic: lastHaptic, enabled: enabled)
    }

    // MARK: VoiceOver

    /// Posts the message text as a VoiceOver announcement; tier 1 uses high priority
    /// (`accessibilitySpeechAnnouncementPriority`, iOS 17.0) so it is spoken before queued speech.
    private func announce(_ kind: GuidanceKind, highPriority: Bool) {
        let text = kind.message.text
        if highPriority {
            let attributed = NSAttributedString(
                string: text,
                attributes: [.accessibilitySpeechAnnouncementPriority: UIAccessibilityPriority.high]
            )
            UIAccessibility.post(notification: .announcement, argument: attributed)
        } else {
            UIAccessibility.post(notification: .announcement, argument: text)
        }
    }
}
