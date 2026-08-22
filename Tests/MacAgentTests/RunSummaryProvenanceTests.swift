import Foundation
import Testing
@testable import MacAgent
import MacAgentCore

/// The enumeration `AgentRunResult.summaryProvenance`'s doc comment names as its guard (row E,
/// SONNY-147).
///
/// **Why there is a source scan here as well as behavioural tests.** `summaryProvenance` defaults to
/// `.codeAuthored`, and that default is only honest because exactly one of the 27 `AgentRunResult`
/// construction sites in `Sources/` authors free text a model wrote. Nothing at run time can observe
/// "how many sites name `.modelAuthored`" — a behavioural test can only observe the sites a fixture
/// happens to execute. That gap was measured rather than assumed: a mutant adding `.modelAuthored`
/// to the *calculator* adapter dies, because two fixtures run the calculator and read its provenance
/// back; the same mutant on `RevealInFinderCapabilityAdapter` survived the whole suite (PR #89
/// review, M9/M9b). Coincidence of coverage is not a guard.
///
/// The converse is just as true and this file used to imply otherwise (SONNY-200): a scan cannot
/// substitute for behaviour either. The chain join's own accumulator is behaviour, and the pair
/// that holds it is `VisionSessionRunTests.aChainWhoseScreenControlSegmentWrotePartOfTheSummaryStoresItAsModelAuthored`
/// for the raising and `AgentActionExecutorTests.anOrdinaryChainsJoinedSummaryStaysCodeAuthored` for
/// the not-raising. Neither cares how a line is spelled, which is the property no text search has.
///
/// **Why it lives in the app test target for a property of `MacAgentCore`.** `MacAgentSource` is
/// this repository's one source scanner, it is here, and the core test target cannot import it. A
/// second scanner there would be a second copy of the comment-stripping discipline whose absence
/// this repository has already been bitten by twice, both recorded on `MacAgentSource` itself.
///
/// The honest limit is the one every scan here has: it is textual. Comments are stripped in both
/// syntaxes, so a mention in prose cannot satisfy it, but a Swift string literal containing the
/// searched token would — narrower than the comment case, and no literal in either target contains
/// one today.
@MainActor
struct RunSummaryProvenanceTests {
    /// **One term, and deliberately not a list of spellings** (SONNY-200).
    ///
    /// This was a list. It searched `summaryProvenance: .modelAuthored` — a labelled argument at
    /// construction — and `summaryProvenance = .modelAuthored` — an assignment afterwards — and it
    /// grew to two because counting only the first let a declaring site written the second way
    /// through (PR #89 cycle 2, M14).
    ///
    /// Two was still not all of them, and a list of spellings never can be. Swift has a third shape
    /// and this codebase already writes it: a declaration with an explicit type annotation between
    /// the name and the value —
    /// `var summaryProvenance: StoredTaskResult.Provenance = .codeAuthored`, which is
    /// `AgentActionExecutor.executeChain`'s accumulator. That text matches neither term, because
    /// each wanted the value immediately after the name, so a mutant flipping that initial value to
    /// `.modelAuthored` survived the enumeration (PR #89 cycle 3).
    ///
    /// So the scan stopped asking *how the property is written* and asks the one question a text
    /// search can actually answer completely: **which files name the value at all.** That has no
    /// spelling hole by construction, and it costs one thing worth stating — the population is now
    /// every mention of `.modelAuthored` in compiled code, which includes `StoredTaskResult`'s own
    /// `modelAuthored(_:)` factory, a site that names the value without being an `AgentRunResult`
    /// declaration at all. It is expected by name below rather than excluded, because an exclusion
    /// is one more rule that can go stale.
    ///
    /// The real guard on the accumulator is behavioural and lives elsewhere:
    /// `AgentActionExecutorTests.anOrdinaryChainsJoinedSummaryStaysCodeAuthored` runs two ordinary
    /// units and reads the provenance back, and does not care how the line is spelled. This scan is
    /// the backstop for the sites no fixture happens to execute.
    static let namesTheValue = ".modelAuthored"

    /// The declaration this whole enum exists for: one authoring site, and it is the screen-control
    /// session's — plus the one forwarding site that assigns the same value along a chain.
    @Test
    func theOnlyModelAuthoredRunSummaryIsTheVisionSessions() throws {
        var namingFiles: [String: Int] = [:]
        for url in try MacAgentSource.coreSourceFiles() {
            let count = MacAgentSource.count(of: Self.namesTheValue, inText: try MacAgentSource.read(url))
            guard count > 0 else {
                continue
            }
            namingFiles[MacAgentSource.coreRelativePath(of: url)] = count
        }

        #expect(
            namingFiles == [
                // The one authoring site: free text a model wrote after reading the user's screen.
                "VisionSessionCapabilityAdapter.swift": 1,
                // The chain join. Two mentions, not one: it compares a segment's provenance against
                // the value and then assigns it. Both are the forward, pinned by name below.
                "AgentActionExecutor.swift": 2,
                // The enum's own home — `StoredTaskResult.modelAuthored(_:)`, the factory every
                // authoring site goes through. Named here rather than excluded: it genuinely
                // mentions the value, and an exclusion rule is one more thing that can go stale.
                "StoredTaskResult.swift": 1
            ],
            """
            These are every mention of `\(Self.namesTheValue)` in Sources/MacAgentCore's compiled \
            code — the whole population, in any spelling, because this counts the value rather than \
            the ways a property can be written next to it. Found: \
            \(namingFiles.sorted { $0.key < $1.key }).
            A new model-authored producer is not forbidden — but `.codeAuthored` is the default for \
            every other site, so a new one arriving means this enumeration, `StoredTaskResult`'s \
            own doc comment and `AgentRunResult.summaryProvenance`'s all now describe a world with \
            one authoring site, and all three have to be updated together.
            What this cannot see, stated because the sentence here used to claim more than it \
            could deliver: comments are stripped, so prose cannot satisfy it, but a Swift string \
            literal containing the token would — no literal in either target contains one today.
            """
        )
    }

    /// The app target never names the value at all. `MacAgent` builds no `AgentRunResult`; if it
    /// ever does, the enumeration above stops being the whole population and this says so.
    ///
    /// Widened with the scan above (SONNY-200): this asked about two declaration spellings and now
    /// asks whether the token appears anywhere in compiled app-target code, which is both simpler
    /// and strictly stronger.
    @Test
    func theAppTargetDeclaresNoRunSummaryProvenanceAtAll() throws {
        for url in try MacAgentSource.appSourceFiles() {
            #expect(
                MacAgentSource.count(of: Self.namesTheValue, inText: try MacAgentSource.read(url)) == 0,
                "\(MacAgentSource.relativePath(of: url)) names \(Self.namesTheValue) in compiled code"
            )
        }
    }

    /// **The three shapes the scan has to survive, each pinned where it actually occurs.**
    ///
    /// The enumeration above is only a guard if its term covers the ways Swift lets you write this.
    /// A list of spellings kept not covering them — one spelling let M14 through, two let the
    /// type-annotated declaration through — so the term is now the value itself, and what this test
    /// pins is that each shape really exists in the tree and really is inside the term's reach. A
    /// term matching nothing anywhere is a term nobody would notice had stopped working.
    @Test
    func everyDeclarationShapeInTheTreeIsInsideTheScansReach() throws {
        let vision = try MacAgentSource.read(
            MacAgentSource.coreSourceDirectory.appendingPathComponent("VisionSessionCapabilityAdapter.swift")
        )
        // 1. Labelled argument at construction.
        #expect(MacAgentSource.count(of: "summaryProvenance: .modelAuthored", inText: vision) == 1)

        let executor = try MacAgentSource.read(
            MacAgentSource.coreSourceDirectory.appendingPathComponent("AgentActionExecutor.swift")
        )
        // 2. Assignment afterwards.
        #expect(
            MacAgentSource.count(of: "summaryProvenance = .modelAuthored", inText: executor) == 1,
            "the assignment shape must still occur, or the scan's reach over it is unexercised"
        )
        // 3. Declaration with an explicit type annotation — the shape neither old search term could
        // see. It holds `.codeAuthored` today, which is exactly why the hole was invisible: there
        // was nothing to find. Pinned by its current value, so a flip to `.modelAuthored` changes
        // `AgentActionExecutor.swift`'s count in the enumeration above from 2 to 3 and fails it.
        #expect(
            MacAgentSource.count(
                of: "var summaryProvenance: StoredTaskResult.Provenance = .codeAuthored",
                inText: executor
            ) == 1,
            "executeChain's accumulator is the third declaration shape and must still be code-authored"
        )
        // And the term itself is the value, not a property spelling — the property name must not
        // creep back into it.
        #expect(Self.namesTheValue == ".modelAuthored")
    }

    /// The two sites that **forward** a provenance rather than authoring one, pinned by name because
    /// hardcoding either to `.codeAuthored` — on the ground that *it* wrote the surrounding template
    /// — is exactly how the model's text would get laundered into a trusted-looking sentence.
    ///
    /// Only the chain is reachable today: a plan may mix ordinary steps with a vision step, which
    /// `visionSplitDisclosure` writes a user-facing sentence about, while
    /// `StoredRoutine.forbiddenStepOperations` refuses `.visionSession` inside a routine outright.
    /// The chain's behaviour is pinned end to end by
    /// `VisionSessionRunTests.aChainWhoseScreenControlSegmentWrotePartOfTheSummaryStoresItAsModelAuthored`;
    /// the routine wrapper cannot be, so it is pinned here.
    @Test
    func theTwoForwardingSitesPassTheProvenanceOnRatherThanDeclaringOne() throws {
        let executor = try MacAgentSource.read(
            MacAgentSource.coreSourceDirectory.appendingPathComponent("AgentActionExecutor.swift")
        )
        #expect(executor.contains("summaryProvenance: summaryProvenance"))
        #expect(executor.contains("if result.summaryProvenance == .modelAuthored"))

        let routine = try MacAgentSource.read(
            MacAgentSource.coreSourceDirectory.appendingPathComponent("RunRoutineCapabilityAdapter.swift")
        )
        #expect(routine.contains("summaryProvenance: result.summaryProvenance"))
    }

    /// And the default itself, which is what makes 26 of the 27 sites correct without saying
    /// anything. Asserted on the declaration rather than only on a constructed value, because a
    /// value proves what the default *is* and this proves nobody removed it.
    @Test
    func theDeclaredDefaultIsCodeAuthored() throws {
        let event = try MacAgentSource.read(
            MacAgentSource.coreSourceDirectory.appendingPathComponent("AgentEvent.swift")
        )
        #expect(event.contains("summaryProvenance: StoredTaskResult.Provenance = .codeAuthored"))
    }
}
