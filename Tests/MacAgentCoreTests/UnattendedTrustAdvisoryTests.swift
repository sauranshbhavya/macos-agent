import Foundation
import Testing
@testable import MacAgentCore

/// Branch 10 checkpoint 2. The opt-in-time heads-up for a routine that could never actually run
/// unattended, so the user isn't left with a routine that silently never runs plus a recurring
/// skip notice.
@Suite
@MainActor
struct UnattendedTrustAdvisoryTests {
    /// Running any saved routine is tier 2 by default, independent of its steps — that is the
    /// whole reason the per-routine opt-in exists. Tier 2 is exactly what unattended trust is for,
    /// so it must not warn.
    @Test
    func anOrdinaryTierTwoRoutineGetsNoWarning() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let routineStore = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))
        try routineStore.save(
            StoredRoutine(
                name: "Morning",
                steps: [AgentStep(id: "open", operation: .openApp, description: "Open Safari.", appName: "Safari")]
            )
        )
        let executor = AgentActionExecutor(routineStore: routineStore)

        #expect(UnattendedTrustAdvisory.warning(forRoutineNamed: "Morning", executor: executor) == nil)
    }

    /// A routine whose step would replace an existing snippet escalates to tier 3, which
    /// `AgentRunner`'s approved-tier comparison can never satisfy from an unattended run.
    @Test
    func aTierThreeRoutineWarnsAndNamesTheRoutine() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let snippetStore = SnippetStore(fileURL: root.appendingPathComponent("snippets.json"))
        try snippetStore.save(StoredSnippet(trigger: ";sig", expansion: "Old text"))
        let routineStore = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))
        try routineStore.save(
            StoredRoutine(
                name: "Signature refresh",
                steps: [
                    AgentStep(
                        id: "snippet",
                        operation: .saveSnippet,
                        description: "Save snippet ;sig.",
                        searchQuery: ";sig",
                        draftContent: "New text"
                    )
                ]
            )
        )
        let executor = AgentActionExecutor(routineStore: routineStore, snippetStore: snippetStore)

        // Guard the premise rather than assuming it: if this stops being tier 3, the test below
        // would pass vacuously for the wrong reason.
        let assessment = try executor.assessRisk(
            plan: RunRoutineCapabilityAdapter.plan(forRoutineNamed: "Signature refresh")
        )
        #expect(assessment.effectiveTier == .tier3)

        let warning = try #require(
            UnattendedTrustAdvisory.warning(forRoutineNamed: "Signature refresh", executor: executor)
        )
        #expect(warning.contains("Signature refresh"))
        #expect(warning.contains("skipped"))
        // The copy must not promise this is settled — tiers escalate from real run-time conditions,
        // so a clean check today is not a guarantee the routine will run tomorrow.
        #expect(warning.contains("re-checks"))
    }

    /// Best-effort by design: an unassessable routine yields no advisory rather than blocking the
    /// opt-in. The real backstop is at execution time, so a failed pre-check costs a skip notice
    /// later — it never lets anything unsafe through.
    @Test
    func anUnknownRoutineYieldsNoWarningRatherThanThrowing() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = AgentActionExecutor(
            routineStore: RoutineStore(fileURL: root.appendingPathComponent("routines.json"))
        )

        #expect(UnattendedTrustAdvisory.warning(forRoutineNamed: "Ghost", executor: executor) == nil)
    }

    /// The scheduler, the instant resolver, and this advisory must all run a routine through the
    /// identical plan — three hand-rolled copies would be three chances to drift apart.
    @Test
    func theSharedRunRoutinePlanFactoryMatchesWhatTheInstantResolverProduces() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let routineStore = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))
        try routineStore.save(
            StoredRoutine(
                name: "Morning",
                steps: [AgentStep(id: "open", operation: .openApp, description: "Open Safari.", appName: "Safari")]
            )
        )
        let resolver = InstantCommandResolver(routineStore: routineStore)

        guard case .plan(let resolved) = resolver.resolve(command: "run routine Morning") else {
            Issue.record("Expected the kind-prefixed form to resolve instantly.")
            return
        }

        #expect(resolved == RunRoutineCapabilityAdapter.plan(forRoutineNamed: "Morning"))
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("UnattendedTrustAdvisoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
