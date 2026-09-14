import Foundation

public struct OpenMediaResultCapabilityAdapter: CapabilityAdapter {
    public init() {}

    public var metadata: CapabilityMetadata {
        Self.metadata
    }

    public static let metadata = CapabilityMetadata(
        id: "local.media.open-result",
        displayName: "Play or open music",
        description: "Try provider-aware Apple Music or Spotify playback, falling back to opening the provider result or search.",
        operations: [.playMedia],
        plannerTools: [
            AgentTool(
                operation: .playMedia,
                name: "Play or open music",
                description: "Try to play a requested song or album in Apple Music or Spotify through the provider playback seam. If playback is unavailable, open the exact provider result URI when supplied, or open the provider search/result fallback.",
                requiredFields: ["mediaProvider", "mediaTitle"],
                sideEffects: ["play or open music app"],
                dryRunBehavior: "Show whether Sonny would search, play, transfer playback, or fall back to opening without starting playback or opening an app.",
                examples: [
                    "Play Jimmy Cooks by Drake on Apple Music",
                    "Play Bad Habit by Steve Lacy on Spotify"
                ]
            )
        ],
        requiredPermissions: [
            CapabilityPermissionMetadata(requirement: .appOpening),
            CapabilityPermissionMetadata(requirement: .networkAccess)
        ],
        defaultRiskTier: .tier1
    )

    public func preview(plan: AgentPlan, context: CapabilityExecutionContext) throws -> [ActionPreview] {
        let spec = try mediaSpec(plan)
        let routePreview = playbackPreview(for: spec.request, context: context)
        return [
            ActionPreview(
                title: "Play \(spec.request.displayTitle)",
                details: [
                    "Provider: \(spec.request.provider.displayName)",
                    "Playback route: \(routeLabel(routePreview.route))",
                    routePreview.detail,
                    fallbackBehaviorDescription(for: spec.request)
                ],
                opens: [spec.request.provider.displayName]
            )
        ]
    }

    public func execute(
        plan: AgentPlan,
        context: CapabilityExecutionContext,
        log: @escaping (AgentPhase, String) -> Void
    ) async throws -> AgentRunResult {
        let previews = try preview(plan: plan, context: context)
        let spec = try mediaSpec(plan)
        log(.act, "Trying \(spec.request.provider.displayName) playback for \(spec.request.displayTitle)")
        let summary: String
        switch spec.request.provider {
        case .appleMusic:
            let playback = await context.appleMusicPlaybackProvider.play(spec.request)
            summary = try await playbackSummary(
                for: playback,
                request: spec.request,
                context: context,
                log: log
            )
        case .spotify:
            let playback = await context.spotifyPlaybackProvider.play(spec.request)
            summary = try await playbackSummary(
                for: playback,
                request: spec.request,
                context: context,
                log: log
            )
        }
        log(.summarize, summary)
        // Every playback sentence quotes what the provider returned — a catalogue's track and artist
        // names, which whoever published the track wrote, or the provider's own failure detail
        // (SONNY-491).
        return AgentRunResult(plan: plan, previews: previews, summary: summary, summaryProvenance: .outsideAuthored)
    }

    private struct MediaSpec {
        var request: MediaPlaybackRequest
    }

    private func mediaSpec(_ plan: AgentPlan) throws -> MediaSpec {
        guard let step = plan.steps.first(where: { $0.operation == .playMedia }) else {
            throw AgentExecutionError.invalidPlan("play_media step is missing.")
        }
        guard let provider = step.mediaProvider else {
            throw MediaPlaybackError.missingProvider
        }
        guard let rawTitle = step.mediaTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawTitle.isEmpty else {
            throw MediaPlaybackError.missingTitle
        }

        let artist = step.mediaArtist?.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = MediaPlaybackRequest(
            provider: provider,
            title: rawTitle,
            artist: artist?.isEmpty == false ? artist : nil,
            mediaURI: step.targetURL
        )

        return MediaSpec(request: request)
    }

    @MainActor
    private func playbackPreview(
        for request: MediaPlaybackRequest,
        context: CapabilityExecutionContext
    ) -> MediaPlaybackRoutePreview {
        switch request.provider {
        case .appleMusic:
            return context.appleMusicPlaybackProvider.preview(request)
        case .spotify:
            return context.spotifyPlaybackProvider.preview(request)
        }
    }

    private func fallbackBehaviorDescription(for request: MediaPlaybackRequest) -> String {
        switch request.provider {
        case .appleMusic:
            if let mediaURI = request.mediaURI, !mediaURI.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Fallback: open the supplied Apple Music result URI."
            }
            return "Fallback: open the best matching Apple Music catalog result, or Apple Music search if no match is found."
        case .spotify:
            if let mediaURI = request.mediaURI, !mediaURI.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Fallback: open the supplied Spotify result URI."
            }
            return "Fallback: open Spotify search for the requested song or album."
        }
    }

    private func routeLabel(_ route: MediaPlaybackRoute) -> String {
        switch route {
        case .search:
            return "search"
        case .play:
            return "play"
        case .transferPlayback:
            return "transfer-playback"
        case .fallbackOpen:
            return "fallback-open"
        }
    }

    @MainActor
    private func playbackSummary(
        for playback: SpotifyPlaybackResult,
        request: MediaPlaybackRequest,
        context: CapabilityExecutionContext,
        log: @escaping (AgentPhase, String) -> Void
    ) async throws -> String {
        switch playback {
        case .started(let start):
            switch start.action {
            case .play:
                return "Started Spotify playback for \(start.track.title) by \(start.track.artistDisplayName)."
            case .transferAndPlay:
                return "Transferred Spotify playback to \(start.device.name) and started \(start.track.title) by \(start.track.artistDisplayName)."
            }
        case .blocked(let failure):
            return try await fallbackSummary(
                provider: .spotify,
                reason: failure.reason,
                detail: failure.detail,
                request: request,
                context: context,
                log: log
            )
        }
    }

    @MainActor
    private func playbackSummary(
        for playback: AppleMusicPlaybackResult,
        request: MediaPlaybackRequest,
        context: CapabilityExecutionContext,
        log: @escaping (AgentPhase, String) -> Void
    ) async throws -> String {
        switch playback {
        case .started(let start):
            return "Started Apple Music playback for \(start.track.title) by \(start.track.artist)."
        case .blocked(let failure):
            return try await fallbackSummary(
                provider: .appleMusic,
                reason: failure.reason,
                detail: failure.detail,
                request: request,
                context: context,
                log: log
            )
        }
    }

    @MainActor
    private func fallbackSummary(
        provider: MediaProvider,
        reason: MediaPlaybackFailureReason,
        detail: String,
        request: MediaPlaybackRequest,
        context: CapabilityExecutionContext,
        log: @escaping (AgentPhase, String) -> Void
    ) async throws -> String {
        log(.observe, "\(provider.displayName) playback blocked: \(reasonLabel(reason))")
        log(.act, "Opening \(provider.displayName) fallback for \(request.displayTitle)")
        let fallback = try await context.mediaOpener.open(request)
        return "\(provider.displayName) playback unavailable (\(reasonLabel(reason))): \(detail) Fallback result: \(fallback)"
    }

    private func reasonLabel(_ reason: MediaPlaybackFailureReason) -> String {
        switch reason {
        case .authorization:
            return "authorization"
        case .subscriptionPremium:
            return "subscription/Premium"
        case .activeDevice:
            return "active device"
        case .catalogMatch:
            return "catalog match"
        case .providerOutage:
            return "provider outage"
        }
    }
}
