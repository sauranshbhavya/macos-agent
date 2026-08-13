import Foundation
import Testing
@testable import MacAgentCore

/// SONNY-85. The router's whole contract lives here: selection honored, unknown and
/// unavailable selections falling back to the default with pinned user-facing copy, the
/// default path's construction failure propagating unchanged, and — the reason the registry
/// exists — a new provider becoming selectable through registration alone, with no edit to
/// any construction site.
@Suite
@MainActor
struct PlannerProviderRegistryTests {
    // MARK: - The shipped registry

    @Test
    func shippedRegistryOffersOpenAIAsDefaultAndSoleProvider() {
        let registry = PlannerProviderRegistry.default
        #expect(registry.defaultProvider.id == "openai")
        #expect(registry.defaultProvider.displayName == "OpenAI")
        #expect(registry.providers.map(\.id) == ["openai"])
        #expect(OpenAIPlanner.provider.id == OpenAIPlanner.providerID)
    }

    @Test
    func shippedRegistryUnknownSelectionCarriesThePinnedNoticeCopy() {
        let resolution = PlannerProviderRegistry.default.resolve(selection: "gpt6")
        #expect(resolution.provider.id == "openai")
        #expect(resolution.fallbackNotice
            == "Sonny doesn't have a planner called “gpt6”, so it used OpenAI instead. Available planners: openai.")
    }

    // MARK: - Selection resolution

    @Test
    func nilEmptyAndWhitespaceSelectionsResolveToTheDefaultWithoutANotice() {
        let registry = makeRegistry()
        for selection in [nil, "", "   ", "\n"] as [String?] {
            let resolution = registry.resolve(selection: selection)
            #expect(resolution.provider.id == "primary")
            #expect(resolution.fallbackNotice == nil)
        }
    }

    @Test
    func selectionMatchingIsCaseInsensitiveAndTrimmed() {
        let registry = makeRegistry()
        for selection in ["alternate", "Alternate", "ALTERNATE", "  alternate  "] {
            let resolution = registry.resolve(selection: selection)
            #expect(resolution.provider.id == "alternate")
            #expect(resolution.fallbackNotice == nil)
        }
    }

    @Test
    func unknownSelectionFallsBackToTheDefaultAndListsWhatExists() {
        let registry = makeRegistry()
        let resolution = registry.resolve(selection: "mystery")
        #expect(resolution.provider.id == "primary")
        #expect(resolution.fallbackNotice
            == "Sonny doesn't have a planner called “mystery”, so it used Primary instead. Available planners: primary, alternate.")
    }

    // MARK: - Construction through the registry

    /// The acceptance criterion, pinned as behavior: registering a provider is all it takes
    /// for a selection to construct that provider's planner through the same `makePlanner`
    /// call the construction site already makes. No edit outside the registry is part of
    /// this test's arrangement.
    @Test
    func registeringAProviderMakesItConstructibleThroughTheExistingSelectionCall() throws {
        let alternatePlanner = StubPlanner(marker: "alternate")
        var registry = PlannerProviderRegistry(defaultProvider: stubProvider(id: "primary", displayName: "Primary"))
        registry.register(
            PlannerProvider(id: "alternate", displayName: "Alternate") { _ in alternatePlanner }
        )

        let selected = try registry.makePlanner(selection: "alternate", usageRecorder: NoopTaskUsageRecorder.shared)

        #expect(selected.planner as? StubPlanner === alternatePlanner)
        #expect(selected.provider.id == "alternate")
        #expect(selected.fallbackNotice == nil)
    }

    @Test
    func defaultSelectionConstructsTheDefaultPlannerWithoutANotice() throws {
        let defaultPlanner = StubPlanner(marker: "primary")
        let registry = PlannerProviderRegistry(
            defaultProvider: PlannerProvider(id: "primary", displayName: "Primary") { _ in defaultPlanner }
        )

        let selected = try registry.makePlanner(selection: nil, usageRecorder: NoopTaskUsageRecorder.shared)

        #expect(selected.planner as? StubPlanner === defaultPlanner)
        #expect(selected.provider.id == "primary")
        #expect(selected.fallbackNotice == nil)
    }

    @Test
    func unknownSelectionConstructsTheDefaultPlannerAndKeepsTheNotice() throws {
        let defaultPlanner = StubPlanner(marker: "primary")
        var registry = PlannerProviderRegistry(
            defaultProvider: PlannerProvider(id: "primary", displayName: "Primary") { _ in defaultPlanner }
        )
        registry.register(stubProvider(id: "alternate", displayName: "Alternate"))

        let selected = try registry.makePlanner(selection: "mystery", usageRecorder: NoopTaskUsageRecorder.shared)

        #expect(selected.planner as? StubPlanner === defaultPlanner)
        #expect(selected.provider.id == "primary")
        #expect(selected.fallbackNotice
            == "Sonny doesn't have a planner called “mystery”, so it used Primary instead. Available planners: primary, alternate.")
    }

    /// "Unavailable" is the second fallback trigger the ticket names: the selection is a real,
    /// registered provider, but constructing it fails (a missing API key is the canonical
    /// case). The swap to the default must carry a notice naming the reason — never silence.
    @Test
    func unavailableSelectedProviderFallsBackToTheDefaultWithTheReasonInTheNotice() throws {
        let defaultPlanner = StubPlanner(marker: "primary")
        var registry = PlannerProviderRegistry(
            defaultProvider: PlannerProvider(id: "primary", displayName: "Primary") { _ in defaultPlanner }
        )
        registry.register(
            PlannerProvider(id: "alternate", displayName: "Alternate") { _ in
                throw StubProviderError.keyMissing
            }
        )

        let selected = try registry.makePlanner(selection: "alternate", usageRecorder: NoopTaskUsageRecorder.shared)

        #expect(selected.planner as? StubPlanner === defaultPlanner)
        #expect(selected.provider.id == "primary")
        #expect(selected.fallbackNotice
            == "The Alternate planner isn't available, so Sonny used Primary instead. (STUB_KEY is not set.)")
    }

    /// The default path must stay byte-identical to constructing the default planner
    /// directly, and that includes its failure: when the *default* provider cannot
    /// construct, the error propagates — no swallowing, no notice, no secondary fallback.
    @Test
    func defaultProviderConstructionFailurePropagatesUnchanged() {
        let registry = PlannerProviderRegistry(
            defaultProvider: PlannerProvider(id: "primary", displayName: "Primary") { _ in
                throw StubProviderError.keyMissing
            }
        )

        #expect(throws: StubProviderError.keyMissing) {
            _ = try registry.makePlanner(selection: nil, usageRecorder: NoopTaskUsageRecorder.shared)
        }
    }

    /// Provider obligation 1 has a seam only if the recorder the construction site supplies is
    /// the recorder the provider's constructor receives — pinned by identity, not by effect.
    @Test
    func makePlannerHandsTheCallersUsageRecorderToTheProviderConstructor() throws {
        let received = RecorderCapture()
        let registry = PlannerProviderRegistry(
            defaultProvider: PlannerProvider(id: "primary", displayName: "Primary") { recorder in
                received.identifier = ObjectIdentifier(recorder as AnyObject)
                return StubPlanner(marker: "primary")
            }
        )
        let recorder = TaskUsageRecorder()

        _ = try registry.makePlanner(selection: nil, usageRecorder: recorder)

        #expect(received.identifier == ObjectIdentifier(recorder))
    }

    // MARK: - Helpers

    private func makeRegistry() -> PlannerProviderRegistry {
        var registry = PlannerProviderRegistry(defaultProvider: stubProvider(id: "primary", displayName: "Primary"))
        registry.register(stubProvider(id: "alternate", displayName: "Alternate"))
        return registry
    }

    private func stubProvider(id: String, displayName: String) -> PlannerProvider {
        PlannerProvider(id: id, displayName: displayName) { _ in StubPlanner(marker: id) }
    }
}

@MainActor
private final class StubPlanner: Planning {
    let marker: String

    init(marker: String) {
        self.marker = marker
    }

    func plan(command: String, priorTaskContext: PriorTaskContext?) async throws -> AgentPlan {
        AgentPlan(summary: "Planned by \(marker).", requiresConfirmation: false, steps: [])
    }
}

@MainActor
private final class RecorderCapture {
    var identifier: ObjectIdentifier?
}

private enum StubProviderError: Error, LocalizedError, Equatable {
    case keyMissing

    var errorDescription: String? {
        "STUB_KEY is not set."
    }
}
