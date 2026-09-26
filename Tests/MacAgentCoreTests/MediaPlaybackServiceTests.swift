import Foundation
import Testing
@testable import MacAgentCore

@Suite(.serialized)
struct MediaPlaybackServiceTests {
    @Test
    func mediaPlaybackFailureDiagnosisReturnsNilWhenNothingBlocksPlayback() {
        #expect(MediaPlaybackFailureDiagnosis.diagnose(MediaPlaybackBlockers()) == nil)
    }

    @Test
    func mediaPlaybackFailureDiagnosisReportsAuthorizationFirstWhenAllBlockersApply() {
        let blockers = MediaPlaybackBlockers(
            authorizationBlocked: true,
            subscriptionBlocked: true,
            activeDeviceBlocked: true,
            catalogMatchBlocked: true,
            providerOutageBlocked: true
        )

        #expect(MediaPlaybackFailureDiagnosis.diagnose(blockers) == .authorization)
    }

    @Test
    func mediaPlaybackFailureDiagnosisUsesFixedPrecedenceOrder() {
        let expectations: [(MediaPlaybackBlockers, MediaPlaybackFailureReason)] = [
            (
                MediaPlaybackBlockers(authorizationBlocked: true),
                .authorization
            ),
            (
                MediaPlaybackBlockers(subscriptionBlocked: true),
                .subscriptionPremium
            ),
            (
                MediaPlaybackBlockers(activeDeviceBlocked: true),
                .activeDevice
            ),
            (
                MediaPlaybackBlockers(catalogMatchBlocked: true),
                .catalogMatch
            ),
            (
                MediaPlaybackBlockers(providerOutageBlocked: true),
                .providerOutage
            ),
            (
                MediaPlaybackBlockers(subscriptionBlocked: true, activeDeviceBlocked: true),
                .subscriptionPremium
            ),
            (
                MediaPlaybackBlockers(activeDeviceBlocked: true, catalogMatchBlocked: true),
                .activeDevice
            ),
            (
                MediaPlaybackBlockers(catalogMatchBlocked: true, providerOutageBlocked: true),
                .catalogMatch
            )
        ]

        for (blockers, expectedReason) in expectations {
            #expect(MediaPlaybackFailureDiagnosis.diagnose(blockers) == expectedReason)
        }
    }

    @Test
    func unavailableSpotifyProviderFailsAsAuthorizationBlocker() async {
        let result = await UnavailableSpotifyPlaybackProvider().play(spotifyRequest())

        guard case .blocked(let failure) = result else {
            Issue.record("Expected unavailable Spotify provider to block playback.")
            return
        }

        #expect(failure.reason == .authorization)
        #expect(failure.detail == "Spotify playback provider not configured.")
        #expect(MediaPlaybackFailureDiagnosis.diagnose(failure.blockers) == failure.reason)
    }

    @Test
    func unavailableAppleMusicProviderFailsAsAuthorizationBlocker() async {
        let result = await UnavailableAppleMusicPlaybackProvider().play(appleMusicRequest())

        guard case .blocked(let failure) = result else {
            Issue.record("Expected unavailable Apple Music provider to block playback.")
            return
        }

        #expect(failure.reason == .authorization)
        #expect(failure.detail == "Apple Music playback provider not configured.")
        #expect(MediaPlaybackFailureDiagnosis.diagnose(failure.blockers) == failure.reason)
    }

    @Test
    func iTunesSearchReturnsAppleMusicAlbumLink() async throws {
        AppleMusicFixtureURLProtocol.handler = { request in
            #expect(request.url?.path == "/search")
            #expect(request.url?.query?.contains("media=music") == true)
            #expect(request.url?.query?.contains("entity=song") == true)
            #expect(request.url?.query?.contains("limit=25") == true)

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            let body = """
            {
              "resultCount": 1,
              "results": [
                {
                  "artistName": "Drake",
                  "trackId": 1628355395,
                  "trackName": "Jimmy Cooks (feat. 21 Savage)",
                  "trackViewUrl": "https://music.apple.com/us/album/jimmy-cooks-feat-21-savage/1628355391?i=1628355395&uo=4"
                }
              ]
            }
            """
            return (response, Data(body.utf8))
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AppleMusicFixtureURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = ITunesSearchAPIClient(
            session: session,
            baseURL: URL(string: "https://itunes.apple.com")!,
            countryCode: "us"
        )

        let track = try await client.bestTrack(
            for: MediaPlaybackRequest(provider: .appleMusic, title: "Jimmy Cooks", artist: "Drake")
        )

        #expect(track?.title == "Jimmy Cooks (feat. 21 Savage)")
        #expect(track?.artist == "Drake")
        #expect(track?.trackID == 1_628_355_395)
        #expect(track?.albumTrackAppURL.absoluteString.contains("/album/jimmy-cooks-feat-21-savage/1628355391") == true)
        #expect(track?.albumTrackAppURL.absoluteString.contains("i=1628355395") == true)
    }

    @Test
    func iTunesSearchReturnsNilWhenNoResults() async throws {
        AppleMusicFixtureURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(#"{"resultCount":0,"results":[]}"#.utf8))
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AppleMusicFixtureURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = ITunesSearchAPIClient(session: session, countryCode: "us")

        let track = try await client.bestTrack(
            for: MediaPlaybackRequest(provider: .appleMusic, title: "not a song")
        )

        #expect(track == nil)
    }

    @Test
    func iTunesSearchRanksExactArtistAndTitleAboveFirstResult() async throws {
        AppleMusicFixtureURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            let body = """
            {
              "resultCount": 3,
              "results": [
                {
                  "artistName": "Kanye West",
                  "trackId": 1,
                  "trackName": "Wrong Song",
                  "trackViewUrl": "https://music.apple.com/us/album/wrong-song/1?i=1"
                },
                {
                  "artistName": "Other Artist",
                  "trackId": 2,
                  "trackName": "Father",
                  "trackViewUrl": "https://music.apple.com/us/album/father/2?i=2"
                },
                {
                  "artistName": "Kanye West",
                  "trackId": 3,
                  "trackName": "Father Stretch My Hands Pt. 1",
                  "trackViewUrl": "https://music.apple.com/us/album/father-stretch-my-hands-pt-1/3?i=3"
                }
              ]
            }
            """
            return (response, Data(body.utf8))
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AppleMusicFixtureURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = ITunesSearchAPIClient(session: session, countryCode: "us")

        let track = try await client.bestTrack(
            for: MediaPlaybackRequest(provider: .appleMusic, title: "Father", artist: "Kanye West")
        )

        #expect(track?.title == "Father Stretch My Hands Pt. 1")
        #expect(track?.artist == "Kanye West")
        #expect(track?.trackID == 3)
    }

    private func spotifyRequest() -> MediaPlaybackRequest {
        MediaPlaybackRequest(
            provider: .spotify,
            title: "Jimmy Cooks",
            artist: "Drake",
            albumTitle: "Honestly, Nevermind",
            durationMilliseconds: 218_365,
            market: "US"
        )
    }

    private func appleMusicRequest() -> MediaPlaybackRequest {
        MediaPlaybackRequest(
            provider: .appleMusic,
            title: "Good Days",
            artist: "SZA",
            albumTitle: "Good Days - Single",
            durationMilliseconds: 279_204,
            market: "us"
        )
    }

}

private final class AppleMusicFixtureURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: MediaPlaybackError.appleMusicCatalogError("missing fixture"))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
