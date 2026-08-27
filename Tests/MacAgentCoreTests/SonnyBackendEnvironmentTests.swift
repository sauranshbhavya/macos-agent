import Foundation
import Testing
@testable import MacAgentCore

/// Where a build sends requests, and the debug-only pointer that moves it.
///
/// This suite runs in a debug build, which is the only configuration a test process is ever built
/// in — so it can show that the override *works*, and it cannot show that a release build ignores
/// it. That half is the compiler's, and it is demonstrated two other ways: the override's keys and
/// its reader are declared inside `#if DEBUG`, which `SignInReleaseSwitchScanTests` holds as a
/// population, and neither key survives `swift build -c release` into the product's `strings`.
@Suite
struct SonnyBackendEnvironmentTests {
    #if DEBUG
    @Test
    func theEnvironmentVariableOverridePointsTheBuildAtItsValue() {
        let resolved = SonnyBackendHost.resolve(
            environment: [SonnyBackendHost.overrideEnvironmentVariable: "http://127.0.0.1:8080"],
            defaultsValue: { _ in nil }
        )

        #expect(resolved?.baseURL.absoluteString == "http://127.0.0.1:8080")
        #expect(resolved?.source == .debugOverride)
    }

    /// The pointer a founder actually uses for the manual pass. **An environment variable cannot be
    /// the only form**: the Screen Recording grant relaunches the app through `/usr/bin/open -n`,
    /// which starts the new process from launchd's environment rather than the terminal's, so a
    /// variable set for a debug run is gone at exactly the moment this ticket needs the app to come
    /// back working. A `defaults write` survives that, and survives a launch from Finder.
    @Test
    func theUserDefaultsOverrideIsUsedWhenNoEnvironmentVariableIsSet() {
        let resolved = SonnyBackendHost.resolve(
            environment: [:],
            defaultsValue: { key in key == SonnyBackendHost.overrideDefaultsKey ? "https://gw.example.com" : nil }
        )

        #expect(resolved?.baseURL.absoluteString == "https://gw.example.com")
        #expect(resolved?.source == .debugOverride)
    }

    @Test
    func theEnvironmentVariableWinsWhenBothAreSet() {
        let resolved = SonnyBackendHost.resolve(
            environment: [SonnyBackendHost.overrideEnvironmentVariable: "http://from-variable.test"],
            defaultsValue: { _ in "http://from-defaults.test" }
        )

        #expect(resolved?.baseURL.absoluteString == "http://from-variable.test")
    }

    /// A typo in a `defaults write` should not look like a backend outage, so a value that is not
    /// an absolute http(s) URL is ignored rather than becoming a base URL every request fails
    /// against.
    @Test(arguments: [
        "",
        "   ",
        "not a url at all",
        "ftp://example.com",
        "file:///tmp/gateway",
        "example.com",
        "https://"
    ])
    func aMalformedOverrideIsIgnoredRatherThanBecomingABaseURL(raw: String) {
        #expect(SonnyBackendHost.normalizedOverride(raw) == nil)
        #expect(SonnyBackendHost.resolve(
            environment: [SonnyBackendHost.overrideEnvironmentVariable: raw],
            defaultsValue: { _ in nil }
        ) == nil)
    }

    @Test
    func anOverrideWithSurroundingWhitespaceStillResolves() {
        #expect(SonnyBackendHost.normalizedOverride("  http://127.0.0.1:8080 \n")?.absoluteString
            == "http://127.0.0.1:8080")
    }
    #endif

    /// **No production host exists yet**, and this test is the record of that rather than a bug.
    /// `docs/sonny-backend-api-contract.md` §13 assigns the host to SONNY-125, both remote deploy
    /// targets are stubs that exit 3, and the first real remote deploy is owed on SONNY-192. When a
    /// host is chosen, this test is the thing that fails and names what to update.
    @Test
    func noProductionHostIsConfiguredUntilSONNY192ChoosesOne() {
        #expect(SonnyBackendHost.productionBaseURL == nil)
    }

    @Test
    func aBuildWithNoOverrideAndNoProductionHostResolvesToNothing() {
        #expect(SonnyBackendHost.resolve(environment: [:], defaultsValue: { _ in nil }) == nil)
    }
}
