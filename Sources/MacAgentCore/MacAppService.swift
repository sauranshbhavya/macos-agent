import AppKit
import Foundation

public struct MacApp: Equatable, Sendable {
    public var displayName: String
    public var bundleIdentifier: String
    public var aliases: [String]

    public init(displayName: String, bundleIdentifier: String, aliases: [String] = []) {
        self.displayName = displayName
        self.bundleIdentifier = bundleIdentifier
        self.aliases = aliases
    }
}

/// The two ways naming an app can fail once membership is gone.
///
/// `appNotAllowed` — "«name» is not in the allowlisted app catalog." — was the third, and it was the
/// launch gate itself: the refusal C12 dissolved (2026-08-12). It is deleted rather than deprecated,
/// so that no path can reach the sentence. What is left is a request that named no app at all, and a
/// request that named one this Mac does not have.
///
/// Renamed from `MacAppCatalogError` with that removal: the catalog no longer decides either of
/// these. `missingAppName` is raised by the workspace create and edit paths for a blank entry as much
/// as by the launch path, and `notInstalled` is Launch Services' answer, not a roster's.
public enum MacAppError: Error, LocalizedError, Equatable {
    case missingAppName
    case notInstalled(String)

    public var errorDescription: String? {
        switch self {
        case .missingAppName:
            return "Opening an app requires an app name."
        case .notInstalled(let appName):
            // Plain and about the machine, not about Sonny's permissions — the old sentence told the
            // user they had hit a policy, and after C12 there is no policy left to hit. Names what
            // they typed, because a name that is merely misspelled reads back wrong here.
            return "\(appName) isn't installed on this Mac."
        }
    }
}

/// The app **alias table**: which human names mean the same application.
///
/// This type used to be the launch allowlist — "exactly one meaning — the allowlist of what Sonny may
/// *launch*", as `WorkspaceScopeOnlyApps`' header put it — and SONNY-82 removed that meaning under
/// C12. What survives is the half that was never a permission: the knowledge that "Google Chrome" and
/// "Chrome" are one app, that "iMessage" is Messages, that "Code" and "Visual Studio Code" are VS
/// Code, and that "iTunes" now means Music.
///
/// **It is deliberately not a roster of what may be opened, and its twelve entries are not a limit on
/// anything.** `InstalledAppResolver` answers what is launchable, from Launch Services. Membership
/// here buys exactly two things: canonicalization (one bundle identifier for several spellings) and
/// a stable `bundle:` scope key for those spellings — which is precisely why C12 records that this
/// resolution function is *replaced, never deleted*. Adding an entry is warranted when a real app has
/// a second common name, and never in order to make something launchable.
public struct MacAppCatalog: Equatable, Sendable {
    public var apps: [MacApp]

    public init(apps: [MacApp] = Self.default.apps) {
        self.apps = apps
    }

    public static let `default` = MacAppCatalog(apps: [
        MacApp(displayName: "Safari", bundleIdentifier: "com.apple.Safari"),
        MacApp(displayName: "Chrome", bundleIdentifier: "com.google.Chrome", aliases: ["Google Chrome"]),
        MacApp(displayName: "Finder", bundleIdentifier: "com.apple.finder"),
        MacApp(displayName: "Notes", bundleIdentifier: "com.apple.Notes"),
        MacApp(displayName: "Calendar", bundleIdentifier: "com.apple.iCal"),
        MacApp(displayName: "Mail", bundleIdentifier: "com.apple.mail"),
        MacApp(displayName: "Messages", bundleIdentifier: "com.apple.MobileSMS", aliases: ["iMessage"]),
        MacApp(displayName: "Apple Music", bundleIdentifier: "com.apple.Music", aliases: ["Music", "iTunes"]),
        MacApp(displayName: "Spotify", bundleIdentifier: "com.spotify.client"),
        MacApp(displayName: "Slack", bundleIdentifier: "com.tinyspeck.slackmacgap"),
        MacApp(displayName: "VS Code", bundleIdentifier: "com.microsoft.VSCode", aliases: ["Visual Studio Code", "Code"]),
        MacApp(displayName: "Terminal", bundleIdentifier: "com.apple.Terminal")
    ])

    /// The canonical app this name is a spelling of, or `nil` when the table has never heard of it.
    ///
    /// Optional rather than throwing, and that is the shape of the dissolution rather than a style
    /// choice: every caller but one already wrote `try? catalog.resolve(...)`, because "this table
    /// does not know that name" was never an error — only the launch capability
    /// treated it as one, and that treatment *was* the launch gate. With the gate gone there is no
    /// caller left for whom a miss is a failure, so there is no error to throw.
    public func canonicalApp(named rawName: String?) -> MacApp? {
        guard let rawName, !rawName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let normalizedName = Self.normalize(rawName)
        return apps.first { app in
            Self.normalize(app.displayName) == normalizedName ||
                app.aliases.contains { Self.normalize($0) == normalizedName }
        }
    }

    public var displayList: String {
        apps.map(\.displayName).joined(separator: ", ")
    }

    /// The one app-name normalization in this module. Internal rather than private so a name the
    /// alias table *cannot* canonicalize is still folded the same way `canonicalApp(named:)` would
    /// have folded it — `WorkspaceScope.appKey`'s fallback and `InstalledAppResolver`'s name lookup
    /// are the callers. A second, weaker folding in either would make "Microsoft Word" and
    /// "MicrosoftWord" different apps to workspace scope, or to Launch Services, while being the same
    /// app to everything else.
    static func normalize(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
    }
}

@MainActor
public protocol AppOpening {
    func open(bundleIdentifier: String) async throws
}

public enum AppOpeningError: Error, LocalizedError, Equatable {
    case appNotInstalled(String)
    case failedToOpen(String)

    public var errorDescription: String? {
        switch self {
        case .appNotInstalled(let bundleIdentifier):
            return "No installed app was found for bundle identifier \(bundleIdentifier)."
        case .failedToOpen(let detail):
            return "Could not open app: \(detail)"
        }
    }
}

public struct WorkspaceAppOpener: AppOpening {
    public init() {}

    @MainActor
    public func open(bundleIdentifier: String) async throws {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            throw AppOpeningError.appNotInstalled(bundleIdentifier)
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let configuration = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
                if let error {
                    continuation.resume(throwing: AppOpeningError.failedToOpen(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            }
        }
    }
}

@MainActor
public protocol WorkspaceAppIconResolving {
    /// Returns the app's real icon, or `nil` when the name resolves to nothing installed on this
    /// machine. Graceful fallback, never an error: callers render a generic glyph.
    ///
    /// It used to be two failure modes — not in the allowlisted catalog, or not installed — and the
    /// first is gone with the catalog's membership meaning (SONNY-82). A workspace listing Figma now
    /// shows Figma's real icon on a Mac that has it, for the same reason it can now open it.
    func icon(forAppName appName: String) -> NSImage?
}

@MainActor
public final class WorkspaceAppIconResolver: WorkspaceAppIconResolving {
    public static let shared = WorkspaceAppIconResolver()

    private let resolver: any InstalledAppResolving
    private var cache: [String: NSImage] = [:]

    public init(resolver: any InstalledAppResolving = InstalledAppResolver.shared) {
        self.resolver = resolver
    }

    public func icon(forAppName appName: String) -> NSImage? {
        // The resolver's own `applicationURL` rather than a second Launch Services lookup: the icon
        // shown and the bundle that would open have to be the same one.
        guard let app = resolver.resolve(appName) else {
            return nil
        }
        if let cached = cache[app.bundleIdentifier] {
            return cached
        }
        let icon = NSWorkspace.shared.icon(forFile: app.applicationURL.path)
        cache[app.bundleIdentifier] = icon
        return icon
    }
}
