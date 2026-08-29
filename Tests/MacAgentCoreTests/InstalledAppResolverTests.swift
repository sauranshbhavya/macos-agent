import Foundation
import MacAgentTestSupport
import Testing
@testable import MacAgentCore

/// SONNY-82: the launch allowlist dissolves and Launch Services takes over resolution.
///
/// Every test here injects the installed universe. None of them may depend on which apps this
/// particular Mac happens to have — that is the difference between a suite that passes here and one
/// that passes everywhere, and it is why `InstalledAppSource` exists as a seam at all.
@Suite
struct InstalledAppResolverTests {
    // MARK: - Fixtures

    private static func app(_ name: String, _ bundleIdentifier: String) -> InstalledApp {
        InstalledApp(
            displayName: name,
            bundleIdentifier: bundleIdentifier,
            applicationURL: URL(fileURLWithPath: "/Applications/\(name).app")
        )
    }

    private static let figma = app("Figma", "com.figma.Desktop")
    private static let discord = app("Discord", "com.hnc.Discord")
    private static let arc = app("Arc", "company.thebrowser.Browser")
    private static let chrome = app("Google Chrome", "com.google.Chrome")
    private static let terminal = app("Terminal", "com.apple.Terminal")
    private static let safari = app("Safari", "com.apple.Safari")

    // MARK: - Alias resolution survives the dissolution

    /// C12 records that the name-to-bundle-identifier resolution function is *replaced, never
    /// deleted*, because workspace scope's anti-imposter keys depend on an authoritative one. The
    /// user-visible half of that is here: two spellings of Chrome are one app, and the canonical
    /// display name is the one the alias table gives — which is what keeps every summary, preview and
    /// scope key Sonny has ever written spelling it the same way.
    @Test
    func aliasSpellingsResolveToOneIdentityUnderTheCanonicalDisplayName() {
        let resolver = InstalledAppResolver(source: FixedAppSource([Self.chrome]))

        let viaAlias = resolver.resolve("Google Chrome")
        let viaDisplayName = resolver.resolve("Chrome")
        let viaCasing = resolver.resolve("  chrome ")

        #expect(viaAlias == viaDisplayName)
        #expect(viaDisplayName == viaCasing)
        #expect(viaAlias?.bundleIdentifier == "com.google.Chrome")
        // The alias table's spelling, not the installed bundle's ("Google Chrome"): canonicalization
        // is the whole job the table has left.
        #expect(viaAlias?.displayName == "Chrome")
    }

    /// The alias table's other entries, each a real second name a user types. Pinned as a table so a
    /// deleted alias fails here rather than in whichever surface happens to notice first.
    @Test
    func everyAliasTableSpellingResolvesToItsCanonicalApp() {
        let source = FixedAppSource([
            Self.chrome,
            Self.app("Messages", "com.apple.MobileSMS"),
            Self.app("Visual Studio Code", "com.microsoft.VSCode"),
            Self.app("Music", "com.apple.Music")
        ])
        let resolver = InstalledAppResolver(source: source)

        let cases: [(typed: String, displayName: String, bundleIdentifier: String)] = [
            ("Google Chrome", "Chrome", "com.google.Chrome"),
            ("iMessage", "Messages", "com.apple.MobileSMS"),
            ("Code", "VS Code", "com.microsoft.VSCode"),
            ("visual studio code", "VS Code", "com.microsoft.VSCode"),
            ("iTunes", "Apple Music", "com.apple.Music"),
            ("Music", "Apple Music", "com.apple.Music")
        ]
        for testCase in cases {
            let resolved = resolver.resolve(testCase.typed)
            #expect(resolved?.displayName == testCase.displayName, "\(testCase.typed) resolved to \(String(describing: resolved?.displayName))")
            #expect(resolved?.bundleIdentifier == testCase.bundleIdentifier)
        }
    }

    /// The normalization is `MacAppCatalog.normalize` on both sides and nowhere else — one folding,
    /// so a name is the same app to the resolver, to workspace scope and to the alias table. A second,
    /// weaker folding anywhere would make "MicrosoftWord" and "Microsoft Word" different apps to one
    /// of them.
    @Test
    func nameLookupFoldsSpacingCasingAndPunctuationTheSameWayTheAliasTableDoes() {
        let resolver = InstalledAppResolver(source: FixedAppSource([Self.app("Microsoft Word", "com.microsoft.Word")]))

        #expect(resolver.resolve("Microsoft Word")?.bundleIdentifier == "com.microsoft.Word")
        #expect(resolver.resolve("microsoftword")?.bundleIdentifier == "com.microsoft.Word")
        #expect(resolver.resolve("micro-soft_word")?.bundleIdentifier == "com.microsoft.Word")
        // Still a real comparison, not a fold-everything-together.
        #expect(resolver.resolve("Microsoft Excel") == nil)
    }

    /// The open universe, which is the whole point: an app the alias table has never heard of
    /// resolves purely because it is installed.
    @Test
    func anAppTheAliasTableHasNeverHeardOfResolvesBecauseItIsInstalled() {
        let resolver = InstalledAppResolver(source: FixedAppSource([Self.figma, Self.discord]))

        #expect(resolver.resolve("Figma")?.bundleIdentifier == "com.figma.Desktop")
        #expect(resolver.resolve("discord")?.bundleIdentifier == "com.hnc.Discord")
        #expect(MacAppCatalog.default.canonicalApp(named: "Figma") == nil)
        #expect(MacAppCatalog.default.canonicalApp(named: "Discord") == nil)
    }

    /// Nothing installed means nothing resolved — and a blank or missing name is not a lookup at all.
    @Test
    func anEmptyUniverseAndAnEmptyNameBothResolveToNothing() {
        let empty = InstalledAppResolver(source: FixedAppSource([]))
        let stocked = InstalledAppResolver(source: FixedAppSource([Self.figma]))

        #expect(empty.resolve("Figma") == nil)
        // Even a cataloged name: membership in the alias table is not installation.
        #expect(empty.resolve("Safari") == nil)
        #expect(stocked.resolve(nil) == nil)
        #expect(stocked.resolve("") == nil)
        #expect(stocked.resolve("   ") == nil)
    }

    /// The alias stage falls through rather than terminating the lookup. With Google's Chrome absent
    /// and something else installed under the name, the user gets the app they actually have — the
    /// stated consequence of launching by name in an open universe, tier-1 work under C12, disclosed
    /// in the preview by bundle identifier and install location.
    @Test
    func anAliasWhoseCanonicalBundleIsNotInstalledFallsThroughToTheInstalledName() {
        let other = Self.app("Chrome", "com.example.NotGoogleChrome")
        let resolver = InstalledAppResolver(source: FixedAppSource([other]))

        #expect(resolver.resolve("Chrome")?.bundleIdentifier == "com.example.NotGoogleChrome")
        // And the alias spelling, which the table folds to the same normalized name, finds nothing:
        // "Google Chrome" is not what that app calls itself.
        #expect(resolver.resolve("Google Chrome") == nil)
    }

    // MARK: - Resolution authority: Launch Services, never a running process

    /// Launch Services has the last word on whether an app is installed. A bundle sitting on disk
    /// that LS declines to answer for is not launchable by bundle identifier, so it is not installed
    /// for this purpose.
    @Test
    func aBundleOnDiskThatLaunchServicesDeclinesIsNotInstalled() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.makeApplicationBundle(named: "Figma", bundleIdentifier: "com.figma.Desktop", in: root)

        let declined = LaunchServicesAppSource(searchRoots: [root], applicationURL: { _ in nil })
        let confirmed = LaunchServicesAppSource(
            searchRoots: [root],
            applicationURL: { _ in URL(fileURLWithPath: "/Applications/Figma.app") }
        )

        #expect(InstalledAppResolver(source: declined).resolve("Figma") == nil)
        #expect(InstalledAppResolver(source: confirmed).resolve("Figma")?.bundleIdentifier == "com.figma.Desktop")
    }

    /// And the URL reported is **Launch Services' answer**, not wherever the sweep found the bundle.
    /// The two differ when more than one copy exists, and the one that matters is the one that will
    /// actually start — so the preview that discloses a location and the launch that follows it name
    /// the same bundle.
    @Test
    func theReportedLocationIsLaunchServicesAnswerNotTheSweptPath() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let swept = try Self.makeApplicationBundle(named: "Figma", bundleIdentifier: "com.figma.Desktop", in: root)
        let launched = URL(fileURLWithPath: "/Applications/Figma.app")

        let source = LaunchServicesAppSource(searchRoots: [root], applicationURL: { _ in launched })
        let resolved = try #require(InstalledAppResolver(source: source).resolve("Figma"))

        #expect(resolved.applicationURL == launched)
        #expect(resolved.applicationURL != swept)
    }

    /// The sweep reaches one level into a root's plain subdirectories, which is where `Utilities` and
    /// the folders installers make live. Deliberately not recursive — an unbounded walk would start
    /// finding app bundles inside downloads and archives.
    @Test
    func theSweepFindsBundlesOneLevelInsideARootsSubdirectories() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("Utilities", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Self.makeApplicationBundle(named: "Deep Utility", bundleIdentifier: "com.example.DeepUtility", in: nested)
        let deeper = nested.appendingPathComponent("Deeper", isDirectory: true)
        try FileManager.default.createDirectory(at: deeper, withIntermediateDirectories: true)
        try Self.makeApplicationBundle(named: "Too Deep", bundleIdentifier: "com.example.TooDeep", in: deeper)

        let source = LaunchServicesAppSource(
            searchRoots: [root],
            applicationURL: { URL(fileURLWithPath: "/Applications/\($0).app") }
        )
        let resolver = InstalledAppResolver(source: source)

        #expect(resolver.resolve("Deep Utility")?.bundleIdentifier == "com.example.DeepUtility")
        #expect(resolver.resolve("Too Deep") == nil)
    }

    /// **The negative the whole anti-imposter model rests on, pinned structurally.**
    ///
    /// Per `CLAUDE.md`'s enumerate-before-you-subtract rule, "no path trusts a running process's
    /// self-reported name" cannot be established by reading one call path — the evidence against it
    /// would live wherever you did not look. What can be established is that the resolution file
    /// names no running-process API at all, and that `InstalledAppResolving`'s only input is a string
    /// and its only collaborator is `InstalledAppSource`. `RunningAppService` remains the one place
    /// that reads live processes, and nothing in resolution reaches it.
    @Test
    func theResolverNamesNoRunningProcessAPI() throws {
        // Code only. The prose in that file *does* name `NSRunningApplication`, in the sentence
        // saying it never reads one — a sweep that could not tell a comment from a call would make
        // documenting the invariant break the test that pins it.
        let code = Self.strippingComments(
            try String(contentsOf: sourceFile(named: "InstalledAppResolver.swift"), encoding: .utf8)
        )

        for forbidden in ["NSRunningApplication", "runningApplications", "RunningAppService"] {
            #expect(!code.contains(forbidden), "InstalledAppResolver.swift now calls \(forbidden)")
        }
        // The positive half: Launch Services is what it does consult.
        #expect(code.contains("urlForApplication(withBundleIdentifier:"))
    }

    /// The membership rejection is gone from the tree, not merely unreachable. Enumerated over the
    /// whole of `Sources/` and `Tests/` rather than asserted from one grep of one file.
    @Test
    func theMembershipRejectionNoLongerExistsAnywhereInTheTree() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        var offenders: [String] = []
        for directory in ["Sources", "Tests"] {
            let root = packageRoot.appendingPathComponent(directory, isDirectory: true)
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
                Issue.record("Could not enumerate \(directory)")
                continue
            }
            for case let url as URL in walker where url.pathExtension == "swift" {
                // This file is the one place the needles legitimately appear as code — they are the
                // needles. Excluded by name rather than by splitting the literals into fragments,
                // which would hide from a future reader what is actually being searched for.
                guard url.lastPathComponent != "InstalledAppResolverTests.swift" else {
                    continue
                }
                // Code only, for the same reason as the sweep above: several files record in prose
                // that this rejection was deleted and what it used to say, which is history worth
                // keeping and not a reachable path.
                let code = Self.strippingComments((try? String(contentsOf: url, encoding: .utf8)) ?? "")
                // The symbol and the sentence it produced, both. The sentence is checked separately
                // because a copy of it could survive as a literal long after the case is deleted.
                if code.contains("appNotAllowed") || code.contains("is not in the allowlisted app catalog") {
                    offenders.append(url.lastPathComponent)
                }
            }
        }
        #expect(offenders.isEmpty, "membership rejection still referenced in: \(offenders.sorted())")
    }
}

// MARK: - The launch capability over the open universe

@MainActor
@Suite
struct OpenAppOverTheInstalledUniverseTests {
    /// The headline acceptance criterion: an installed app the catalog never carried opens by name,
    /// through the real capability, the real risk gate and the real opener seam.
    @Test
    func anInstalledNonCatalogAppOpensByName() async throws {
        let fixture = try Fixture(installed: [Fixture.figma])
        defer { fixture.tearDown() }

        let preview = try fixture.executor.preview(plan: Fixture.openAppPlan("Figma"))
        let result = try await fixture.executor.execute(plan: Fixture.openAppPlan("Figma")) { _, _ in }

        #expect(preview.first?.title == "Open the Figma app")
        #expect(preview.first?.opens == ["Figma"])
        #expect(fixture.appOpener.openedBundleIDs == ["com.figma.Desktop"])
        #expect(result.summary == "Opened the Figma app.")
    }

    /// The preview's second detail line, which replaced "Allowed apps: <the twelve>". It names the
    /// bundle that will actually start — the disclosure that makes launching by name legible when two
    /// apps can share a display name.
    @Test
    func thePreviewDisclosesTheBundleAndTheInstallLocationRatherThanARoster() throws {
        let fixture = try Fixture(installed: [Fixture.figma])
        defer { fixture.tearDown() }

        let preview = try #require(fixture.executor.preview(plan: Fixture.openAppPlan("Figma")).first)

        #expect(preview.details == ["Bundle: com.figma.Desktop", "Installed at: /Applications/Figma.app"])
        #expect(!preview.details.contains { $0.hasPrefix("Allowed apps:") })
    }

    /// Launch is not control. E6 bars Sonny from ever *controlling* a terminal — typing into one is
    /// arbitrary shell execution (§7.4), and that holds for a perfectly accurate model — and C12
    /// states the other half explicitly: terminals stay launchable. Pinned because "terminals are
    /// special" is exactly the kind of rule a later reader over-applies.
    @Test
    func terminalsRemainLaunchable() async throws {
        let fixture = try Fixture(installed: [Fixture.terminal, Fixture.iTerm])
        defer { fixture.tearDown() }

        _ = try await fixture.executor.execute(plan: Fixture.openAppPlan("Terminal")) { _, _ in }
        _ = try await fixture.executor.execute(plan: Fixture.openAppPlan("iTerm")) { _, _ in }

        #expect(fixture.appOpener.openedBundleIDs == ["com.apple.Terminal", "com.googlecode.iterm2"])
    }

    /// The tier and the gating are untouched by the dissolution: `open_app` was tier 1 before the
    /// allowlist went and is tier 1 after, through the same `prepare -> assessRisk -> execute` path.
    /// C12 loosened no authority — it removed a capability hedge — and this is the pin that says so.
    @Test
    func openingAnyInstalledAppIsStillTierOneWithNoNewConsentSurface() throws {
        let fixture = try Fixture(installed: [Fixture.figma])
        defer { fixture.tearDown() }

        let assessment = try fixture.executor.assessRisk(plan: Fixture.openAppPlan("Figma"), scope: .unscoped)

        #expect(assessment.effectiveTier == .tier1)
        #expect(assessment.escalations.isEmpty)
        #expect(OpenAppCapabilityAdapter.metadata.defaultRiskTier == .tier1)
        #expect(OpenAppCapabilityAdapter.metadata.requiredPermissions.map(\.requirement) == [.appOpening])
    }

    // MARK: - Workspace open, over the same seam

    /// The second catalog-consulting launch path, which soft-skipped rather than refusing. Both doors
    /// now ask the same question: the installed non-catalog entry launches, the uninstalled one is
    /// skipped in its own position with the new wording, and the walk stays in stored order.
    @Test
    func aWorkspaceLaunchesItsInstalledNonCatalogEntriesAndSkipsTheRest() async throws {
        let fixture = try Fixture(installed: [Fixture.figma, Fixture.safari])
        defer { fixture.tearDown() }
        try fixture.workspaceStore.save(
            StoredWorkspace(name: "Design", apps: ["Figma", "Microsoft Word", "Safari"], urls: [])
        )

        var logs: [String] = []
        let result = try await fixture.executor.execute(plan: Fixture.openWorkspacePlan("Design")) { _, message in
            logs.append(message)
        }

        #expect(fixture.appOpener.openedBundleIDs == ["com.figma.Desktop", "com.apple.Safari"])
        #expect(logs.contains("Skipping Microsoft Word — it isn't installed on this Mac; it counts for workspace scope only."))
        #expect(result.summary == "Opened workspace Design with 2 app(s) and 0 URL(s). Microsoft Word isn't installed and was not opened.")
        // Order preserved: the skip is narrated between the two launches, where the user expects it.
        let opening = logs.filter { $0.hasPrefix("Opening ") || $0.hasPrefix("Skipping ") }
        #expect(opening == ["Opening Figma", "Skipping Microsoft Word — it isn't installed on this Mac; it counts for workspace scope only.", "Opening Safari"])
    }

    /// `WorkspaceBrowserCatalog` has carried Arc, Firefox and Edge since SONNY-24 as dead weight:
    /// only catalog-resolved apps ever reached `firstBrowser`, and the catalog carried neither. The
    /// file's own comment anticipated exactly this widening. Now a workspace listing Arc opens its
    /// URLs in Arc.
    @Test
    func aWorkspaceListingArcOpensItsURLsInArc() async throws {
        let fixture = try Fixture(installed: [Fixture.arc])
        defer { fixture.tearDown() }
        try fixture.workspaceStore.save(
            StoredWorkspace(name: "Reading", apps: ["Arc"], urls: ["https://github.com"])
        )

        _ = try await fixture.executor.execute(plan: Fixture.openWorkspacePlan("Reading")) { _, _ in }

        #expect(fixture.browserOpener.openedURLs == [URL(string: "https://github.com")!])
        #expect(fixture.browserOpener.openedBrowsers == [MacApp(displayName: "Arc", bundleIdentifier: "company.thebrowser.Browser")])
    }

    /// Firefox and Edge, the other two that were unreachable. Pinned as a table so that a change to
    /// the browser set fails here rather than silently sending a workspace's links to the system
    /// default.
    @Test
    func firefoxAndEdgeAreAlsoReachableNow() async throws {
        for browser in [Fixture.firefox, Fixture.edge] {
            let fixture = try Fixture(installed: [browser])
            defer { fixture.tearDown() }
            try fixture.workspaceStore.save(
                StoredWorkspace(name: "Reading", apps: [browser.displayName], urls: ["https://github.com"])
            )

            _ = try await fixture.executor.execute(plan: Fixture.openWorkspacePlan("Reading")) { _, _ in }

            #expect(fixture.browserOpener.openedBrowsers == [browser.macApp])
        }
    }

    /// The three doors into a workspace's apps list — create, edit and open — read one rule, and the
    /// rule now answers "is it installed". Pinned across all three at once, because the drift this
    /// shared rule exists to prevent is exactly the one where a name means something different
    /// depending on which door it came through (SONNY-40 shipped the edit path without the
    /// disclosure once already).
    @Test
    func createEditAndOpenAllDiscloseTheSameNarrowedScopeOnlySet() async throws {
        let fixture = try Fixture(installed: [Fixture.figma])
        defer { fixture.tearDown() }

        let created = try await fixture.executor.execute(
            plan: Fixture.createWorkspacePlan("Design", apps: ["Figma", "Sketch"])
        ) { _, _ in }
        let edited = try await fixture.executor.execute(
            plan: Fixture.editWorkspacePlan("Design", addApps: ["Discord"])
        ) { _, _ in }
        let opened = try await fixture.executor.execute(plan: Fixture.openWorkspacePlan("Design")) { _, _ in }

        // Figma is installed, so it is disclosed by none of the three; Sketch and Discord are not.
        #expect(created.summary.hasSuffix("Sketch isn't installed on this Mac — counted for workspace scope only."))
        #expect(edited.summary.hasSuffix("Discord isn't installed on this Mac — counted for workspace scope only."))
        #expect(opened.summary.hasSuffix("Sketch and Discord aren't installed and were not opened."))
        #expect(fixture.appOpener.openedBundleIDs == ["com.figma.Desktop"])
    }

    // MARK: - Fixture

    struct Fixture {
        static let figma = InstalledApp(displayName: "Figma", bundleIdentifier: "com.figma.Desktop", applicationURL: URL(fileURLWithPath: "/Applications/Figma.app"))
        static let safari = InstalledApp(displayName: "Safari", bundleIdentifier: "com.apple.Safari", applicationURL: URL(fileURLWithPath: "/Applications/Safari.app"))
        static let terminal = InstalledApp(displayName: "Terminal", bundleIdentifier: "com.apple.Terminal", applicationURL: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
        static let iTerm = InstalledApp(displayName: "iTerm", bundleIdentifier: "com.googlecode.iterm2", applicationURL: URL(fileURLWithPath: "/Applications/iTerm.app"))
        static let arc = InstalledApp(displayName: "Arc", bundleIdentifier: "company.thebrowser.Browser", applicationURL: URL(fileURLWithPath: "/Applications/Arc.app"))
        static let firefox = InstalledApp(displayName: "Firefox", bundleIdentifier: "org.mozilla.firefox", applicationURL: URL(fileURLWithPath: "/Applications/Firefox.app"))
        static let edge = InstalledApp(displayName: "Edge", bundleIdentifier: "com.microsoft.edgemac", applicationURL: URL(fileURLWithPath: "/Applications/Edge.app"))

        let root: URL
        let executor: AgentActionExecutor
        fileprivate let appOpener: RecordingAppOpener
        fileprivate let browserOpener: RecordingBrowserOpener
        let workspaceStore: WorkspaceStore

        @MainActor
        init(installed: [InstalledApp]) throws {
            root = try makeDirectory()
            appOpener = RecordingAppOpener()
            browserOpener = RecordingBrowserOpener()
            workspaceStore = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
            executor = AgentActionExecutor(
                whitelist: PathWhitelist(roots: [root]),
                browserOpener: browserOpener,
                installedAppResolver: InstalledAppResolver(source: FixedAppSource(installed)),
                appOpener: appOpener,
                routineStore: RoutineStore(fileURL: root.appendingPathComponent("routines.json")),
                workspaceStore: workspaceStore,
                clipboardHistoryStore: UnreachableLocalStores.clipboardHistory(),
                snippetStore: UnreachableLocalStores.snippets(),
                recentArtifactStore: UnreachableLocalStores.recentArtifacts(),
                shortcutRunHistoryStore: UnreachableLocalStores.shortcutRunHistory()
            )
        }

        func tearDown() {
            try? FileManager.default.removeItem(at: root)
        }

        static func openAppPlan(_ appName: String) -> AgentPlan {
            AgentPlan(
                summary: "Open \(appName).",
                requiresConfirmation: true,
                steps: [AgentStep(id: "open-app", operation: .openApp, description: "Open \(appName).", appName: appName)]
            )
        }

        static func openWorkspacePlan(_ name: String) -> AgentPlan {
            AgentPlan(
                summary: "Open workspace \(name).",
                requiresConfirmation: true,
                steps: [AgentStep(id: "open-workspace", operation: .openWorkspace, description: "Open \(name).", workspaceName: name)]
            )
        }

        static func createWorkspacePlan(_ name: String, apps: [String]) -> AgentPlan {
            AgentPlan(
                summary: "Save workspace \(name).",
                requiresConfirmation: true,
                steps: [
                    AgentStep(
                        id: "create-workspace",
                        operation: .createWorkspace,
                        description: "Save \(name).",
                        workspaceName: name,
                        workspaceApps: apps,
                        workspaceURLs: []
                    )
                ]
            )
        }

        static func editWorkspacePlan(_ name: String, addApps: [String]) -> AgentPlan {
            AgentPlan(
                summary: "Edit workspace \(name).",
                requiresConfirmation: true,
                steps: [
                    AgentStep(
                        id: "edit-workspace",
                        operation: .editWorkspace,
                        description: "Edit \(name).",
                        workspaceName: name,
                        workspaceApps: addApps
                    )
                ]
            )
        }
    }
}

// MARK: - Shared helpers

private extension InstalledAppResolverTests {
    func sourceFile(named name: String) -> URL {
        // <package root>/Tests/MacAgentCoreTests/<this file>
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/MacAgentCore/\(name)")
    }

    /// Swift source with `//` and `///` comments removed, so a source-scanning assertion reads what
    /// the compiler reads rather than what the file says about itself.
    ///
    /// Line-oriented and deliberately simple: it does not understand `//` inside a string literal,
    /// which is sound for every needle these sweeps look for — each is either an identifier or a
    /// user-facing sentence, and neither contains a double slash. Block comments are not used in this
    /// repo's Swift.
    static func strippingComments(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let slashes = line.range(of: "//") else {
                    return line
                }
                return line[line.startIndex..<slashes.lowerBound]
            }
            .joined(separator: "\n")
    }

    /// A real application bundle, minimal but genuine: `Bundle(url:)` needs `Contents/Info.plist` to
    /// report a bundle identifier, and the sweep has to be exercised against something it can read
    /// rather than against a stubbed reader.
    @discardableResult
    static func makeApplicationBundle(named name: String, bundleIdentifier: String, in directory: URL) throws -> URL {
        let bundleURL = directory.appendingPathComponent("\(name).app", isDirectory: true)
        let contents = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleName": name,
            "CFBundlePackageType": "APPL"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return bundleURL
    }
}

@MainActor
private final class RecordingAppOpener: AppOpening {
    private(set) var openedBundleIDs: [String] = []

    func open(bundleIdentifier: String) async throws {
        openedBundleIDs.append(bundleIdentifier)
    }
}

private final class RecordingBrowserOpener: BrowserOpening {
    private(set) var openedURLs: [URL] = []
    /// Parallel to `openedURLs`: the browser each open was targeted at, `nil` for the system default.
    private(set) var openedBrowsers: [MacApp?] = []

    func open(_ url: URL, using browser: MacApp?) async throws {
        openedURLs.append(url)
        openedBrowsers.append(browser)
    }
}
