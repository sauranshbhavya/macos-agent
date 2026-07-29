import AppKit
import Foundation

public struct MediaPlaybackRequest: Equatable, Sendable {
    public var provider: MediaProvider
    public var title: String
    public var artist: String?
    public var albumTitle: String?
    public var durationMilliseconds: Int?
    public var market: String?
    public var mediaURI: String?

    public init(
        provider: MediaProvider,
        title: String,
        artist: String? = nil,
        albumTitle: String? = nil,
        durationMilliseconds: Int? = nil,
        market: String? = nil,
        mediaURI: String? = nil
    ) {
        self.provider = provider
        self.title = title
        self.artist = artist
        self.albumTitle = albumTitle
        self.durationMilliseconds = durationMilliseconds
        self.market = market
        self.mediaURI = mediaURI
    }

    public var query: String {
        [title, artist]
            .compactMap { value in
                let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed?.isEmpty == false ? trimmed : nil
            }
            .joined(separator: " ")
    }

    public var displayTitle: String {
        if let artist, !artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "\(title) by \(artist)"
        }
        return title
    }
}

@MainActor
public protocol MediaOpening {
    func open(_ request: MediaPlaybackRequest) async throws -> String
}

public struct AppleMusicCatalogTrack: Equatable, Sendable {
    public var title: String
    public var artist: String
    public var trackID: Int64
    public var trackViewURL: URL
    public var countryCode: String

    public init(
        title: String,
        artist: String,
        trackID: Int64,
        trackViewURL: URL,
        countryCode: String
    ) {
        self.title = title
        self.artist = artist
        self.trackID = trackID
        self.trackViewURL = trackViewURL
        self.countryCode = countryCode
    }

    public var albumTrackAppURL: URL {
        guard var components = URLComponents(url: trackViewURL, resolvingAgainstBaseURL: false),
              components.host == "music.apple.com" else {
            return trackViewURL
        }

        components.scheme = "music"
        return components.url ?? trackViewURL
    }
}

public protocol AppleMusicCatalogSearching: Sendable {
    func bestTrack(for request: MediaPlaybackRequest) async throws -> AppleMusicCatalogTrack?
}

public enum MediaPlaybackFailureReason: String, Codable, CaseIterable, Equatable, Sendable {
    case authorization
    case subscriptionPremium = "subscription_premium"
    case activeDevice = "active_device"
    case catalogMatch = "catalog_match"
    case providerOutage = "provider_outage"
}

public struct MediaPlaybackBlockers: Equatable, Sendable {
    public var authorizationBlocked: Bool
    public var subscriptionBlocked: Bool
    public var activeDeviceBlocked: Bool
    public var catalogMatchBlocked: Bool
    public var providerOutageBlocked: Bool

    public init(
        authorizationBlocked: Bool = false,
        subscriptionBlocked: Bool = false,
        activeDeviceBlocked: Bool = false,
        catalogMatchBlocked: Bool = false,
        providerOutageBlocked: Bool = false
    ) {
        self.authorizationBlocked = authorizationBlocked
        self.subscriptionBlocked = subscriptionBlocked
        self.activeDeviceBlocked = activeDeviceBlocked
        self.catalogMatchBlocked = catalogMatchBlocked
        self.providerOutageBlocked = providerOutageBlocked
    }
}

public enum MediaPlaybackFailureDiagnosis {
    public static func diagnose(_ blockers: MediaPlaybackBlockers) -> MediaPlaybackFailureReason? {
        let orderedReasons: [(MediaPlaybackFailureReason, Bool)] = [
            (.authorization, blockers.authorizationBlocked),
            (.subscriptionPremium, blockers.subscriptionBlocked),
            (.activeDevice, blockers.activeDeviceBlocked),
            (.catalogMatch, blockers.catalogMatchBlocked),
            (.providerOutage, blockers.providerOutageBlocked)
        ]

        return orderedReasons.first { $0.1 }?.0
    }
}

public enum MediaPlaybackRoute: String, Codable, Equatable, Sendable {
    case search
    case play
    case transferPlayback = "transfer_playback"
    case fallbackOpen = "fallback_open"
}

public struct MediaPlaybackRoutePreview: Equatable, Sendable {
    public var route: MediaPlaybackRoute
    public var detail: String
    public var failureReason: MediaPlaybackFailureReason?

    public init(
        route: MediaPlaybackRoute,
        detail: String,
        failureReason: MediaPlaybackFailureReason? = nil
    ) {
        self.route = route
        self.detail = detail
        self.failureReason = failureReason
    }
}

public struct SpotifyTrackCandidate: Equatable, Sendable {
    public var uri: String
    public var title: String
    public var artists: [String]
    public var albumTitle: String?
    public var durationMilliseconds: Int?
    public var availableMarkets: [String]

    public init(
        uri: String,
        title: String,
        artists: [String],
        albumTitle: String? = nil,
        durationMilliseconds: Int? = nil,
        availableMarkets: [String] = []
    ) {
        self.uri = uri
        self.title = title
        self.artists = artists
        self.albumTitle = albumTitle
        self.durationMilliseconds = durationMilliseconds
        self.availableMarkets = availableMarkets
    }

    public var artistDisplayName: String {
        artists.joined(separator: ", ")
    }
}

public struct SpotifyPlaybackDevice: Equatable, Sendable {
    public var id: String
    public var name: String
    public var isActive: Bool
    public var isTransferable: Bool

    public init(
        id: String,
        name: String,
        isActive: Bool,
        isTransferable: Bool = true
    ) {
        self.id = id
        self.name = name
        self.isActive = isActive
        self.isTransferable = isTransferable
    }
}

public enum SpotifyProviderStatus: String, Codable, Equatable, Sendable {
    case available
    case outage
    case rateLimited = "rate_limited"
}

public struct SpotifyPlaybackState: Equatable, Sendable {
    public var isAuthorized: Bool
    public var hasPremium: Bool
    public var devices: [SpotifyPlaybackDevice]
    public var candidates: [SpotifyTrackCandidate]
    public var providerStatus: SpotifyProviderStatus

    public init(
        isAuthorized: Bool,
        hasPremium: Bool,
        devices: [SpotifyPlaybackDevice],
        candidates: [SpotifyTrackCandidate],
        providerStatus: SpotifyProviderStatus = .available
    ) {
        self.isAuthorized = isAuthorized
        self.hasPremium = hasPremium
        self.devices = devices
        self.candidates = candidates
        self.providerStatus = providerStatus
    }
}

public enum SpotifyPlaybackAction: Equatable, Sendable {
    case play(uri: String, deviceID: String)
    case transferAndPlay(uri: String, deviceID: String)
}

public struct SpotifyPlaybackStart: Equatable, Sendable {
    public var action: SpotifyPlaybackAction
    public var track: SpotifyTrackCandidate
    public var device: SpotifyPlaybackDevice

    public init(action: SpotifyPlaybackAction, track: SpotifyTrackCandidate, device: SpotifyPlaybackDevice) {
        self.action = action
        self.track = track
        self.device = device
    }
}

public struct SpotifyPlaybackFailure: Equatable, Sendable {
    public var blockers: MediaPlaybackBlockers
    public var reason: MediaPlaybackFailureReason
    public var detail: String
    public var matchedTrack: SpotifyTrackCandidate?

    public init(
        blockers: MediaPlaybackBlockers,
        detail: String,
        matchedTrack: SpotifyTrackCandidate? = nil
    ) {
        self.blockers = blockers
        self.reason = MediaPlaybackFailureDiagnosis.diagnose(blockers) ?? .providerOutage
        self.detail = detail
        self.matchedTrack = matchedTrack
    }
}

public enum SpotifyPlaybackResult: Equatable, Sendable {
    case started(SpotifyPlaybackStart)
    case blocked(SpotifyPlaybackFailure)
}

@MainActor
public protocol SpotifyPlaybackProviding {
    func preview(_ request: MediaPlaybackRequest) -> MediaPlaybackRoutePreview
    func play(_ request: MediaPlaybackRequest) async -> SpotifyPlaybackResult
}

public struct UnavailableSpotifyPlaybackProvider: SpotifyPlaybackProviding {
    public init() {}

    public func preview(_ request: MediaPlaybackRequest) -> MediaPlaybackRoutePreview {
        MediaPlaybackRoutePreview(
            route: .fallbackOpen,
            detail: "Spotify playback provider not configured.",
            failureReason: .authorization
        )
    }

    public func play(_ request: MediaPlaybackRequest) async -> SpotifyPlaybackResult {
        .blocked(
            SpotifyPlaybackFailure(
                blockers: MediaPlaybackBlockers(authorizationBlocked: true),
                detail: "Spotify playback provider not configured."
            )
        )
    }
}

public enum SpotifyPlaybackResolver {
    public static func preview(
        request: MediaPlaybackRequest,
        state: SpotifyPlaybackState
    ) -> MediaPlaybackRoutePreview {
        switch resolve(request: request, state: state) {
        case .started(let start):
            switch start.action {
            case .play:
                return MediaPlaybackRoutePreview(
                    route: .play,
                    detail: "Spotify can play \(start.track.title) on \(start.device.name)."
                )
            case .transferAndPlay:
                return MediaPlaybackRoutePreview(
                    route: .transferPlayback,
                    detail: "Spotify can transfer playback to \(start.device.name), then play \(start.track.title)."
                )
            }
        case .blocked(let failure):
            return MediaPlaybackRoutePreview(
                route: .fallbackOpen,
                detail: failure.detail,
                failureReason: failure.reason
            )
        }
    }

    public static func resolve(
        request: MediaPlaybackRequest,
        state: SpotifyPlaybackState
    ) -> SpotifyPlaybackResult {
        let matchedTrack = bestTrack(for: request, in: state.candidates)
        let targetDevice = playbackDevice(in: state.devices)
        let blockers = MediaPlaybackBlockers(
            authorizationBlocked: !state.isAuthorized,
            subscriptionBlocked: !state.hasPremium,
            activeDeviceBlocked: targetDevice == nil,
            catalogMatchBlocked: matchedTrack == nil,
            providerOutageBlocked: state.providerStatus != .available
        )

        if MediaPlaybackFailureDiagnosis.diagnose(blockers) != nil {
            return .blocked(
                SpotifyPlaybackFailure(
                    blockers: blockers,
                    detail: failureDetail(for: state.providerStatus),
                    matchedTrack: matchedTrack
                )
            )
        }

        guard let matchedTrack, let targetDevice else {
            return .blocked(
                SpotifyPlaybackFailure(
                    blockers: MediaPlaybackBlockers(providerOutageBlocked: true),
                    detail: "Spotify playback could not be resolved."
                )
            )
        }

        let action: SpotifyPlaybackAction = targetDevice.isActive
            ? .play(uri: matchedTrack.uri, deviceID: targetDevice.id)
            : .transferAndPlay(uri: matchedTrack.uri, deviceID: targetDevice.id)
        return .started(SpotifyPlaybackStart(action: action, track: matchedTrack, device: targetDevice))
    }

    public static func bestTrack(
        for request: MediaPlaybackRequest,
        in candidates: [SpotifyTrackCandidate]
    ) -> SpotifyTrackCandidate? {
        MediaSearchMatcher.best(
            in: candidates,
            request: request,
            title: \.title,
            artist: { $0.artists.joined(separator: " ") },
            albumTitle: \.albumTitle,
            durationMilliseconds: \.durationMilliseconds,
            availableMarkets: \.availableMarkets
        )
    }

    private static func playbackDevice(in devices: [SpotifyPlaybackDevice]) -> SpotifyPlaybackDevice? {
        devices.first(where: \.isActive) ?? devices.first(where: \.isTransferable)
    }

    private static func failureDetail(for providerStatus: SpotifyProviderStatus) -> String {
        switch providerStatus {
        case .available:
            return "Spotify playback requirements were not met."
        case .outage:
            return "Spotify playback is currently unavailable."
        case .rateLimited:
            return "Spotify playback is currently rate-limited."
        }
    }
}

public struct AppleMusicTrackCandidate: Equatable, Sendable {
    public var catalogID: String
    public var title: String
    public var artist: String
    public var albumTitle: String?
    public var durationMilliseconds: Int?
    public var storefronts: [String]
    public var url: URL?

    public init(
        catalogID: String,
        title: String,
        artist: String,
        albumTitle: String? = nil,
        durationMilliseconds: Int? = nil,
        storefronts: [String] = [],
        url: URL? = nil
    ) {
        self.catalogID = catalogID
        self.title = title
        self.artist = artist
        self.albumTitle = albumTitle
        self.durationMilliseconds = durationMilliseconds
        self.storefronts = storefronts
        self.url = url
    }
}

public enum AppleMusicProviderStatus: String, Codable, Equatable, Sendable {
    case available
    case outage
}

public struct AppleMusicPlaybackState: Equatable, Sendable {
    public var isAuthorized: Bool
    public var hasSubscription: Bool
    public var candidates: [AppleMusicTrackCandidate]
    public var providerStatus: AppleMusicProviderStatus

    public init(
        isAuthorized: Bool,
        hasSubscription: Bool,
        candidates: [AppleMusicTrackCandidate],
        providerStatus: AppleMusicProviderStatus = .available
    ) {
        self.isAuthorized = isAuthorized
        self.hasSubscription = hasSubscription
        self.candidates = candidates
        self.providerStatus = providerStatus
    }
}

public enum AppleMusicPlaybackAction: Equatable, Sendable {
    case queueAndPlay(catalogID: String)
}

public struct AppleMusicPlaybackStart: Equatable, Sendable {
    public var action: AppleMusicPlaybackAction
    public var track: AppleMusicTrackCandidate

    public init(action: AppleMusicPlaybackAction, track: AppleMusicTrackCandidate) {
        self.action = action
        self.track = track
    }
}

public struct AppleMusicPlaybackFailure: Equatable, Sendable {
    public var blockers: MediaPlaybackBlockers
    public var reason: MediaPlaybackFailureReason
    public var detail: String
    public var matchedTrack: AppleMusicTrackCandidate?

    public init(
        blockers: MediaPlaybackBlockers,
        detail: String,
        matchedTrack: AppleMusicTrackCandidate? = nil
    ) {
        self.blockers = blockers
        self.reason = MediaPlaybackFailureDiagnosis.diagnose(blockers) ?? .providerOutage
        self.detail = detail
        self.matchedTrack = matchedTrack
    }
}

public enum AppleMusicPlaybackResult: Equatable, Sendable {
    case started(AppleMusicPlaybackStart)
    case blocked(AppleMusicPlaybackFailure)
}

@MainActor
public protocol AppleMusicPlaybackProviding {
    func preview(_ request: MediaPlaybackRequest) -> MediaPlaybackRoutePreview
    func play(_ request: MediaPlaybackRequest) async -> AppleMusicPlaybackResult
}

public struct UnavailableAppleMusicPlaybackProvider: AppleMusicPlaybackProviding {
    public init() {}

    public func preview(_ request: MediaPlaybackRequest) -> MediaPlaybackRoutePreview {
        MediaPlaybackRoutePreview(
            route: .fallbackOpen,
            detail: "Apple Music playback provider not configured.",
            failureReason: .authorization
        )
    }

    public func play(_ request: MediaPlaybackRequest) async -> AppleMusicPlaybackResult {
        .blocked(
            AppleMusicPlaybackFailure(
                blockers: MediaPlaybackBlockers(authorizationBlocked: true),
                detail: "Apple Music playback provider not configured."
            )
        )
    }
}

public enum AppleMusicPlaybackResolver {
    public static func preview(
        request: MediaPlaybackRequest,
        state: AppleMusicPlaybackState
    ) -> MediaPlaybackRoutePreview {
        switch resolve(request: request, state: state) {
        case .started(let start):
            return MediaPlaybackRoutePreview(
                route: .play,
                detail: "Apple Music can queue and play \(start.track.title)."
            )
        case .blocked(let failure):
            return MediaPlaybackRoutePreview(
                route: .fallbackOpen,
                detail: failure.detail,
                failureReason: failure.reason
            )
        }
    }

    public static func resolve(
        request: MediaPlaybackRequest,
        state: AppleMusicPlaybackState
    ) -> AppleMusicPlaybackResult {
        let matchedTrack = bestTrack(for: request, in: state.candidates)
        let blockers = MediaPlaybackBlockers(
            authorizationBlocked: !state.isAuthorized,
            subscriptionBlocked: !state.hasSubscription,
            catalogMatchBlocked: matchedTrack == nil,
            providerOutageBlocked: state.providerStatus != .available
        )

        if MediaPlaybackFailureDiagnosis.diagnose(blockers) != nil {
            return .blocked(
                AppleMusicPlaybackFailure(
                    blockers: blockers,
                    detail: failureDetail(for: state.providerStatus),
                    matchedTrack: matchedTrack
                )
            )
        }

        guard let matchedTrack else {
            return .blocked(
                AppleMusicPlaybackFailure(
                    blockers: MediaPlaybackBlockers(providerOutageBlocked: true),
                    detail: "Apple Music playback could not be resolved."
                )
            )
        }

        return .started(
            AppleMusicPlaybackStart(
                action: .queueAndPlay(catalogID: matchedTrack.catalogID),
                track: matchedTrack
            )
        )
    }

    public static func bestTrack(
        for request: MediaPlaybackRequest,
        in candidates: [AppleMusicTrackCandidate]
    ) -> AppleMusicTrackCandidate? {
        MediaSearchMatcher.best(
            in: candidates,
            request: request,
            title: \.title,
            artist: \.artist,
            albumTitle: \.albumTitle,
            durationMilliseconds: \.durationMilliseconds,
            availableMarkets: \.storefronts
        )
    }

    private static func failureDetail(for providerStatus: AppleMusicProviderStatus) -> String {
        switch providerStatus {
        case .available:
            return "Apple Music playback requirements were not met."
        case .outage:
            return "Apple Music playback is currently unavailable."
        }
    }
}

public enum MediaPlaybackError: Error, LocalizedError, Equatable {
    case missingProvider
    case missingTitle
    case invalidProviderURI(String)
    case appleMusicCatalogError(String)
    case openFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingProvider:
            return "Opening music requires Apple Music or Spotify."
        case .missingTitle:
            return "Opening music requires a song or album title."
        case .invalidProviderURI(let uri):
            return "\(uri) is not a supported Apple Music or Spotify URL."
        case .appleMusicCatalogError(let detail):
            return "Apple Music catalog search failed: \(detail)"
        case .openFailed(let detail):
            return "Opening music result failed: \(detail)"
        }
    }
}

public struct ITunesSearchAPIClient: AppleMusicCatalogSearching {
    private let session: URLSession
    private let baseURL: URL
    private let countryCode: String

    public init(
        session: URLSession = .shared,
        baseURL: URL = URL(string: "https://itunes.apple.com")!,
        countryCode: String = Locale.current.region?.identifier.lowercased() ?? "us"
    ) {
        self.session = session
        self.baseURL = baseURL
        self.countryCode = countryCode
    }

    public func bestTrack(for request: MediaPlaybackRequest) async throws -> AppleMusicCatalogTrack? {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("search"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "term", value: request.query),
            URLQueryItem(name: "country", value: countryCode),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "25")
        ]

        guard let url = components.url else {
            throw MediaPlaybackError.appleMusicCatalogError("Could not build Apple Music search URL.")
        }

        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "<unreadable response>"
            throw MediaPlaybackError.appleMusicCatalogError(body)
        }

        let decoded = try JSONDecoder().decode(ITunesSearchResponse.self, from: data)
        guard let result = MediaSearchMatcher.best(
            in: decoded.results,
            request: request,
            title: \.trackName,
            artist: \.artistName
        ),
            let url = URL(string: result.trackViewURL) else {
            return nil
        }

        return AppleMusicCatalogTrack(
            title: result.trackName,
            artist: result.artistName,
            trackID: result.trackID,
            trackViewURL: url,
            countryCode: countryCode
        )
    }

    private struct ITunesSearchResponse: Decodable {
        var results: [Result]

        struct Result: Decodable {
            var artistName: String
            var trackID: Int64
            var trackName: String
            var trackViewURL: String

            enum CodingKeys: String, CodingKey {
                case artistName
                case trackID = "trackId"
                case trackName
                case trackViewURL = "trackViewUrl"
            }
        }
    }
}

enum MediaSearchMatcher {
    static func best<Candidate>(
        in candidates: [Candidate],
        request: MediaPlaybackRequest,
        title: (Candidate) -> String,
        artist: (Candidate) -> String,
        albumTitle: ((Candidate) -> String?)? = nil,
        durationMilliseconds: ((Candidate) -> Int?)? = nil,
        availableMarkets: ((Candidate) -> [String])? = nil
    ) -> Candidate? {
        candidates
            .enumerated()
            .compactMap { offset, candidate -> (candidate: Candidate, score: Int, offset: Int)? in
                guard let score = score(
                    candidateTitle: title(candidate),
                    candidateArtist: artist(candidate),
                    candidateAlbumTitle: albumTitle?(candidate),
                    candidateDurationMilliseconds: durationMilliseconds?(candidate),
                    candidateAvailableMarkets: availableMarkets?(candidate) ?? [],
                    request: request
                ) else {
                    return nil
                }
                return (candidate, score, offset)
            }
            .sorted { first, second in
                if first.score == second.score {
                    return first.offset < second.offset
                }
                return first.score > second.score
            }
            .first?
            .candidate
    }

    private static func score(
        candidateTitle: String,
        candidateArtist: String,
        candidateAlbumTitle: String?,
        candidateDurationMilliseconds: Int?,
        candidateAvailableMarkets: [String],
        request: MediaPlaybackRequest
    ) -> Int? {
        guard let titleScore = titleScore(candidateTitle: candidateTitle, requestedTitle: request.title) else {
            return nil
        }

        let matchedArtistScore: Int
        if let requestedArtist = request.artist?.trimmingCharacters(in: .whitespacesAndNewlines),
           !requestedArtist.isEmpty {
            guard let score = artistScore(candidateArtist: candidateArtist, requestedArtist: requestedArtist) else {
                return nil
            }
            matchedArtistScore = score
        } else {
            matchedArtistScore = 0
        }

        guard let marketScore = marketScore(
            candidateMarkets: candidateAvailableMarkets,
            requestedMarket: request.market
        ) else {
            return nil
        }

        return titleScore +
            matchedArtistScore +
            albumScore(candidateAlbumTitle: candidateAlbumTitle, requestedAlbumTitle: request.albumTitle) +
            durationScore(
                candidateDurationMilliseconds: candidateDurationMilliseconds,
                requestedDurationMilliseconds: request.durationMilliseconds
            ) +
            marketScore
    }

    private static func titleScore(candidateTitle: String, requestedTitle: String) -> Int? {
        let candidate = normalize(candidateTitle)
        let requested = normalize(requestedTitle)
        guard !candidate.isEmpty, !requested.isEmpty else {
            return nil
        }

        if candidate == requested {
            return 100
        }
        if candidate.hasPrefix(requested + " ") {
            return 92
        }
        if candidate.contains(" " + requested + " ") ||
            candidate.hasSuffix(" " + requested) {
            return 86
        }

        let requestedTokens = tokens(requested)
        let candidateTokens = Set(tokens(candidate))
        guard !requestedTokens.isEmpty,
              requestedTokens.allSatisfy({ candidateTokens.contains($0) }) else {
            return nil
        }

        return requestedTokens.count == 1 ? 68 : 76
    }

    private static func artistScore(candidateArtist: String, requestedArtist: String) -> Int? {
        let candidate = normalize(candidateArtist)
        let requested = normalize(requestedArtist)
        guard !candidate.isEmpty, !requested.isEmpty else {
            return nil
        }

        if candidate == requested {
            return 60
        }
        if candidate.contains(requested) || requested.contains(candidate) {
            return 46
        }

        let requestedTokens = tokens(requested)
        let candidateTokens = Set(tokens(candidate))
        guard !requestedTokens.isEmpty,
              requestedTokens.allSatisfy({ candidateTokens.contains($0) }) else {
            return nil
        }
        return 34
    }

    private static func albumScore(candidateAlbumTitle: String?, requestedAlbumTitle: String?) -> Int {
        guard let candidateAlbumTitle,
              let requestedAlbumTitle,
              !requestedAlbumTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return 0
        }

        let candidate = normalize(candidateAlbumTitle)
        let requested = normalize(requestedAlbumTitle)
        guard !candidate.isEmpty, !requested.isEmpty else {
            return 0
        }

        if candidate == requested {
            return 32
        }
        if candidate.contains(requested) || requested.contains(candidate) {
            return 24
        }

        let requestedTokens = tokens(requested)
        let candidateTokens = Set(tokens(candidate))
        guard !requestedTokens.isEmpty,
              requestedTokens.allSatisfy({ candidateTokens.contains($0) }) else {
            return -10
        }
        return 18
    }

    private static func durationScore(
        candidateDurationMilliseconds: Int?,
        requestedDurationMilliseconds: Int?
    ) -> Int {
        guard let candidateDurationMilliseconds,
              let requestedDurationMilliseconds,
              candidateDurationMilliseconds > 0,
              requestedDurationMilliseconds > 0 else {
            return 0
        }

        let difference = abs(candidateDurationMilliseconds - requestedDurationMilliseconds)
        if difference <= 2_000 {
            return 24
        }
        if difference <= 5_000 {
            return 18
        }
        if difference <= 15_000 {
            return 8
        }
        if difference > 30_000 {
            return -16
        }
        return 0
    }

    private static func marketScore(candidateMarkets: [String], requestedMarket: String?) -> Int? {
        guard let requestedMarket,
              !requestedMarket.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return 0
        }

        let normalizedRequestedMarket = requestedMarket
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        let normalizedCandidateMarkets = Set(candidateMarkets.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        }.filter { !$0.isEmpty })
        guard !normalizedCandidateMarkets.isEmpty else {
            return 0
        }

        return normalizedCandidateMarkets.contains(normalizedRequestedMarket) ? 20 : nil
    }

    private static func normalize(_ value: String) -> String {
        let folded = value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()

        var scalars: [UnicodeScalar] = []
        var previousWasSeparator = true
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                scalars.append(scalar)
                previousWasSeparator = false
            } else if !previousWasSeparator {
                scalars.append(" ")
                previousWasSeparator = true
            }
        }

        return String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func tokens(_ normalizedValue: String) -> [String] {
        normalizedValue
            .split(separator: " ")
            .map(String.init)
            .filter { !$0.isEmpty }
    }
}

public struct NativeMediaOpener: MediaOpening {
    private let appleMusicSearcher: AppleMusicCatalogSearching

    public init(appleMusicSearcher: AppleMusicCatalogSearching = ITunesSearchAPIClient()) {
        self.appleMusicSearcher = appleMusicSearcher
    }

    @MainActor
    public func open(_ request: MediaPlaybackRequest) async throws -> String {
        switch request.provider {
        case .appleMusic:
            return try await openAppleMusic(request)
        case .spotify:
            return try openSpotify(request)
        }
    }

    @MainActor
    private func openAppleMusic(_ request: MediaPlaybackRequest) async throws -> String {
        if let url = try providerURL(from: request.mediaURI, provider: .appleMusic) {
            try openURL(url, failureMessage: "Could not open Apple Music URL.")
            return "Opened Apple Music result for \(request.displayTitle)."
        }

        // Only the catalog search is guarded here. Opening the found track must stay outside the
        // catch, or a failed open gets reported as "catalog lookup failed" even though the
        // lookup succeeded — and the real openFailed detail is lost.
        let track: AppleMusicCatalogTrack?
        do {
            track = try await appleMusicSearcher.bestTrack(for: request)
        } catch {
            let searchURL = appleMusicSearchURL(query: request.query)
            try openURL(searchURL, failureMessage: "Could not open Apple Music search.")
            return "Apple Music catalog lookup failed, so Sonny opened search for \(request.displayTitle)."
        }

        if let track {
            try openURL(track.albumTrackAppURL, failureMessage: "Could not open Apple Music catalog result.")
            return "Opened Apple Music album result for \(track.title) by \(track.artist)."
        }

        let searchURL = appleMusicSearchURL(query: request.query)
        try openURL(searchURL, failureMessage: "Could not open Apple Music search.")
        return "Opened Apple Music search for \(request.displayTitle)."
    }

    @MainActor
    private func openSpotify(_ request: MediaPlaybackRequest) throws -> String {
        if let url = try providerURL(from: request.mediaURI, provider: .spotify) {
            try openURL(url, failureMessage: "Could not open Spotify URL.")
            return "Opened Spotify result for \(request.displayTitle)."
        }

        let url = spotifySearchURL(query: request.query)
        try openURL(url, failureMessage: "Could not open Spotify search.")
        return "Opened Spotify search for \(request.displayTitle)."
    }

    private func providerURL(from rawURI: String?, provider: MediaProvider) throws -> URL? {
        guard let rawURI = rawURI?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawURI.isEmpty else {
            return nil
        }

        guard let url = URL(string: rawURI) else {
            throw MediaPlaybackError.invalidProviderURI(rawURI)
        }

        switch provider {
        case .appleMusic:
            guard rawURI.hasPrefix("music://music.apple.com/") ||
                rawURI.hasPrefix("https://music.apple.com/") else {
                throw MediaPlaybackError.invalidProviderURI(rawURI)
            }
        case .spotify:
            guard rawURI.hasPrefix("spotify:track:") ||
                rawURI.hasPrefix("spotify:album:") ||
                rawURI.hasPrefix("https://open.spotify.com/track/") ||
                rawURI.hasPrefix("https://open.spotify.com/album/") else {
                throw MediaPlaybackError.invalidProviderURI(rawURI)
            }
        }

        return url
    }

    @MainActor
    private func openURL(_ url: URL, failureMessage: String) throws {
        guard NSWorkspace.shared.open(url) else {
            throw MediaPlaybackError.openFailed(failureMessage)
        }
    }

    private func spotifySearchURL(query: String) -> URL {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        return URL(string: "spotify:search:\(encoded)")!
    }

    private func appleMusicSearchURL(query: String) -> URL {
        let countryCode = Locale.current.region?.identifier.lowercased() ?? "us"
        var components = URLComponents()
        components.scheme = "music"
        components.host = "music.apple.com"
        components.path = "/\(countryCode)/search"
        components.queryItems = [
            URLQueryItem(name: "term", value: query)
        ]
        return components.url!
    }
}
