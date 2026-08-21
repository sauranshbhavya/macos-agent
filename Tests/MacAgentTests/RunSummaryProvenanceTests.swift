import Foundation
import Testing
@testable import MacAgent
import MacAgentCore

/// The enumeration `AgentRunResult.summaryProvenance`'s doc comment names as its guard (row E,
/// SONNY-147).
///
/// **Why this is a source scan and not a behavioural test.** `summaryProvenance` defaults to
/// `.codeAuthored`, and that default is only honest because exactly one of the 27 `AgentRunResult`
/// construction sites in `Sources/` authors free text a model wrote. Nothing at run time can observe
/// "how many sites declare `.modelAuthored`" — a behavioural test can only observe the sites a
/// fixture happens to execute. That gap was measured rather than assumed: a mutant adding
/// `.modelAuthored` to the *calculator* adapter dies, because two fixtures run the calculator and
/// read its provenance back; the same mutant on `RevealInFinderCapabilityAdapter` survived the whole
/// suite (PR #89 review, M9/M9b). Coincidence of coverage is not a guard.
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
    /// **Both spellings of a declaration, because Swift has two and this codebase uses both.**
    ///
    /// A labelled argument at construction — `AgentRunResult(…, summaryProvenance: .modelAuthored)` —
    /// and an assignment after it — `result.summaryProvenance = .modelAuthored`. The scan counted
    /// only the first, so a second declaring site written the second way passed it (PR #89 cycle 2,
    /// M14). That spelling is not hypothetical: `AgentActionExecutor.executeChain` already assigns
    /// `summaryProvenance = .modelAuthored` inside its join, which is the *forwarding* site and is
    /// pinned by name in `theTwoForwardingSitesPassTheProvenanceOnRatherThanDeclaringOne` below —
    /// so the enumeration here has to be able to see that shape in order to tell a new declaration
    /// from the forward it already knows about.
    ///
    /// Which is why the expected map has two entries rather than one, and why the forward is
    /// expected *by name and by count*: this test says "exactly these sites declare or assign it,
    /// and no others", and the other test says which of them is a forward.
    static let declaringSpellings = [
        "summaryProvenance: .modelAuthored",   // labelled argument at construction
        "summaryProvenance = .modelAuthored"   // assignment afterwards
    ]

    /// The declaration this whole enum exists for: one authoring site, and it is the screen-control
    /// session's — plus the one forwarding site that assigns the same value along a chain.
    @Test
    func theOnlyModelAuthoredRunSummaryIsTheVisionSessions() throws {
        var declaringFiles: [String: Int] = [:]
        for url in try MacAgentSource.coreSourceFiles() {
            let text = try MacAgentSource.read(url)
            let count = Self.declaringSpellings.reduce(0) { total, spelling in
                total + MacAgentSource.count(of: spelling, inText: text)
            }
            guard count > 0 else {
                continue
            }
            declaringFiles[MacAgentSource.coreRelativePath(of: url)] = count
        }

        #expect(
            declaringFiles == [
                // The one authoring site: free text a model wrote after reading the user's screen.
                "VisionSessionCapabilityAdapter.swift": 1,
                // The chain join, which forwards rather than authors — pinned as a forward below.
                "AgentActionExecutor.swift": 1
            ],
            """
            Exactly two sites in Sources/MacAgentCore may carry `.modelAuthored`, in either \
            spelling: the screen-control session declares it, and the chain join forwards it. \
            Found: \(declaringFiles.sorted { $0.key < $1.key }).
            A new model-authored producer is not forbidden — but `.codeAuthored` is the default for \
            every other site, so a third one arriving means this enumeration, `StoredTaskResult`'s \
            own doc comment and `AgentRunResult.summaryProvenance`'s all now describe a world with \
            one authoring site, and all three have to be updated together.
            """
        )
    }

    /// The app target declares none at all, in either spelling. `MacAgent` builds no
    /// `AgentRunResult`; if it ever does, the enumeration above stops being the whole population and
    /// this says so.
    @Test
    func theAppTargetDeclaresNoRunSummaryProvenanceAtAll() throws {
        for url in try MacAgentSource.appSourceFiles() {
            let text = try MacAgentSource.read(url)
            for spelling in Self.declaringSpellings {
                #expect(
                    MacAgentSource.count(of: spelling, inText: text) == 0,
                    "\(MacAgentSource.relativePath(of: url)) carries a model-authored run summary (\(spelling))"
                )
            }
        }
    }

    /// **The scan can see both spellings**, asserted against the code rather than trusted.
    ///
    /// The enumeration above is only a guard if its search terms cover the ways Swift lets you write
    /// the thing. Counting one spelling and calling it a population is what let M14 through, so this
    /// pins that the assignment form really is searched for and really does occur — a term that
    /// matched nothing anywhere would be a term nobody would notice had stopped working.
    @Test
    func bothDeclarationSpellingsAreSearchedForAndBothOccur() throws {
        #expect(Self.declaringSpellings.count == 2)

        let executor = try MacAgentSource.read(
            MacAgentSource.coreSourceDirectory.appendingPathComponent("AgentActionExecutor.swift")
        )
        #expect(
            MacAgentSource.count(of: "summaryProvenance = .modelAuthored", inText: executor) == 1,
            "the assignment spelling must still occur, or the search term for it is unexercised"
        )

        let vision = try MacAgentSource.read(
            MacAgentSource.coreSourceDirectory.appendingPathComponent("VisionSessionCapabilityAdapter.swift")
        )
        #expect(MacAgentSource.count(of: "summaryProvenance: .modelAuthored", inText: vision) == 1)
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
