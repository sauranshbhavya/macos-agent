import Foundation

/// The cap on standing watchers, in one place because it is one decision.
///
/// **Watchers are free and capped** (founder decision 2026-08-31, recorded on SONNY-236 beside
/// SONNY-212's credit model). They draw nothing from the paid allowance, so "screen-control runs
/// left" stays the single number a user tracks; what stops the runaway case the founders were
/// worried about — ten watchers started, forgotten, polling for a week — is this, and nothing else.
/// So these five numbers are the whole of the containment, and the ticket's own sentence about
/// metering watcher checks is superseded by that decision rather than deleted.
///
/// **They are release-time inputs, like every other number in row 13**, which is why they are a
/// value rather than five scattered literals: setting them from measured use is one edit.
///
/// **Why a watcher can be free at all, since that is the load-bearing half.** Its check is
/// `PublicWebPageLoader.load` — a direct `URLSession` fetch of a public page, a robots.txt check,
/// and local readability extraction. No gateway request, no model call, no search provider. The
/// cost of a check is the user's own bandwidth and the watched site's politeness budget, and
/// `checkInterval` is set against the second of those rather than the first.
public struct StandingWatcherLimits: Equatable, Sendable {
    /// How many watchers may run at once.
    ///
    /// Five. A person can hold in their head what five standing watchers are for; the case this
    /// bounds is the one the founders named, where the count is large enough that the user has
    /// stopped knowing. Reaching it **refuses** the sixth rather than evicting the oldest — see
    /// `ResumableTaskStore.saveWatcher(_:)`, where the reasoning is that silently dropping
    /// something the user explicitly asked for is the worse of the two failures.
    public var maxActive: Int

    /// How long between one watcher's checks.
    ///
    /// Fifteen minutes. Chosen against the watched site rather than against Sonny: four requests an
    /// hour to one URL is inside any ordinary politeness budget, and over `maxLifetime` it is 672
    /// fetches of one page. Shorter buys very little — the things people watch for (a page edited,
    /// an invoice appearing) do not resolve in minutes — and multiplies the request count against
    /// somebody else's server.
    public var checkInterval: TimeInterval

    /// How long a watcher lives before it gives up and says so.
    ///
    /// Seven days. This is the number that makes the stopping condition part of the cap rather than
    /// a convenience: without it a watcher is exactly the background process the founders' decision
    /// describes, running against a page nobody remembers naming. A week is long enough for the
    /// cases the ticket names — a page that changes when someone gets round to it, an invoice that
    /// arrives on a billing cycle — and short enough that a forgotten watcher ends on its own.
    ///
    /// **Expiry notifies.** A watcher that dies quietly leaves the user believing it is still
    /// watching, which is worse than never having started it.
    public var maxLifetime: TimeInterval

    /// How many readings in a row may differ from each other before the page is called unwatchable.
    ///
    /// Four, which is an hour of churn at `checkInterval`. A page whose readable text differs on
    /// every fetch — a rotating quote, a served-through advertisement, a visible clock — can never
    /// produce the two consecutive identical readings a notification needs, so without this it would
    /// poll to `maxLifetime` and then report "nothing changed", which is false. Saying "I cannot
    /// watch this one" is the honest answer and it is available within the hour.
    public var maxUnstableReadings: Int

    /// How many consecutive failed fetches before the watcher stops and says the page is
    /// unreachable.
    ///
    /// Eight, two hours at `checkInterval`. A single failure is a transient — a flaky network, a
    /// rate limit, a deploy — and killing a week-long watcher for one of those would be absurd, so
    /// failures have to be tolerated. But they cannot be tolerated *forever*: a URL that 404s or
    /// that robots.txt has started disallowing will never change again as far as Sonny can see, and
    /// a watcher that quietly retries a dead page until its lifetime runs out ends by telling the
    /// user nothing changed. That sentence would be a lie about a page Sonny never read.
    public var maxConsecutiveFailures: Int

    /// The shipped values. `noProductionPathPassesStandingWatcherLimits` pins that nothing in
    /// `Sources/` constructs any others — the injectability below is for tests, the same way
    /// `ResumableTaskStore.idleExpiry` is, and is not a second way to change what ships.
    public static let standard = StandingWatcherLimits(
        maxActive: 5,
        checkInterval: 15 * 60,
        maxLifetime: 7 * 24 * 60 * 60,
        maxUnstableReadings: 4,
        maxConsecutiveFailures: 8
    )

    /// Every field floored, for the reason `ResumableTaskStore.init` gives for flooring its own two:
    /// a zero here is not a small limit, it is a broken watcher. A `maxActive` of 0 refuses every
    /// watcher including the first; a `checkInterval` of 0 turns the shared 30-second pulse into a
    /// fetch every 30 seconds against somebody else's server; a `maxLifetime` of 0 ends a watcher
    /// before its first check.
    public init(
        maxActive: Int,
        checkInterval: TimeInterval,
        maxLifetime: TimeInterval,
        maxUnstableReadings: Int,
        maxConsecutiveFailures: Int
    ) {
        self.maxActive = max(1, maxActive)
        self.checkInterval = max(1, checkInterval)
        self.maxLifetime = max(1, maxLifetime)
        self.maxUnstableReadings = max(1, maxUnstableReadings)
        self.maxConsecutiveFailures = max(1, maxConsecutiveFailures)
    }
}

/// One thing Sonny is waiting on: a public page, the reading it had when the watcher was created,
/// and enough state to tell a real change from a page that simply never looks the same twice.
///
/// **A watcher notifies and does nothing else** (founder decision 2026-08-31, SONNY-236). When its
/// condition is met it tells the user, and that is the whole of what it may do — it may not open,
/// write, send, file, delete or run anything. Acting on a pre-approval given when the watcher was
/// created is the better product and was declined for v1, because the consequence rule cannot
/// express "approved earlier, for later" and this ticket's constraints forbid changing that rule to
/// fit. **So there is deliberately no route to acting here, switched off or otherwise** — no
/// operation to dispatch, no plan, no executor reference. An unreachable capability in the tree is
/// a thing a later session finds and turns on.
///
/// **This is not a `ResumableTask`, and it shares that type's store rather than its shape.** Both
/// live in `resumable-tasks.json`, which is the thirteenth local store and stays the thirteenth
/// (SONNY-210 built it; SONNY-235 and this ticket extend it, and neither adds a fourteenth). What
/// they do not share is a record: an unfinished task is a plan with steps left to run, and under the
/// notify-only decision a watcher has no plan at all. Putting a waking condition *on* `ResumableTask`
/// — which that type's own comment anticipated on 2026-08-22, before the decision — would produce
/// records for which `isResumable` is false, `mayBeOfferedForResume` is meaningless and the Memory
/// row's "unfinished task" count is wrong, and would leave roughly fifteen surfaces each needing a
/// filter nobody can see is missing.
///
/// **A stopped watcher is deleted rather than kept.** Its four ends — the page changed, the lifetime
/// ran out, the page proved unwatchable, the page proved unreachable — all reach the user as a
/// notification, and the user cancelling is the fifth. Keeping stopped records would mean a second
/// lifecycle, a second surface to list them on, and a count that no longer means "watchers running",
/// which is the number `StandingWatcherLimits.maxActive` is about.
public struct StandingWatcher: Codable, Equatable, Sendable, Identifiable {
    /// The longest `subject` this keeps, in characters. Display-only text, so trimming it is safe.
    public static let maxSubjectCharacters = 200

    public var id: String

    /// What the user is watching for, in their words — the phrase the notification names back to
    /// them, and the label the Routines page lists. A label and nothing more: nothing re-plans from
    /// it and nothing compares it.
    public var subject: String

    /// The page being watched. Already through `SafeURL.validateWebURL` when the record is made, and
    /// validated again by `PublicWebPageLoader.load` on every check — a stored URL is not trusted
    /// input just because Sonny wrote it.
    public var url: URL

    public var createdAt: Date

    /// When this watcher last completed a check, or `nil` before its first. Drives due-ness against
    /// `StandingWatcherLimits.checkInterval`, and a `nil` is due immediately.
    ///
    /// Written on a failed check too, deliberately: a page that is refusing connections must not be
    /// retried on every 30-second pulse.
    public var lastCheckedAt: Date?

    /// The reading this watcher is comparing against — the page as it was when the user asked.
    public var baselineDigest: String

    /// A reading that differs from the baseline and has been seen exactly once.
    ///
    /// **The whole of the ad-slot answer.** A first difference is never a notification; it becomes
    /// this, and only a second consecutive reading equal to it promotes it. A rotating advertisement,
    /// a served-through clock or a shuffled "related articles" strip differs from the baseline on
    /// every fetch *and differs from itself*, so it never produces the pair. A real edit does, at the
    /// next check. The cost is stated rather than hidden: notification is one `checkInterval` later
    /// than the change.
    public var candidateDigest: String?

    /// How many readings in a row have differed from the baseline and from each other. Reset by any
    /// reading equal to the baseline, and by a promotion.
    public var unstableReadings: Int

    /// How many checks in a row have failed to read the page at all. Reset by any successful read.
    public var consecutiveFailures: Int

    public init(
        id: String = UUID().uuidString,
        subject: String,
        url: URL,
        createdAt: Date,
        lastCheckedAt: Date? = nil,
        baselineDigest: String,
        candidateDigest: String? = nil,
        unstableReadings: Int = 0,
        consecutiveFailures: Int = 0
    ) {
        self.id = id
        self.subject = Self.cappedSubject(subject)
        self.url = url
        self.createdAt = createdAt
        self.lastCheckedAt = lastCheckedAt
        self.baselineDigest = baselineDigest
        self.candidateDigest = candidateDigest
        // Floored at zero rather than trusted: a decoded record obeys the same rule a written one
        // does, and a negative count read off a hand-edited file would put the unwatchable and
        // unreachable stops permanently out of reach.
        self.unstableReadings = max(0, unstableReadings)
        self.consecutiveFailures = max(0, consecutiveFailures)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case subject
        case url
        case createdAt
        case lastCheckedAt
        case baselineDigest
        case candidateDigest
        case unstableReadings
        case consecutiveFailures
    }

    /// Written out rather than synthesized so a decoded record runs through the same subject cap and
    /// the same count floors a written one does. `ResumableTask` states the reason this shape exists:
    /// a rule the decode path skips is a rule that holds in one direction only.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            subject: try container.decode(String.self, forKey: .subject),
            url: try container.decode(URL.self, forKey: .url),
            createdAt: try container.decode(Date.self, forKey: .createdAt),
            lastCheckedAt: try container.decodeIfPresent(Date.self, forKey: .lastCheckedAt),
            baselineDigest: try container.decode(String.self, forKey: .baselineDigest),
            candidateDigest: try container.decodeIfPresent(String.self, forKey: .candidateDigest),
            unstableReadings: try container.decode(Int.self, forKey: .unstableReadings),
            consecutiveFailures: try container.decode(Int.self, forKey: .consecutiveFailures)
        )
    }

    /// When this watcher's lifetime runs out, whatever else happens to it.
    public func expiresAt(limits: StandingWatcherLimits = .standard) -> Date {
        createdAt.addingTimeInterval(limits.maxLifetime)
    }

    private static func cappedSubject(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxSubjectCharacters else {
            return trimmed
        }
        return String(trimmed.prefix(maxSubjectCharacters - 1)) + "\u{2026}"
    }
}
