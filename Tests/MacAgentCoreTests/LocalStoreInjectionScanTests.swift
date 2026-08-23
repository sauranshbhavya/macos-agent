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
    static let otherRequiredParameters = ["clipboardHistoryMonitor", "localDataDeletionService"]

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
                invisible to every call site that predates it: it compiles fifteen fixtures \
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
        #expect(checkedLabels.count == expectedLabels.count + 2)
        #expect(checkedLabels.isSuperset(of: ["clipboardHistoryMonitor", "localDataDeletionService"]))
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
        // not the property under test.
        #expect(
            constructionsScanned >= 150,
            "expected the fifteen fixtures' store constructions, scanned \(constructionsScanned)"
        )
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
    /// **What it still does not reach, so the claim is the size of the check.** A wrapper that
    /// constructs the real stores *inline* rather than calling this method is invisible here — it
    /// names nothing to find. Nothing stops that being written; what stops it mattering is that a
    /// test reaching it would have to construct those stores itself, which
    /// `noTestSourceBuildsALocalStoreWithoutNamingItsFileURL` refuses. The earlier wording claimed
    /// "under any name, at any level of indirection", which was more than this enforces.
    @Test
    func onlyMainAsksForTheRealStoreLocations() throws {
        let forbidden = "atItsRealStore" + "Locations"
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
            mentions.keys.sorted() == ["AgentViewModel.swift", "main.swift"],
            """
            \(forbidden)() is mentioned in \(mentions.keys.sorted()) — it may be named only where it \
            is declared and in main.swift. A default, a wrapper or a convenience that reaches it from \
            anywhere else hands its callers the developer's real ~/Library stores while every one of \
            those call sites says nothing at all.
            """
        )
        #expect(
            mentions["AgentViewModel.swift"] == 1,
            """
            AgentViewModel.swift names \(forbidden)() \(mentions["AgentViewModel.swift"] ?? 0) times. \
            One is the declaration; a second is a factory calling it, which is the same door under a \
            new name inside a file this check already trusts.
            """
        )
        #expect(mentions["main.swift"] == 1, "main.swift should call it exactly once")
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

        // **Assembled at run time so the literal never appears in this file**, which the sweep reads
        // like any other: `TestSourceTree.codeLines` drops comment-prefixed lines, so naming the
        // method in the prose above is free, but a string literal spelling it out would make this
        // suite fail on itself. The alternative — excluding this file by name — is an exclusion list
        // that outlives its reason, and it would leave the scan unable to see the one file most
        // likely to mention the method.
        let forbidden = "atItsRealStore" + "Locations"

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
    private static func splitTopLevel(_ text: Substring) -> [String] {
        var pieces: [String] = []
        var current = ""
        var depth = 0
        for character in text {
            switch character {
            case "(", "[", "<":
                depth += 1
                current.append(character)
            case ")", "]", ">":
                depth -= 1
                current.append(character)
            case "," where depth == 0:
                pieces.append(current)
                current = ""
            default:
                current.append(character)
            }
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
    private static func containsTopLevelDefault(_ text: String) -> Bool {
        var depth = 0
        for (offset, character) in text.enumerated() {
            switch character {
            case "(", "[", "<":
                depth += 1
            case ")", "]", ">":
                depth -= 1
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
    /// stopped at the first `)` would read one argument and call it the call. The character before
    /// the name is checked so that `ClipboardHistorySettingsStore(` is not read as a
    /// `ClipboardHistoryStore(`, and so that `SomeType.Store(` or `myStore(` cannot match.
    static func constructions(of name: String, in source: String) -> [String] {
        var results: [String] = []
        var searchStart = source.startIndex
        while let found = source.range(of: name + "(", range: searchStart..<source.endIndex) {
            searchStart = found.upperBound
            if found.lowerBound > source.startIndex {
                let previous = source[source.index(before: found.lowerBound)]
                if previous.isLetter || previous.isNumber || previous == "_" || previous == "." {
                    continue
                }
            }

            var depth = 0
            var index = source.index(before: found.upperBound)
            var closed: String.Index?
            while index < source.endIndex {
                if source[index] == "(" {
                    depth += 1
                } else if source[index] == ")" {
                    depth -= 1
                    if depth == 0 {
                        closed = index
                        break
                    }
                }
                index = source.index(after: index)
            }
            guard let closed else {
                break
            }
            results.append(String(source[found.upperBound..<closed]))
            searchStart = closed
        }
        return results
    }
}
