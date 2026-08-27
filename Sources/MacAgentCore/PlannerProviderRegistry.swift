import Foundation

/// One selectable planning backend behind the `Planning` seam: a stable selection id, a
/// human-readable name, and the constructor the router calls when this provider is selected.
///
/// **Provider obligations.** `Planning` is the entire seam — there is no translation layer
/// above it — so the planner `construct` returns must satisfy all three of these itself;
/// the router cannot add them afterwards:
///
/// 1. **Usage recording is opt-in via `TaskUsageRecording`.** The recorder handed to
///    `construct` is the per-task recorder; a provider that never calls `record` simply
///    reports no usage for its tasks. Nothing above the seam records on a provider's behalf.
/// 2. **User cancellation surfaces as `CancellationError` or `URLError(.cancelled)`.** The
///    cancel UX depends on telling those apart from failure: a provider that wraps either in
///    its own error type turns a deliberate cancellation into a red failure with a Retry
///    button.
/// 3. **Every thrown error carries its own `LocalizedError` conformance.** Planner errors
///    reach the user verbatim through the failure surface; a raw `DecodingError` or
///    Foundation error rendered to the user is a bug.
public struct PlannerProvider: Identifiable, Sendable {
    /// Stable selection key, unique within a registry. Selections are matched against it
    /// case-insensitively after trimming, so register lowercase ids.
    public let id: String
    /// Human-readable name for notices and (later) settings surfaces.
    public let displayName: String
    private let construct: Construct

    /// **Two shapes, because two kinds of planner genuinely exist right now** (SONNY-130).
    ///
    /// A planner that runs through Sonny's backend needs the run's `task_id` and `retention` — the
    /// contract requires both on every content-bearing request and defaults neither (§2.4.2) — and
    /// those are facts about *this run*, so they arrive at construction rather than at registration.
    /// A planner that still holds its own provider credential needs neither, because it does not
    /// talk to Sonny's backend at all.
    ///
    /// That second shape is not a legacy allowance kept for convenience: `CerebrasPlanner` is on
    /// this ticket's never-touch list and reads `CEREBRAS_API_KEY` today, and
    /// `feature/row-12-provider-router` is the branch that moves it. When it does, this enum
    /// collapses to one case and both initializers below become one.
    private enum Construct: Sendable {
        case local(@MainActor @Sendable (any TaskUsageRecording) throws -> any Planning)
        case throughTheGateway(
            @MainActor @Sendable (BackendTaskContext, any TaskUsageRecording) throws -> any Planning
        )
    }

    /// A planner that holds its own provider credential and needs nothing from the run.
    public init(
        id: String,
        displayName: String,
        construct: @escaping @MainActor @Sendable (any TaskUsageRecording) throws -> any Planning
    ) {
        self.id = id
        self.displayName = displayName
        self.construct = .local(construct)
    }

    /// A planner that runs through Sonny's backend and therefore needs this run's task context.
    public init(
        id: String,
        displayName: String,
        throughTheGateway: @escaping @MainActor @Sendable (
            BackendTaskContext, any TaskUsageRecording
        ) throws -> any Planning
    ) {
        self.id = id
        self.displayName = displayName
        self.construct = .throughTheGateway(throughTheGateway)
    }

    /// `taskContext` is handed to every provider and used by the ones that need it. A provider that
    /// holds its own credential ignores it, rather than the registry having to know which is which.
    @MainActor
    public func makePlanner(
        taskContext: BackendTaskContext,
        usageRecorder: any TaskUsageRecording
    ) throws -> any Planning {
        switch construct {
        case .local(let make):
            return try make(usageRecorder)
        case .throughTheGateway(let make):
            return try make(taskContext, usageRecorder)
        }
    }
}

/// Which provider a selection resolved to, before any construction. `fallbackNotice` is
/// non-nil exactly when the selection was not honored — the "never a silent planner swap"
/// half of the contract, separated from construction so it stays testable without keys.
public struct PlannerProviderResolution: Sendable {
    public let provider: PlannerProvider
    public let fallbackNotice: String?
}

/// A constructed planner plus the provider that produced it and, when the configured
/// selection could not be honored, the user-facing notice saying who actually planned and
/// why. Not `Sendable` — `Planning` is a main-actor seam and the value is consumed where it
/// was made.
public struct SelectedPlanner {
    public let planner: any Planning
    public let provider: PlannerProvider
    public let fallbackNotice: String?
}

/// Client-side stand-in for spec §16.5's provider-agnostic router (SONNY-85): the single
/// place that maps a planner selection to a constructed `Planning` implementation, so no
/// call site hardcodes one vendor's wire shape and adding a provider is a registration, not
/// a new branch at the construction site.
///
/// Selection contract: `nil`, empty, and whitespace-only selections mean the default,
/// silently. A non-empty selection either matches a registered provider id
/// (case-insensitively, after trimming) or falls back to the default provider **with a
/// user-facing notice**. A registered non-default provider whose construction fails also
/// falls back to the default, with a notice naming the reason. Only the default provider's
/// own construction failure throws — exactly what constructing it directly would have done.
public struct PlannerProviderRegistry: Sendable {
    public let defaultProvider: PlannerProvider
    /// Registration order, default first. Ids are unique; the shipped set is compiled in and
    /// pinned by tests, so a collision is a programmer error caught there, not at runtime.
    public private(set) var providers: [PlannerProvider]

    /// The default provider is the registry's fallback for every unhonorable selection, so it
    /// is registered by construction — a registry cannot exist without one.
    public init(defaultProvider: PlannerProvider) {
        self.defaultProvider = defaultProvider
        self.providers = [defaultProvider]
    }

    public mutating func register(_ provider: PlannerProvider) {
        providers.append(provider)
    }

    public func provider(withID id: String) -> PlannerProvider? {
        let normalized = Self.normalize(id)
        return providers.first { Self.normalize($0.id) == normalized }
    }

    public func resolve(selection: String?) -> PlannerProviderResolution {
        guard let selection else {
            return PlannerProviderResolution(provider: defaultProvider, fallbackNotice: nil)
        }
        let trimmed = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return PlannerProviderResolution(provider: defaultProvider, fallbackNotice: nil)
        }
        if let match = provider(withID: trimmed) {
            return PlannerProviderResolution(provider: match, fallbackNotice: nil)
        }
        return PlannerProviderResolution(
            provider: defaultProvider,
            fallbackNotice: "Sonny doesn't have a planner called “\(trimmed)”, so it used "
                + "\(defaultProvider.displayName) instead. Available planners: "
                + "\(providers.map(\.id).joined(separator: ", "))."
        )
    }

    /// Resolves `selection`, constructs the resolved provider's planner, and reports who
    /// actually got constructed. See the type doc for the fallback contract; the one throwing
    /// path is the default provider's own construction failure, which propagates unchanged so
    /// the default path stays byte-identical to constructing the default planner directly.
    @MainActor
    public func makePlanner(
        selection: String?,
        taskContext: BackendTaskContext,
        usageRecorder: any TaskUsageRecording
    ) throws -> SelectedPlanner {
        let resolution = resolve(selection: selection)
        guard Self.normalize(resolution.provider.id) != Self.normalize(defaultProvider.id) else {
            return SelectedPlanner(
                planner: try defaultProvider.makePlanner(
                    taskContext: taskContext,
                    usageRecorder: usageRecorder
                ),
                provider: defaultProvider,
                fallbackNotice: resolution.fallbackNotice
            )
        }

        do {
            return SelectedPlanner(
                planner: try resolution.provider.makePlanner(
                    taskContext: taskContext,
                    usageRecorder: usageRecorder
                ),
                provider: resolution.provider,
                fallbackNotice: nil
            )
        } catch {
            return SelectedPlanner(
                planner: try defaultProvider.makePlanner(
                    taskContext: taskContext,
                    usageRecorder: usageRecorder
                ),
                provider: defaultProvider,
                fallbackNotice: "The \(resolution.provider.displayName) planner isn't available, "
                    + "so Sonny used \(defaultProvider.displayName) instead. "
                    + "(\(error.localizedDescription))"
            )
        }
    }

    private static func normalize(_ id: String) -> String {
        id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

extension PlannerProviderRegistry {
    /// The shipped registry. The default planner is the one that runs through Sonny's backend; the
    /// Cerebras-served open-weights planner is the explicitly-selectable A/B alternate (SONNY-86).
    /// No flip logic exists anywhere — changing the default is a founder decision, not a code path.
    ///
    /// **A function of the backend client rather than a `static let`** (SONNY-130): the default
    /// provider constructs a planner that talks to Sonny's backend, and there is exactly one client
    /// in the process. Taking it here rather than reaching for a shared instance is the same rule
    /// `SonnyBackendClient.init` states for its own token store — the shared thing is passed, never
    /// defaulted, so no call site can acquire it by saying nothing.
    public static func `default`(client: SonnyBackendClient) -> PlannerProviderRegistry {
        var registry = PlannerProviderRegistry(defaultProvider: OpenAIPlanner.provider(client: client))
        registry.register(CerebrasPlanner.provider)
        return registry
    }
}
