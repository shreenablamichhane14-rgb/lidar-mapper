import Foundation
import UIKit

/// The only writer of `UIApplication.shared.isIdleTimerDisabled` in the app: the idle timer is
/// disabled while at least one holder exists (a visible scan screen, a running job). Main actor.
/// Holders take a token with `acquire` and give it back with `release`, so a job ending during
/// a scan, or a scan screen closing during processing, never re-enables auto-lock under the
/// other holder.
@MainActor enum IdleTimerGuard {
    /// Current holders: token to reason (for the log).
    private static var holders: [UUID: String] = [:]

    /// Adds a holder and disables the idle timer. Returns the token to release.
    static func acquire(_ reason: String) -> UUID {
        let token = UUID()
        holders[token] = reason
        LogStore.shared.write("idle timer hold: \(reason) (\(holders.count) holders)", category: "pipeline")
        apply()
        return token
    }

    /// Removes a holder; the idle timer is enabled again when none is left. An unknown or
    /// already released token is ignored.
    static func release(_ token: UUID) {
        guard let reason = holders.removeValue(forKey: token) else { return }
        LogStore.shared.write("idle timer release: \(reason) (\(holders.count) holders)", category: "pipeline")
        apply()
    }

    /// Number of holders now.
    static var holderCount: Int { holders.count }

    /// Pure rule used by the self-test: disabled when the holder set is not empty.
    nonisolated static func shouldDisable(holders: Int) -> Bool {
        holders > 0
    }

    /// Writes the flag when it differs from the rule.
    private static func apply() {
        let disable = shouldDisable(holders: holders.count)
        if UIApplication.shared.isIdleTimerDisabled != disable {
            UIApplication.shared.isIdleTimerDisabled = disable
        }
    }
}
