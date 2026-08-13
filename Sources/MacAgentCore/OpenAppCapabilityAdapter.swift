import Foundation

/// Opens an app by name — **any** app installed on this Mac.
///
/// This adapter held the only hard launch gate in the codebase: `context.appCatalog.resolve` threw
/// `appNotAllowed` for anything outside the twelve-app catalog, and "Figma is not in the allowlisted
/// app catalog." was the sentence a user got for asking to open an app they had installed. C12
/// (ratified 2026-08-12) dissolved that gate: launching an installed app is tier-1, low-authority
/// work, and the membership check was a capability hedge from the era of not "pretending to support
/// arbitrary app automation *yet*". Consent stays where authority actually lives — *controlling* an
/// app (E6, row I) — and nothing about this capability's tier, permissions or gating changed with the
/// gate's removal.
///
/// The type is named for what it does now. Renamed from `OpenAllowlistedAppCapabilityAdapter`, and
/// the capability identifier with it (`local.apps.open-allowlisted-app` -> `local.apps.open-app`),
/// after sweeping for persistence: at `0fdac1c` the string occurred in exactly three places — the
/// descriptor and two in-memory test expectations (`CapabilityRegistryTests.swift:44`,
/// `RiskApprovalTests.swift:97`) — no local store, no `Codable` record, no `UserDefaults` key and no
/// document writes it, so nothing on disk carries the old spelling forward.
public struct OpenAppCapabilityAdapter: CapabilityAdapter {
    public init() {}

    public var metadata: CapabilityMetadata {
        Self.metadata
    }

    public static let metadata = CapabilityMetadata(
        id: descriptor.capabilityID,
        displayName: descriptor.displayName,
        description: descriptor.description,
        operations: descriptor.supportedActions,
        plannerTools: [
            AgentTool(
                operation: .openApp,
                // Every string in this tool reaches the model verbatim through
                // `ToolRegistry.plannerDescription`, and telling it the truth about the open universe
                // is SONNY-83's outcome, not this one's — the planner-prompt goldens are this
                // ticket's never-touch list, and their staying untouched is what proves the boundary
                // held. The runtime widened first on purpose: a model told about an app universe the
                // runtime still refused would be the worse half to ship alone.
                name: "Open allowlisted Mac app",
                description: "Open an app from the local allowlist by human app name. Supported apps: \(MacAppCatalog.default.displayList).",
                requiredFields: ["appName"],
                sideEffects: ["open app"],
                dryRunBehavior: "Show the allowlisted app that would open.",
                examples: ["Open Safari", "Open Spotify", "Launch Apple Music"]
            )
        ],
        requiredPermissions: descriptor.requiredPermissions,
        defaultRiskTier: descriptor.defaultRiskTier
    )

    public static let descriptor = AppWebsiteActionDescriptors.openApp

    public func preview(plan: AgentPlan, context: CapabilityExecutionContext) throws -> [ActionPreview] {
        let spec = try spec(in: plan, context: context)
        return [
            ActionPreview(
                title: "Open the \(spec.app.displayName) app",
                details: [
                    "Bundle: \(spec.app.bundleIdentifier)",
                    // Replaces "Allowed apps: <the twelve>", which described a boundary that no
                    // longer exists. The honest open-universe replacement is not a wider roster but
                    // the fact that took the roster's place: *this* is the bundle on disk that will
                    // start, named before it does. It is also the disclosure that makes launching by
                    // name in an open universe legible — two apps can share a display name, and only
                    // one of them is at this path.
                    "Installed at: \(spec.app.applicationURL.path)"
                ],
                opens: [spec.app.displayName]
            )
        ]
    }

    public func execute(
        plan: AgentPlan,
        context: CapabilityExecutionContext,
        log: @escaping (AgentPhase, String) -> Void
    ) async throws -> AgentRunResult {
        let previews = try preview(plan: plan, context: context)
        let spec = try spec(in: plan, context: context)
        log(.act, "Opening \(spec.app.displayName)")
        try await context.appOpener.open(bundleIdentifier: spec.app.bundleIdentifier)
        log(.summarize, "Opened \(spec.app.displayName)")
        // Says "app" explicitly: a saved workspace can share a name with an app (a workspace called
        // "Slack"), and a bare "Opened Slack." left the user unable to tell which one actually ran.
        // The workspace summary already names itself a workspace.
        return AgentRunResult(plan: plan, previews: previews, summary: "Opened the \(spec.app.displayName) app.")
    }

    private struct AppSpec {
        var app: InstalledApp
    }

    /// Resolution, and the only two ways it can fail now.
    ///
    /// A blank name is still a malformed request. A name nothing installed answers to is a plain
    /// statement about this machine — not a refusal, which is the distinction the whole ticket turns
    /// on. Both are raised here rather than in the resolver, because a resolver that throws would
    /// force every other caller (workspace open, scope keys, the icon resolver, the instant
    /// resolver's ambiguity check) to catch an error none of them treat as one.
    private func spec(in plan: AgentPlan, context: CapabilityExecutionContext) throws -> AppSpec {
        guard let step = plan.steps.first(where: { $0.operation == .openApp }) else {
            throw AgentExecutionError.invalidPlan("open_app step is missing.")
        }
        let requested = step.appName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !requested.isEmpty else {
            throw MacAppError.missingAppName
        }
        guard let app = context.installedAppResolver.resolve(requested) else {
            throw MacAppError.notInstalled(requested)
        }
        return AppSpec(app: app)
    }
}
