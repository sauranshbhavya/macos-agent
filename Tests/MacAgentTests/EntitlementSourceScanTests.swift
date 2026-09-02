import Foundation
import Testing
@testable import MacAgent
@testable import MacAgentCore

/// The two structural properties of the entitlement check that no runtime assertion can reach
/// (SONNY-135).
///
/// Both read comment-stripped source through `MacAgentSource`, whose own doc records the limits of a
/// textual scan and why counts are trusted where mere presence is not.
@Suite
@MainActor
struct EntitlementReleaseSwitchScanTests {
    /// Everything that names the debug-only public-key pointer. The two string literals are what a
    /// `strings` sweep of a release binary would look for; the three identifiers are what a release
    /// build would have to be able to resolve.
    ///
    /// A separate list from `SignInReleaseSwitchScanTests`' by design: that one holds the staging
    /// *base URL* pointer and asserts its file set is exactly one file. Two pointers with one shared
    /// token list would make each scan's file assertion the other's problem.
    static let overrideTokens = [
        "\"SONNY_ENTITLEMENT_PUBLIC_KEYS\"",
        "\"SonnyEntitlementPublicKeys\"",
        "overrideEnvironmentVariable",
        "overrideDefaultsKey",
        "normalizedOverride"
    ]

    @Test
    func everyMentionOfTheEntitlementKeyPointerIsInsideIfDebug() throws {
        // SONNY-106: no environment variable is required for anything in a build a user runs. The
        // compiler is the enforcement — the keys are *declared* inside the conditional, so a
        // release-build caller cannot name them — and this holds the population.
        var offenders: [String] = []
        var mentions = 0

        for url in try MacAgentSource.coreSourceFiles()
        where url.lastPathComponent.hasPrefix("Entitlement")
            || url.lastPathComponent == "EntitlementKeys.swift" {
            let source = try MacAgentSource.read(url)
            let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let guarded = ConditionalRegionScan.debugGuardedLines(of: lines)
            for (index, line) in lines.enumerated() {
                guard Self.overrideTokens.contains(where: line.contains) else { continue }
                mentions += 1
                if !guarded[index] {
                    offenders.append(
                        "\(url.lastPathComponent):\(index + 1) "
                            + line.trimmingCharacters(in: .whitespaces)
                    )
                }
            }
        }

        // A walker that found nothing reads exactly like a tree with nothing to find.
        #expect(mentions >= 5, "the scan saw \(mentions) mentions — too few to be the real declaration")
        #expect(offenders.isEmpty, "outside #if DEBUG:\n\(offenders.joined(separator: "\n"))")
    }

    @Test
    func theShippedKeySetIsEmptyBecauseNoGatewayHasBeenDeployed() {
        // The same fact, and the same shape, as `SonnyBackendHost.productionBaseURL` being nil: no
        // remote deploy has happened, so no signing key exists to hold the public half of. An empty
        // set verifies nothing, which is the fail-closed direction.
        #expect(SonnyEntitlementKeys.shipped.isEmpty)
        #expect(SonnyBackendHost.productionBaseURL == nil)
        // And with no override present, `resolve` answers the shipped set rather than inventing one.
        #expect(SonnyEntitlementKeys.resolve(environment: [:], defaultsValue: { _ in nil }).isEmpty)
    }

    @Test
    func anOverrideIsHonouredOnlyWhenAPairInItParses() {
        let real = String(repeating: "A", count: 43)
        #expect(
            SonnyEntitlementKeys.resolve(
                environment: ["SONNY_ENTITLEMENT_PUBLIC_KEYS": "dev-1:\(real)"],
                defaultsValue: { _ in nil }
            ).keyIdentifiers == ["dev-1"]
        )
        // A `UserDefaults` value works too, and it exists because a Screen Recording grant relaunches
        // the bundle through `open -n`, where an environment variable set for a debug run is gone.
        #expect(
            SonnyEntitlementKeys.resolve(
                environment: [:],
                defaultsValue: { $0 == "SonnyEntitlementPublicKeys" ? "dev-1:\(real)" : nil }
            ).keyIdentifiers == ["dev-1"]
        )
        // A typo falls through to the shipped answer rather than becoming an empty override, so a
        // mistyped `defaults write` reads as "no override" rather than as "no keys".
        for broken in ["", "   ", "dev-1", "dev-1:not*base64", ":\(real)"] {
            #expect(
                SonnyEntitlementKeys.resolve(
                    environment: ["SONNY_ENTITLEMENT_PUBLIC_KEYS": broken],
                    defaultsValue: { _ in nil }
                ).isEmpty,
                "\(broken.debugDescription) was treated as an override"
            )
        }
    }
}

/// The structural half of §5.3.1: **no free path takes the entitlement check as a dependency.**
///
/// `EntitlementFreePathTests` in the core target is the behavioural half — the free capabilities
/// resolve with none of this in existence. This is the half that keeps it true: a later ticket that
/// wired an entitlement check into a local resolver would pass every behavioural test that did not
/// happen to construct one, and fail here.
@Suite
@MainActor
struct EntitlementFreePathScanTests {
    /// The types a file must not name to be a free path.
    static let entitlementTypes = [
        "EntitlementService",
        "EntitlementDecision",
        "EntitlementCapability",
        "EntitlementJudgement",
        "EntitlementKeySet"
    ]

    /// The files that decide what a *free local capability* does, and must therefore never consult
    /// an entitlement.
    ///
    /// Named rather than derived, because "free" is a product fact rather than a property of the
    /// file system — and a derived list would silently shrink to nothing if the derivation broke.
    /// `InstantCommandResolver` is the one the contract names, and the four adapters beside it are
    /// the capabilities the founder's headline manual check exercises.
    static let freePaths = [
        "InstantCommandResolver.swift",
        "RunRoutineCapabilityAdapter.swift",
        "OpenWorkspaceCapabilityAdapter.swift",
        "SnippetExpansionCapabilityAdapter.swift",
        "CalculatorCapabilityAdapter.swift"
    ]

    @Test
    func noFreeLocalPathNamesTheEntitlementCheck() throws {
        var offenders: [String] = []
        var scanned: Set<String> = []

        for url in try MacAgentSource.coreSourceFiles()
        where Self.freePaths.contains(url.lastPathComponent) {
            scanned.insert(url.lastPathComponent)
            let source = try MacAgentSource.read(url)
            for type in Self.entitlementTypes where source.contains(type) {
                offenders.append("\(url.lastPathComponent) names \(type)")
            }
        }

        // The population is real: a scan that matched no file would pass silently, which is exactly
        // what a renamed file would produce.
        #expect(scanned == Set(Self.freePaths), "the scan reached \(scanned.sorted())")
        #expect(
            offenders.isEmpty,
            Comment(rawValue: "a free path consults the entitlement check:\n"
                + offenders.joined(separator: "\n"))
        )
    }

    @Test
    func theScanWouldFlagAFreePathThatAcquiredTheDependency() throws {
        // The rule run over a held sample, so it is shown to flag what it names rather than only to
        // pass against the current tree — the shape `LocalStoreInjectionScanTests` adopted after a
        // mutant survived a guard that had only ever been run against the real thing.
        let planted = """
        import Foundation
        struct Resolver {
            let entitlements: EntitlementService
        }
        """
        #expect(Self.entitlementTypes.contains { planted.contains($0) })

        // And the real resolver, read the way the scan reads it, names none of them.
        let resolver = try MacAgentSource.read(
            MacAgentSource.coreSourceDirectory.appendingPathComponent("InstantCommandResolver.swift")
        )
        #expect(!Self.entitlementTypes.contains { resolver.contains($0) })
        // It really was read: an empty string would satisfy the line above.
        #expect(resolver.contains("InstantCommandResolver"))
    }

    @Test
    func theGatedCapabilitySetIsRowEighteensAndThisRepositoryNamesNoKey() throws {
        // The never-touch list in executable form: this ticket builds the gate and decides nothing
        // about what goes through it. No capability key literal exists under `Sources/` at all —
        // the ones in the suite are in tests, which say so.
        var offenders: [String] = []
        for url in try MacAgentSource.coreSourceFiles() + MacAgentSource.appSourceFiles() {
            let source = try MacAgentSource.read(url)
            guard source.contains("EntitlementCapability(") else { continue }
            // A construction with a literal argument would be this repository naming a key.
            for line in source.split(separator: "\n") where line.contains("EntitlementCapability(\"") {
                offenders.append("\(url.lastPathComponent): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        #expect(
            offenders.isEmpty,
            Comment(rawValue: "a capability key is named in Sources:\n"
                + offenders.joined(separator: "\n"))
        )
    }
}

/// The narrow-surface property, held by shape rather than by convention (SONNY-388).
///
/// `EntitlementService.decision(for:)` is the one place the entitlement question is answered, and
/// the reasoning above `currentSubscription()` says why nothing else may hand out the raw claim: a
/// caller holding an `EntitlementClaim` can read `capabilities` and decide entitlement itself, with
/// no judge, no session check and no clock defence, none of it enforceable once the value leaves
/// the actor. `refreshNow()` handed the claim out anyway, so the property was a convention every
/// future caller had to remember — and SONNY-216's own record claimed it was structural when it was
/// not. The founders' ratification (2026-08-31, on SONNY-388) removed the return value; this suite
/// is what makes the removal stick.
///
/// **The population is enumerated by value, not merely swept.** A blanket "no signature names the
/// claim" would pass silently over a public member the sweep failed to parse, and a parallel branch
/// is adding to this surface right now (`claimConfirmation()`, SONNY-213's lane) — so every public
/// declaration on the actor must equal a line in the pinned table below, and a new arrival fails
/// this suite until a person classifies it here, under this header. That is the stop working as
/// designed, the same shape as `theWipesOwnSentenceNamesEveryStoreItDeletes` stopping an unnamed
/// store.
///
/// **A `public ` prefix is not the same thing as a public declaration, and the first version of this
/// suite confused them** (PR #189's review, F1 and F2 — both blocking, one fix). The extractor
/// selected lines with `hasPrefix("public ")`, so a member written `nonisolated public func …` was
/// invisible to it — and that is not a hypothetical spelling: it is the only ordering this
/// repository uses for that pair, in the same target this scan reads
/// (`git grep -nE '^\s*nonisolated (public|private|internal)' -- Sources` names
/// `OpenAIPlanner.swift` twice; the reversed `^\s*public nonisolated` exits 1). The reviewer's
/// mutants settled it rather than arguing it: a `nonisolated public` claim door **survived** the
/// whole suite, the same door reached through an `extension EntitlementService` in another file
/// **survived**, and a plainly written control **was killed by both tests below** — so the control
/// fired and the two survivors were this guard's. The extractor now selects a `public` **token** at
/// declaration position, which is what "public declaration" meant all along.
///
/// **The reason it could stand was in the held-sample test, not in the extractor** — and that half
/// is the more useful one. `theScanWouldFlagASurfaceThatWidenedBack` compared string literals
/// against the table and against the token, with both samples supplied *already in `public `-prefixed
/// form*, so the extractor was never on the path the sample took. A guard whose own held sample
/// skips the component under suspicion has been shown to do nothing; its sibling one screen up gets
/// this right, reading a real file and then asserting the read happened. Every held sample here now
/// goes through `publicDeclarationLines(in:)`, and the `nonisolated` one fails against the extractor
/// this suite shipped with — which is what makes it worth writing.
///
/// **The one-file scope has its own consequence, and stating the type-chasing one is not stating
/// this one.** A `public` member declared in an `extension EntitlementService` anywhere else in
/// `MacAgentCore` reaches the same surface and no filter over this one file can see it. That is why
/// `noOtherFileInTheTargetExtendsTheServiceIntoANewSurface` sweeps the whole target — **including
/// `public extension EntitlementService`, whose members are public by default and which is how this
/// repository writes ten of its seventeen extension lines**. Today no such extension exists, so the
/// cheap assertion is true now and fails the day it stops being — at which point the population has
/// to be widened rather than the assertion relaxed. It is already known to fail that way: PR #190
/// adds `extension EntitlementService: ScreenControlEntitlementConfirming {}`, and this sweep is
/// meant to stop it until someone folds that extension's members into the enumeration.
///
/// **The same defect twice, one round apart, in adjacent functions** (PR #189's cycle 3, G1). The
/// round that replaced `hasPrefix("public ")` with a token match wrote the sweep's own predicate as
/// `hasPrefix("extension EntitlementService")`, one function away, in the code added to close that
/// exact defect — so a `public extension` door was invisible twice over, and a mutant carrying one
/// passed the whole suite. Both predicates now share `tokens(of:)`, which is what makes them unable
/// to disagree about what a declaration looks like. **The generalisation is worth more than the
/// fix**: a prefix test asks where text begins, and every question this suite actually asks is about
/// which tokens a line carries, so a prefix test here is wrong by construction however carefully it
/// is written.
///
/// **The honest limits that remain, stated as `MacAgentSource`'s own doc demands.** This is still a
/// textual scan: it cannot chase types, so a public member returning some wrapper that carries a
/// claim passes the token sweep and is caught only by the enumeration forcing a human read of the
/// new line. A `public` token inside a multi-line signature's continuation would be read as its own
/// declaration — the fail-loud direction, since it adds a line the value table does not hold. And
/// **the enumeration answers for `public`, while the reasoning behind it reaches one access level
/// further**: `MacAgent` and `MacAgentCore` are two targets of one package, so a `package` member of
/// the actor is callable from the app target and would hand out a claim exactly as a public one
/// would (PR #189's cycle 3, G2, which measured a `package` door surviving). Nothing uses `package`
/// in `Sources/` today — `git grep -nE '^\s*package (func|var|let|init|struct|enum|class|actor|protocol|typealias)' -- Sources`
/// exits 1 — and the ratified property is about the public surface, so this is recorded as a limit
/// rather than folded in: widening the table to two access levels would change what it means, and
/// that is a decision for whoever needs it. Anything needing more than this needs a different tool,
/// not a stronger claim about this one.
@Suite
@MainActor
struct EntitlementClaimSurfaceScanTests {
    /// Every public declaration on `EntitlementService`, verbatim. The value table IS the review:
    /// adding a public member means adding its exact signature line here, having decided it hands
    /// out no `EntitlementClaim` — and a signature that changes (a return type widened back) is a
    /// line this table no longer contains.
    static let publicSurface = [
        "public actor EntitlementService {",
        "public init(",
        "public func decision(for capability: EntitlementCapability) async -> EntitlementDecision {",
        // **Classified here, under this header, as SONNY-388's design requires** (SONNY-213's lane,
        // which this suite's own doc above anticipated arriving). `claimConfirmation()` asks whether
        // this Mac holds a claim it can confirm *without naming a capability*, and it hands out no
        // `EntitlementClaim`: it returns an `EntitlementDecision`, which is `.entitled` or
        // `.refused(EntitlementRefusal)` and carries no claim, no capability list and no plan. So a
        // caller cannot read `capabilities` off it and decide entitlement for itself, which is the
        // whole property this table exists to hold. `decision(for:)` remains the only member that
        // answers whether a capability is granted; this one runs the same path and stops one
        // question short of that.
        "public func claimConfirmation() async -> EntitlementDecision {",
        "public func currentSubscription() async -> SubscriptionSnapshot? {",
        "public func refreshNow() async throws {",
        "public func discardLocally() throws {",
        "public func awaitPendingRefresh() async {"
    ]

    /// The keywords a Swift declaration is built on. A line carrying a `public` token *and* one of
    /// these is a declaration; a line carrying `public` and none of them is something else.
    static let declarationKeywords: Set<String> = [
        "func", "var", "let", "init", "deinit", "subscript", "actor", "class", "struct",
        "enum", "protocol", "extension", "typealias", "associatedtype", "case", "operator"
    ]

    /// One line's whitespace-separated tokens. **The single tokeniser for every predicate in this
    /// suite, and having one is the point** — PR #189's cycle 3 found the sweep below written as a
    /// prefix match one function away from the prefix match cycle 1 had just replaced, so the two
    /// predicates disagreed about what a Swift declaration looks like while reading the same source.
    static func tokens(of line: String) -> [String] {
        line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
    }

    /// The keyword a token opens, which is its leading run of letters — `init(` and `subscript(`
    /// carry their parenthesis, and `EntitlementService:` its colon.
    static func keyword(of word: String) -> String {
        String(word.prefix(while: \.isLetter))
    }

    /// Whether one already-trimmed, comment-stripped line declares something public.
    ///
    /// **Token-based rather than prefix-based, which is the whole of PR #189's F1.** Swift lets
    /// attributes and modifiers precede the access modifier, and this repository writes
    /// `nonisolated public func` — so `hasPrefix("public ")` answers false for a public member and
    /// the enumeration silently shrinks. Matching a whitespace-separated `public` token also refuses
    /// the two ways a prefix match would have gone wrong in the other direction: `publicURL` is one
    /// token and not this one, and a `"public func"` inside a string literal carries its quote into
    /// the token, so neither reaches the declaration test.
    static func declaresSomethingPublic(_ line: String) -> Bool {
        let words = tokens(of: line)
        guard words.contains("public") else { return false }
        return words.contains { declarationKeywords.contains(keyword(of: $0)) }
    }

    /// Whether a line carries the access modifier but not the thing it modifies — `public` alone on
    /// its own line, which is legal Swift and which the line-at-a-time reading below would otherwise
    /// split into two lines neither of which declares anything (PR #189's cycle 3, M4).
    static func carriesPublicWithoutADeclaration(_ line: String) -> Bool {
        let words = tokens(of: line)
        return words.contains("public")
            && !words.contains { declarationKeywords.contains(keyword(of: $0)) }
    }

    /// Every line of already-read source that declares something public, trimmed. Split out from the
    /// file-reading form **so a held sample can be driven through the extractor** — the component
    /// F1's hole was in, and the one F2 found the old held-sample test walking around.
    ///
    /// **A declaration whose modifier sits on its own line is joined back together first.** Reading
    /// one line at a time is what a textual scan can do, and it is wrong for
    /// `public` on one line and `func …` on the next: neither line declares anything by itself, so a
    /// public member disappears from the enumeration. A line carrying `public` without a declaration
    /// keyword is therefore carried forward onto the next one. The join can only *add* a candidate —
    /// a line that would have been selected alone already has its keyword — so the failure direction
    /// is a spurious entry the value table does not hold, which fails loudly.
    ///
    /// Multi-line signatures are represented by their first line (`public init(` today), which is
    /// enough for equality against the table and is where a return type cannot hide: a Swift
    /// function's arrow sits on the line its parameter list closes on, so a single-line signature
    /// that grew an arrow no longer equals its table entry.
    static func publicDeclarationLines(in source: String) -> [String] {
        var joined: [String] = []
        var carried = ""
        for line in source.split(separator: "\n", omittingEmptySubsequences: false)
            .map({ $0.trimmingCharacters(in: .whitespaces) }) {
            let candidate = carried.isEmpty ? line : carried + " " + line
            if carriesPublicWithoutADeclaration(candidate) {
                carried = candidate
                continue
            }
            carried = ""
            joined.append(candidate)
        }
        if !carried.isEmpty {
            joined.append(carried)
        }
        return joined.filter { declaresSomethingPublic($0) }
    }

    /// The same, over the real `EntitlementService.swift` with both comment syntaxes stripped.
    static func publicDeclarationLines() throws -> [String] {
        publicDeclarationLines(in: try MacAgentSource.read(
            MacAgentSource.coreSourceDirectory.appendingPathComponent("EntitlementService.swift")
        ))
    }

    /// Whether a line opens an extension **of this actor**.
    ///
    /// **Token-based for the same reason `declaresSomethingPublic` is, and this function is why the
    /// reason had to be written down twice** (PR #189's cycle 3, G1). It was `hasPrefix("extension
    /// EntitlementService")` — written in the round that replaced cycle 1's `hasPrefix("public ")`,
    /// one function away, in the code added to close that exact defect. So `public extension
    /// EntitlementService { … }` was invisible: to the enumeration because it is in another file,
    /// and to this sweep because of the prefix. Members of a `public extension` are public by
    /// default, so that is a public claim door, and the whole suite passed with one in place.
    /// **The spelling is this repository's, not a hypothetical**: `git grep -nE '^\s*public
    /// extension ' -- Sources` answers 10 lines across 9 files, every one of them under
    /// `Sources/MacAgentCore/`, which is the directory this sweep walks — against 17 extension lines
    /// in total.
    ///
    /// The name must be the whole identifier, or `extension EntitlementServiceTests` matches.
    static func extendsTheService(_ line: String) -> Bool {
        let words = tokens(of: line)
        guard let position = words.firstIndex(of: "extension"), position + 1 < words.count else {
            return false
        }
        return keyword(of: words[position + 1]) == "EntitlementService"
    }

    /// An extension whose body is **provably empty** — `{}` closed on the declaration's own line.
    ///
    /// **The exemption the sweep below needed, and the narrowest one that answers** (SONNY-213).
    /// That sweep asserts there are *no* extensions of the actor outside its own file, and its own
    /// comment names that as the cheap proxy for the real property — no public member reaching the
    /// surface unenumerated — "enough because it fails the day the assumption stops holding, which
    /// is when the population has to be widened". SONNY-213 is that day: it adds
    /// `extension EntitlementService: ScreenControlEntitlementConfirming {}` in `ScreenControlGate.swift`,
    /// a conformance declaring **no members at all**, whose one protocol requirement
    /// (`claimConfirmation()`) is declared in `EntitlementService.swift` and enumerated in the table
    /// above like every other member.
    ///
    /// So the widening is by exactly one case and no more: a body closed on its own line can contain
    /// nothing, so it can add nothing to the surface. **Every other extension is still flagged**,
    /// including an empty-looking one whose body opens across lines — which is the direction that
    /// matters, since a `{` alone is where a member would go next.
    static func isMemberlessExtension(_ line: String) -> Bool {
        line.hasSuffix("{}")
    }

    @Test
    func everyPublicDeclarationOnTheServiceIsOneThisSuiteHasClassified() throws {
        let lines = try Self.publicDeclarationLines()
        // The scan found the real surface rather than an empty or renamed file: zero would read
        // exactly like a tree with nothing to find, and zero must fail (the clean-zero rule).
        try #require(!lines.isEmpty, "the scan read no public declarations — the file moved or the filter broke")
        #expect(lines.sorted() == Self.publicSurface.sorted(), """
            the service's public surface is not the classified one. A member is added to the table \
            only after deciding, under this suite's header, that it hands out no EntitlementClaim. \
            Declared:
            \(lines.joined(separator: "\n"))
            """)
    }

    @Test
    func noPublicDeclarationOnTheServiceNamesTheClaim() throws {
        // The property itself, swept over what the file actually declares rather than over the
        // table, so a widening has to defeat this and the enumeration at once. The full type name
        // is the token: `EntitlementCapability` and `EntitlementDecision` share the prefix and must
        // keep passing.
        let lines = try Self.publicDeclarationLines()
        // **Zero lines is zero assertions and a green test** (PR #189's review, F4). The sibling
        // above guards this and this one used to lean on that, which is a coupling nothing stated —
        // and it is not even the same guard, since a file that moved defeats both at once.
        try #require(!lines.isEmpty, "the scan read no public declarations — the file moved or the filter broke")
        for line in lines {
            #expect(
                !line.contains("EntitlementClaim"),
                "a public declaration hands out or takes in the claim: \(line)"
            )
        }
    }

    @Test
    func theScanWouldFlagASurfaceThatWidenedBack() throws {
        // The rule run over held samples, the shape `theScanWouldFlagAFreePathThatAcquiredTheDependency`
        // records the reason for: a guard only ever run against the tree it currently passes on has
        // never been shown to catch anything.
        //
        // **Every sample goes through the extractor, which is what this test used to skip** (PR
        // #189's F2). It compared literals already written in `public `-prefixed form against the
        // table and against the token — both of which worked — while the extractor, where the hole
        // actually was, sat off the path. Feeding a source fragment in instead means the assertion
        // below fails against the filter this suite shipped with.
        for sample in [
            // The return value put back: an existing table line changes, so the enumeration sees it.
            "    public func refreshNow() async throws -> EntitlementClaim {",
            // A fresh accessor: a line the table does not hold.
            "    public var latestClaim: EntitlementClaim? {",
            // The same door in this repository's own house style for that modifier pair. A
            // `hasPrefix("public ")` extractor returns nothing at all for this line, so the mutant
            // carrying it survived the whole suite until F1 was fixed.
            "    nonisolated public func latestClaim() -> EntitlementClaim? { nil }",
            // And with the attribute in front, the other way a declaration can begin.
            "    @MainActor public func latestClaim() -> EntitlementClaim? { nil }",
            // **The modifier on its own line** (PR #189's cycle 3, M4). Legal Swift, unusual style,
            // and read one line at a time it is two lines neither of which declares anything — so
            // the member vanished from the enumeration entirely. It is one sample rather than two
            // because the thing being held is the join, and a sample that arrived already joined
            // would be entering below it, which is SONNY-397's whole shape.
            "    public\n    func latestClaim() -> EntitlementClaim? { nil }"
        ] {
            let declared = Self.publicDeclarationLines(in: sample)
            try #require(
                declared.count == 1,
                "the extractor saw \(declared.count) declarations in this sample, not one: \(sample.debugDescription)"
            )
            // Caught twice over: the table does not hold it, and it names the claim.
            #expect(!Self.publicSurface.contains(declared[0]))
            #expect(declared[0].contains("EntitlementClaim"))
        }

        // And the extractor is not simply matching everything: a line that carries the word without
        // declaring anything, and one that carries it inside a literal, are both refused. Without
        // this, widening the filter to fix F1 could have been widened into a filter that passes
        // every line and an enumeration that means nothing.
        // Comment-prefixed lines are gone before the extractor sees them — `MacAgentSource.read`
        // strips both syntaxes — so they are not this function's job and are not asserted here. A
        // *trailing* comment does survive that strip, and one carrying both a `public` token and a
        // declaration keyword would be read as a declaration: that direction adds a line the value
        // table does not hold, so it fails loudly rather than hiding a door, which is the direction
        // to be wrong in.
        for notADeclaration in [
            "return publicClaim",
            #"log("public func latestClaim() -> EntitlementClaim?")"#
        ] {
            #expect(
                Self.publicDeclarationLines(in: notADeclaration).isEmpty,
                "the extractor read a non-declaration as one: \(notADeclaration)"
            )
        }
    }

    @Test
    func noOtherFileInTheTargetExtendsTheServiceIntoANewSurface() throws {
        // **The one-file scope's own consequence** (PR #189's F1, second half). A `public` member
        // declared in an `extension EntitlementService` in any other file of this target reaches the
        // same surface, and no filter over `EntitlementService.swift` can see it — a mutant doing
        // exactly that survived the whole suite. Folding those bodies into the enumeration is the
        // thorough fix; asserting there are none is the cheap one, and it is enough because it fails
        // the day the assumption stops holding, which is when the population has to be widened.
        let files = try MacAgentSource.coreSourceFiles()
        try #require(!files.isEmpty, "no source files were read — the target moved or the walk broke")
        var offenders: [String] = []
        var sawTheService = false
        for url in files {
            let relativePath = MacAgentSource.coreRelativePath(of: url)
            if relativePath == "EntitlementService.swift" {
                sawTheService = true
                continue
            }
            for line in try MacAgentSource.read(url).split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard Self.extendsTheService(trimmed) else { continue }
                // A conformance that declares nothing cannot widen the surface; anything else is
                // flagged and a person decides. See `isMemberlessExtension`.
                guard !Self.isMemberlessExtension(trimmed) else { continue }
                offenders.append("\(relativePath): \(trimmed)")
            }
        }
        // The walk really reached the actor's own file; without this, a renamed or moved
        // `EntitlementService.swift` leaves an empty sweep that reads exactly like a clean one.
        #expect(sawTheService, "EntitlementService.swift was not among the files walked")

        // **The exemption run over held samples, in both directions** (SONNY-213). The sweep now
        // lets a member-less conformance through, and an exemption that has only ever been run
        // against the one line it was written for has not been shown to stop at that line. The
        // repository's own case is first; everything under it must still be flagged, and the third
        // is the one that matters — an extension that looks empty because its brace opens alone.
        for exempt in [
            "extension EntitlementService: ScreenControlEntitlementConfirming {}",
            "public extension EntitlementService: SomeProtocol {}"
        ] {
            #expect(
                Self.extendsTheService(exempt) && Self.isMemberlessExtension(exempt),
                "a member-less conformance should be recognised as one: \(exempt)"
            )
        }
        for flagged in [
            "extension EntitlementService {",
            "public extension EntitlementService {",
            "extension EntitlementService: ScreenControlEntitlementConfirming {",
            "extension EntitlementService { public func latestClaim() -> EntitlementClaim? { nil } }"
        ] {
            #expect(
                Self.extendsTheService(flagged) && !Self.isMemberlessExtension(flagged),
                "an extension that can carry a member must still be flagged: \(flagged)"
            )
        }
        #expect(
            offenders.isEmpty,
            Comment(rawValue: "the service's surface is extended outside its own file, so the "
                + "enumeration above no longer sees all of it:\n" + offenders.joined(separator: "\n"))
        )

        // The rule shown to flag what it names, and to leave the near-miss alone.
        #expect(Self.extendsTheService("extension EntitlementService {"))
        #expect(Self.extendsTheService("extension EntitlementService: Sendable {"))
        // **The spelling this repository actually uses, and the one this predicate missed** (PR
        // #189's cycle 3, G1). Members of a `public extension` are public by default, so this is a
        // public claim door; `public extension` appears ten times under `Sources/MacAgentCore/`,
        // which is the directory walked above. The first three samples all begin with the literal
        // `extension`, so every one of them passed the prefix match this replaced — which is why
        // adding a sample that does not is the fix and not the token predicate alone.
        #expect(Self.extendsTheService("public extension EntitlementService {"))
        #expect(Self.extendsTheService("nonisolated public extension EntitlementService {"))
        #expect(Self.extendsTheService("@MainActor public extension EntitlementService: Sendable {"))
        #expect(!Self.extendsTheService("extension EntitlementServiceTests {"))
        #expect(!Self.extendsTheService("public extension EntitlementServiceTests {"))
        #expect(!Self.extendsTheService("extension EntitlementClaim {"))
        // A line that merely names the type is not a declaration of an extension on it.
        #expect(!Self.extendsTheService("let x = EntitlementService.self"))
    }
}
