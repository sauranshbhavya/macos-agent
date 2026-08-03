import Foundation
import Testing
@testable import MacAgentCore

@MainActor
@Suite
struct WorkspaceBrowserOpenerTests {
    private static let safari = MacApp(displayName: "Safari", bundleIdentifier: "com.apple.Safari")
    private static let chrome = MacApp(displayName: "Chrome", bundleIdentifier: "com.google.Chrome", aliases: ["Google Chrome"])
    private static let notes = MacApp(displayName: "Notes", bundleIdentifier: "com.apple.Notes")
    private static let slack = MacApp(displayName: "Slack", bundleIdentifier: "com.tinyspeck.slackmacgap")

    // MARK: - Which app counts as the workspace's browser

    @Test
    func theWorkspacesBrowserIsTheFirstBrowserCapableAppNotSimplyTheFirstApp() {
        let apps = [Self.notes, Self.chrome, Self.safari]
        #expect(WorkspaceBrowserCatalog.firstBrowser(in: apps) == Self.chrome)
    }

    @Test
    func aWorkspaceThatNamesNoBrowserHasNoBrowser() {
        #expect(WorkspaceBrowserCatalog.firstBrowser(in: [Self.notes, Self.slack]) == nil)
        #expect(WorkspaceBrowserCatalog.firstBrowser(in: []) == nil)
        #expect(WorkspaceBrowserCatalog.isBrowser(Self.notes) == false)
        #expect(WorkspaceBrowserCatalog.isBrowser(Self.slack) == false)
    }

    /// The catalog resolves aliases down to one canonical `MacApp` before recognition ever runs, so
    /// a workspace saved as "Google Chrome" is the same browser as one saved as "Chrome". Pinned
    /// because recognition keys on the bundle identifier precisely so the alias problem cannot exist.
    @Test
    func aBrowserSavedUnderAnAliasIsStillRecognized() throws {
        let catalog = MacAppCatalog.default
        let viaAlias = try catalog.resolve("Google Chrome")
        let viaDisplayName = try catalog.resolve("chrome")

        #expect(viaAlias == viaDisplayName)
        #expect(WorkspaceBrowserCatalog.isBrowser(viaAlias))
    }

    /// Safari and Chrome are the only browsers `MacAppCatalog.default` carries today. The other
    /// three identifiers are listed ahead of the catalog on purpose: adding Arc, Firefox or Edge to
    /// the allowlist should make it the workspace's browser in that same edit, with no second place
    /// to remember. Both halves are pinned so neither can drift silently.
    @Test
    func recognitionCoversBrowsersTheDefaultCatalogDoesNotCarryYet() {
        let browsersInDefaultCatalog = MacAppCatalog.default.apps.filter(WorkspaceBrowserCatalog.isBrowser)
        #expect(browsersInDefaultCatalog.map(\.displayName) == ["Safari", "Chrome"])

        let arc = MacApp(displayName: "Arc", bundleIdentifier: "company.thebrowser.Browser")
        let firefox = MacApp(displayName: "Firefox", bundleIdentifier: "org.mozilla.firefox")
        let edge = MacApp(displayName: "Edge", bundleIdentifier: "com.microsoft.edgemac")
        #expect(WorkspaceBrowserCatalog.isBrowser(arc))
        #expect(WorkspaceBrowserCatalog.isBrowser(firefox))
        #expect(WorkspaceBrowserCatalog.isBrowser(edge))

        // A browser-shaped display name with an unknown bundle identifier is not a browser — the set
        // is the whole rule, and nothing infers browser-ness from the name.
        #expect(WorkspaceBrowserCatalog.isBrowser(MacApp(displayName: "Safari", bundleIdentifier: "com.example.NotSafari")) == false)
    }

    // MARK: - Opening

    /// The bug was that a `false` return from `NSWorkspace.open` was discarded, so every failed
    /// browser open reported success. This exercises that decision with an injected result
    /// rather than a real unregistered scheme — asking Launch Services to open one puts a
    /// "no application set to open the URL" dialog on the developer's screen every test run.
    /// (Moved here from `ProcessSeamTests` when `WorkspaceBrowserOpener` got its own file.)
    @Test
    func workspaceBrowserOpenerThrowsWhenMacOSDeclinesToOpenTheURL() async throws {
        let url = try #require(URL(string: "https://example.com/story"))

        let refusingSeam = Seam()
        refusingSeam.defaultBrowserAccepts = false
        await #expect(throws: BrowserOpeningError.failedToOpen(url.absoluteString)) {
            try await refusingSeam.opener().open(url)
        }

        let accepting = Seam()
        try await accepting.opener().open(url)
        #expect(accepting.defaultBrowserURLs == [url])
    }

    /// The ticket's headline case: Chrome is the system default, the workspace names Safari, and the
    /// URL must reach Safari. "Chrome is default" is represented by the default-browser seam — if it
    /// is ever consulted here, the original bug is back.
    @Test
    func aNamedBrowserGetsTheURLAndTheSystemDefaultIsNeverAsked() async throws {
        let url = try #require(URL(string: "https://github.com"))
        let seam = Seam()

        try await seam.opener().open(url, using: Self.safari)

        #expect(seam.applicationOpens.count == 1)
        #expect(seam.applicationOpens.first?.url == url)
        #expect(seam.applicationOpens.first?.browser == Self.safari)
        #expect(seam.defaultBrowserURLs.isEmpty)
        #expect(seam.fallbackLogs.isEmpty)
    }

    @Test
    func openingWithoutABrowserGoesStraightToTheDefaultAndNeverTouchesTheApplicationSeam() async throws {
        let url = try #require(URL(string: "https://github.com"))
        let seam = Seam()

        try await seam.opener().open(url, using: nil)

        #expect(seam.defaultBrowserURLs == [url])
        #expect(seam.applicationOpens.isEmpty)
        #expect(seam.fallbackLogs.isEmpty)
    }

    /// A browser in the workspace that is not installed on this Mac. Opening somewhere beats
    /// failing, so this is a fallback plus a log line — never a thrown, user-facing error.
    @Test
    func aBrowserThatIsNotInstalledFallsBackToTheDefaultBrowserAndLogsWhy() async throws {
        let url = try #require(URL(string: "https://github.com"))
        let seam = Seam()
        seam.applicationOpenError = AppOpeningError.appNotInstalled("com.apple.Safari")

        try await seam.opener().open(url, using: Self.safari)

        #expect(seam.applicationOpens.count == 1)
        #expect(seam.defaultBrowserURLs == [url])
        #expect(seam.fallbackLogs.count == 1)
        // Asserted whole rather than by `contains`, because the defect this pins is punctuation:
        // `appNotInstalled`'s own description ends in a period, and appending another one produced
        // "…com.apple.Safari.. Falling back…". A substring check cannot see that.
        #expect(seam.fallbackLogs.first == """
            Could not open https://github.com in Safari: No installed app was found for bundle \
            identifier com.apple.Safari. Falling back to the default browser.
            """)
    }

    /// The other unresolvable case: the app exists but Launch Services refuses to launch it. Same
    /// contract, and the log carries the launch failure's own detail rather than a generic message.
    @Test
    func aBrowserThatRefusesToLaunchFallsBackToTheDefaultBrowserAndLogsWhy() async throws {
        let url = try #require(URL(string: "https://github.com"))
        let seam = Seam()
        seam.applicationOpenError = AppOpeningError.failedToOpen("Safari quit unexpectedly")

        try await seam.opener().open(url, using: Self.safari)

        #expect(seam.defaultBrowserURLs == [url])
        // The other half of the punctuation rule: this description carries no trailing period, so
        // nothing may be stripped from it and the template supplies the only one.
        #expect(seam.fallbackLogs.first == """
            Could not open https://github.com in Safari: Could not open app: Safari quit \
            unexpectedly. Falling back to the default browser.
            """)
    }

    /// The fallback is a fallback, not a swallow: when macOS also declines the default browser,
    /// the caller still gets the same `BrowserOpeningError` it would have got before this change.
    @Test
    func aFallbackTheDefaultBrowserAlsoDeclinesStillThrows() async throws {
        let url = try #require(URL(string: "https://github.com"))
        let seam = Seam()
        seam.applicationOpenError = AppOpeningError.appNotInstalled("com.apple.Safari")
        seam.defaultBrowserAccepts = false

        await #expect(throws: BrowserOpeningError.failedToOpen(url.absoluteString)) {
            try await seam.opener().open(url, using: Self.safari)
        }
        #expect(seam.fallbackLogs.count == 1)
    }

    /// Every URL in the workspace goes to the workspace's browser, not just the first one.
    @Test
    func everyURLGoesToTheNamedBrowser() async throws {
        let first = try #require(URL(string: "https://github.com"))
        let second = try #require(URL(string: "https://news.ycombinator.com"))
        let seam = Seam()
        let opener = seam.opener()

        try await opener.open(first, using: Self.chrome)
        try await opener.open(second, using: Self.chrome)

        #expect(seam.applicationOpens.map(\.url) == [first, second])
        #expect(seam.applicationOpens.allSatisfy { $0.browser == Self.chrome })
        #expect(seam.defaultBrowserURLs.isEmpty)
    }

    /// Captures both live seams so no test in this file can reach Launch Services.
    @MainActor
    private final class Seam {
        private(set) var defaultBrowserURLs: [URL] = []
        private(set) var applicationOpens: [(url: URL, browser: MacApp)] = []
        private(set) var fallbackLogs: [String] = []
        var defaultBrowserAccepts = true
        var applicationOpenError: (any Error)?

        func opener() -> WorkspaceBrowserOpener {
            WorkspaceBrowserOpener(
                openURL: { [self] url in
                    defaultBrowserURLs.append(url)
                    return defaultBrowserAccepts
                },
                openURLInApplication: { [self] url, browser in
                    applicationOpens.append((url: url, browser: browser))
                    if let applicationOpenError {
                        throw applicationOpenError
                    }
                },
                logFallback: { [self] message in
                    fallbackLogs.append(message)
                }
            )
        }
    }
}
