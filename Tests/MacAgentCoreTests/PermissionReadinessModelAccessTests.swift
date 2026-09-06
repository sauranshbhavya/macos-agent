import Foundation
import MacAgentTestSupport
import Testing
@testable import MacAgentCore

/// The readiness row that replaced "OpenAI" (SONNY-136, PR #139's F10).
///
/// **What it replaced, and why a rewording would not have done.** The old row asked whether
/// `OPENAI_API_KEY` was set and reported `.ready` or `.needsAction` on the answer. Both of its
/// sentences were wrong the moment SONNY-130 moved planning, transcription, search and screen
/// control behind Sonny's own gateway: nothing reads that variable, so someone who had never
/// exported it — everyone launching the packaged app from Finder, which inherits no shell
/// environment — was told to go and set something that changes nothing, and someone who had one was
/// shown a green row for a credential that does nothing. The second is the worse of the two: it
/// reports readiness that is not readiness, which is the failure a readiness page exists to prevent.
///
/// **Three states rather than two, and `undetermined` is the one that carries the rule.** The old
/// row could not be uncertain because reading an environment variable cannot fail. Reading the
/// session can — the answer lives behind an actor, and the bytes in the Keychain may be ones this
/// build cannot decode — and a check that could not be completed is not a check that passed. So the
/// third state exists and it is never `.ready`.
@Suite
struct PermissionReadinessModelAccessTests {
    /// The provider names and the variable shape this file refuses, kept identical to
    /// `SonnyBackendCopyTests`' — two copies of one rule rather than one, because the two suites are
    /// in the same target but the sentences they cover come from different types and neither owns
    /// the other's. They are asserted to agree by being written the same way and by the
    /// cross-reference in that file, which PR #153's F8 made true rather than aspirational.
    static let providerNames = ["OpenAI", "Cerebras", "Tavily", "OpenCode", "Anthropic", "GPT", "Whisper"]
    static let environmentVariableShape = try! NSRegularExpression(pattern: "[A-Z][A-Z0-9]{2,}_[A-Z0-9_]{2,}")

    /// Every value `PlanReadiness` can take, refusals enumerated one by one (SONNY-336).
    ///
    /// **Spelled out rather than sampled**, because the sweeps below are population checks — a row
    /// naming a provider, or moving a row that is not its own, is only caught on the input that
    /// produces it. `EntitlementRefusal` is not `CaseIterable`, so this is a hand-written list and
    /// `everyRefusalIsAnsweredByName` is what stops it going quietly stale: it fails when the enum
    /// grows a case this array does not carry.
    static let everyRefusal: [EntitlementRefusal] = [
        .notSignedIn,
        .noClaim,
        .unreadableClaim,
        .claimIsForAnotherSession,
        .clockUnusable,
        .lapsed,
        .notEntitled
    ]
    static let everyPlanReadiness: [PlanReadiness] =
        [.confirmed, .undetermined] + everyRefusal.map { PlanReadiness.unconfirmed($0) }

    /// **Not about readiness, and it is here rather than in a file of its own for one reason: this
    /// is where SONNY-136's "no user-facing string mentions an environment variable" sweep is
    /// held.** The row above was one of the two sites that criterion was written for. The other was
    /// `DocumentConversionError.wordUnavailable`, which the ticket's own sweep missed because that
    /// sweep enumerated *provider* variables and this one is the DOCX mock flag — a population
    /// defined too narrowly, which is the failure mode `CLAUDE.md`'s quantified-claim rule describes
    /// from the inside.
    ///
    /// **It was held by nothing at all**, which is how it survived: `git grep -n 'Microsoft Word is
    /// unavailable' -- Sources Tests` answered one line at `13b37c4`, in the source. So the reword
    /// gets an assertion, or the next edit puts the variable back and no run says so.
    ///
    /// The flag is untouched — this asserts the sentence, never the mechanism.
    @Test
    @MainActor
    func theWordUnavailableSentenceNamesNoEnvironmentVariable() throws {
        let sentence = try #require(DocumentConversionError.wordUnavailable.errorDescription)
        #expect(sentence == "Microsoft Word isn't available, so Sonny can't convert this document.")
        #expect(!sentence.contains("MAC_AGENT_MOCK_DOCX"))
        // The shape rather than the name, so a *different* variable in this sentence fails too.
        #expect(
            Self.environmentVariableShape.firstMatch(
                in: sentence,
                range: NSRange(sentence.startIndex..., in: sentence)
            ) == nil
        )
        // And the mechanism the founder's ratification put out of bounds is still there, so this
        // test cannot be satisfied by deleting the mock path (SONNY-136's never-touch list).
        #expect(MockDocumentConverter(enabled: true).isAvailable)
    }

    private func accountRow(
        _ readiness: ModelAccessReadiness,
        _ plan: PlanReadiness = .confirmed
    ) throws -> PermissionReadinessItem {
        let items = PermissionReadinessService
            .deterministic()
            .currentStatus(modelAccess: readiness, planAccess: plan, hotKeyReady: true)
        return try #require(items.first { $0.id == "sonny-account" })
    }

    @Test
    func eachModelAccessStateGetsItsOwnRowStateAndItsOwnSentence() throws {
        let signedIn = try accountRow(.signedIn, .confirmed)
        #expect(signedIn.title == "Sonny account")
        #expect(signedIn.state == .ready)
        #expect(signedIn.detail == "Signed in, and your plan is confirmed.")

        let signedOut = try accountRow(.signedOut, .confirmed)
        #expect(signedOut.state == .needsAction)
        #expect(signedOut.detail == "Sign in to Sonny in Command Center.")

        let undetermined = try accountRow(.undetermined, .confirmed)
        #expect(undetermined.state == .unknown)
        #expect(undetermined.detail == "Sonny checks this when it needs it.")

        // Distinct as a set, not only one by one: three `#expect`s on three literals all pass if two
        // of the literals are the same string, and "its own sentence" is exactly what would then be
        // false.
        #expect(Set([signedIn.detail, signedOut.detail, undetermined.detail]).count == 3)
        #expect(Set([signedIn.state, signedOut.state, undetermined.state]).count == 3)
    }

    /// **Only a held session reports ready.** The direction that matters: an unread or unreadable
    /// account must never render green, because a green readiness row is a claim that the thing
    /// works, and the whole reason the old row was a defect is that it made that claim on evidence
    /// that had nothing to do with it.
    @Test
    func nothingButAHeldSessionEverReportsReady() throws {
        for readiness: ModelAccessReadiness in [.signedOut, .undetermined] {
            for plan: PlanReadiness in Self.everyPlanReadiness {
                #expect(
                    try accountRow(readiness, plan).state != .ready,
                    "\(readiness) with \(plan) reported ready"
                )
            }
        }
        #expect(try accountRow(.signedIn, .confirmed).state == .ready)
    }

    /// **The row is one row, and it is where the old one was.**
    ///
    /// Two things a reader of `currentStatus` would otherwise have to take on trust. The row count
    /// is unchanged at eight — the account row replaced the OpenAI row rather than joining it — and
    /// no row anywhere in the list carries the old `openai` id, which is the check that catches a
    /// half-done rename leaving two rows about the same thing.
    @Test
    func theAccountRowReplacedTheOpenAIRowRatherThanJoiningIt() throws {
        for readiness: ModelAccessReadiness in [.signedIn, .signedOut, .undetermined] {
          for plan: PlanReadiness in Self.everyPlanReadiness {
            let items = PermissionReadinessService
                .deterministic()
                .currentStatus(modelAccess: readiness, planAccess: plan, hotKeyReady: true)
            #expect(items.count == 8)
            #expect(items.filter { $0.id == "sonny-account" }.count == 1)
            #expect(!items.contains { $0.id == "openai" })
            #expect(items.first?.id == "sonny-account", "the account row is still the first one")
            // And no row in the whole list names a provider or a variable, which is the founder's
            // decision of 2026-08-19 applied to the surface it was originally about.
            //
            // **The same two properties `SonnyBackendCopyTests` checks over its own sentences, and
            // checked the same way** (PR #153's F8). This was three literals — `openai`, `_KEY` and
            // `export ` — while the copy sweep two files away used a seven-name provider list and a
            // SCREAMING_SNAKE *shape*, so a detail naming `SONNY_VISION_MODEL`, or Anthropic, passed
            // here and would have failed there. That gap was invisible because a cross-reference in
            // the other file said this test held "the same two properties"; it does now.
            for item in items {
                for field in [item.title, item.detail] {
                    for provider in Self.providerNames {
                        #expect(
                            !field.localizedCaseInsensitiveContains(provider),
                            "a readiness row names \(provider): \(field)"
                        )
                    }
                    #expect(
                        Self.environmentVariableShape.firstMatch(
                            in: field,
                            range: NSRange(field.startIndex..., in: field)
                        ) == nil,
                        "a readiness row carries an environment-variable-shaped token: \(field)"
                    )
                }
                #expect(!item.detail.localizedCaseInsensitiveContains("export "))
            }
          }
        }
    }

    /// **The entitled half, and the rule it is held to: `.ready` needs both halves known-good**
    /// (SONNY-336).
    ///
    /// `ModelAccessReadiness.undetermined`'s own doc states the rule for the session — a check that
    /// could not be completed is not a check that passed — and this is that rule applied to the
    /// second half. Signed in is no longer sufficient for a green row; signed in *with a confirmed
    /// claim* is. That is a real behaviour change to a row that shipped, and it is the one the
    /// ticket exists for: the row reported ready while saying nothing at all about entitlement.
    @Test
    func aHeldSessionAloneIsNoLongerEnoughToReportReady() throws {
        #expect(try accountRow(.signedIn, .confirmed).state == .ready)

        // Every other plan answer, including the never-asked one, is not ready.
        for plan: PlanReadiness in Self.everyPlanReadiness where plan != .confirmed {
            let row = try accountRow(.signedIn, plan)
            #expect(row.state != .ready, "\(plan) reported ready")
            // And not red either — nothing is gated, so an unconfirmed plan blocks nothing and the
            // row must not demand action for it. This is the product call in assertion form: if a
            // capability is ever gated, this line is what a session changing the rule has to argue
            // with rather than discover.
            #expect(row.state == .unknown, "\(plan) was not reported as check-when-used")
        }
    }

    /// **The row still says the session is held even when the plan cannot be confirmed.**
    ///
    /// The failure this forbids is the row collapsing to one fact: a signed-in user whose claim has
    /// lapsed being shown a sentence that reads as signed out, which would send them to a sign-in
    /// that changes nothing — the same shape as `EntitlementCopy`'s `claimIsForAnotherSession`
    /// defect, where the advice was the thing the user had just done.
    @Test
    func anUnconfirmedPlanStillReportsThatTheSessionIsHeld() throws {
        for refusal in Self.everyRefusal {
            let detail = try accountRow(.signedIn, .unconfirmed(refusal)).detail
            #expect(detail.hasPrefix("Signed in."), "\(refusal): \(detail)")
            #expect(!detail.localizedCaseInsensitiveContains("sign in to"), "\(refusal): \(detail)")
        }
        #expect(try accountRow(.signedIn, .undetermined).detail.hasPrefix("Signed in."))
    }

    /// **Every refusal is answered by name, and the switch has no `default`.**
    ///
    /// The point is not the sentences, it is that adding a case to `EntitlementRefusal` cannot
    /// silently inherit another one's wording: `planSentence(for:)` lists all seven, so a new case
    /// fails to compile there, and `Self.everyRefusal` lists all seven here, so a new case makes
    /// this test's own population wrong in a way the assertion below catches.
    ///
    /// **Three sentences for seven refusals is the deliberate shape**, because what a user can do
    /// collapses to three things — connect once, fix the clock, or nothing — and inventing four more
    /// sentences that all mean "nothing you can do" would be words without information. So this
    /// asserts the grouping by value rather than asserting seven distinct strings, which would pin
    /// the opposite of what was decided.
    @Test
    func everyRefusalIsAnsweredByName() throws {
        let sentences = try Self.everyRefusal.map { try accountRow(.signedIn, .unconfirmed($0)).detail }
        // Nothing empty, nothing defaulted to the confirmed row's wording.
        for (refusal, sentence) in zip(Self.everyRefusal, sentences) {
            #expect(!sentence.isEmpty, "\(refusal)")
            #expect(!sentence.contains("your plan is confirmed"), "\(refusal) read as confirmed")
        }
        // The two refusals with a specific action get their own sentence, and neither shares one.
        let noClaim = try accountRow(.signedIn, .unconfirmed(.noClaim)).detail
        let clock = try accountRow(.signedIn, .unconfirmed(.clockUnusable)).detail
        #expect(noClaim == "Signed in. Connect once so Sonny can check your plan.")
        #expect(clock == "Signed in. Your Mac's date and time are too far off to check your plan.")
        #expect(noClaim != clock)
        // The remaining five share one sentence, deliberately, and it is neither of the two above.
        let shared = Set(
            try [EntitlementRefusal.unreadableClaim, .claimIsForAnotherSession, .lapsed, .notSignedIn, .notEntitled]
                .map { try accountRow(.signedIn, .unconfirmed($0)).detail }
        )
        #expect(shared == ["Signed in. Sonny couldn't check your plan."])
        // Three groups, not one and not seven — the decision above, asserted as a count.
        #expect(Set(sentences).count == 3)
    }

    /// **The plan is not consulted while the session says signed out or undetermined.**
    ///
    /// A signed-out Mac's plan question has exactly one answer and it is the advice the session half
    /// already gives, so consulting it could only produce a second sentence about the same problem.
    /// Asserted as identity across every plan value rather than as a sentence, so it holds whatever
    /// the wording becomes.
    @Test
    func thePlanIsNotConsultedUntilASessionIsHeld() throws {
        for readiness: ModelAccessReadiness in [.signedOut, .undetermined] {
            let rows = try Self.everyPlanReadiness.map { try accountRow(readiness, $0) }
            #expect(Set(rows.map(\.detail)).count == 1, "\(readiness) varied with the plan")
            #expect(Set(rows.map(\.state)).count == 1, "\(readiness) varied with the plan")
        }
    }

    /// The rest of the list does not move when the account state does. Written because the account
    /// row is now the only argument `currentStatus` takes besides the hotkey, and a mistake there
    /// would be a whole page that reads differently for a signed-out user.
    @Test
    func theOtherSevenRowsAreUnaffectedByTheAccountState() throws {
        let service = PermissionReadinessService.deterministic()
        let signedIn = service.currentStatus(modelAccess: .signedIn, planAccess: .confirmed, hotKeyReady: true)
        let signedOut = service.currentStatus(modelAccess: .signedOut, planAccess: .confirmed, hotKeyReady: true)

        #expect(signedIn.dropFirst().map(\.id) == signedOut.dropFirst().map(\.id))
        #expect(signedIn.dropFirst() == signedOut.dropFirst())

        // And the plan half moves the account row without moving the other seven either
        // (SONNY-336) — the same property, on the argument this row gained.
        for plan: PlanReadiness in Self.everyPlanReadiness {
            let items = service.currentStatus(modelAccess: .signedIn, planAccess: plan, hotKeyReady: true)
            #expect(items.dropFirst() == signedIn.dropFirst(), "\(plan) moved a row that is not the account row")
        }
    }
}
