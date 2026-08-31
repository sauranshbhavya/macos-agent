import CryptoKit
import Foundation

/// Why a watcher stopped. Every case reaches the user as a sentence; four of them are things Sonny
/// decided and the fifth is the user's own press.
public enum StandingWatcherStopReason: Equatable, Sendable {
    /// The page changed, and the change held across two consecutive readings. What the watcher was
    /// created to say.
    case changed
    /// `StandingWatcherLimits.maxLifetime` ran out with no confirmed change.
    ///
    /// **This notifies like the others.** Silence at the end of a week reads as "still watching",
    /// which is exactly the forgotten background process the cap exists to prevent.
    case expired
    /// The page's readable text differed on every reading, so no change could ever be confirmed.
    case unwatchable
    /// The page could not be read at all, `maxConsecutiveFailures` times in a row.
    case unreachable
    /// The user stopped it. Carried for completeness of the enum rather than produced by the
    /// evaluator — nothing here decides it, and the surface that does deletes the record directly.
    case cancelled
}

/// What one check concluded. Each case carries what the caller must do next, and nothing else — the
/// evaluator neither writes nor notifies.
public enum StandingWatcherDecision: Equatable, Sendable {
    /// Not due yet. The record is untouched; the caller does nothing, and in particular does not
    /// fetch. Returned before any observation is attempted, so a watcher that is not due costs no
    /// request.
    case notDue
    /// The check happened and the page still reads as it did. Save the carried record.
    case unchanged(StandingWatcher)
    /// Something moved, or a fetch failed, and neither is yet enough to conclude anything. Save the
    /// carried record — its candidate or failure count has advanced.
    case pending(StandingWatcher)
    /// The watcher is finished. Tell the user, then delete the record.
    case stopped(StandingWatcher, StandingWatcherStopReason)
}

/// The digest a watcher compares, and the pure state machine one check runs.
///
/// **Everything here is a function of its arguments.** No clock, no network, no store — the whole
/// awkward part of this feature (what counts as a change, when to give up, when to fire) is decided
/// by code a test can call directly, in the shape `RoutineScheduler` already uses for schedule
/// arithmetic. The observation and the writing live one level out, in the caller.
public enum StandingWatcherEvaluator {
    /// The reading a watcher compares, from a page's readable text.
    ///
    /// **Whitespace-collapsed, not lower-cased.** Collapsing runs of whitespace absorbs the
    /// reflowing an extractor does on markup that has not meaningfully changed; lower-casing would
    /// hide a real edit — a heading recapitalised, a status flipped from "Pending" to "PENDING" — and
    /// this is the one place in the feature where hiding a difference is the expensive direction.
    ///
    /// SHA-256 rather than the text itself, for two reasons that both matter: the record stays a
    /// fixed small size whatever page it watches, and `resumable-tasks.json` does not accumulate the
    /// readable text of every page the user has ever watched. The store is encrypted either way; not
    /// storing the content at all is better than storing it well.
    public static func digest(of readableText: String) -> String {
        let collapsed = readableText
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        let hash = SHA256.hash(data: Data(collapsed.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    /// Whether this watcher is due for a check.
    ///
    /// A watcher that has never been checked is due immediately, so the record written at creation
    /// gets its first comparison on the next pulse rather than a `checkInterval` later.
    public static func isDue(
        _ watcher: StandingWatcher,
        now: Date,
        limits: StandingWatcherLimits = .standard
    ) -> Bool {
        guard let lastCheckedAt = watcher.lastCheckedAt else {
            return true
        }
        return now.timeIntervalSince(lastCheckedAt) >= limits.checkInterval
    }

    /// Whether this watcher's lifetime has run out.
    ///
    /// Checked by `decide` **before** due-ness and before any fetch, so an expired watcher is
    /// retired on the next pulse rather than at its next check — which for a watcher that expires
    /// three minutes after a check would otherwise be fifteen minutes of a lifetime that had already
    /// ended.
    public static func hasExpired(
        _ watcher: StandingWatcher,
        now: Date,
        limits: StandingWatcherLimits = .standard
    ) -> Bool {
        now >= watcher.expiresAt(limits: limits)
    }

    /// What to do about this watcher before anything is fetched.
    ///
    /// Split from `apply(reading:)` on purpose: this is the half that must run without a network
    /// request, so that an expired or not-yet-due watcher costs nothing. A caller that fetched first
    /// and asked afterwards would spend a request on every watcher on every pulse.
    public static func decideBeforeObserving(
        _ watcher: StandingWatcher,
        now: Date,
        limits: StandingWatcherLimits = .standard
    ) -> StandingWatcherDecision {
        if hasExpired(watcher, now: now, limits: limits) {
            return .stopped(watcher, .expired)
        }
        guard isDue(watcher, now: now, limits: limits) else {
            return .notDue
        }
        return .pending(watcher)
    }

    /// What one successful reading means.
    ///
    /// The state machine, written out because it is the feature:
    ///
    /// - equal to the baseline — nothing has happened. Any candidate is dropped and the instability
    ///   count resets, because a page that has come back to its baseline was churning rather than
    ///   changing.
    /// - different, with no candidate — the first sighting. Recorded, **not** notified.
    /// - different, and equal to the candidate — the change held across two consecutive readings.
    ///   Stop and tell the user.
    /// - different, and different from the candidate — the page does not look the same twice. The new
    ///   reading becomes the candidate and the instability count rises; at `maxUnstableReadings` the
    ///   page is declared unwatchable rather than polled to the end of its lifetime and then reported
    ///   as unchanged.
    public static func apply(
        reading: String,
        to watcher: StandingWatcher,
        now: Date,
        limits: StandingWatcherLimits = .standard
    ) -> StandingWatcherDecision {
        var updated = watcher
        updated.lastCheckedAt = now
        // A reading arrived, so whatever the last few checks did, the page is reachable.
        updated.consecutiveFailures = 0

        guard reading != watcher.baselineDigest else {
            updated.candidateDigest = nil
            updated.unstableReadings = 0
            return .unchanged(updated)
        }

        if reading == watcher.candidateDigest {
            // Promoted. The baseline moves to the confirmed reading so the record the caller
            // notifies from describes the page as it now is, even though that record is about to be
            // deleted — a stopped watcher handed to a notifier should not still claim the old page.
            updated.baselineDigest = reading
            updated.candidateDigest = nil
            updated.unstableReadings = 0
            return .stopped(updated, .changed)
        }

        updated.candidateDigest = reading
        // Set once and never cleared — `.expired`'s sentence reads it, and every other record of a
        // difference on this type is reset by a reading equal to the baseline (F4).
        if updated.firstDifferenceAt == nil {
            updated.firstDifferenceAt = now
        }
        updated.unstableReadings = watcher.unstableReadings + 1
        guard updated.unstableReadings < limits.maxUnstableReadings else {
            return .stopped(updated, .unwatchable)
        }
        return .pending(updated)
    }

    /// What one failed reading means.
    ///
    /// Failures are tolerated and then are not. A single one is a transient — a flaky network, a
    /// rate limit, a deploy — and ending a week-long watcher on one would be absurd. But a URL that
    /// has started 404ing, or that robots.txt now disallows, will never read again, and a watcher
    /// that retried it silently to the end of its lifetime would finish by telling the user nothing
    /// had changed on a page it never once read.
    ///
    /// `lastCheckedAt` advances on a failure exactly as it does on a success, so a refusing page is
    /// retried at `checkInterval` rather than on every 30-second pulse.
    public static func applyFailure(
        to watcher: StandingWatcher,
        now: Date,
        limits: StandingWatcherLimits = .standard
    ) -> StandingWatcherDecision {
        var updated = watcher
        updated.lastCheckedAt = now
        updated.consecutiveFailures = watcher.consecutiveFailures + 1
        guard updated.consecutiveFailures < limits.maxConsecutiveFailures else {
            return .stopped(updated, .unreachable)
        }
        return .pending(updated)
    }
}
