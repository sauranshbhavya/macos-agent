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
    /// Opens `url` in the system default browser. The shorthand for a caller that names no browser.
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

/// Opens URLs through Launch Services.
///
/// With a browser named, the URL goes to that app. Without one — or when that app turns out not to
/// be installed or refuses to launch — it goes to the system default browser, because a link opened
/// in the wrong browser is a far better outcome than one that fails to open.
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
                // Whether `localizedDescription` already ends in a period depends on which error
                // this is — `AppOpeningError.appNotInstalled`'s does, `.failedToOpen`'s does not —
                // so strip one if present and let the template own the sentence break. Assuming
                // either way shipped "…com.apple.Safari.. Falling back…" for the not-installed case.
                let reason = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                let clause = reason.hasSuffix(".") ? String(reason.dropLast()) : reason
                logFallback(
                    """
                    Could not open \(url.absoluteString) in \(browser.displayName): \
                    \(clause). Falling back to the default browser.
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
