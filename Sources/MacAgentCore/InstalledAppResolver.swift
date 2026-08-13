import AppKit
import Foundation

/// One application installed on this Mac, as Launch Services reports it.
///
/// `applicationURL` is **Launch Services' answer**, not wherever the bundle was found on disk. The
/// two can differ when more than one copy of an app exists, and the one that matters is the one
/// `NSWorkspace.openApplication` will actually start — so the preview that discloses a location and
/// the launch that follows it name the same bundle.
public struct InstalledApp: Equatable, Sendable {
    public var displayName: String
    public var bundleIdentifier: String
    public var applicationURL: URL

    public init(displayName: String, bundleIdentifier: String, applicationURL: URL) {
        self.displayName = displayName
        self.bundleIdentifier = bundleIdentifier
        self.applicationURL = applicationURL
    }

    /// The identity the launch and browser seams already speak (`AppOpening.open(bundleIdentifier:)`,
    /// `WorkspaceBrowserCatalog.firstBrowser(in:)`, `CapabilityExecutionContext.preferredBrowser`).
    /// Kept as a projection rather than replacing `MacApp` everywhere: those seams need a name and a
    /// bundle identifier and nothing else, and widening them to carry a URL they never read would be
    /// churn without a reader.
    public var macApp: MacApp {
        MacApp(displayName: displayName, bundleIdentifier: bundleIdentifier)
    }
}

/// Answers the one question the app-catalog dissolution left standing: **which installed app does
/// this human name mean?**
///
/// Before SONNY-82 the question was "is this name one of the twelve `MacAppCatalog` carries", and a
/// no was a refusal — the launch allowlist. C12 (ratified 2026-08-12) removed that meaning: launching
/// an installed app is tier-1, low-authority work, so the only honest gate left is whether the app
/// exists on this Mac. Membership is gone; *resolution* is not, and this is where it moved.
///
/// **The resolution authority is the Launch Services database.** Never a running process's
/// self-reported display name — that is the whole point of `WorkspaceScope`'s `bundle:` keys
/// (SONNY-58), and an identity sourced from a process that merely calls itself "Chrome" would hand
/// exactly that imposter the real Chrome's scope membership. Nothing in this file reads
/// `NSRunningApplication`.
public protocol InstalledAppResolving: Sendable {
    /// The installed app `rawName` names, or `nil` when nothing installed answers to it.
    ///
    /// `nil` — never a throw — because most callers are asking a question rather than executing a
    /// request: `WorkspaceScope` falls back to a name key, the workspace open path skips the entry,
    /// and only the launch capability turns a miss into a user-facing failure.
    func resolve(_ rawName: String?) -> InstalledApp?
}

/// The installed-app universe itself, as a seam.
///
/// Separated from `InstalledAppResolver` so that name canonicalization — trimming, folding, and the
/// alias table — is **production code every test exercises**, with only the "what is installed on
/// this machine" half swapped out. A test double that implemented `InstalledAppResolving` directly
/// would be a second normalizer, which is the exact divergence `MacAppCatalog.normalize`'s own doc
/// comment exists to prevent.
public protocol InstalledAppSource: Sendable {
    /// The installed app with this exact bundle identifier, or `nil` when it is not installed.
    func application(bundleIdentifier: String) -> InstalledApp?
    /// The installed app whose name folds to `normalizedName` under `MacAppCatalog.normalize`, or
    /// `nil`. Callers normalize; a source never re-folds.
    func application(normalizedName: String) -> InstalledApp?
}

/// Resolves a human app name against the installed universe, canonicalizing through the alias table
/// first.
///
/// Two stages, in this order:
///
/// 1. **The alias table** (`MacAppCatalog`, demoted by SONNY-82 to exactly that). "Google Chrome",
///    "Chrome", "iMessage", "Code" and "iTunes" are folded onto one bundle identifier, which is then
///    checked for installation like any other. This stage exists because it is the only thing that
///    knows two different names are one app.
/// 2. **The installed universe by name**, for everything the alias table has never heard of — which
///    after the dissolution is most of it.
///
/// Stage 1 falling through to stage 2 is deliberate: an alias whose canonical bundle identifier is
/// not installed is not an answer, and if the user has *something* installed under that name, that
/// is what they meant by typing it. The consequence is stated rather than hidden — an app installed
/// under the name "Chrome" that is not Google's will be launched by "open Chrome". That is inherent
/// to launching by name in an open universe, it is tier-1 work under C12, and the preview discloses
/// both the bundle identifier and the install location before it happens. It cannot leak *scope*
/// membership: `WorkspaceScope.appKey` consults the alias table itself before this resolver, so a
/// cataloged name always keys to the cataloged bundle identifier.
public struct InstalledAppResolver: InstalledAppResolving {
    private let aliases: MacAppCatalog
    private let source: any InstalledAppSource

    public init(aliases: MacAppCatalog = .default, source: any InstalledAppSource = LaunchServicesAppSource()) {
        self.aliases = aliases
        self.source = source
    }

    public func resolve(_ rawName: String?) -> InstalledApp? {
        guard let rawName else {
            return nil
        }
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        if let alias = aliases.canonicalApp(named: trimmed),
           let installed = source.application(bundleIdentifier: alias.bundleIdentifier) {
            // The alias table's own display name, not the bundle's file name: "Chrome" has been the
            // canonical spelling of `com.google.Chrome` in every summary, preview and workspace key
            // Sonny has ever written, and canonicalization is what an alias table is for.
            return InstalledApp(
                displayName: alias.displayName,
                bundleIdentifier: installed.bundleIdentifier,
                applicationURL: installed.applicationURL
            )
        }

        return source.application(normalizedName: MacAppCatalog.normalize(trimmed))
    }

    /// The process-appropriate default, used wherever a resolver is not injected.
    ///
    /// Live Launch Services in the real app; under XCTest/SwiftPM, a fixed source holding exactly the
    /// alias table's roster. Same shape and the same reason as
    /// `LocalStorageEncryption.defaultKeyManager()`: a default that reaches out to the machine makes
    /// every test that does not inject depend on which apps this particular Mac happens to have,
    /// which is a test suite that passes here and fails on the next machine. The roster is chosen
    /// over an empty source so that the suite's answers are *byte-identical to the pre-dissolution
    /// catalog* — every existing test keeps the universe it was written against, and a test about
    /// the open universe injects the app it means. New tests should inject rather than lean on this,
    /// exactly as `CLAUDE.md` says of the encryption fallback.
    public static let shared = InstalledAppResolver(source: defaultSource())

    private static func defaultSource() -> any InstalledAppSource {
        isRunningTests ? FixedAppSource.aliasTableRoster : LaunchServicesAppSource()
    }

    /// Copied in shape from `LocalStorageEncryption.isRunningTests` rather than shared, because the
    /// two answer for different reasons and neither should start moving when the other does.
    private static var isRunningTests: Bool {
        let processInfo = ProcessInfo.processInfo
        let processName = processInfo.processName.lowercased()
        let bundlePath = Bundle.main.bundlePath.lowercased()
        return processName.contains("test")
            || bundlePath.contains(".xctest")
            || bundlePath.contains("packagetests")
            || processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}

/// The live universe: application bundles on disk, confirmed through Launch Services.
///
/// Name lookup is a sweep of the standard application directories matched on the bundle's **file
/// name**, which is the name macOS itself shows in Finder, Launchpad and the Dock for effectively
/// every app. Reading `CFBundleDisplayName` out of every installed bundle instead was considered and
/// declined: it is a plist read per app on a path `WorkspaceScope` walks for every stored entry of
/// every risk assessment, to recover a divergence that the alias table already covers for the names
/// where it actually occurs.
///
/// Whatever the sweep finds is then **confirmed through Launch Services**, and Launch Services'
/// answer is the one returned. A bundle sitting on disk that LS does not know about is not
/// launchable by bundle identifier, so it is not installed for this purpose; and when several copies
/// exist, the URL reported is the one that will actually start.
public struct LaunchServicesAppSource: InstalledAppSource {
    /// Launch Services' bundle-identifier lookup. Injectable so a test can drive the confirmation
    /// step without depending on what this Mac has installed.
    public typealias ApplicationURLForBundleIdentifier = @Sendable (String) -> URL?

    private let searchRoots: [URL]
    private let applicationURL: ApplicationURLForBundleIdentifier
    private let index: InstalledAppNameIndex

    public init(
        searchRoots: [URL] = Self.defaultSearchRoots,
        applicationURL: @escaping ApplicationURLForBundleIdentifier = {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
        }
    ) {
        self.searchRoots = searchRoots
        self.applicationURL = applicationURL
        self.index = InstalledAppNameIndex(searchRoots: searchRoots)
    }

    /// Where macOS keeps applications. `/System/Library/CoreServices` is here for Finder, which lives
    /// nowhere else and is one of the alias table's own twelve.
    public static let defaultSearchRoots: [URL] = [
        URL(fileURLWithPath: "/Applications", isDirectory: true),
        URL(fileURLWithPath: "/System/Applications", isDirectory: true),
        URL(fileURLWithPath: "/System/Library/CoreServices", isDirectory: true),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
    ]

    public func application(bundleIdentifier: String) -> InstalledApp? {
        guard let url = applicationURL(bundleIdentifier) else {
            return nil
        }
        return InstalledApp(
            displayName: Self.name(of: url),
            bundleIdentifier: bundleIdentifier,
            applicationURL: url
        )
    }

    public func application(normalizedName: String) -> InstalledApp? {
        guard !normalizedName.isEmpty else {
            return nil
        }
        guard let bundleURL = index.applicationBundleURL(normalizedName: normalizedName),
              let bundleIdentifier = Bundle(url: bundleURL)?.bundleIdentifier else {
            return nil
        }
        // Launch Services has the last word, including on *where* the app is.
        guard let confirmed = applicationURL(bundleIdentifier) else {
            return nil
        }
        return InstalledApp(
            displayName: Self.name(of: bundleURL),
            bundleIdentifier: bundleIdentifier,
            applicationURL: confirmed
        )
    }

    /// `Figma.app` -> `Figma`. The name the user sees and the name they type.
    private static func name(of applicationURL: URL) -> String {
        applicationURL.deletingPathExtension().lastPathComponent
    }
}

/// Normalized app name -> application bundle URL, swept from disk and cached briefly.
///
/// Cached because `WorkspaceScope` resolves every stored app entry on every risk assessment, and a
/// workspace listing an app that is *not* installed would otherwise re-sweep every application
/// directory each time. Cached only *briefly* because installing an app and immediately asking Sonny
/// to open it is the exact motion this branch exists to make work — a process-lifetime cache would
/// answer "isn't installed" until the next relaunch.
private final class InstalledAppNameIndex: @unchecked Sendable {
    /// Long enough that a burst of scope evaluations sweeps once; short enough that a just-installed
    /// app is reachable in the same breath as installing it.
    private static let freshness: TimeInterval = 15

    private let lock = NSLock()
    private let searchRoots: [URL]
    private var cached: [String: URL] = [:]
    private var sweptAt: Date?

    init(searchRoots: [URL]) {
        self.searchRoots = searchRoots
    }

    func applicationBundleURL(normalizedName: String, now: Date = Date()) -> URL? {
        lock.lock()
        defer { lock.unlock() }

        if let sweptAt, now.timeIntervalSince(sweptAt) < Self.freshness {
            return cached[normalizedName]
        }
        cached = Self.sweep(searchRoots)
        sweptAt = now
        return cached[normalizedName]
    }

    /// One shallow listing per root, plus one level into each root's plain subdirectories so that
    /// `/Applications/Utilities` and the folders installers like to make (`/Applications/Setapp`)
    /// are not invisible. Deliberately not a recursive walk: an unbounded sweep of every home
    /// directory would be slow and would start finding app bundles inside downloads and archives.
    private static func sweep(_ roots: [URL]) -> [String: URL] {
        let fileManager = FileManager.default
        var index: [String: URL] = [:]

        func record(_ url: URL) {
            let key = MacAppCatalog.normalize(url.deletingPathExtension().lastPathComponent)
            guard !key.isEmpty else {
                return
            }
            // First writer wins, in the roots' own order, so `/Applications` beats a copy further
            // down the list rather than the answer depending on enumeration order.
            if index[key] == nil {
                index[key] = url
            }
        }

        for root in roots {
            guard let entries = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            for entry in entries {
                if entry.pathExtension == "app" {
                    record(entry)
                    continue
                }
                guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
                    continue
                }
                let nested = (try? fileManager.contentsOfDirectory(
                    at: entry,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )) ?? []
                for child in nested where child.pathExtension == "app" {
                    record(child)
                }
            }
        }

        return index
    }
}

/// A fixed installed universe, for tests and for the test-process default.
///
/// The only implementation of `InstalledAppSource` that does not touch the machine, which is what
/// makes "which apps are installed" a fact a test states rather than a fact a test inherits.
public struct FixedAppSource: InstalledAppSource {
    private let apps: [InstalledApp]

    public init(_ apps: [InstalledApp]) {
        self.apps = apps
    }

    /// Every app in the alias table, as if installed — the pre-dissolution universe exactly.
    ///
    /// `applicationURL` is synthesized rather than looked up: this source exists so that nothing on
    /// the machine is consulted, and no caller under it reads the path for anything but disclosure.
    public static let aliasTableRoster = FixedAppSource(
        MacAppCatalog.default.apps.map { app in
            InstalledApp(
                displayName: app.displayName,
                bundleIdentifier: app.bundleIdentifier,
                applicationURL: URL(fileURLWithPath: "/Applications/\(app.displayName).app")
            )
        }
    )

    public func application(bundleIdentifier: String) -> InstalledApp? {
        apps.first { $0.bundleIdentifier == bundleIdentifier }
    }

    public func application(normalizedName: String) -> InstalledApp? {
        apps.first { MacAppCatalog.normalize($0.displayName) == normalizedName }
    }
}
