import Foundation
import MacAgentTestSupport
import Testing
@testable import MacAgent
@testable import MacAgentCore

/// **"Exactly one gate, and no free capability blocks"** — SONNY-213's acceptance criterion as a
/// population scan rather than as a claim a reviewer has to re-derive.
///
/// The behavioural halves live elsewhere: `ScreenControlGateTests` drives the gate's own rules and
/// runs three free capabilities with no billing wiring in reach, and `VisionSessionRunTests` drives
/// the door and the mid-run halt through the real loop. What only a scan can hold is the *negative*
/// — that nothing else in either target can consult a gate at all — because a capability that has
/// not acquired the dependency looks exactly like one that has and happens not to have been driven
/// by a test.
///
/// Both scans read comment-stripped source through `MacAgentSource`, whose own doc records why a
/// count is trusted where mere presence is not, and both carry a control that fires.
@Suite
@MainActor
struct ScreenControlGateReachTests {
    /// Every name by which the gate, its verdicts or its allowance reader could be reached.
    ///
    /// **Deliberately not `ScreenControlPolicy`, `ScreenControlRefusal` or `ScreenControlVerdict`**:
    /// those are the terminal ban, a different rule that many files legitimately consult, and
    /// folding them in would make this scan fail for reasons that have nothing to do with billing.
    static let gateTokens = [
        "ScreenControlGating",
        "ScreenControlGateDecision",
        "ScreenControlGateRefusal",
        "ScreenControlGateMoment",
        "SonnyScreenControlGate",
        "ClosedScreenControlGate",
        "screenControlGate",
        "ScreenControlEntitlementConfirming"
    ]

    /// The *figure* the gate reads, which is a different population from the gate and has to be
    /// scanned separately — **it was one list until SONNY-214 landed** (PR #188).
    ///
    /// `ScreenControlAllowance` sat in `gateTokens` while the gate was its only consumer, and that
    /// stopped being true the moment SONNY-214 put "3 of 20 left" in the Account section and a runs-
    /// left line in the widget. Five app files legitimately name it now, and none of them names a
    /// gate token.
    ///
    /// **Merging the two lists would have been the quiet mistake, so it is written down rather than
    /// avoided by luck.** Adding those five files to one shared permitted set makes the set say
    /// "these files may name *anything* in the billing vocabulary" — after which a usage view
    /// acquiring `screenControlGate` and refusing to render on it passes the scan, because the file
    /// is already permitted. Splitting keeps the enforcement surface's set at exactly the files that
    /// enforce, which is the criterion this suite exists for; the figure's own set is wider because
    /// reading a number a user is shown is not gating on it. This is the same reasoning the token
    /// list already gives for excluding the terminal ban: a rule many files legitimately consult
    /// makes a scan fail for reasons that have nothing to do with billing.
    static let allowanceTokens = ["ScreenControlAllowance"]

    /// The files in `Sources/` allowed to name any of the above, and **why each one is on the list**.
    /// Exact equality below, so this fails in both directions: a tenth file acquiring the dependency
    /// fails it, and so does one of these losing it under a rename.
    static let permittedFiles: Set<String> = [
        // The gate itself.
        "ScreenControlGate.swift",
        // The vision path: the aggregate that carries the gate, the door, the loop's halt, and the
        // refusal the halt ends with.
        "VisionSessionEnvironment.swift",
        "VisionSessionCapabilityAdapter.swift",
        "VisionSessionRunner.swift",
        "VisionSessionContainment.swift",
        // The app's wiring: the property, the factory parameter, and the one line that installs the
        // live gate.
        "AgentViewModel.swift",
        "AgentViewModel+VisionSession.swift",
        "main.swift"
    ]

    /// The files that may name the allowance *figure*. Wider than the set above by exactly SONNY-214's
    /// readers, and each one is a place a user is shown a number rather than a place anything is
    /// refused.
    static let permittedAllowanceFiles: Set<String> = [
        // The figure's own type, and the gate that reads it to decide.
        "ScreenControlAllowance.swift",
        "ScreenControlGate.swift",
        // The app's wiring: the view model holds the last read and the composition root builds the
        // service.
        "AgentViewModel.swift",
        "main.swift",
        // SONNY-214's surfaces (PR #188): the sentence, the Account section that hosts it, the
        // widget's in-task line, and the first-run sequence that shows what a new account has.
        "ScreenControlUsagePresentation.swift",
        "SignInView.swift",
        "CommandCenterView.swift",
        "FloatingWidgetView.swift",
        "FirstRunSequence.swift"
    ]

    @Test
    func onlyTheVisionPathAndItsWiringCanNameTheGate() throws {
        var namingTheGate: Set<String> = []
        var namingTheFigure: Set<String> = []
        var scanned = 0

        for url in try MacAgentSource.coreSourceFiles() + MacAgentSource.appSourceFiles() {
            scanned += 1
            let source = try MacAgentSource.read(url)
            if Self.gateTokens.contains(where: source.contains) {
                namingTheGate.insert(url.lastPathComponent)
            }
            if Self.allowanceTokens.contains(where: source.contains) {
                namingTheFigure.insert(url.lastPathComponent)
            }
        }

        // A walker that reached nothing reads exactly like a tree with nothing to find, and this
        // repository has had a scan pass by matching no file at all.
        #expect(scanned > 150, "the scan read \(scanned) files — too few to be both source trees")
        #expect(
            namingTheGate == Self.permittedFiles,
            Comment(rawValue: """
            The set of files naming the screen-control gate is not the permitted set.
            Unexpected: \(namingTheGate.subtracting(Self.permittedFiles).sorted())
            Missing:    \(Self.permittedFiles.subtracting(namingTheGate).sorted())
            """)
        )
        #expect(
            namingTheFigure == Self.permittedAllowanceFiles,
            Comment(rawValue: """
            The set of files naming the allowance figure is not the permitted set.
            Unexpected: \(namingTheFigure.subtracting(Self.permittedAllowanceFiles).sorted())
            Missing:    \(Self.permittedAllowanceFiles.subtracting(namingTheFigure).sorted())
            """)
        )
        // **The split is only safe while the two vocabularies stay distinct.** If a token ever
        // appeared in both lists, the wider permitted set would silently license the narrower one's
        // files — the exact weakening the header argues against — so the disjointness is asserted
        // rather than maintained by care.
        #expect(Set(Self.gateTokens).isDisjoint(with: Set(Self.allowanceTokens)))
    }

    /// **No capability adapter but the vision one names the gate**, stated over the adapters as a
    /// population of their own.
    ///
    /// The scan above already implies this, and it is asserted separately because the two fail for
    /// different reasons and a reader chasing "did a free capability start blocking?" should meet a
    /// test that asks exactly that. It also carries its own floor: the adapters are the population
    /// §16.3's guarantee is about.
    @Test
    func noCapabilityAdapterButTheVisionOneNamesTheGate() throws {
        var adapters: [String] = []
        var offenders: [String] = []

        for url in try MacAgentSource.coreSourceFiles()
        where url.lastPathComponent.hasSuffix("CapabilityAdapter.swift") {
            adapters.append(url.lastPathComponent)
            guard url.lastPathComponent != "VisionSessionCapabilityAdapter.swift" else { continue }
            let source = try MacAgentSource.read(url)
            // **Both vocabularies here, unlike the file-set scan above.** No capability adapter
            // should reach the gate *or* the figure: reading a run count is how an adapter would
            // build a second gate under another name, and SONNY-214's readers are surfaces rather
            // than adapters, so nothing legitimate is caught by widening this one.
            for token in Self.gateTokens + Self.allowanceTokens where source.contains(token) {
                offenders.append("\(url.lastPathComponent) names \(token)")
            }
        }

        // The floor is a real count of a real population: `DefaultCapabilityAdapters.all(_:)` is
        // what the executor dispatches through, and every one of its members is one of these
        // files. The revealer is `{ _ in }` because this test counts the list and executes none of
        // it — the argument exists at all because SONNY-395 removed its default.
        let registered = DefaultCapabilityAdapters.all(finderRevealer: { _ in }).count
        #expect(
            adapters.count >= registered,
            "the scan saw \(adapters.count) adapter files against \(registered) registered adapters"
        )
        #expect(adapters.contains("VisionSessionCapabilityAdapter.swift"))
        #expect(
            offenders.isEmpty,
            Comment(rawValue: "a capability adapter consults the billing gate:\n"
                + offenders.joined(separator: "\n"))
        )
    }

    /// **There are exactly two consult sites, and they are the two the ticket names.**
    ///
    /// This is the "exactly one gate" criterion at its sharpest: one gate consulted at two moments
    /// is the design, and a third consult would be a second gate however it was named. A count
    /// rather than a presence check, for `MacAgentSource`'s own recorded reason — a trailing comment
    /// can add a token but cannot remove one, so counts survive what presence does not.
    @Test
    func theGateIsConsultedAtExactlyTwoSitesAndTheyAreTheDoorAndTheBoundary() throws {
        var consultsByFile: [String: Int] = [:]

        for url in try MacAgentSource.coreSourceFiles() + MacAgentSource.appSourceFiles() {
            let source = try MacAgentSource.read(url)
            let count = source.components(separatedBy: "screenControlGate.decide(").count - 1
            if count > 0 {
                consultsByFile[url.lastPathComponent] = count
            }
        }

        #expect(
            consultsByFile == [
                "VisionSessionCapabilityAdapter.swift": 1,
                "VisionSessionRunner.swift": 1
            ],
            "consult sites: \(consultsByFile)"
        )

        // Each site asks about its own moment, and the two are different. A door that asked
        // `.stepBoundary` would silently inherit the boundary's read-failure tolerance and stop
        // failing closed — the exact inversion this ticket is about, invisible to every assertion
        // above.
        let door = try MacAgentSource.read(
            MacAgentSource.coreSourceDirectory.appendingPathComponent("VisionSessionCapabilityAdapter.swift")
        )
        let loop = try MacAgentSource.read(
            MacAgentSource.coreSourceDirectory.appendingPathComponent("VisionSessionRunner.swift")
        )
        #expect(door.contains("screenControlGate.decide(at: .sessionStart)"))
        #expect(!door.contains("screenControlGate.decide(at: .stepBoundary)"))
        #expect(loop.contains("screenControlGate.decide(at: .stepBoundary)"))
        #expect(!loop.contains("screenControlGate.decide(at: .sessionStart)"))
    }

    /// **The boundary's figure reaches no surface, so the gate and SONNY-214's usage line cannot
    /// tell the user two different things.**
    ///
    /// The two consumers of one allowance read the product's *published* number differently on
    /// purpose: SONNY-214 renders `runsLeft` ("3 of 20 left", and the in-task "1 run left"), and this
    /// gate's **door** refuses on exactly that same field, so a user shown "0 left" is refused and a
    /// user shown "1 left" is admitted — they cannot disagree, because they are one number.
    ///
    /// `creditsRemaining` is the other half of the gate's reading and it answers a different
    /// question — may the run already admitted *continue* — which no surface asks and no surface
    /// should answer. **If it were ever rendered it would be the second number in the product that
    /// `WireScreenControlAllowance`'s own note was written to prevent**, and the first thing it would
    /// do is contradict the line beside it: an account reading "0 runs left" has real credit behind
    /// it for the length of one session. So the property is that the figure stays inside `MacAgentCore`.
    ///
    /// A file count rather than a token search over one file, and a floor under the walk, for the
    /// same reason as the scans above: an empty walk reads exactly like a clean one.
    @Test
    func theBoundarysFigureNeverReachesAUserFacingSurface() throws {
        var naming: [String] = []
        var scanned = 0

        for url in try MacAgentSource.appSourceFiles() {
            scanned += 1
            if try MacAgentSource.read(url).contains("creditsRemaining") {
                naming.append(url.lastPathComponent)
            }
        }

        #expect(scanned > 25, "the scan read \(scanned) app files — too few to be the app target")
        #expect(
            naming.isEmpty,
            Comment(rawValue: "the step boundary's credit figure reached the app target, where the "
                + "only allowance number a user may be shown is `runsLeft`:\n"
                + naming.joined(separator: "\n"))
        )

        // The control: the field really is in the tree under the name this scan looks for, so an
        // empty result above is a measurement rather than a typo. It is read from the core target,
        // which is where it is allowed to be.
        let allowance = try MacAgentSource.read(
            MacAgentSource.coreSourceDirectory.appendingPathComponent("ScreenControlAllowance.swift")
        )
        #expect(allowance.contains("creditsRemaining"))
    }

    /// The rule run over a held sample, so it is shown to flag what it names rather than only to
    /// pass against the current tree — the shape `LocalStoreInjectionScanTests` adopted after a
    /// mutant survived a guard that had only ever been run against the real thing.
    @Test
    func theScanWouldFlagAnAdapterThatAcquiredTheGate() throws {
        let planted = """
        import Foundation
        struct OpenAppCapabilityAdapter {
            let gate: any ScreenControlGating
        }
        """
        #expect(Self.gateTokens.contains { planted.contains($0) })

        // And a real free adapter, read the way the scan reads it, names none of them — with a
        // control that the file was actually read, because an empty string satisfies the line above.
        let free = try MacAgentSource.read(
            MacAgentSource.coreSourceDirectory.appendingPathComponent("RunRoutineCapabilityAdapter.swift")
        )
        #expect(!Self.gateTokens.contains { free.contains($0) })
        #expect(free.contains("RunRoutineCapabilityAdapter"))
    }
}

/// **The wiring, driven rather than scanned** (PR #190's F2).
///
/// The scans above prove which files may *name* the gate. They cannot prove that the gate
/// `main.swift` installs is the one a real session ends up consulting, and that turned out to be the
/// difference between a held property and an unheld one: replacing `screenControlGate:` inside
/// `AgentViewModel.makeLiveVisionEnvironment` with a fresh `ClosedScreenControlGate()` left the whole
/// suite green. The scan could not see it — `ClosedScreenControlGate` is already a permitted name in
/// that file, so the token set does not change — and no behavioural test could, because every vision
/// test assigns `viewModel.visionSessionEnvironment` directly and never calls the builder.
///
/// One line of product behaviour, and it is the only line: this is the sole path from the installed
/// gate to the environment a session runs against.
@Suite
@MainActor
struct ScreenControlGateWiringTests {
    /// The environment the view model builds carries **the gate that was installed on it**, not a
    /// fresh one and not a default.
    ///
    /// Driven through `makeLiveVisionEnvironment`, the real builder, and asserted by *consulting* the
    /// gate rather than by comparing identity: identity would pass on a copy that had lost its
    /// answers, and what the product needs is that the installed gate's verdict is the verdict a
    /// session gets. The scripted gate refuses, which no default in this path does — `AgentViewModel`
    /// starts at `ClosedScreenControlGate`, which also refuses — so the assertion is on the
    /// *distinguishing* evidence: the scripted gate records that it was the one asked.
    @Test
    func theEnvironmentCarriesTheGateThatWasInstalledOnTheViewModel() async {
        let viewModel = Self.makeViewModel()
        let installed = ScriptedScreenControlGate(thereafter: .refused(.allowanceExhausted))
        viewModel.screenControlGate = installed

        let environment = viewModel.makeLiveVisionEnvironment(recordingPolicy: .record)
        let decision = await environment.screenControlGate.decide(at: .sessionStart)

        // The installed gate answered, and it is the one that was asked — `consults` is what tells a
        // carried gate apart from a look-alike default that happens to refuse for its own reasons.
        #expect(decision == .refused(.allowanceExhausted))
        #expect(installed.consults == [.sessionStart])
    }

    /// And the same builder carries a *permissive* gate through unchanged.
    ///
    /// **The direction that matters, because every default on this path refuses.** Without this the
    /// test above passes on a mutant that ignores the installed gate entirely and hard-codes a closed
    /// one — the exact mutant that survived — since a closed gate also answers "refused". A gate that
    /// allows is a verdict no default in reach can produce.
    @Test
    func aPermissiveGateReachesTheEnvironmentUnchanged() async {
        let viewModel = Self.makeViewModel()
        viewModel.screenControlGate = ScriptedScreenControlGate.permissive()

        let environment = viewModel.makeLiveVisionEnvironment(recordingPolicy: .record)

        #expect(await environment.screenControlGate.decide(at: .sessionStart) == .allowed)
        #expect(await environment.screenControlGate.decide(at: .stepBoundary) == .allowed)
    }

    /// Every store unreachable: this suite constructs a view model to read one wired dependency off
    /// it and touches no local data at all.
    private static func makeViewModel() -> AgentViewModel {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenControlGateWiringTests-\(UUID().uuidString)", isDirectory: true)
        let clipboardSettings = ClipboardHistorySettingsStore(
            fileURL: scratch.appendingPathComponent("clipboard-history-settings.json")
        )
        return AgentViewModel(
            routineStore: UnreachableLocalStores.routines(),
            workspaceStore: UnreachableLocalStores.workspaces(),
            snippetStore: UnreachableLocalStores.snippets(),
            recentArtifactStore: UnreachableLocalStores.recentArtifacts(),
            finderRevealer: { _ in },
            shortcutRunHistoryStore: UnreachableLocalStores.shortcutRunHistory(),
            taskHistoryStore: UnreachableLocalStores.taskHistory(),
            taskPlanDetailStore: UnreachableLocalStores.taskPlanDetails(),
            visionSessionJournalStore: UnreachableLocalStores.visionSessionJournal(),
            clipboardHistorySettingsStore: clipboardSettings,
            approvedAppStore: UnreachableLocalStores.approvedApps(),
            outputLocationStore: UnreachableLocalStores.outputLocations(),
            resumableTaskStore: UnreachableLocalStores.resumableTasks(),
            pendingServerDeletionStore: UnreachableLocalStores.pendingServerDeletions(),
            standingWatcherObserver: UnreachableStandingWatcherObserver(),
            clipboardHistoryMonitor: ClipboardHistoryMonitor(
                store: UnreachableLocalStores.clipboardHistory(),
                settingsStore: clipboardSettings
            ),
            // Nothing here deletes anything.
            localDataDeletionService: LocalDataDeletionService(fileURLs: []),
            backendClient: makeHermeticBackendClient(),
            userDefaults: UserDefaults(
                suiteName: "ScreenControlGateWiringTests-\(UUID().uuidString)"
            ) ?? .standard
        )
    }
}
