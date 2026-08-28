import Foundation
import Testing
@testable import MacAgentCore

/// A test may never reach a local store the developer's own app uses (SONNY-240).
///
/// **The failure this exists for happened twice, on the founder's Mac.** `AgentViewModel.init` used
/// to default ten store parameters to a store at the *real*
/// `~/Library/Application Support/Sonny/` path, and a fixture that did not pass one had its tests
/// writing to the developer's own data — encrypted with the deterministic key
/// `LocalStorageEncryption` substitutes inside a test process, so the packaged app could not decrypt
/// its own file and showed a storage banner. Per SONNY-239 there is no recovery from inside the
/// product: every path into these stores loads before it writes. Diagnosed at `f7d3553` — the file
/// decrypted under `Data(repeating: 0x53, count: 32)` and not under the Keychain key, and all 50 of
/// its entries were test temp directories belonging to four named suites.
///
/// **The enforcement is the compiler; this suite covers the two things a compiler cannot see.** The
/// initializer has no defaulted store any more, so a fixture that omits one does not build — which
/// is what closes the hole, and it is not something a test can demonstrate (an omission that does
/// not compile cannot be written down here to fail). What a test *can* do is the rest:
///
/// 1. **The defaults cannot come back.** A parameter re-defaulted for convenience would silently
///    restore the whole mechanism, and every existing fixture would keep compiling — which is
///    exactly how it arrived the first time.
/// 2. **A store may be passed and still point at the real path.** `taskHistoryStore:
///    TaskHistoryStore()` satisfies the compiler and writes to `~/Library` regardless. Nothing in
///    the type system distinguishes it from a store at a temp root.
///
/// **The population is `LocalStore.allCases`**, which already refuses a new store file without a
/// case, so a fourteenth store cannot reach the tree without being mapped here — and being mapped
/// here is what puts it on the initializer without a default.
///
/// **This replaces `OutputLocationFixtureWiringScanTests`**, which checked the same two things for
/// two named stores and said in its own comment that SONNY-240 was the ticket that generalises it.
/// Its fixture-omission check is gone rather than generalised, because the compiler now does that
/// job better than a scan can: the scan could only fail after the damage was already written, and
/// only for a store somebody had remembered to name in it.
///
/// **In the core target because `TestSourceTree` is**, and a second copy of this repository's
/// comment-stripping discipline is exactly what its own doc warns against.
/// `LivePermissionCheckerScanTests` already scans across targets from here, so the direction is
/// precedented.
@Suite
struct LocalStoreInjectionScanTests {
    /// How each local store reaches an `AgentViewModel`.
    ///
    /// A `switch` with no `default`, so a fourteenth `LocalStore` case does not compile until
    /// somebody answers this question for it — the same device `LocalStore.kind` and
    /// `LocalStore.memoryCategory` already use, and the reason a new store cannot slip past them.
    struct Injection {
        /// The initializer's argument label, or `nil` for a store that arrives inside something else.
        let parameterLabel: String?
        /// The Swift type a call site constructs, for the file-URL sweep below.
        let typeName: String
    }

    static func injection(of store: LocalStore) -> Injection {
        switch store {
        case .routines:
            return Injection(parameterLabel: "routineStore", typeName: "RoutineStore")
        case .workspaces:
            return Injection(parameterLabel: "workspaceStore", typeName: "WorkspaceStore")
        case .clipboardHistory:
            // **The one store that is not a parameter of its own.** It reaches the view model inside
            // `ClipboardHistoryMonitor`, whose own defaults are this file *and* the real system
            // pasteboard — so a fixture that let the monitor default had one that would have copied
            // the developer's actual clipboard into the developer's actual store. The monitor
            // parameter is therefore required too, asserted separately below.
            return Injection(parameterLabel: nil, typeName: "ClipboardHistoryStore")
        case .clipboardHistorySettings:
            return Injection(
                parameterLabel: "clipboardHistorySettingsStore",
                typeName: "ClipboardHistorySettingsStore"
            )
        case .snippets:
            return Injection(parameterLabel: "snippetStore", typeName: "SnippetStore")
        case .recentArtifacts:
            return Injection(parameterLabel: "recentArtifactStore", typeName: "RecentArtifactStore")
        case .shortcutRunHistory:
            return Injection(
                parameterLabel: "shortcutRunHistoryStore",
                typeName: "ShortcutRunHistoryStore"
            )
        case .taskHistory:
            return Injection(parameterLabel: "taskHistoryStore", typeName: "TaskHistoryStore")
        case .taskPlanDetails:
            return Injection(parameterLabel: "taskPlanDetailStore", typeName: "TaskPlanDetailStore")
        case .visionSessionJournal:
            return Injection(
                parameterLabel: "visionSessionJournalStore",
                typeName: "VisionSessionJournalStore"
            )
        case .approvedApps:
            return Injection(parameterLabel: "approvedAppStore", typeName: "ApprovedAppStore")
        case .outputLocations:
            return Injection(parameterLabel: "outputLocationStore", typeName: "OutputLocationStore")
        case .resumableTasks:
            return Injection(parameterLabel: "resumableTaskStore", typeName: "ResumableTaskStore")
        }
    }

    /// Parameters that are not stores and are required for the same reason.
    ///
    /// `clipboardHistoryMonitor` carries the thirteenth store and the system pasteboard.
    /// `localDataDeletionService` is worse than either: its default is the real file list and the
    /// service *deletes* what it is given, so a fixture that let it default and then exercised the
    /// wipe would have erased the developer's data rather than corrupted it.
    ///
    /// `finderRevealer` is the third, and it is the one that shows this list is about a *shape*
    /// rather than about stores (SONNY-239). It touches no file at all — its live implementation is
    /// `NSWorkspace.activateFileViewerSelecting`, so the worst a fixture that let it default could
    /// do is steal focus and open Finder windows in the middle of a suite run. It landed defaulted,
    /// which is the whole argument against defaults arriving one parameter at a time: "a call site
    /// that predates the parameter cannot know to pass it" does not care what the parameter is for.
    static let otherRequiredParameters = [
        "clipboardHistoryMonitor",
        "localDataDeletionService",
        "finderRevealer"
    ]

    /// The real-store factory's name, **assembled at run time so the literal never appears in this
    /// file**, which the sweep below reads like any other test source. `TestSourceTree.codeLines`
    /// drops comment-prefixed lines, so naming the method in prose is free — a string literal
    /// spelling it out is not, and one in a failure message is what made this constant shared rather
    /// than local to the sweep.
    static var realStoreFactoryName: String { "atItsRealStore" + "Locations" }

    // MARK: - 1. The defaults cannot come back

    @Test
    func everyLocalStoreIsAnUndefaultedParameterOfTheViewModelsInitializer() throws {
        let parameters = try Self.initializerParameters()
        // A parse that found nothing reads exactly like a signature with no defaults.
        #expect(
            parameters.count > 20,
            "parsed \(parameters.count) initializer parameters — too few to be the real signature"
        )

        var expectedLabels: Set<String> = []
        for store in LocalStore.allCases {
            guard let label = Self.injection(of: store).parameterLabel else {
                continue
            }
            expectedLabels.insert(label)
        }
        // Twelve of the thirteen; `.clipboardHistory` is the one inside the monitor.
        #expect(expectedLabels.count == LocalStore.allCases.count - 1)

        var checkedLabels: Set<String> = []
        for label in expectedLabels.sorted() + Self.otherRequiredParameters {
            checkedLabels.insert(label)
            guard let parameter = parameters.first(where: { $0.label == label }) else {
                Issue.record("`AgentViewModel.init` has no `\(label):` parameter any more")
                continue
            }
            #expect(
                !parameter.hasDefault,
                """
                `AgentViewModel.init`'s `\(label):` has a default again. A defaulted store is \
                invisible to every call site that predates it: it compiles every existing fixture \
                unchanged and points them at ~/Library/Application Support/Sonny, where a test \
                process writes under a key the packaged app cannot read. Delete the default and let \
                the compiler ask each call site.
                """
            )
        }

        // **What the loop actually covered, because the loop's own input can be emptied** (PR #109
        // review F6, R9). `otherRequiredParameters` could be set to `[]` with the whole suite green:
        // nothing else in this file mentions the monitor or the deletion service, so the two
        // parameters most easily re-defaulted were checked by a list and by nothing that checked the
        // list.
        #expect(checkedLabels.count == expectedLabels.count + Self.otherRequiredParameters.count)
        #expect(
            checkedLabels.isSuperset(
                of: ["clipboardHistoryMonitor", "localDataDeletionService", "finderRevealer"]
            )
        )
    }

    /// The premise the rule above rests on: a store built with no `fileURL` really does land in the
    /// developer's own home directory. Asserted rather than assumed — if a default ever became
    /// temp-aware, this whole suite would be guarding nothing and should be re-argued rather than
    /// left standing. (That change is also explicitly rejected on SONNY-240: it would hide the
    /// wiring gap instead of closing it.)
    @Test
    func aStoreBuiltWithNoFileURLLandsInTheDevelopersHomeDirectory() {
        let applicationSupport = ClipboardHistoryStore.defaultDirectory(fileManager: .default).path

        for path in [
            RoutineStore().fileURL.path,
            WorkspaceStore().fileURL.path,
            ClipboardHistoryStore().fileURL.path,
            ClipboardHistorySettingsStore().fileURL.path,
            SnippetStore().fileURL.path,
            RecentArtifactStore().fileURL.path,
            ShortcutRunHistoryStore().fileURL.path,
            TaskHistoryStore().fileURL.path,
            TaskPlanDetailStore().fileURL.path,
            VisionSessionJournalStore().fileURL.path,
            ApprovedAppStore().fileURL.path,
            OutputLocationStore().fileURL.path,
            ResumableTaskStore().fileURL.path
        ] {
            #expect(path.hasPrefix(applicationSupport + "/"), "\(path) is not under Application Support")
            #expect(!path.contains("/var/folders/"), "\(path) is already a temp path")
        }
    }

    // MARK: - 2. A store may be passed and still point at the real path

    @Test
    func noTestSourceBuildsALocalStoreWithoutNamingItsFileURL() throws {
        let typeNames = LocalStore.allCases.map { Self.injection(of: $0).typeName }
        #expect(Set(typeNames).count == LocalStore.allCases.count, "two stores share a type name")

        // **Every test target except one, and the exception is named rather than implied** (PR #109
        // review F5, which found `MacAgentTestSupport` excluded by an omission this comment did not
        // even mention).
        //
        // `MacAgentTests` is where a store reaches an `AgentViewModel`, which is where the damage
        // this suite exists for was done. `MacAgentTestSupport` is linked into both test targets and
        // has none of the defence below, so it is swept too — a helper there would be the least
        // visible place for a default-path store to sit.
        //
        // **`MacAgentCoreTests` is the one excluded target.** It is the stores' own, and it
        // constructs seven default-path stores on purpose — to assert what `ApprovedAppStore()`'s
        // file name is, what `ResumableTaskStore()`'s idle period is, what `TaskHistoryStore()`'s cap
        // is — and never writes through one. Blanket-flagging those would be a false positive on the
        // tests that pin the very defaults this rule depends on, including
        // `aStoreBuiltWithNoFileURLLandsInTheDevelopersHomeDirectory` in this file.
        //
        // **The residual, so nobody reads a clean run as a wider claim than it is:** a *write*
        // through a default-path store inside `MacAgentCoreTests` would not be caught here. Those
        // suites use a temp root for every write today, and their subject is the store rather than
        // the view model.
        let sweptTargets = TestSourceTree.targets.filter { $0 != "MacAgentCoreTests" }
        #expect(
            sweptTargets.sorted() == ["MacAgentTestSupport", "MacAgentTests"],
            "a test target was added to TestSourceTree.targets and this sweep has not been re-argued for it"
        )
        var files: [TestSourceTree.SourceFile] = []
        for target in sweptTargets {
            files.append(contentsOf: try TestSourceTree.swiftFiles(in: target))
        }
        #expect(
            !files.isEmpty,
            "the enumerator found no test sources — a scan matching nothing reads exactly like a passing one"
        )

        var constructionsScanned = 0
        for file in files {
            let code = TestSourceTree.codeLines(of: try TestSourceTree.read(file))
                .map(\.text)
                .joined(separator: "\n")

            for typeName in typeNames {
                for construction in Self.constructions(of: typeName, in: code) {
                    constructionsScanned += 1
                    #expect(
                        construction.contains("fileURL:"),
                        """
                        \(file.relativePath) builds a \(typeName) that names no fileURL, so it writes \
                        to the real ~/Library/Application Support/Sonny path — with the deterministic \
                        key a test process uses, which the packaged app cannot read. Give it this \
                        fixture's own temp root.
                        """
                    )
                }
            }
        }

        // The floor keeps a broken matcher or a renamed type from passing this vacuously. It is a
        // floor rather than an equality on purpose: fixtures are added often and the exact number is
        // not the property under test — **which the message beside it used to contradict** by
        // spelling a fixture count, and one the tree had already moved past (SONNY-326).
        #expect(
            constructionsScanned >= 150,
            "expected the fixtures' store constructions, scanned \(constructionsScanned)"
        )
    }

    /// **`Sources/` builds a default-path local store in exactly one place, and it is the factory**
    /// (SONNY-269).
    ///
    /// **Why this exists when `theOnlyViewModelConstructionInSourcesIsTheRealStoreFactory` is right
    /// there.** That check counts a *type name*. SONNY-248 widened the count from one spelling to
    /// every spelling that writes `AgentViewModel` beside its parenthesis — `Name(…)`,
    /// `Name.init(…)`, either qualified by a module — and three spellings name the type nowhere near
    /// the parenthesis and are therefore outside any name-keyed scan at all: a `typealias` and a
    /// construction through it, a metatype value (`let t = AgentViewModel.self; t.init(…)`, which a
    /// `final class` permits with no `required` initializer), and a bare contextual `.init(…)` where
    /// an annotation or a return type fixes the type. All three compile.
    ///
    /// **Probed as a live defect before this test existed**, the way SONNY-248's four doors were. A
    /// wrapper in `Sources/MacAgent/` built the thirteen stores inline and returned an
    /// `AgentViewModel` through a `typealias` — so it hands its caller the developer's real
    /// `~/Library` data and names neither `atItsRealStoreLocations` nor the type. With that file in
    /// place at `a99a03a`: `LocalStoreInjectionScanTests` passed, **13 tests in 1 suite**, and so did
    /// the whole flagged suite, **2342 tests in 162 suites**. Nothing in this repository saw it.
    ///
    /// **So this keys on a different property, and that is the point rather than a fifth spelling.**
    /// A wrapper has to get the real stores from *somewhere*; if it builds them, it names a store
    /// type beside a parenthesis and passes no `fileURL:`, and it fails here — whatever it calls the
    /// type it returns, and whether or not it returns one at all.
    ///
    /// **`Sources/MacAgentCore/` is the one excluded directory, and the argument is written rather
    /// than implied** — the same debt PR #109's F5 found in the test-tree sweep above. It is the
    /// stores' own target and it constructs default-path stores legitimately, three ways:
    /// `LocalDataDeletionService.defaultStoreFileURLs()` builds every store to read its URL, which is
    /// what a privacy wipe is *for*; `LocalStoreClassification` does the same to answer what each
    /// store's file is called; and `ClipboardHistoryMonitor`'s own default is how the thirteenth
    /// store reaches the view model at all. Blanket-flagging those would flag the plumbing this rule
    /// depends on.
    ///
    /// **The residual, so a clean run is not read as a wider claim than it is:** a wrapper written
    /// inside `Sources/MacAgentCore/` is outside this sweep, and a wrapper anywhere that obtained its
    /// stores from somewhere else — passed in, or read off an existing view model — names no store
    /// type and is outside it too. What is closed is the door that was actually open: building them.
    ///
    /// **A count, not just a file set**, for the reason PR #109's re-check gives about the factory:
    /// a second convenience written *inside* `AgentViewModel.swift` would keep the file set identical.
    /// The expected count is derived from `LocalStore.allCases` rather than written down — every
    /// store that is a parameter of its own, which is all thirteen except the clipboard history the
    /// monitor carries.
    @Test
    func noAppSourceBuildsALocalStoreWithoutNamingItsFileURL() throws {
        let typeNames = LocalStore.allCases.map { Self.injection(of: $0).typeName }
        #expect(Set(typeNames).count == LocalStore.allCases.count, "two stores share a type name")

        let sources = Self.repositoryRoot.appendingPathComponent("Sources")
        guard let walker = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil) else {
            Issue.record("could not enumerate Sources/")
            return
        }

        var defaultPathSites: [String: Int] = [:]
        var filesRead = 0
        var filesSkipped = 0
        for case let url as URL in walker where url.pathExtension == "swift" {
            guard !url.pathComponents.contains("MacAgentCore") else {
                filesSkipped += 1
                continue
            }
            filesRead += 1
            let code = TestSourceTree.codeLines(of: try String(contentsOf: url, encoding: .utf8))
                .map(\.text)
                .joined(separator: "\n")
            for typeName in typeNames {
                for construction in Self.constructions(of: typeName, in: code)
                where !construction.contains("fileURL:") {
                    defaultPathSites[url.lastPathComponent, default: 0] += 1
                }
            }
        }

        // Both floors, because either half enumerating to nothing would make this vacuously green
        // and would do it silently — the exclusion has to be excluding something real, and the swept
        // half has to be the real app target.
        #expect(filesRead > 20, "the enumerator saw \(filesRead) swept app sources — too few to be the real tree")
        #expect(filesSkipped > 100, "the MacAgentCore exclusion skipped \(filesSkipped) files — too few to be that target")

        let expected = LocalStore.allCases.filter { Self.injection(of: $0).parameterLabel != nil }.count
        let found = defaultPathSites.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }
        #expect(
            defaultPathSites == ["AgentViewModel.swift": expected],
            """
            Sources/ builds default-path local stores in \(found) — it may do so in exactly one \
            place, AgentViewModel.\(Self.realStoreFactoryName)(), and \(expected) times there. A \
            store built anywhere else with no fileURL: points at the developer's real \
            ~/Library/Application Support/Sonny data, and a wrapper handing that out names neither \
            the factory nor, if it is spelled through a typealias or a metatype, the view model type.
            """
        )
    }

    /// **The sweep above, shown flagging the defect it names** — this suite's own rule, and the
    /// reason the probe in that comment was run against the real tree first.
    ///
    /// The held sample is the wrapper in all three of the spellings a name-keyed scan cannot see. For
    /// each one, two things are asserted and the pair is the whole point: `constructions(of:
    /// "AgentViewModel", in:)` finds **nothing**, so the older guard is blind to it; and the
    /// store-type sweep finds the inline constructions, so this one is not.
    @Test
    func theAppSourceSweepFlagsEveryWrapperSpellingTheNameCountCannotSee() {
        let samples: [(String, String)] = [
            ("typealias", """
            typealias ConvenientViewModel = AgentViewModel
            enum DeveloperConvenience {
                static func viewModel() -> ConvenientViewModel {
                    ConvenientViewModel(routineStore: RoutineStore(), taskHistoryStore: TaskHistoryStore())
                }
            }
            """),
            ("metatype", """
            enum DeveloperConvenience {
                static func viewModel() -> AnyObject {
                    let type = AgentViewModel.self
                    return type.init(routineStore: RoutineStore(), taskHistoryStore: TaskHistoryStore())
                }
            }
            """),
            ("contextual .init", """
            enum DeveloperConvenience {
                static func viewModel() -> AgentViewModel {
                    .init(routineStore: RoutineStore(), taskHistoryStore: TaskHistoryStore())
                }
            }
            """)
        ]
        for (label, sample) in samples {
            #expect(
                Self.constructions(of: "AgentViewModel", in: sample).isEmpty,
                Comment(rawValue: "\(label): the name count can see this after all — the sample is not the door")
            )
            let inline = LocalStore.allCases
                .map { Self.injection(of: $0).typeName }
                .flatMap { Self.constructions(of: $0, in: sample) }
                .filter { !$0.contains("fileURL:") }
            #expect(inline.count == 2, Comment(rawValue: "\(label): the store sweep found \(inline.count) of the 2 inline stores"))
        }

        // And the negative control: the same wrapper handed its stores instead of building them is
        // not this sweep's to catch, which is the residual the test above writes down.
        let passedIn = """
        enum DeveloperConvenience {
            static func viewModel(routineStore: RoutineStore) -> AgentViewModel {
                .init(routineStore: routineStore)
            }
        }
        """
        let inline = LocalStore.allCases
            .map { Self.injection(of: $0).typeName }
            .flatMap { Self.constructions(of: $0, in: passedIn) }
        #expect(inline.isEmpty, "a store that is passed in is not a construction")
    }

    /// **The one door the compiler opens on purpose, and `main.swift` is the whole of who may walk
    /// through it** (PR #109 review F4).
    ///
    /// `AgentViewModel.atItsRealStoreLocations()` exists so that the shipping app has somewhere to
    /// ask for the real `~/Library` paths. It is also a single call that hands its caller every one
    /// of them at once — so a *defaulted parameter* whose default is that call recreates the exact
    /// invisibility SONNY-240 removed, one level up, and does it in a file the caller never reads.
    /// `AppDelegate.init(viewModel:)` was that parameter for one round, and a test writing
    /// `AppDelegate()` passed every check in this suite: the sweep below looks for the method's
    /// *name*, and a bare `AppDelegate()` never spells it.
    ///
    /// **So this is a population over `Sources/`, not a name search over tests.** Exactly two files
    /// may mention the method — the one declaring it, and `main.swift` — and each may mention it
    /// exactly **once**.
    ///
    /// **The count is the second half, and without it the file set alone permits a third door** (PR
    /// #109 re-check). A new named factory written *inside* `AgentViewModel.swift` would call this
    /// and keep the file set identical, so the guard would pass while a second convenience handed
    /// out the real stores. One occurrence per file is the declaration and the one call, and nothing
    /// else.
    ///
    /// **A wrapper that constructs the real stores *inline* names nothing for this to find, and is
    /// caught by `theOnlyViewModelConstructionInSourcesIsTheRealStoreFactory` instead** — see there
    /// for why the mitigation this comment used to claim was false.
    @Test
    func onlyMainAsksForTheRealStoreLocations() throws {
        let forbidden = Self.realStoreFactoryName
        let sources = Self.repositoryRoot.appendingPathComponent("Sources")
        guard let walker = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil) else {
            Issue.record("could not enumerate Sources/")
            return
        }

        var mentions: [String: Int] = [:]
        var filesRead = 0
        for case let url as URL in walker where url.pathExtension == "swift" {
            filesRead += 1
            let code = TestSourceTree.codeLines(of: try String(contentsOf: url, encoding: .utf8))
                .map(\.text)
                .joined(separator: "\n")
            let count = code.components(separatedBy: forbidden).count - 1
            if count > 0 {
                mentions[url.lastPathComponent] = count
            }
        }

        // A walker that found nothing reads exactly like a tree with no mentions.
        #expect(filesRead > 50, "the enumerator saw \(filesRead) app sources — too few to be the real tree")
        #expect(
            Self.violations(in: mentions).isEmpty,
            """
            \(forbidden)() reaches the developer's real ~/Library stores in one call, so it may be \
            named only where it is declared and in main.swift, once each. Found: \
            \(mentions.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }). \
            \(Self.violations(in: mentions).joined(separator: " "))
            """
        )
    }

    /// **The rule, as a function, so it can be shown to flag what it names** (PR #109 re-check).
    ///
    /// The check above ran the rule against the real tree and nothing else, which makes it the shape
    /// PR #100's F4 warned about: a guard that cannot be demonstrated without introducing the defect
    /// it guards against. A mutant weakening the count from `== 1` to `>= 1` survived the suite —
    /// and read as *killed*, because its only reported killer was SONNY-224's flaky test. Pulling
    /// the rule out lets it be run over held samples instead.
    static func violations(in mentions: [String: Int]) -> [String] {
        var problems: [String] = []
        for (file, count) in mentions.sorted(by: { $0.key < $1.key }) {
            switch file {
            case "AgentViewModel.swift", "main.swift":
                if count != 1 {
                    problems.append(
                        "\(file) names it \(count) times; one is the declaration or the one call, "
                        + "and a second is the same door under a new name inside a file this check "
                        + "already trusts."
                    )
                }
            default:
                problems.append("\(file) may not name it at all.")
            }
        }
        for required in ["AgentViewModel.swift", "main.swift"] where mentions[required] == nil {
            problems.append("\(required) no longer names it — the guard would pass vacuously.")
        }
        return problems
    }

    /// **The splitter, run over held samples rather than only over the real signature.**
    ///
    /// Written when a closure-typed parameter broke it (SONNY-239's rebase): `@escaping ([URL]) ->
    /// Void` decremented the bracket depth at the arrow, so the real signature parsed as 11
    /// parameters and eleven required labels vanished. The premise check caught that, but a check
    /// that only fires against the live tree cannot say *which* syntax it handles — so the cases are
    /// held here, where a future parameter type can be added to the list before it is added to the
    /// signature.
    @Test
    func theParameterSplitterSurvivesAClosureTypedParameter() {
        // The case that broke it, minimal: an arrow between two ordinary parameters.
        let arrow = LocalStoreInjectionScanTests.splitTopLevel(
            Substring("a: Int, b: @escaping ([URL]) -> Void, c: String")
        )
        #expect(arrow.count == 3, "the arrow swallowed the commas after it: \(arrow)")
        #expect(arrow.map { $0.trimmingCharacters(in: .whitespaces) }.first == "a: Int")
        #expect(arrow.map { $0.trimmingCharacters(in: .whitespaces) }.last == "c: String")

        // Generics still bracket, so a comma inside one is not a split.
        let generic = LocalStoreInjectionScanTests.splitTopLevel(
            Substring("a: Dictionary<String, Int>, b: Int")
        )
        #expect(generic.count == 2, "a generic's comma split the list: \(generic)")

        // A tuple return, which has both an arrow and a bracketed comma after it.
        let tuple = LocalStoreInjectionScanTests.splitTopLevel(
            Substring("a: () -> (Int, Int), b: Int")
        )
        #expect(tuple.count == 2, "\(tuple)")

        // Nested closures, where the arrow appears inside a bracket as well as outside one.
        let nested = LocalStoreInjectionScanTests.splitTopLevel(
            Substring("a: (@escaping (Int) -> Void) -> Void, b: Int")
        )
        #expect(nested.count == 2, "\(nested)")

        // And the defaulted form, since that is what the loop above reads afterwards.
        let defaulted = LocalStoreInjectionScanTests.splitTopLevel(
            Substring("a: @escaping ([URL]) -> Void = { _ in }, b: Int")
        )
        #expect(defaulted.count == 2, "\(defaulted)")
        #expect(LocalStoreInjectionScanTests.containsTopLevelDefaultForTests(defaulted[0]))
    }

    /// The rule run over held text: the tree as it should be, and each way it can go wrong.
    @Test
    func theRealStoreLocationRuleFlagsASecondFactoryAndAThirdFile() {
        #expect(Self.violations(in: ["AgentViewModel.swift": 1, "main.swift": 1]).isEmpty)

        // The door the file-set assertion alone permitted: a second named factory inside the file
        // that legitimately declares the first.
        #expect(Self.violations(in: ["AgentViewModel.swift": 2, "main.swift": 1]).count == 1)
        // The door it always caught.
        #expect(Self.violations(in: [
            "AgentViewModel.swift": 1, "main.swift": 1, "AppDelegate.swift": 1
        ]).count == 1)
        // And a guard that stopped finding either required site is a guard passing over nothing.
        #expect(Self.violations(in: ["main.swift": 1]).count == 1)
        #expect(Self.violations(in: [:]).count == 2)
    }

    /// **The third door, closed rather than documented** (PR #109 re-check, round two).
    ///
    /// The name-population check above catches anything that *calls* the real-store factory. It does
    /// not catch a wrapper that builds the thirteen stores inline and hands over an
    /// `AgentViewModel` without naming the factory at all — and the sentence that used to sit here
    /// claimed such a wrapper was mitigated, because a test reaching it "would have to construct
    /// those stores itself, which `noTestSourceBuildsALocalStoreWithoutNamingItsFileURL` refuses".
    /// **That was false.** The file-URL sweep walks test targets only, so it never looks where the
    /// constructions are; the reviewer built the door — a wrapper in `Sources/MacAgent/` with all
    /// thirteen stores inline, and a test file holding one line that constructs nothing — and every
    /// check in this suite passed.
    ///
    /// **What actually closes it: `Sources/` builds an `AgentViewModel` in exactly one place.** That
    /// place is `atItsRealStoreLocations()`, which is allowed to and is the whole reason it exists.
    /// A wrapper anywhere else in `Sources/` has to construct one to hand it out, so it fails here.
    ///
    /// **And a wrapper inside `AgentViewModel.swift` cannot dodge by spelling the type differently.**
    /// From inside the type, `Self(…)` and a bare contextual `.init(…)` construct it without writing
    /// the name this counts anywhere near the parenthesis. Both are banned in that one file, where
    /// neither appears today; a blanket ban would be useless, since `.init(` is ordinary Swift and
    /// occurs legitimately across the tree.
    ///
    /// **The fourth door was that ban's own shape: it is scoped to one file, and the count it backs
    /// up knew one spelling** (SONNY-248, T3). `AgentViewModel.init(…)` written in any *other* file
    /// under `Sources/` is an ordinary construction that names the type — and the matcher searched
    /// for the single literal `AgentViewModel(`, which that text does not contain, so the file
    /// counted zero and this assertion passed. Probed as a defect before it was fixed, the way the
    /// two doors above were: a wrapper in `Sources/MacAgent/` with all thirteen stores inline,
    /// returning `AgentViewModel.init(…)`, and this suite green with it in place (`swift test
    /// --filter LocalStoreInjectionScanTests` at `9cd5b64` plus the wrapper → 8 tests in 1 suite
    /// passed; the same command with the count fixed fails here, naming the wrapper's file). The
    /// module-qualified spelling `MacAgent.AgentViewModel(…)` was probed the same way and passed
    /// the same way.
    /// **It is closed in the count rather than by widening the ban** — `constructions(of:in:)` now
    /// recognises the spellings that construct the type instead of one of them, so this stays an
    /// assertion that `Sources/` has exactly one construction site rather than becoming a list of
    /// forbidden strings. What it recognises, and the three spellings that name the type nowhere and
    /// so remain outside any name-keyed scan, are enumerated on that function.
    @Test
    func theOnlyViewModelConstructionInSourcesIsTheRealStoreFactory() throws {
        let sources = Self.repositoryRoot.appendingPathComponent("Sources")
        guard let walker = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil) else {
            Issue.record("could not enumerate Sources/")
            return
        }

        var constructionSites: [String: Int] = [:]
        var declaringFileCode = ""
        var filesRead = 0
        for case let url as URL in walker where url.pathExtension == "swift" {
            filesRead += 1
            let code = TestSourceTree.codeLines(of: try String(contentsOf: url, encoding: .utf8))
                .map(\.text)
                .joined(separator: "\n")
            let count = Self.constructions(of: "AgentViewModel", in: code).count
            if count > 0 {
                constructionSites[url.lastPathComponent] = count
            }
            if url.lastPathComponent == "AgentViewModel.swift" {
                declaringFileCode = code
            }
        }

        #expect(filesRead > 50, "the enumerator saw \(filesRead) app sources — too few to be the real tree")
        let found = constructionSites.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }
        #expect(
            constructionSites == ["AgentViewModel.swift": 1],
            """
            Sources/ constructs an AgentViewModel in \(found) — it may do so in exactly one place, \
            AgentViewModel.\(Self.realStoreFactoryName)(). A second construction hands its callers the \
            developer's real ~/Library stores, and does it without naming the factory, so the \
            name-population check cannot see it.
            """
        )
        // The same door from inside the type, where the name is optional.
        #expect(!declaringFileCode.isEmpty, "AgentViewModel.swift was not read")
        for spelling in ["Self(", ".init("] {
            #expect(
                !declaringFileCode.contains(spelling),
                """
                AgentViewModel.swift uses `\(spelling)`, which constructs the type without naming it, \
                so the count above cannot see it. If this is legitimate, the count needs to learn \
                the spelling rather than this check being dropped.
                """
            )
        }
    }

    /// **`Sources/` builds one `SonnyBackendClient`, and the property is load-bearing rather than
    /// tidy** (SONNY-130; PR #139's F12).
    ///
    /// It belongs in this suite for the reason `SonnyBackendClient.init`'s own doc gives: it is
    /// SONNY-240's hazard one step worse. A defaulted or duplicated local store writes to the
    /// developer's `~/Library`; this client holds the **Keychain session every packaged build on
    /// this Mac shares**, so a second one is a second reader and a second deleter of the founder's
    /// own sign-in.
    ///
    /// **And a second client is a live defect even when both are correct.** The client holds the
    /// single-flight generation counter that makes ten concurrent `401 auth.token_expired`s cause
    /// one rotation; the server reads a second rotation presented past its ten-second overlap as
    /// theft and revokes the whole family (contract §3.3). Two clients means two counters, so the
    /// guard would be guarding half the callers — and PR #133 recorded that this goes live "the
    /// moment SONNY-130 and SONNY-131 add a second concurrent authenticated caller", which SONNY-130
    /// is. `main.swift` therefore builds one and hands the same instance to `SonnyAccountModel` and
    /// `AgentViewModel`, and neither has a default for it.
    ///
    /// **The compiler cannot see this one at all**, which is why it is a scan: both undefaulted
    /// parameters are satisfied by *a* client, and nothing in the type system says it must be the
    /// same client. `SignInSurfaceTests.theProductionClientDoesNotRunOnTheSharedSession` counts the
    /// constructions inside one file; this counts them across `Sources/`, which is where a second
    /// one would actually appear.
    @Test
    func theOnlyBackendClientConstructionInSourcesIsTheRealKeychainFactory() throws {
        let sources = Self.repositoryRoot.appendingPathComponent("Sources")
        guard let walker = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil) else {
            Issue.record("could not enumerate Sources/")
            return
        }

        var constructionSites: [String: Int] = [:]
        var declaringFileCode = ""
        var filesRead = 0
        for case let url as URL in walker where url.pathExtension == "swift" {
            filesRead += 1
            let code = TestSourceTree.codeLines(of: try String(contentsOf: url, encoding: .utf8))
                .map(\.text)
                .joined(separator: "\n")
            let count = Self.constructions(of: "SonnyBackendClient", in: code).count
            if count > 0 {
                constructionSites[url.lastPathComponent] = count
            }
            if url.lastPathComponent == "SonnyBackendClient.swift" {
                declaringFileCode = code
            }
        }

        #expect(filesRead > 50, "the enumerator saw \(filesRead) sources — too few to be the real tree")
        let found = constructionSites.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }
        #expect(
            constructionSites == ["SignInView.swift": 1],
            """
            Sources/ constructs a SonnyBackendClient in \(found) — it may do so in exactly one             place, SonnyAccountModel.atItsRealKeychainLocation(). A second one is a second token             cache and a second single-flight refresh guard over the same Keychain account, which             the server reads as a stolen refresh token and answers by revoking the whole family.
            """
        )
        // The same door from inside the type, where the name is optional — the shape the view-model
        // scan above already found worth closing.
        #expect(!declaringFileCode.isEmpty, "SonnyBackendClient.swift was not read")
        for spelling in ["Self(", ".init("] {
            #expect(
                !declaringFileCode.contains(spelling),
                """
                SonnyBackendClient.swift uses `\(spelling)`, which constructs the type without                 naming it, so the count above cannot see it. If this is legitimate, the count needs                 to learn the spelling rather than this check being dropped.
                """
            )
        }
    }

    /// **The one construction really does hand the shipping app the live Finder reveal.**
    ///
    /// Written because a mutant that replaced it with `{ _ in }` was reported killed by exactly one
    /// test — and that test was `asyncProcessRunnerCancelsRunningProcess`, SONNY-224's load flake.
    /// By this repository's own discriminator that is a survivor, not a kill (SONNY-239's rebase
    /// onto this branch). The line cannot be reached from a test: `atItsRealStoreLocations()` builds
    /// the real `~/Library` stores, and `noTestSourceAsksForTheRealStoreLocations` forbids calling
    /// it — so a scan is the only instrument left, which is the same answer
    /// `onlyMainAsksForTheRealStoreLocations` reaches for the same reason.
    ///
    /// **The same gap covers the thirteen store constructions beside it and is not closed here.**
    /// `routineStore: RoutineStore()` could become a temp store with the whole suite green, for
    /// exactly this reason. Generalising this check to every argument of that one call is available
    /// and belongs to whoever owns that suite; recording the gap is better than quietly benefiting
    /// from the fact that nobody has mutated those lines yet.
    @Test
    func theRealStoreFactoryHandsTheAppTheLiveFinderReveal() throws {
        let source = try String(contentsOf: Self.viewModelSource, encoding: .utf8)
        let code = TestSourceTree.codeLines(of: source).map(\.text).joined(separator: "\n")

        let calls = Self.constructions(of: "AgentViewModel", in: code)
        #expect(calls.count == 1, "AgentViewModel.swift constructs the type \(calls.count) times")
        let factoryCall = try #require(calls.first)

        // The live implementation, named in the argument the app actually passes.
        #expect(
            factoryCall.contains("activateFileViewerSelecting"),
            """
            \(Self.realStoreFactoryName)() no longer hands the app a real Finder reveal, so the product's Reveal in Finder control would do nothing and no test could see it — the line is unreachable from a test by construction. The name is interpolated rather than spelled, because this file is itself swept for that literal.
            """
        )
        #expect(factoryCall.contains("finderRevealer:"), "the argument is not passed by that label any more")
    }

    /// The same door from the other side: no test may ask for the real locations either.
    ///
    /// Scanned across every test target, because a helper in the support target would be the least
    /// visible place for it to appear.
    @Test
    func noTestSourceAsksForTheRealStoreLocations() throws {
        var files: [TestSourceTree.SourceFile] = []
        for target in TestSourceTree.targets {
            files.append(contentsOf: try TestSourceTree.swiftFiles(in: target))
        }
        #expect(!files.isEmpty, "the enumerator found no test sources")

        let forbidden = Self.realStoreFactoryName

        for file in files {
            let code = TestSourceTree.codeLines(of: try TestSourceTree.read(file))
                .map(\.text)
                .joined(separator: "\n")
            #expect(
                !code.contains(forbidden),
                """
                \(file.relativePath) calls AgentViewModel.\(forbidden)(), which hands it every store \
                at the developer's real ~/Library path at once. Build the fixture's stores at its own \
                temp root instead.
                """
            )
        }
    }

    /// **This suite's own reach, proven rather than claimed** — the residual
    /// `OutputLocationFixtureWiringScanTests` was corrected for on PR #100: a sweep is only a guard
    /// once it has been shown to flag the thing it names. Run over text carrying the defect, the
    /// matcher finds it; run over text carrying the fixed form, it does not.
    @Test
    func theSweepFlagsAStoreBuiltWithNoFileURLAndClearsOneBuiltWithIt() {
        let defective = """
        let viewModel = AgentViewModel(
            taskHistoryStore: TaskHistoryStore(),
            outputLocationStore: OutputLocationStore(whitelist: PathWhitelist(roots: [root]))
        )
        """
        let fixed = """
        let viewModel = AgentViewModel(
            taskHistoryStore: TaskHistoryStore(fileURL: root.appendingPathComponent("task-history.json")),
            outputLocationStore: OutputLocationStore(
                fileURL: root.appendingPathComponent("output-locations.json"),
                whitelist: PathWhitelist(roots: [root])
            )
        )
        """

        for typeName in ["TaskHistoryStore", "OutputLocationStore"] {
            let flagged = Self.constructions(of: typeName, in: defective)
                .filter { !$0.contains("fileURL:") }
            #expect(flagged.count == 1, "\(typeName) was not flagged in the defective text")

            let cleared = Self.constructions(of: typeName, in: fixed)
                .filter { !$0.contains("fileURL:") }
            #expect(cleared.isEmpty, "\(typeName) was flagged in the fixed text")
        }

        // And a longer type name is not matched by a shorter one that ends the same way — the trap
        // this repository's other textual scans have hit, and the reason the matcher checks the
        // character before the name.
        let settings = "ClipboardHistorySettingsStore(fileURL: url)"
        #expect(Self.constructions(of: "ClipboardHistoryStore", in: settings).isEmpty)
        #expect(Self.constructions(of: "ClipboardHistorySettingsStore", in: settings).count == 1)
    }

    /// **The count knows every spelling that names the type, shown on held text** (SONNY-248, T3).
    ///
    /// The matcher used to search for one literal, `AgentViewModel(`, and `AgentViewModel.init(…)`
    /// is the same construction written the other ordinary way — so the count for a file using it
    /// was zero and `theOnlyViewModelConstructionInSourcesIsTheRealStoreFactory` passed over a
    /// wrapper handing out the developer's real stores. Probed as a defect first: the wrapper was
    /// written into `Sources/MacAgent/` with all thirteen stores inline, and this suite passed with
    /// it in place (`swift test --filter LocalStoreInjectionScanTests` at `9cd5b64` plus the
    /// wrapper → 8 tests in 1 suite passed).
    ///
    /// **Held samples rather than the tree alone**, for the reason `violations(in:)` was pulled out
    /// above: a rule run only over a tree that satisfies it cannot be shown to flag anything. Each
    /// positive below is a spelling `swiftc` accepts for a `final class` with a plain `init`; each
    /// negative is a thing that looks like one and constructs nothing.
    @Test
    func theConstructionCountRecognisesEverySpellingThatNamesTheType() {
        let constructing = [
            "AgentViewModel(routineStore: store)",
            "AgentViewModel.init(routineStore: store)",
            "AgentViewModel (routineStore: store)",
            "AgentViewModel\n            .init(routineStore: store)",
            "AgentViewModel . init(routineStore: store)",
            "MacAgent.AgentViewModel(routineStore: store)",
            "MacAgent.AgentViewModel.init(routineStore: store)"
        ]
        for text in constructing {
            #expect(
                Self.constructions(of: "AgentViewModel", in: text) == ["routineStore: store"],
                "spelling not counted as a construction: \(text)"
            )
        }

        let notConstructing = [
            "let viewModel: AgentViewModel",
            "@ObservedObject var viewModel: AgentViewModel",
            "extension AgentViewModel {",
            "AgentViewModel.self",
            "AgentViewModel.initialize(now)",
            "AgentViewModelFactory(routineStore: store)",
            "makeAgentViewModel(routineStore: store)",
            "Legacy.AgentViewModel(routineStore: store)"
        ]
        for text in notConstructing {
            #expect(
                Self.constructions(of: "AgentViewModel", in: text).isEmpty,
                "counted as a construction: \(text)"
            )
        }
    }

    /// **The store sweep inherits the same fix, because it is the same matcher** (SONNY-248, T3).
    ///
    /// `noTestSourceBuildsALocalStoreWithoutNamingItsFileURL` is the other caller of
    /// `constructions(of:in:)`, and it had the identical blind spot for the identical reason: a
    /// fixture writing `TaskHistoryStore.init()` — or `MacAgentCore.TaskHistoryStore()`, which the
    /// app target has to write when a name collides — was counted zero and swept past, at a store
    /// pointing straight at `~/Library/Application Support/Sonny`. Checked here rather than assumed
    /// from the shared helper, because "they call the same function" is exactly the claim this
    /// repository keeps finding to be true of the code and false of the behaviour — and probed live
    /// as well as held: a `Tests/MacAgentTests/` file whose only content was
    /// `TaskHistoryStore.init()` was swept past at `9cd5b64` (`swift test --filter
    /// LocalStoreInjectionScanTests` → 8 tests in 1 suite passed) and is named by
    /// `noTestSourceBuildsALocalStoreWithoutNamingItsFileURL` with the matcher fixed.
    @Test
    func theFileURLSweepSeesTheSameSpellings() {
        let defective = """
        let viewModel = AgentViewModel.init(
            taskHistoryStore: TaskHistoryStore.init(),
            outputLocationStore: MacAgentCore.OutputLocationStore(whitelist: PathWhitelist(roots: [root]))
        )
        """
        let fixed = """
        let viewModel = AgentViewModel.init(
            taskHistoryStore: TaskHistoryStore.init(fileURL: root.appendingPathComponent("task-history.json")),
            outputLocationStore: MacAgentCore.OutputLocationStore(
                fileURL: root.appendingPathComponent("output-locations.json"),
                whitelist: PathWhitelist(roots: [root])
            )
        )
        """

        for typeName in ["TaskHistoryStore", "OutputLocationStore"] {
            #expect(
                Self.constructions(of: typeName, in: defective).filter { !$0.contains("fileURL:") }.count == 1,
                "\(typeName) was not flagged in the defective text"
            )
            #expect(
                Self.constructions(of: typeName, in: fixed).filter { !$0.contains("fileURL:") }.isEmpty,
                "\(typeName) was flagged in the fixed text"
            )
        }
    }

    // MARK: - Reading the initializer

    struct Parameter {
        let label: String
        let hasDefault: Bool
    }

    /// The repository root, from this file's own location.
    ///
    /// `TestSourceTree.root` is `Tests/`, so the repository root is its parent. Its own path rather
    /// than a working-directory-relative one, for the reason `TestSourceTree` gives: a test process
    /// does not run from the repository root.
    static var repositoryRoot: URL {
        TestSourceTree.root.deletingLastPathComponent()
    }

    static var viewModelSource: URL {
        repositoryRoot.appendingPathComponent("Sources/MacAgent/AgentViewModel.swift")
    }

    /// The parameters of `AgentViewModel.init`, in declaration order.
    ///
    /// **Textual, with the residuals this repository already names for its other scans.** Comment
    /// lines are dropped first, so a parameter named only inside a doc comment cannot satisfy this,
    /// and a default written inside a comment cannot fail it. A parenthesis inside a string literal
    /// would miscount the depth; the signature contains none.
    static func initializerParameters() throws -> [Parameter] {
        let source = try String(contentsOf: viewModelSource, encoding: .utf8)
        let code = TestSourceTree.codeLines(of: source).map(\.text).joined(separator: "\n")
        guard let start = code.range(of: "\n    init(") else {
            throw ScanError.initializerNotFound
        }

        var depth = 0
        var index = code.index(before: start.upperBound)
        var closed: String.Index?
        while index < code.endIndex {
            if code[index] == "(" {
                depth += 1
            } else if code[index] == ")" {
                depth -= 1
                if depth == 0 {
                    closed = index
                    break
                }
            }
            index = code.index(after: index)
        }
        guard let closed else {
            throw ScanError.initializerNotFound
        }

        let body = code[start.upperBound..<closed]
        return splitTopLevel(body).compactMap { piece in
            let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let colon = trimmed.firstIndex(of: ":") else {
                return nil
            }
            // An argument label plus an internal name ("_ foo:") would need the second word; the
            // signature has none, and one added later shows up as a label nothing matches rather
            // than as a silent pass.
            let label = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            let rest = String(trimmed[trimmed.index(after: colon)...])
            return Parameter(label: label, hasDefault: containsTopLevelDefault(rest))
        }
    }

    enum ScanError: Error {
        case initializerNotFound
    }

    /// Splits a parameter list on commas that are not inside brackets of any kind.
    ///
    /// **The `>` of a `->` is not a closing bracket, and getting that wrong silently halves the
    /// parse** (SONNY-239's rebase onto this branch). `finderRevealer: @escaping ([URL]) -> Void`
    /// took `depth` to `-1` at the arrow, after which no comma was ever at depth 0 again: the
    /// signature parsed as **11** parameters instead of 34, and eleven of the labels the loop above
    /// requires simply were not there. The premise check — `parameters.count > 20` — is what caught
    /// it rather than a quiet pass, which is that assertion doing exactly the job it was written for.
    ///
    /// Two guards, because one of them would have been enough here and the other is what makes the
    /// function honest about the rest of Swift's syntax: an arrow's `>` is skipped, and `depth` can
    /// never go below zero — if some other construct unbalances it, the split degrades to
    /// top-level-ish rather than to one enormous piece, and the premise check still fires.
    ///
    /// Internal rather than private since the same rebase, so
    /// `theParameterSplitterSurvivesAClosureTypedParameter` can run it over held samples. That is
    /// the shape PR #109's re-check established for the F4 rule and PR #100's F4 before it: a parser
    /// that is only ever run against the real tree cannot be shown to handle what it claims to.
    static func splitTopLevel(_ text: Substring) -> [String] {
        var pieces: [String] = []
        var current = ""
        var depth = 0
        var previous: Character?
        for character in text {
            switch character {
            case "(", "[", "<":
                depth += 1
                current.append(character)
            case ">" where previous == "-":
                // `->`, not the end of a generic argument list.
                current.append(character)
            case ")", "]", ">":
                depth = max(0, depth - 1)
                current.append(character)
            case "," where depth == 0:
                pieces.append(current)
                current = ""
            default:
                current.append(character)
            }
            previous = character
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            pieces.append(current)
        }
        return pieces
    }

    /// Whether a parameter's type-and-default half carries a default assignment.
    ///
    /// Depth-aware so that a generic constraint or a defaulted closure argument nested inside the
    /// type cannot be read as this parameter's own default.
    /// Internal, and named for the suite, so the splitter's held samples can check the half that
    /// reads a piece after it has been split — the same shape `MemoryRowPresentation.systemImageForTests`
    /// uses.
    static func containsTopLevelDefaultForTests(_ text: String) -> Bool {
        containsTopLevelDefault(text)
    }

    /// **The arrow's `>` is skipped here for the same reason as in `splitTopLevel`, and here it was
    /// a hole in the guard rather than a parse failure** (SONNY-239's rebase). A closure-typed
    /// parameter's `->` took the depth to `-1`, so its own `= { … }` was never at depth 0 and
    /// `hasDefault` came back `false`. A defaulted `finderRevealer: @escaping ([URL]) -> Void = { … }`
    /// would have passed the check above while being exactly what it exists to refuse — invisible,
    /// because no store has a closure type and the case had never arisen.
    /// `theParameterSplitterSurvivesAClosureTypedParameter` holds it.
    private static func containsTopLevelDefault(_ text: String) -> Bool {
        var depth = 0
        var previousCharacter: Character?
        for (offset, character) in text.enumerated() {
            defer { previousCharacter = character }
            switch character {
            case "(", "[", "<":
                depth += 1
            case ">" where previousCharacter == "-":
                break
            case ")", "]", ">":
                depth = max(0, depth - 1)
            case "=" where depth == 0:
                // Not `==`, `>=` or `!=`, none of which appear in a signature today but all of
                // which would read as a default.
                let index = text.index(text.startIndex, offsetBy: offset)
                let next = text.index(after: index)
                let previous = offset == 0 ? nil : text[text.index(before: index)]
                if next < text.endIndex, text[next] == "=" {
                    continue
                }
                if let previous, "=!<>".contains(previous) {
                    continue
                }
                return true
            default:
                break
            }
        }
        return false
    }

    /// Every argument list of a construction of `name`, depth-matched on parentheses.
    ///
    /// Depth-matching rather than line slicing because these calls nest — a fixture's
    /// `AgentViewModel(` argument list contains a dozen further constructions, and a scan that
    /// stopped at the first `)` would read one argument and call it the call.
    ///
    /// **It counts the spellings that construct the type, not one of them** (SONNY-248, T3). It used
    /// to search for the single literal `name + "("`, so `AgentViewModel.init(…)` — ordinary Swift,
    /// identical in effect — was counted zero, and the wrapper door
    /// `theOnlyViewModelConstructionInSourcesIsTheRealStoreFactory` exists to close stood open
    /// again for anyone who spelled it that way. Probed as a defect before it was fixed: a wrapper
    /// in `Sources/MacAgent/` building all thirteen stores inline and returning
    /// `AgentViewModel.init(…)` passed this whole suite, and so did a fixture writing
    /// `TaskHistoryStore.init()` — the evidence is anchored on the two tests that now kill them. The
    /// `.init` ban in that test is
    /// scoped to the declaring file, where a bare contextual `.init(` needs no type name at all, so
    /// it never reached this. What is recognised now, each one compiled rather than assumed
    /// (`swiftc` accepts all of them):
    ///
    /// - `Name(…)` and `Name.init(…)`;
    /// - either with whitespace or a line break where Swift allows one — `Name (…)`,
    ///   `Name\n    .init(…)`, `Name . init(…)`;
    /// - either qualified by the module that declares it — `MacAgentCore.RoutineStore()` from the
    ///   app target, `MacAgent.AgentViewModel(…)` from inside `MacAgent` itself.
    ///
    /// **What still names nothing for this to count**, stated rather than left to be found: a
    /// `typealias` to the type and a construction through the alias; a metatype value
    /// (`let t = AgentViewModel.self; t.init(…)`, which a `final` class permits with no `required`
    /// initializer); and a bare contextual `.init(…)` returned where the type is fixed by an
    /// annotation or a return type. All three compile — measured, not assumed — and none writes the
    /// type's name beside its own parenthesis, so no text scan keyed on the name can see them. The
    /// property that would cover them regardless of spelling is a different one: that `Sources/`
    /// constructs a *default-path local store* in exactly one place, which is the sweep below run
    /// over the app tree instead of the test tree. It is not built, and it is not a mitigation
    /// sentence either — the last time this guard carried one of those it was false, and a reviewer
    /// built the door it claimed was covered. It is **SONNY-269**, which carries the population
    /// measurement and the probe recipe.
    ///
    /// The character before the name is checked so that `ClipboardHistorySettingsStore(` is not read
    /// as a `ClipboardHistoryStore(`, and so that `myStore(` cannot match. A dotted prefix is a
    /// *different* type — `SomeType.Store(` is `SomeType`'s nested `Store`, not this one — unless
    /// the prefix is one of this repository's own module names, which is the same type wearing its
    /// module.
    static func constructions(of name: String, in source: String) -> [String] {
        var results: [String] = []
        var searchStart = source.startIndex
        while let found = source.range(of: name, range: searchStart..<source.endIndex) {
            searchStart = found.upperBound
            guard namesThisType(at: found, in: source),
                  let open = openingParenthesis(afterNameEndingAt: found.upperBound, in: source),
                  let closed = closingParenthesis(matching: open, in: source) else {
                continue
            }
            results.append(String(source[source.index(after: open)..<closed]))
            searchStart = closed
        }
        return results
    }

    /// The module names a type of this repository's own can be qualified by, which are the two
    /// SwiftPM targets. Swift has no source-level import aliasing, so this list is the whole set of
    /// prefixes that mean "the same type".
    static let moduleQualifiers: Set<String> = ["MacAgent", "MacAgentCore"]

    /// Whether the occurrence at `range` is the type's own name rather than the tail of a longer
    /// identifier or the last component of some other type's nested name.
    private static func namesThisType(at range: Range<String.Index>, in source: String) -> Bool {
        guard range.lowerBound > source.startIndex else {
            return true
        }
        let previousIndex = source.index(before: range.lowerBound)
        let previous = source[previousIndex]
        if previous.isLetter || previous.isNumber || previous == "_" {
            return false
        }
        guard previous == "." else {
            return true
        }
        return moduleQualifiers.contains(identifier(endingAt: previousIndex, in: source))
    }

    /// The identifier immediately before `index`, or "" if there is none — the qualifier in
    /// `MacAgentCore.RoutineStore(`, and nothing at all in a contextual `.init(`.
    private static func identifier(endingAt index: String.Index, in source: String) -> String {
        var start = index
        while start > source.startIndex {
            let candidate = source.index(before: start)
            let character = source[candidate]
            guard character.isLetter || character.isNumber || character == "_" else {
                break
            }
            start = candidate
        }
        return String(source[start..<index])
    }

    /// The `(` that opens a construction written after the name, across both spellings and any
    /// whitespace Swift permits between the pieces, or `nil` if this occurrence constructs nothing.
    private static func openingParenthesis(
        afterNameEndingAt nameEnd: String.Index,
        in source: String
    ) -> String.Index? {
        var index = skippingWhitespace(from: nameEnd, in: source)
        guard index < source.endIndex else {
            return nil
        }
        if source[index] == "(" {
            return index
        }
        guard source[index] == "." else {
            return nil
        }
        index = skippingWhitespace(from: source.index(after: index), in: source)
        guard source[index...].hasPrefix("init") else {
            return nil
        }
        // `.initialize(` starts with `init` and constructs nothing: what follows has to be the
        // argument list itself, not more of a longer name.
        index = skippingWhitespace(from: source.index(index, offsetBy: 4), in: source)
        guard index < source.endIndex, source[index] == "(" else {
            return nil
        }
        return index
    }

    private static func skippingWhitespace(from index: String.Index, in source: String) -> String.Index {
        var index = index
        while index < source.endIndex, source[index].isWhitespace {
            index = source.index(after: index)
        }
        return index
    }

    /// The `)` matching an opening parenthesis, or `nil` for text that never closes it.
    private static func closingParenthesis(matching open: String.Index, in source: String) -> String.Index? {
        var depth = 0
        var index = open
        while index < source.endIndex {
            if source[index] == "(" {
                depth += 1
            } else if source[index] == ")" {
                depth -= 1
                if depth == 0 {
                    return index
                }
            }
            index = source.index(after: index)
        }
        return nil
    }
}
