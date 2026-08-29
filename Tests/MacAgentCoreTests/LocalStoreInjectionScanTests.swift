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
///    TaskHistoryStore(fileURL: TaskHistoryStore.realFileURL())` satisfies the compiler and writes
///    to `~/Library` regardless. Nothing in the type system distinguishes it from a store at a temp
///    root.
///
/// **What SONNY-350 took away from this suite, and why the rest stayed.** This file used to carry a
/// third arm as well: a source sweep for a store built with **no** `fileURL` at all —
/// `noTestSourceBuildsALocalStoreWithoutNamingItsFileURL`, its app-source twin, their two
/// self-tests, and the premise test that showed `RoutineStore()` really did land under Application
/// Support. That arm is gone, because `fileURL` is now a required parameter of all thirteen store
/// initializers and `RoutineStore()` does not compile. A scan that re-proves what will not build is
/// not a second line of defence; it is a second thing to maintain that can only ever agree with the
/// compiler, and it costs a reader the time to work out which of the two is actually load-bearing.
///
/// The rest stayed because **none of it is subsumed**. A required parameter forces a call site to
/// pass a location; it says nothing about *which* location, nothing about a defaulted parameter one
/// level up, and nothing about where the app assembles its stores. So the arms that survive are the
/// ones the type system cannot express: the undefaulted-parameter check, the argument-label sweep
/// (which is spelling-proof where a type-name sweep never was), the single-factory rules, and — new
/// with SONNY-350 — `onlyTheShippedConstantsTestsNameAStoresRealLocation`, which holds the four
/// tests permitted to write the words `realFileURL`. That last one is the residue the compiler
/// leaves behind by design: the real path stays reachable in words, because the shipping app needs
/// it, so what is held is the population rather than the spelling.
///
/// **The evasions that ended the sweep, on the record** (SONNY-350, from PR #158's cycle-2 review).
/// The sweep was defeated five times by reviewers looking for one afternoon each: a typealias
/// wrapper, `routineStore: .init()`, a backticked label, a block comment between label and colon,
/// and a store vendor that never constructs an `AgentViewModel` at all. Two of those are not
/// fixable by a better pattern — contextual member lookup means `.init()` has no type name to
/// match, and a vendor with no `AgentViewModel` call has no argument label to name. That is the
/// argument for moving the guarantee into the type system rather than sharpening the matcher again.
///
/// **The population is `LocalStore.allCases`**, which already refuses a new store file without a
/// case, so a fourteenth store cannot reach the tree without being mapped here — and being mapped
/// here is what puts it on the initializer without a default.
///
/// **This replaced `OutputLocationFixtureWiringScanTests`**, which checked the same two things for
/// two named stores and said in its own comment that SONNY-240 was the ticket that generalises it.
/// Its fixture-omission check went rather than being generalised, because the compiler did that job
/// better than a scan can: the scan could only fail after the damage was already written, and only
/// for a store somebody had remembered to name in it. SONNY-350 then applied the identical argument
/// to this file's own store-type sweep, which is the paragraph above.
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

    /// The same rule one level down: **no store vendor may default a store parameter either**
    /// (SONNY-350).
    ///
    /// `AgentViewModel.init` was cleaned of defaulted stores by SONNY-240, and the hazard simply
    /// moved. `AgentActionExecutor`, `InstantCommandResolver` and `ClipboardHistoryMonitor` each
    /// defaulted their store parameters to a real-path store, and `AgentRunner` defaulted its whole
    /// `executor:` to one of those — so `AgentActionExecutor(runningAppSwitcher: switcher)`, in a
    /// fixture about switching apps, held six stores pointed at the developer's own data, and
    /// `AgentRunner(planner: …)` held them two levels down. That is SONNY-209's failure with the
    /// name changed, and it is the fifth of the evasions in this file's header: a store vendor that
    /// never constructs an `AgentViewModel` has no argument label for the sweep above to see.
    ///
    /// **The compiler holds it now and this test holds the compiler's input.** The defaults are
    /// gone, so a fixture that omits a store does not build — but a default put back for
    /// convenience would compile every one of those fixtures unchanged, which is exactly how the
    /// view model's arrived the first time.
    ///
    /// `executor:` is on the list for the same reason `clipboardHistoryMonitor:` is on
    /// `otherRequiredParameters`: it is not a store, it *carries* six.
    @Test
    func noStoreVendorDefaultsAStoreParameter() throws {
        struct Vendor {
            let file: String
            let marker: String
            let labels: [String]
        }

        let vendors = [
            Vendor(
                file: "Sources/MacAgentCore/AgentActionExecutor.swift",
                // The first parameter is part of the marker: this file declares three `public
                // init(`s and the earliest is `PreparedRun`'s, which the bare marker found.
                marker: "\n    public init(\n        recordingPolicy:",
                labels: [
                    "routineStore", "workspaceStore", "clipboardHistoryStore",
                    "snippetStore", "recentArtifactStore", "shortcutRunHistoryStore"
                ]
            ),
            Vendor(
                file: "Sources/MacAgentCore/InstantCommandResolver.swift",
                marker: "\n    public init(\n        snippetStore:",
                labels: ["snippetStore", "recentArtifactStore", "routineStore", "workspaceStore"]
            ),
            Vendor(
                file: "Sources/MacAgentCore/ClipboardHistoryService.swift",
                marker: "\n    public init(\n        reader:",
                labels: ["store", "settingsStore"]
            )
        ]

        var checked = 0
        for vendor in vendors {
            let url = Self.repositoryRoot.appendingPathComponent(vendor.file)
            let parameters = try Self.parameters(ofInitializerAt: vendor.marker, in: url)
            #expect(
                parameters.count > 1,
                "parsed \(parameters.count) parameters of \(vendor.file) — too few to be the real signature"
            )
            for label in vendor.labels {
                guard let parameter = parameters.first(where: { $0.label == label }) else {
                    Issue.record("\(vendor.file) has no `\(label):` parameter any more")
                    continue
                }
                checked += 1
                #expect(
                    !parameter.hasDefault,
                    """
                    \(vendor.file)'s `\(label):` has a default again. A vendor that defaults a store \
                    hands the real ~/Library store to every fixture that never mentioned it — the \
                    same failure SONNY-240 removed from AgentViewModel.init, one level down.
                    """
                )
            }
        }

        // `AgentRunner` is the fourth, and its parameter is an executor rather than a store, so it
        // is read separately rather than bent into the shape above. **Both** initializers: a store
        // threaded through one door and defaulted away in the other is a seam honoured on whichever
        // path somebody happened to look at, which is the argument the second one already carries.
        let runner = Self.repositoryRoot
            .appendingPathComponent("Sources/MacAgentCore/AgentRunner.swift")
        for marker in ["\n    public init(\n        planner:", "\n    public init(\n        plannerProvider:"] {
            let parameters = try Self.parameters(ofInitializerAt: marker, in: runner)
            guard let executor = parameters.first(where: { $0.label == "executor" }) else {
                Issue.record("AgentRunner.init has no `executor:` parameter any more")
                continue
            }
            checked += 1
            #expect(
                !executor.hasDefault,
                """
                AgentRunner.init's `executor:` has a default again, and an AgentActionExecutor \
                carries six local stores — so every fixture that names only a planner gets them at \
                the developer's real path.
                """
            )
        }

        // The loop's own input can be emptied, exactly as `otherRequiredParameters` could be
        // (PR #109 review F6): a `vendors` list trimmed to nothing passes every expectation above.
        #expect(checked == 14, "checked \(checked) vendor parameters, expected 6 + 4 + 2 + 2")
    }

    /// The premise everything below rests on: `realFileURL()` really does name the developer's own
    /// home directory.
    ///
    /// **This replaces `aStoreBuiltWithNoFileURLLandsInTheDevelopersHomeDirectory`**, which asserted
    /// the same thing about a store built with no `fileURL` at all. That construction stopped
    /// compiling at SONNY-350, so the test could not be kept; the premise it was protecting did not
    /// go away, it moved to a named member. If a `realFileURL` ever became temp-aware, this suite
    /// and the compile-time rule above it would both be guarding nothing, and that change should be
    /// re-argued rather than made quietly — it is explicitly rejected on SONNY-240, because it hides
    /// the wiring gap instead of closing it.
    ///
    /// Reads a URL and touches no file: `realFileURL` resolves a path and creates nothing.
    @Test
    func everyStoresRealLocationIsUnderTheDevelopersApplicationSupport() {
        let applicationSupport = ClipboardHistoryStore.defaultDirectory(fileManager: .default).path

        // `LocalStore.fileURL()` resolves through each store's own `realFileURL`, so this is the
        // whole population by construction rather than by a list that can go one store stale.
        #expect(LocalStore.allCases.count == 13)
        for store in LocalStore.allCases {
            let path = store.fileURL().path
            #expect(path.hasPrefix(applicationSupport + "/"), "\(path) is not under Application Support")
            #expect(!path.contains("/var/folders/"), "\(path) is already a temp path")
        }
    }

    // MARK: - 2. A store may be passed and still point at the real path

    /// **The spelling-proof arm: a parameter label cannot be aliased, metatyped, or elided**
    /// (SONNY-269, PR #158 review F1).
    ///
    /// Four doors have now been closed on this one hazard and each was closed on a *name* — first
    /// `AgentViewModel(`, then every spelling that writes that name beside a parenthesis (SONNY-248),
    /// then the thirteen store type names. Each time, the next spelling walked past, because Swift
    /// lets a caller reach a type without naming it. **An argument label is the one thing in a call
    /// that Swift will not let you leave out.** `AgentViewModel.init` labels every store parameter,
    /// so any construction of it — through a typealias, through a metatype, through a bare
    /// `.init(…)`, with the stores written `RoutineStore()` or `.init()` or through a factory of
    /// their own — writes `routineStore:` in the source, verbatim. There is no spelling that does
    /// not.
    ///
    /// **So the property is a file set rather than a count, and the file set is the whole of it.**
    /// Outside `Sources/MacAgentCore/`, a store parameter label appears in `AgentViewModel.swift`
    /// and nowhere else. The count is deliberately not asserted: it is 71 across the fifteen labels
    /// today and it moves with ordinary work — a forwarding call site, a stored property, a new
    /// consumer inside the view model — so an equality here would be a number that fails for reasons
    /// that are not this rule. **What is asserted per label instead is a floor of two**, which is the
    /// initializer's declaration plus the factory's argument, so a label that stopped appearing (a
    /// renamed parameter, a broken matcher) fails rather than passing vacuously.
    ///
    /// **The in-file door this does not need to close, and why.** A *second* factory written inside
    /// `AgentViewModel.swift` would add label uses to the one file this permits. It is closed
    /// already, and by a different test: `theOnlyViewModelConstructionInSourcesIsTheRealStoreFactory`
    /// bans `Self(` and `.init(` in that file outright, so a second factory there cannot use the
    /// spelling that would hide it, and must write `AgentViewModel(` — where the name count, pinned
    /// at exactly one, sees it.
    ///
    /// **The false positive this can produce, stated rather than discovered later.** A legitimate new
    /// file under `Sources/MacAgent/` that took, say, `taskHistoryStore:` as a parameter of its own
    /// would fail here. That is the rule working rather than misfiring — stores are assembled in one
    /// place, and a second assembly point is the thing this suite exists to refuse — but the failure
    /// message says so, in the shape the `.init(` ban's message already uses: if the site is
    /// legitimate, the scan learns it rather than being dropped.
    @Test
    func noAppSourceOutsideTheFactoryNamesAStoreParameterLabel() throws {
        let storeLabels = LocalStore.allCases.compactMap { Self.injection(of: $0).parameterLabel }
        let labels = storeLabels + Self.otherRequiredParameters
        #expect(
            storeLabels.count == LocalStore.allCases.count - 1,
            "expected every store but the clipboard history the monitor carries to be a parameter of its own"
        )

        let sources = Self.repositoryRoot.appendingPathComponent("Sources")
        guard let walker = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil) else {
            Issue.record("could not enumerate Sources/")
            return
        }

        var elsewhere: [String] = []
        var inTheFactorysFile: [String: Int] = [:]
        var filesRead = 0
        var filesSkipped = 0
        for case let url as URL in walker where url.pathExtension == "swift" {
            // The same exclusion the sweep above argues, for the same reason: `AgentActionExecutor`,
            // `CapabilityAdapter`, `AgentRunner`, `InstantCommandResolver` and `WorkspaceTaskTagging`
            // all take stores under these labels, legitimately, because they are handed the ones the
            // view model already holds.
            guard !url.pathComponents.contains("MacAgentCore") else {
                filesSkipped += 1
                continue
            }
            filesRead += 1
            let code = TestSourceTree.codeLines(of: try String(contentsOf: url, encoding: .utf8))
                .map(\.text)
                .joined(separator: "\n")
            for label in labels {
                let uses = Self.argumentLabelUses(of: label, in: code)
                guard !uses.isEmpty else { continue }
                if url.lastPathComponent == "AgentViewModel.swift" {
                    inTheFactorysFile[label] = uses.count
                } else {
                    elsewhere.append("\(url.lastPathComponent) names \(label): \(uses.count)×")
                }
            }
        }

        #expect(filesRead > 20, "the enumerator saw \(filesRead) swept app sources — too few to be the real tree")
        #expect(filesSkipped > 100, "the MacAgentCore exclusion skipped \(filesSkipped) files — too few to be that target")
        #expect(
            elsewhere.isEmpty,
            """
            \(elsewhere.sorted().joined(separator: "; ")) — a store parameter label outside \
            AgentViewModel.swift means something other than the factory is assembling an \
            AgentViewModel, and a label is the one part of that call Swift will not let a caller \
            leave out, so no spelling hides it. If the site is legitimate, this scan needs to learn \
            it rather than being dropped.
            """
        )

        // Per label rather than in aggregate, so one label going quiet cannot be absorbed by the
        // other fourteen.
        for label in labels {
            let uses = inTheFactorysFile[label] ?? 0
            #expect(
                uses >= 2,
                """
                AgentViewModel.swift names \(label) \(uses) time(s); the initializer's declaration \
                and the factory's argument are two, so fewer means the parameter was renamed or this \
                matcher stopped seeing it.
                """
            )
        }
    }

    /// **The sweep above, shown seeing the spelling the store-type arm cannot** (PR #158 review, F1).
    ///
    /// The reviewer's wrapper, reduced to its two shapes: a store written `.init()` in argument
    /// position, and a store reached through a type annotation. Three things are asserted per sample
    /// and the triple is the point — the view-model name count finds nothing, the **store type**
    /// sweep finds nothing either, and the label arm finds the labels.
    @Test
    func theLabelArmSeesTheSpellingTheStoreTypeArmCannotSee() {
        let samples: [(String, String, Int)] = [
            ("stores written .init() in argument position", """
            typealias ConvenientViewModel = AgentViewModel
            enum DeveloperConvenience {
                static func viewModel() -> ConvenientViewModel {
                    ConvenientViewModel(routineStore: .init(), taskHistoryStore: .init())
                }
            }
            """, 2),
            ("a store reached through a type annotation", """
            enum DeveloperConvenience {
                static func viewModel() -> AgentViewModel {
                    let settings: ClipboardHistorySettingsStore = .init()
                    return .init(clipboardHistorySettingsStore: settings)
                }
            }
            """, 1)
        ]
        for (label, sample, expectedLabels) in samples {
            #expect(
                Self.constructions(of: "AgentViewModel", in: sample).isEmpty,
                Comment(rawValue: "\(label): the view-model name count can see this after all")
            )
            let byType = LocalStore.allCases
                .map { Self.injection(of: $0).typeName }
                .flatMap { Self.constructions(of: $0, in: sample) }
            #expect(
                byType.isEmpty,
                Comment(rawValue: "\(label): the store-type arm found \(byType.count) — this sample is not the door")
            )
            let byLabel = (LocalStore.allCases.compactMap { Self.injection(of: $0).parameterLabel })
                .flatMap { Self.argumentLabelUses(of: $0, in: sample) }
            #expect(
                byLabel.count == expectedLabels,
                Comment(rawValue: "\(label): the label arm found \(byLabel.count) of \(expectedLabels)")
            )
        }

        // **Every kind of trivia Swift permits between a label and its colon**, which is the whole
        // reason this key closes rather than moving. The first version skipped whitespace only, and
        // the two below compiled straight past it (cycle 2, G1). The comment openers are assembled
        // from characters rather than written out, for the reason `skippingTrivia` gives.
        let slash = "/"
        let star = "*"
        let block = slash + star + " c " + star + slash
        let line = slash + slash + " c"
        for (label, text) in [
            ("plain", "f(routineStore: .init())"),
            ("space", "f(routineStore : .init())"),
            ("newline", "f(routineStore\n    : .init())"),
            ("backticks", "f(`routineStore`: .init())"),
            ("backticks and space", "f(`routineStore` : .init())"),
            ("block comment", "f(routineStore \(block) : .init())"),
            ("nested block comment", "f(routineStore \(slash + star + " a " + block + " b " + star + slash) : .init())"),
            ("line comment", "f(routineStore \(line)\n    : .init())")
        ] {
            #expect(
                Self.argumentLabelUses(of: "routineStore", in: text).count == 1,
                Comment(rawValue: "\(label): \(text.debugDescription)")
            )
        }

        // **The identifier boundary, on an input that actually reaches it.** This assertion read
        // `myRoutineStore:` for one round and was vacuous: `myRoutineStore` does not contain
        // `routineStore` — the `R` is capital — so the search never found the label and the boundary
        // check never ran (cycle 2, G3). One lowercase character is the difference between a test
        // and a sentence.
        #expect("myRoutineStore".contains("routineStore") == false, "the old input never reached the boundary check")
        #expect("myroutineStore".contains("routineStore"), "the new input does reach it")
        #expect(Self.argumentLabelUses(of: "routineStore", in: "f(myroutineStore: .init())").isEmpty)
        #expect(Self.argumentLabelUses(of: "routineStore", in: "f(theroutineStore: .init())").isEmpty)
        #expect(Self.argumentLabelUses(of: "routineStore", in: "f(_routineStore: .init())").isEmpty)

        // And a use that is not a label at all.
        #expect(Self.argumentLabelUses(of: "routineStore", in: "let x = routineStore.load()").isEmpty)
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

    /// The store-level twin of the rule above, and the one thing SONNY-350's compile-time rule
    /// cannot see.
    ///
    /// Requiring `fileURL:` stops a test reaching the real path *by silence*. It does not stop one
    /// reaching it **in words** — `TaskHistoryStore(fileURL: TaskHistoryStore.realFileURL())`
    /// compiles, and it must, because that is exactly what the shipping app writes. So the
    /// population is held instead of the spelling banned: four tests name a `realFileURL`, each
    /// because its subject is what production builds, and each reads a value the initializer decides
    /// without ever opening a file.
    ///
    /// **A floor as well as a ceiling**, for the reason the label arm above gives: a set that only
    /// forbids passes vacuously the day the matcher breaks. A fifth file here is a real decision —
    /// either that test wants an `UnreachableLocalStores` store, or it belongs on this list with its
    /// reason written beside it.
    @Test
    func onlyTheShippedConstantsTestsNameAStoresRealLocation() throws {
        let permitted: Set<String> = [
            // The shipped task-history cap, read off a store built the way production builds one.
            "MacAgentCoreTests/TaskHistoryRetentionTests.swift",
            // The plan store's cap, which must equal the task row's.
            "MacAgentCoreTests/TaskResultStorageTests.swift",
            // The shipped fourteen-day idle expiry.
            "MacAgentCoreTests/ResumableTaskStoreTests.swift",
            // That row J's file sits beside the others under Application Support.
            "MacAgentCoreTests/ApprovedAppStoreTests.swift"
        ]

        var files: [TestSourceTree.SourceFile] = []
        for target in TestSourceTree.targets {
            files.append(contentsOf: try TestSourceTree.swiftFiles(in: target))
        }
        #expect(!files.isEmpty, "the enumerator found no test sources")

        // Assembled so the literal never appears in this file, which the sweep reads like any other.
        let named = "real" + "FileURL"
        var found: Set<String> = []

        for file in files {
            let code = TestSourceTree.codeLines(of: try TestSourceTree.read(file))
                .map(\.text)
                .joined(separator: "\n")
            guard code.contains(named) else {
                continue
            }
            found.insert(file.relativePath)
            #expect(
                permitted.contains(file.relativePath),
                """
                \(file.relativePath) names a store's real ~/Library location. A fixture that does \
                not care about the file wants UnreachableLocalStores; one that does wants its own \
                temp root. If this site really is about what production builds, add it to this \
                test's list with the reason.
                """
            )
        }

        #expect(
            found == permitted,
            """
            these permitted files no longer name a store's real location: \
            \(permitted.subtracting(found).sorted().joined(separator: ", ")) — drop them from the \
            list, or the list is protecting a site that has gone.
            """
        )
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
        // An argument label plus an internal name ("_ foo:") would need the second word; the
        // signature has none, and one added later shows up as a label nothing matches rather
        // than as a silent pass.
        try parameters(ofInitializerAt: "\n    init(", in: viewModelSource)
    }

    enum ScanError: Error {
        case initializerNotFound
    }

    /// The parameters of one initializer in an arbitrary source file, in declaration order.
    ///
    /// The same parse as `initializerParameters()` above, which now delegates to it. Split out for
    /// `noStoreVendorDefaultsAStoreParameter`, which has four more initializers to read and no
    /// reason to own a second copy of a paren-balancing scanner.
    static func parameters(ofInitializerAt marker: String, in file: URL) throws -> [Parameter] {
        let source = try String(contentsOf: file, encoding: .utf8)
        let code = TestSourceTree.codeLines(of: source).map(\.text).joined(separator: "\n")
        guard let start = code.range(of: marker) else {
            throw ScanError.initializerNotFound
        }

        // **The scan starts at the marker's first character, not its last.** A marker naming the
        // first parameter — which is how two of the vendors below are told apart from an earlier
        // `public init(` in the same file — ends at a colon rather than at the opening parenthesis,
        // so a scanner starting at its end counts the first parenthesis of a *default value* as the
        // parameter list's own and closes on that value's. What it returns then is a fragment: a
        // parse that finds a handful of plausible parameters and none of the ones being asked
        // about, which reads exactly like a signature that has lost them.
        var depth = 0
        var index = start.lowerBound
        var opened: String.Index?
        var closed: String.Index?
        while index < code.endIndex {
            if code[index] == "(" {
                depth += 1
                if depth == 1 {
                    opened = index
                }
            } else if code[index] == ")" {
                depth -= 1
                if depth == 0 {
                    closed = index
                    break
                }
            }
            index = code.index(after: index)
        }
        guard let opened, let closed else {
            throw ScanError.initializerNotFound
        }

        let body = code[code.index(after: opened)..<closed]
        return splitTopLevel(body).compactMap { piece in
            let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let colon = trimmed.firstIndex(of: ":") else {
                return nil
            }
            let label = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            let rest = String(trimmed[trimmed.index(after: colon)...])
            return Parameter(label: label, hasDefault: containsTopLevelDefault(rest))
        }
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
    /// Every use of `label` as an **argument label or a type-annotated binding** — the identifier,
    /// any trivia Swift allows, then `:` — with the preceding character not part of a longer
    /// identifier (SONNY-269, PR #158 review F1, and its cycle-2 G1).
    ///
    /// **Both shapes on purpose.** `f(routineStore: .init())` is the argument label, which is what
    /// makes this spelling-proof. `let settings: ClipboardHistorySettingsStore = .init()` is a type
    /// annotation and reads as the same text — and it is the shape the reviewer's wrapper used for
    /// the one store the monitor has to share, so a matcher that saw only argument positions would
    /// have missed half of the door it was written to close.
    ///
    /// **What may sit between the identifier and the colon is trivia, and trivia is a finite set** —
    /// which is the whole reason this key is worth having. The first version skipped spaces, tabs
    /// and newlines and nothing else, so `` `routineStore`: .init() `` and
    /// `routineStore /* c */ : .init()` both compiled and both walked past it (cycle 2, G1). Swift
    /// permits exactly: whitespace, a `//` line comment to the end of its line, and a `/* */` block
    /// comment, which nests. All three are skipped now, and the backtick-escaped spelling of the
    /// identifier is matched on both sides. **There is no fourth thing** — a label and its colon
    /// cannot be separated by anything that is not trivia — so unlike the four name-keyed doors
    /// before it, this one closes rather than moving.
    ///
    /// It deliberately does **not** try to tell a call from a declaration: the initializer's own
    /// `routineStore: RoutineStore,` counts, which is what the floor of two above is counting.
    static func argumentLabelUses(of label: String, in source: String) -> [String] {
        guard !label.isEmpty else { return [] }
        var uses: [String] = []
        var index = source.startIndex
        while let found = source.range(of: label, range: index..<source.endIndex) {
            index = found.upperBound
            if found.lowerBound > source.startIndex {
                let before = source[source.index(before: found.lowerBound)]
                if before.isLetter || before.isNumber || before == "_" {
                    continue
                }
            }
            var cursor = found.upperBound
            // The closing half of a backtick-escaped identifier, which Swift requires on both sides
            // and which is not trivia.
            if cursor < source.endIndex, source[cursor] == "`" {
                cursor = source.index(after: cursor)
            }
            cursor = skippingTrivia(from: cursor, in: source)
            guard cursor < source.endIndex, source[cursor] == ":" else { continue }
            uses.append(String(source[found.lowerBound...cursor]))
        }
        return uses
    }

    /// The first index at or after `start` that is not whitespace or a comment.
    ///
    /// Block comments nest in Swift, so the depth is counted rather than stopped at the first close.
    /// The two comment openers are assembled from single characters rather than written out, because
    /// this file is read by scans that strip comments and a literal opener inside one is the trap
    /// `CLAUDE.md` records under the slash-star gotcha.
    private static func skippingTrivia(from start: String.Index, in source: String) -> String.Index {
        let slash: Character = "/"
        let star: Character = "*"
        var cursor = start
        while cursor < source.endIndex {
            let character = source[cursor]
            if character.isWhitespace {
                cursor = source.index(after: cursor)
                continue
            }
            guard character == slash, source.index(after: cursor) < source.endIndex else {
                return cursor
            }
            let second = source[source.index(after: cursor)]
            if second == slash {
                while cursor < source.endIndex, !source[cursor].isNewline {
                    cursor = source.index(after: cursor)
                }
                continue
            }
            if second == star {
                var depth = 1
                cursor = source.index(cursor, offsetBy: 2)
                while cursor < source.endIndex, depth > 0 {
                    let next = source.index(after: cursor)
                    if source[cursor] == slash, next < source.endIndex, source[next] == star {
                        depth += 1
                        cursor = source.index(cursor, offsetBy: 2)
                    } else if source[cursor] == star, next < source.endIndex, source[next] == slash {
                        depth -= 1
                        cursor = source.index(cursor, offsetBy: 2)
                    } else {
                        cursor = next
                    }
                }
                continue
            }
            return cursor
        }
        return cursor
    }

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
