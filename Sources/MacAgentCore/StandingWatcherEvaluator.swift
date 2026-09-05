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
    /// The state machine, written out because it is the feature. **Every branch compares against the
    /// reading before it, not against the baseline** (SONNY-390):
    ///
    /// - equal to the previous reading, and equal to the baseline — the page held still. The
    ///   instability count resets.
    /// - equal to the previous reading, and different from the baseline — the change held across two
    ///   consecutive readings. Stop and tell the user. This is the two-reading rule and it is
    ///   untouched: a real change is still notified on the second identical reading.
    /// - different from the previous reading — the page moved, and the instability count rises,
    ///   whichever direction it moved in. At `maxUnstableReadings` the page is declared unwatchable
    ///   rather than polled to the end of its lifetime.
    ///
    /// **A return to the baseline is a movement, and that is the whole of SONNY-390's change.** It
    /// used to reset the count, so a page alternating between its baseline and one other reading was
    /// never `.changed` — the two never land consecutively — and never `.unwatchable` either, because
    /// every return reset the counter. It polled for its whole seven days and told the user nothing.
    /// Counting the return makes it `.unwatchable` on the fourth check.
    ///
    /// **What forgives an ordinary page that wobbles, measured rather than assumed** (the corpus is
    /// on SONNY-390: 21 archetypes plus two randomized populations at 2000 seeded trials each, one
    /// watcher life of 672 checks apiece). The reset is on *any* pair of consecutive equal readings
    /// rather than on a confirmed change alone, which is the shape `consecutiveFailures` already has.
    /// The ticket's own proposal reset only on a confirmed pair, and that accumulates: a single
    /// one-check wobble costs two increments — one leaving the baseline and one returning — so it
    /// declared a page wobbling once a day unwatchable on check 193, and one wobbling once an hour on
    /// check 9. With this reset every wobble rate from hourly to fortnightly reads exactly as it did
    /// before the change.
    ///
    /// **Where it fails, since four consecutive differences is what it counts:** two one-off wobbles
    /// separated by exactly one stable reading — `w`, baseline, `w`, baseline — end the watcher,
    /// where the old rule carried it. That is 45 minutes of local alternation, and at check four it
    /// is indistinguishable from a page that will alternate all week, so any rule meeting the
    /// four-check requirement calls both unwatchable. Two *adjacent* wobbles are forgiven; two
    /// wobbles two or more stable readings apart are forgiven.
    ///
    /// The candidate is still what a difference is recorded in, so `candidateDigest ?? baselineDigest`
    /// is the previous reading and no new stored field was needed.
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

        // The reading this one is compared against. It needs no field of its own: a difference is
        // stored in the candidate and a baseline match clears it, so this expression names the last
        // reading seen, and every branch below leaves it naming this one.
        let previousReading = watcher.candidateDigest ?? watcher.baselineDigest

        if reading == previousReading {
            guard reading != watcher.baselineDigest else {
                updated.candidateDigest = nil
                updated.unstableReadings = 0
                return .unchanged(updated)
            }
            // Promoted. The baseline moves to the confirmed reading so the record the caller
            // notifies from describes the page as it now is, even though that record is about to be
            // deleted — a stopped watcher handed to a notifier should not still claim the old page.
            updated.baselineDigest = reading
            updated.candidateDigest = nil
            updated.unstableReadings = 0
            return .stopped(updated, .changed)
        }

        updated.unstableReadings = watcher.unstableReadings + 1
        let returnedToBaseline = reading == watcher.baselineDigest
        if returnedToBaseline {
            updated.candidateDigest = nil
        } else {
            updated.candidateDigest = reading
            // Set once and never cleared — `.expired`'s sentence reads it, and the counter beside it
            // is reset by any pair of equal readings (F4).
            if updated.firstDifferenceAt == nil {
                updated.firstDifferenceAt = now
            }
        }
        // The guard is reached from both directions on purpose. Were it on the difference branch
        // alone, an alternating page would spend its fourth increment on a baseline reading that
        // could not stop it, and the ticket's four checks would be five.
        guard updated.unstableReadings < limits.maxUnstableReadings else {
            return .stopped(updated, .unwatchable)
        }
        // A reading equal to the baseline still reads as the page the user asked about, so it is
        // `.unchanged` even though the count advanced. The single caller saves on both.
        return returnedToBaseline ? .unchanged(updated) : .pending(updated)
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
