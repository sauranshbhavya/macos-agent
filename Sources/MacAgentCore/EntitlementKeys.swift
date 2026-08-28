import Foundation

/// Which public keys this build verifies entitlement claims against, and the single place that is
/// decided (SONNY-135).
///
/// **The shipped set is empty, and that is a fact rather than a guess at one.** The same shape, and
/// the same reasoning, as `SonnyBackendHost.productionBaseURL` being `nil`: no gateway has been
/// deployed anywhere (`./scripts/deploy.sh staging` and `production` exit 3, and the first real
/// remote deploy is owed on SONNY-126), so no signing key exists to hold the public half of. Writing
/// a plausible key here would be a confidently stated fact nobody decided.
///
/// **What an empty set does is refuse, which is the direction §16.3 requires.** With no key, no claim
/// verifies, so every *gated* capability is refused — and no free local capability is affected at
/// all, because a free capability never consults this. That is the contract's own formulation of the
/// rule (§5.3.1): "a free local capability never consults the entitlement claim at all. Not 'consults
/// it and succeeds'; does not call it. A check that is never made cannot fail closed."
///
/// **The release build has no override, and that is enforced by the compiler rather than asserted.**
/// SONNY-106 requires that no environment variable be needed for anything in a build a user runs, so
/// every line that reads an override below sits inside `#if DEBUG` and is not compiled into a release
/// binary at all. `EntitlementReleaseSwitchScanTests` holds the population, exactly as
/// `SignInReleaseSwitchScanTests` does for the staging pointer.
public enum SonnyEntitlementKeys {
    /// The keys a shipped build holds. Empty until a gateway exists to have signed anything.
    ///
    /// Computed rather than `static let ... = EntitlementKeySet([:])` so that no call site is folded
    /// into a diagnostic about unreachable code while the set is still empty.
    public static var shipped: EntitlementKeySet { EntitlementKeySet([:]) }

    #if DEBUG
    /// The debug-only pointer, as an environment variable. One or more `kid:base64url` pairs,
    /// comma-separated; `npm run entitlements -- public-key` prints a pair in that form.
    public static let overrideEnvironmentVariable = "SONNY_ENTITLEMENT_PUBLIC_KEYS"

    /// The debug-only pointer, as a `UserDefaults` key:
    /// `defaults write com.sonny.MacAgent SonnyEntitlementPublicKeys "dev-1:AbCd…"`.
    ///
    /// The second form exists for the reason `SonnyBackendEnvironment`'s does: a Screen Recording
    /// grant relaunches the bundle through `/usr/bin/open -n`, which starts the new process from
    /// launchd's environment rather than the terminal's, so an environment variable set for a debug
    /// run is gone at exactly the moment the app comes back.
    public static let overrideDefaultsKey = "SonnyEntitlementPublicKeys"

    /// A pointer value becomes a key set only if at least one pair in it parses.
    ///
    /// A blank or wholly malformed value falls through to the shipped answer rather than becoming an
    /// empty override, so a typo in a `defaults write` reads as "no override" rather than silently
    /// replacing a real key set with nothing.
    static func normalizedOverride(_ raw: String?) -> EntitlementKeySet? {
        guard let raw else { return nil }
        let pairs = raw.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        let parsed = EntitlementKeySet.parsing(pairs)
        return parsed.isEmpty ? nil : parsed
    }
    #endif

    /// The key set this build should verify with.
    ///
    /// Both parameters are unread in a release build, where the whole override branch is compiled out
    /// and there is no key left to look up.
    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaultsValue: @Sendable (String) -> String? = { UserDefaults.standard.string(forKey: $0) }
    ) -> EntitlementKeySet {
        #if DEBUG
        if let override = normalizedOverride(environment[overrideEnvironmentVariable]) {
            return override
        }
        if let override = normalizedOverride(defaultsValue(overrideDefaultsKey)) {
            return override
        }
        #endif
        return shipped
    }
}
