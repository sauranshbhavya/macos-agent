import Foundation

/// How a standing watcher reads the page it is watching.
///
/// **A seam, and the reason it exists is that nothing else in this repository has one.**
/// `AgentActionExecutor` builds its own `PublicWebPageLoader` internally and defaults it to
/// `.live()`, so no fixture controls it — which is fine for an executor a test drives deliberately
/// and is not fine for something a 30-second timer calls. A watcher check runs from a pulse nobody
/// asked for, so a fixture that never heard of watchers must not be one network request away from
/// the real internet.
///
/// **`@MainActor` because `PublicWebPageLoader.load` is.** That isolation is the loader's own
/// (`SafeURL` validation, the robots check and the fetch all run there), and re-declaring the
/// protocol as non-isolated would only move the hop somewhere less obvious.
@MainActor
public protocol StandingWatcherObserving {
    /// The readable text of the page at `url`, or a throw.
    ///
    /// **Readable text rather than a digest**, so the comparison rule lives in exactly one place:
    /// `StandingWatcherEvaluator.digest(of:)`. An observer that returned a digest would be a second
    /// home for the decision about what counts as a change, and the two would drift.
    func readableText(at url: URL) async throws -> String
}

/// The shipped observer: a direct public-page fetch, the same one row 12's research capability uses.
///
/// **This is the whole reason a watcher can be free** (founder decision 2026-08-31). It goes through
/// `PublicWebPageLoader`, which validates the URL, honours `robots.txt`, refuses a redirect onto a
/// host whose robots were never consulted, and extracts readable text locally with SwiftSoup. No
/// gateway request, no model call, no search provider — so a check costs the user bandwidth and
/// nothing else, and the cap in `StandingWatcherLimits` is set against the watched site's politeness
/// budget rather than against a bill.
///
/// **Nothing here caches.** `PublicWebPageLoader.live()`'s session is `.ephemeral` with cookies
/// refused, which for a watcher is a requirement rather than a default: a cached response would make
/// every check after the first return the reading that produced the baseline, so the watcher would
/// wait out its whole lifetime and then report that nothing had changed.
@MainActor
public struct LiveStandingWatcherObserver: StandingWatcherObserving {
    private let loader: PublicWebPageLoader

    public init(loader: PublicWebPageLoader? = nil) {
        self.loader = loader ?? PublicWebPageLoader.live()
    }

    public func readableText(at url: URL) async throws -> String {
        try await loader.load(rawURL: url.absoluteString).readableText
    }
}

/// What Sonny says when a watcher has something to report.
///
/// **In `MacAgentCore` rather than beside the notification service, and each sentence is a value a
/// test can assert.** These reach the user through a system banner and through Command Center, and
/// a banner is the one surface no agent can verify fires — so the wording had better be checkable
/// where it is decided, since the only other proof available is a founder reading a notification.
///
/// **Every ending gets a sentence, including the ones that are not news.** A watcher that expires or
/// gives up in silence leaves the user believing Sonny is still watching, which is the forgotten
/// background process the cap exists to prevent — so "I have stopped, and here is why" is owed even
/// when the answer is that nothing happened.
public enum StandingWatcherNoticeCopy {
    /// Takes the whole record rather than its subject, because `.expired`'s sentence depends on
    /// something only the record knows: whether this watcher ever read anything other than its
    /// baseline (founder decision on F4, PR #184).
    public static func message(
        for reason: StandingWatcherStopReason,
        watcher: StandingWatcher,
        limits: StandingWatcherLimits = .standard
    ) -> String {
        let subject = watcher.subject
        switch reason {
        case .changed:
            // The only one of the five that is the thing the user asked for. It says what changed
            // and nothing else — there is no action to offer, because a watcher notifies and does
            // nothing else, and a button here would be the route to acting the founders declined.
            return "“\(subject)” changed."
        case .expired:
            // **"It did not change" is asserted only when nothing ever differed** (founder decision
            // on F4). A page alternating between its baseline and one other reading is never
            // `.changed` — the two never land consecutively — and never `.unwatchable`, because any
            // return to the baseline resets the instability count; so it runs its whole life and
            // used to end by asserting the one thing that was certainly false about it. "Nothing
            // settled" is true of that page and of a page that flickered once and steadied, and it
            // does not claim to know which.
            guard watcher.firstDifferenceAt == nil else {
                return "Sonny stopped watching “\(subject)” after \(dayCount(limits.maxLifetime)). Nothing settled."
            }
            return "Sonny stopped watching “\(subject)” after \(dayCount(limits.maxLifetime)). It did not change."
        case .unwatchable:
            // Says which of the two silences this is. "It did not change" would be false — the page
            // changed constantly, which is precisely why nothing could be reported.
            return "Sonny stopped watching “\(subject)”. That page reads differently every time it is checked, so there is no change to report."
        case .unreachable:
            return "Sonny stopped watching “\(subject)”. The page could not be read."
        case .cancelled:
            // Reachable only if a caller asks for it. The user pressed Stop, so they know; the
            // sentence exists so the enum has no silent arm rather than because anything posts it.
            return "Sonny is no longer watching “\(subject)”."
        }
    }

    /// "7 days", "1 day" — derived from the cap rather than written into the sentence, so changing
    /// `maxLifetime` cannot leave the notification quoting the old number.
    static func dayCount(_ lifetime: TimeInterval) -> String {
        let days = max(1, Int((lifetime / 86_400).rounded()))
        return days == 1 ? "1 day" : "\(days) days"
    }
}
