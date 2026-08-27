import Foundation

/// Where this build sends backend requests, and the single place a base URL is decided.
///
/// **The release build has no staging switch, and that is enforced by the compiler rather than
/// asserted.** SONNY-106 requires that no environment variable be needed for anything in a build a
/// user runs, so every line that reads an override below sits inside `#if DEBUG` and is not
/// compiled into a release binary at all. `SonnyBackendEnvironmentScanTests` holds the population —
/// the two override key strings appear in this file and nowhere else under `Sources/` — and
/// `swift build -c release` plus a `strings` sweep of the product demonstrates the other half:
/// neither key survives into the release binary. A test asserting "release ignores the override"
/// cannot run, because a test process is a debug build; the scan and the binary sweep are what can
/// be checked, and both are.
///
/// **Two override sources, and the second exists because of this ticket's own headline
/// constraint.** A Screen Recording grant forces `DefaultAppRelauncher.relaunch()` to reopen the
/// bundle with `/usr/bin/open -n`, which starts the new process from launchd's environment and not
/// from the terminal's — so an environment variable set for a debug run is gone the moment the app
/// relaunches, exactly when this ticket needs the app to come back working. A `UserDefaults` value
/// survives that, and survives a launch from Finder, which an environment variable never does.
/// The environment variable is kept as the more explicit, per-launch form and wins when both are
/// set.
public struct SonnyBackendEnvironment: Equatable, Sendable {
    /// Which of the two answers below produced `baseURL` — read by tests and by the debug-only
    /// indicator on the sign-in surface, never by request-building code.
    public enum Source: String, Equatable, Sendable {
        case production
        case debugOverride
    }

    public let baseURL: URL
    public let source: Source

    public init(baseURL: URL, source: Source) {
        self.baseURL = baseURL
        self.source = source
    }
}

public enum SonnyBackendHost {
    /// **No production host exists yet, and this is that fact rather than a guess at one.**
    ///
    /// The host is deliberately held: `docs/sonny-backend-api-contract.md` §13 assigns it to
    /// SONNY-125, `./scripts/deploy.sh staging` and `production` are stubs that exit 3, and the
    /// first real remote deploy is owed on SONNY-192. Writing a plausible domain here would be a
    /// confidently stated fact nobody decided, and it would fail as a DNS error rather than as the
    /// honest "this build has no backend" the surface can actually say. When a host is chosen this
    /// becomes one line.
    ///
    /// Computed rather than `static let ... = nil` so that no call site is folded into a
    /// diagnostic about unreachable code while the value is still unset.
    public static var productionBaseURL: URL? { nil }

    // **Everything to do with the override lives inside this one conditional, keys included.**
    //
    // Guarding only the *reads* would leave the two key strings compiled into a release binary,
    // which is a weaker property than the one this ticket asks to be demonstrated: with the
    // constants in here too, a release build has no symbol to name and no literal to find, and
    // `strings` over the release product finds neither key. The compiler is the enforcement; the
    // scan in `SonnyBackendEnvironmentScanTests` proves the guard is where this comment says, and
    // a `swift build -c release` plus a `strings` sweep proves the consequence.
    #if DEBUG
    /// The debug-only pointer, as an environment variable.
    public static let overrideEnvironmentVariable = "SONNY_BACKEND_BASE_URL"

    /// The debug-only pointer, as a `UserDefaults` key:
    /// `defaults write com.sonny.MacAgent SonnyBackendBaseURL http://127.0.0.1:8080`.
    public static let overrideDefaultsKey = "SonnyBackendBaseURL"

    /// A pointer value is honoured only when it parses as an absolute `http`/`https` URL.
    ///
    /// A blank or malformed value falls through to the production answer rather than becoming a
    /// base URL every request then fails against — a typo in a `defaults write` should not look
    /// like a backend outage.
    static func normalizedOverride(_ raw: String?) -> URL? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else {
            return nil
        }
        return url
    }
    #endif

    /// The base URL this build should use, or `nil` when no host is configured for it.
    ///
    /// **`defaultsValue` is a closure rather than a `UserDefaults`** so that a test can answer it
    /// from memory. A test given a real `UserDefaults` suite writes a plist under the developer's
    /// own `~/Library/Preferences`, which is the same class of hazard SONNY-240 removed from the
    /// local stores — smaller, but there is no reason to take it for a lookup this simple.
    ///
    /// Both parameters are unread in a release build, where the whole override branch is compiled
    /// out and there is no key left to look up.
    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaultsValue: @Sendable (String) -> String? = { UserDefaults.standard.string(forKey: $0) }
    ) -> SonnyBackendEnvironment? {
        #if DEBUG
        if let override = normalizedOverride(environment[overrideEnvironmentVariable]) {
            return SonnyBackendEnvironment(baseURL: override, source: .debugOverride)
        }
        if let override = normalizedOverride(defaultsValue(overrideDefaultsKey)) {
            return SonnyBackendEnvironment(baseURL: override, source: .debugOverride)
        }
        #endif
        return productionBaseURL.map { SonnyBackendEnvironment(baseURL: $0, source: .production) }
    }
}
