import AppKit
import Foundation
import os

@MainActor
public protocol BrowserOpening {
    /// Opens `url`, preferring `browser` when the caller names one.
    ///
    /// A named browser is a *preference*, not a requirement: an implementation that cannot use it
    /// must still open the URL somewhere rather than fail. Passing `nil` means "whatever macOS
    /// treats as the default browser".
    func open(_ url: URL, using browser: MacApp?) async throws
}

public extension BrowserOpening {
    /// Opens `url` in the system default browser. The shorthand every caller without a workspace
    /// behind it uses — safe-URL opens, app search URLs, the Hacker News link.
    @MainActor
    func open(_ url: URL) async throws {
        try await open(url, using: nil)
    }
}

public enum BrowserOpeningError: Error, LocalizedError, Equatable {
    case failedToOpen(String)

    public var errorDescription: String? {
        switch self {
        case .failedToOpen(let url):
            return "macOS could not open \(url) in a browser."
        }
    }
}

/// Which allowlisted apps count as browsers when Sonny opens a workspace's URLs.
///
/// An explicit bundle-identifier set, deliberately not a heuristic: probing Launch Services for
/// apps that declare an `http` handler would silently pull in every Electron app, mail client and
/// PDF reader that registers one. Bundle identifier rather than display name because that is the
/// identity `MacAppCatalog` already resolves aliases down to ("Google Chrome" and "Chrome" both
/// land on `com.google.Chrome`), so there is one source of truth instead of two that can disagree.
///
/// `MacAppCatalog.default` only carries Safari and Chrome today; Arc, Firefox and Edge are listed
/// so that adding one to the catalog makes it browser-aware in the same edit, with nothing here to
/// remember to update.
public enum WorkspaceBrowserCatalog {
    public static let browserBundleIdentifiers: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "company.thebrowser.Browser",
        "org.mozilla.firefox",
        "com.microsoft.edgemac"
    ]

    public static func isBrowser(_ app: MacApp) -> Bool {
        browserBundleIdentifiers.contains(app.bundleIdentifier)
    }

    /// A workspace's browser: the *first* browser-capable app in its own apps list, so the order
    /// the user saved decides. `nil` when the workspace names no browser at all — the caller then
    /// keeps the pre-existing default-browser behavior.
    public static func firstBrowser(in apps: [MacApp]) -> MacApp? {
        apps.first(where: isBrowser)
    }
}

/// Opens URLs through Launch Services.
///
/// With a browser named, the URL goes to that app. Without one — or when that app turns out not to
/// be installed or refuses to launch — it goes to the system default browser, because a workspace
/// that opens its links in the wrong browser is a far better outcome than one that fails mid-open.
/// The fallback is logged, never surfaced as a user-facing error.
public struct WorkspaceBrowserOpener: BrowserOpening {
    /// Opens in the system default browser; `false` means Launch Services declined.
    public typealias OpenURL = @MainActor (URL) -> Bool
    /// Opens in a specific app; throwing means the app was unavailable or declined.
    public typealias OpenURLInApplication = @MainActor (URL, MacApp) async throws -> Void

    private static let logger = Logger(subsystem: "com.sonny.macagent", category: "browser-opening")

    private let openURL: OpenURL
    private let openURLInApplication: OpenURLInApplication
    private let logFallback: @MainActor (String) -> Void

    public init(
        openURL: @escaping OpenURL = { NSWorkspace.shared.open($0) },
        openURLInApplication: @escaping OpenURLInApplication = { try await Self.launchServicesOpen($0, in: $1) },
        logFallback: @escaping @MainActor (String) -> Void = { Self.logFallbackToDefaultBrowser($0) }
    ) {
        self.openURL = openURL
        self.openURLInApplication = openURLInApplication
        self.logFallback = logFallback
    }

    /// The live default for `logFallback`. `public` for the same default-argument-visibility reason
    /// as `launchServicesOpen`.
    public static func logFallbackToDefaultBrowser(_ message: String) {
        logger.warning("\(message, privacy: .public)")
    }

    @MainActor
    public func open(_ url: URL, using browser: MacApp?) async throws {
        if let browser {
            do {
                try await openURLInApplication(url, browser)
                return
            } catch {
                logFallback(
                    """
                    Could not open \(url.absoluteString) in \(browser.displayName): \
                    \(error.localizedDescription). Falling back to the default browser.
                    """
                )
            }
        }

        guard openURL(url) else {
            throw BrowserOpeningError.failedToOpen(url.absoluteString)
        }
    }

    /// The live default for `openURLInApplication`. `public` only because a default argument value
    /// on a `public init` is inlined at the call site and cannot name anything less visible.
    @MainActor
    public static func launchServicesOpen(_ url: URL, in browser: MacApp) async throws {
        guard let applicationURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: browser.bundleIdentifier
        ) else {
            throw AppOpeningError.appNotInstalled(browser.bundleIdentifier)
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let configuration = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open(
                [url],
                withApplicationAt: applicationURL,
                configuration: configuration
            ) { _, error in
                if let error {
                    continuation.resume(throwing: AppOpeningError.failedToOpen(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            }
        }
    }
}
