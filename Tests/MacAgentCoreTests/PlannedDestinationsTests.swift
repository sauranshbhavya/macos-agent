import Foundation
import Testing
@testable import MacAgentCore

/// `PlannedDestinations` is the pre-execution half of the pair `RunClaims` completes (SONNY-220), and
/// these pin the two rules it enforces *by construction* rather than by its callers remembering them.
/// Both are invisible end to end today — a generated draft's stem is a lowercased slug, so no
/// executor test can produce a case-differing collision, and no adapter resolves a step to a blank
/// path — which is exactly why they are asserted here instead of assumed there.
@Suite
struct PlannedDestinationsTests {
    /// The fold is what makes seeding the executor's disambiguation set a union of like with like.
    /// `RunClaims.destinations` and that set both hold `DestinationKey.folded` keys; a set that held
    /// raw paths would union cleanly, compare unequal, and let a nested routine generate
    /// `/Notes/Report.md` over a plan that already names `/notes/report.md` — one file on every
    /// volume nearly every user has.
    @Test
    func destinationsAreFoldedOnTheWayIn() {
        #expect(
            PlannedDestinations(paths: ["/Notes/Report.md"]) == PlannedDestinations(paths: ["/notes/report.md"])
        )
        #expect(PlannedDestinations(paths: ["/Notes/Report.md"]).paths == [DestinationKey.folded("/Notes/Report.md")])
        // The fold is a pure string operation and folds the whole path, not just the last component.
        #expect(PlannedDestinations(paths: ["/Notes/Report.md"]).paths.first?.contains("/notes/") == true)
    }

    /// A step with no destination, or one that is whitespace, names nothing — and has to be dropped
    /// rather than folded to `""` and stored. An empty key matches no generated path, so keeping it
    /// would change no behaviour and would make `paths` report a destination the plan does not have:
    /// a set that lies about its own size is the kind of thing a later reader builds on.
    ///
    /// Matches the executor's own accumulation test exactly, which skips a step whose trimmed
    /// `outputPath` is empty rather than inserting it.
    @Test
    func stepsWithoutARealDestinationAreDropped() {
        let plan = AgentPlan(
            summary: "Draft a note.",
            requiresConfirmation: false,
            steps: [
                AgentStep(id: "a", operation: .createLocalDraft, description: "Named", outputPath: "/Notes/a.md"),
                AgentStep(id: "b", operation: .runRoutine, description: "No destination", routineName: "Notes"),
                AgentStep(id: "c", operation: .createLocalDraft, description: "Blank", outputPath: "   ")
            ]
        )

        #expect(PlannedDestinations(namedBy: plan).paths == [DestinationKey.folded("/Notes/a.md")])
    }

    /// Both kinds of destination belong: the generated default the resolver filled in and the path
    /// the plan spelled out itself. A nested routine colliding with either is the same collision.
    @Test
    func bothGeneratedAndExplicitDestinationsAreCollected() {
        let plan = AgentPlan(
            summary: "Draft two notes.",
            requiresConfirmation: false,
            steps: [
                AgentStep(id: "a", operation: .createLocalDraft, description: "Resolved default", outputPath: "/Notes/draft-note-1.md"),
                AgentStep(id: "b", operation: .createLocalDraft, description: "Named by the plan", outputPath: "/Notes/standup.md")
            ]
        )

        #expect(
            PlannedDestinations(namedBy: plan).paths == [
                DestinationKey.folded("/Notes/draft-note-1.md"),
                DestinationKey.folded("/Notes/standup.md")
            ]
        )
    }

    /// `union` is how a chain adds its own plan's destinations to whatever its caller already named,
    /// so it has to keep both sides rather than replace one with the other.
    @Test
    func unionKeepsBothSidesDestinations() {
        let enclosing = PlannedDestinations(paths: ["/Notes/outer.md"])
        let own = PlannedDestinations(paths: ["/Notes/inner.md"])

        #expect(
            enclosing.union(own).paths == [
                DestinationKey.folded("/Notes/outer.md"),
                DestinationKey.folded("/Notes/inner.md")
            ]
        )
        #expect(PlannedDestinations.none.union(own) == own)
        #expect(own.union(.none) == own)
    }
}
