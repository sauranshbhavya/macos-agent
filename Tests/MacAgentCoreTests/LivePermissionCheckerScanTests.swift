import Foundation
import Testing
@testable import MacAgentCore

/// **No test may reach a live permission checker** (SONNY-123).
///
/// The reason this exists rather than a convention: the seams are *defaulted*, so a fixture that
/// reaches for the live service is a call that compiles, passes, and reads exactly like every other
/// fixture. SONNY-103 was one instance found by accident. SONNY-106 section D states the rule; this
/// file is the thing that enforces it, and source text is the only place it can be enforced, because
/// the deterministic default is a state a real Mac can also be in — a runtime assertion cannot tell
/// an injected grant from a granted machine.
///
/// **Measured, not assumed.** Every pin here was written against a mutant that survived without it:
/// two fixture defaults reverted to a live service (PR #72 cycle 0), an executor fixture that never
/// named the seam at all (F1), a partial injection naming only the screen checker (F3), a neutered
/// matching loop (F6), and an argument spelled `.init()` (C1).
///
/// Scanning both target directories from one file is deliberate: the property is about the whole
/// suite, and a per-target copy is a copy that can be deleted from one target and still look
/// enforced.
///
/// ## What this cannot do, stated so it is not mistaken for a boundary
///
/// It is textual, and four forms evade it:
///
/// 1. **Omission** — a constructor that leaves a defaulted seam out entirely puts no forbidden token
///    on any line. Not hypothetical, and the form that actually shipped: `AgentRunnerTests.makeExecutor`
///    built an `AgentActionExecutor` without `permissionReadinessService` and drove a readiness plan
///    through it (PR #72 F1). Closed for the three fixtures that can drive readiness, by
///    `everyExecutorFixtureThatCanDriveReadinessInjectsTheSeam`, and nowhere else — requiring the
///    parameter at all 37 executor constructions in the suite would be churn, since most never touch
///    a readiness path.
/// 2. **Spelling, which is what this keys on rather than route.** `everyExecutorFixtureThatCanDriveReadinessInjectsTheSeam`
///    matches files that write `.showPermissionReadiness`; a fixture that resolves the same operation
///    as `AgentOperation(rawValue: "show_permission_readiness")` is not in the matched set and never
///    was. The cycle-2 review built exactly that file, ran a readiness plan through an executor with
///    no seam, and watched every pin here pass. Its count pin does catch an *existing* matched file
///    that stops spelling the symbol (measured: rewriting `AgentRunnerTests`' step that way drops the
///    count to two and fails). It cannot catch a *new* file that never spelled it. This is a
///    permanent property of a textual scan, not a defect to harden away: any spelling-based rule has
///    a spelling that evades it, and the enumerating method is the marker probe recorded on the
///    ticket, not a longer regex.
/// 3. **Indirection** — a typealias, a stored metatype, or a construction split across lines.
/// 4. **A new defaulted seam** that nobody adds to `forbidden`. `theForbiddenTokensStillNameTheLiveImplementations`
///    catches a *rename* of the ones that exist; it cannot catch a third being introduced.
///
/// It raises the cost of the accident it is aimed at and does not pretend to be a barrier against
/// intent.
@Suite
struct LivePermissionCheckerScanTests {
    /// Constructions that hand a test whatever this Mac has granted.
    ///
    /// `PermissionReadinessService(` is listed **with no closing parenthesis** (PR #72 F3): matching
    /// the argument-free `PermissionReadinessService()` let *partial* injection through, since a call
    /// naming `screenPermissionChecker` and leaving `microphonePermissionChecker` at its live default
    /// is a live authorization read. Both checkers are defaulted, so any direct construction can be
    /// partial; the only safe rule is that tests do not call this initializer at all.
    static let forbidden = [
        "SystemScreenCapturePermissionChecker(",
        "SystemMicrophonePermissionChecker(",
        "PermissionReadinessService("
    ]

    /// The single file allowed to construct a readiness service directly, target-qualified because
    /// both targets carry a file of this name and only this one is exempt.
    private static let constructionSite = "MacAgentCoreTests/DeterministicPermissions.swift"

    private static let thisFile = "MacAgentCoreTests/LivePermissionCheckerScanTests.swift"

    /// The matching rule, as a pure function so a fixture can hold it.
    static func offenders(inSource source: String, label: String) -> [String] {
        var found: [String] = []
        for line in TestSourceTree.codeLines(of: source) {
            for token in forbidden where line.text.contains(token) {
                found.append("\(label):\(line.number) — \(token)")
            }
        }
        return found
    }

    /// Pins the matching rule itself against a fixture, so that neutering the scan's loop is a
    /// failure rather than a silent green. Without this, a mutant that made the scan inspect no
    /// lines at all survived the whole suite (PR #72 F6).
    ///
    /// Line 3 is the F3 case: partial injection, which the first version of this list let through.
    @Test
    func theScanMatchesConstructionsAndIgnoresProse() {
        let fixture = """
        // PermissionReadinessService() in a line comment is prose, not a construction.
        /// So is SystemMicrophonePermissionChecker() in a doc comment.
        let partiallyInjected = PermissionReadinessService(screenPermissionChecker: DeterministicScreenPermissions())
        let live = PermissionReadinessService()
        let checker = SystemScreenCapturePermissionChecker()  // a trailing comment must not hide this
        let safe = PermissionReadinessService.deterministic(microphoneStatus: .denied)
        """

        #expect(Self.offenders(inSource: fixture, label: "F") == [
            "F:3 — PermissionReadinessService(",
            "F:4 — PermissionReadinessService(",
            "F:5 — SystemScreenCapturePermissionChecker("
        ])
    }

    @Test
    func noTestSourceConstructsALivePermissionChecker() throws {
        var scannedFileCount = 0
        var offenders: [String] = []

        for target in TestSourceTree.targets {
            let files = try TestSourceTree.swiftFiles(in: target)
            let names = Set(files.map { URL(fileURLWithPath: $0.relativePath).lastPathComponent })
            // Guards against a silently empty scan, which is a source scan's classic failure. Named
            // files rather than a count near the real one: a `> 20` floor once sat three files above
            // this target's actual 23 and would have tripped on an ordinary consolidation (PR #72 F3).
            #expect(names.contains("DeterministicPermissions.swift"), "\(target) is not the directory this expects")
            #expect(names.contains("UnprivilegedProcess.swift"), "\(target) is not the directory this expects")

            for file in files where file.relativePath != Self.thisFile && file.relativePath != Self.constructionSite {
                scannedFileCount += 1
                offenders += Self.offenders(
                    inSource: try TestSourceTree.read(file),
                    label: file.relativePath
                )
            }
        }

        #expect(scannedFileCount > 40)
        #expect(
            offenders.isEmpty,
            """
            A test constructs a live permission checker, so its result depends on what this Mac has \
            granted (SONNY-106 section D). Use PermissionReadinessService.deterministic(...) or \
            DeterministicScreenPermissions instead, both in this target and its twin. Offenders: \
            \(offenders.joined(separator: ", "))
            """
        )
    }

    /// The exemption is a hole by construction, so it is bounded rather than trusted: the one file
    /// allowed to call the initializer may do so exactly once, inside `deterministic`.
    @Test
    func theExemptFileConstructsExactlyOneReadinessServiceAndOnlyInsideTheHelper() throws {
        let source = try String(
            contentsOf: TestSourceTree.root.appendingPathComponent(Self.constructionSite),
            encoding: .utf8
        )
        let constructions = Self.offenders(inSource: source, label: "exempt")
        #expect(constructions.count == 1, "the exempt file constructs \(constructions.count) readiness services: \(constructions)")
        let helperStart = try #require(source.range(of: "static func deterministic("))
        let construction = try #require(source.range(of: "PermissionReadinessService("))
        #expect(construction.lowerBound > helperStart.lowerBound)
        // Both checkers named, so the exempt construction cannot itself be partial.
        #expect(source.contains("screenPermissionChecker: DeterministicScreenPermissions("))
        #expect(source.contains("microphonePermissionChecker: DeterministicMicrophonePermission("))
    }

    /// **Every value handed to `permissionReadinessService:` is the deterministic helper** (PR #72 C1).
    ///
    /// The token scan sees constructions that spell the type. `.init()` is a construction that does
    /// not: `permissionReadinessService: .init()` is `PermissionReadinessService.init()` with both
    /// checkers left at their live defaults, and it walked past every other pin here — measured, a
    /// survivor at the exact fixture whose live reads were F1. Checking the parameter's *value*
    /// rather than the presence of its name closes that, and closes every other spelling of a
    /// non-deterministic argument at the same time.
    ///
    /// Two forms are allowed: `.deterministic(` in any arity, and forwarding a parameter of the same
    /// name through a fixture's own signature.
    @Test
    func everyReadinessServiceArgumentIsTheDeterministicHelper() throws {
        var checked = 0
        var offenders: [String] = []

        for target in TestSourceTree.targets {
            for file in try TestSourceTree.swiftFiles(in: target) where file.relativePath != Self.thisFile {
                for line in TestSourceTree.codeLines(of: try TestSourceTree.read(file)) {
                    guard line.text.contains("permissionReadinessService:") else { continue }
                    checked += 1
                    let forwards = line.text.contains("permissionReadinessService: permissionReadinessService")
                    guard !forwards, !line.text.contains(".deterministic(") else { continue }
                    offenders.append("\(file.relativePath):\(line.number) — \(line.text.trimmingCharacters(in: .whitespaces))")
                }
            }
        }

        // A rule that matched nothing would pass forever.
        #expect(checked >= 7, "expected the known readiness arguments, matched \(checked) lines")
        #expect(
            offenders.isEmpty,
            """
            A readiness service is being passed to a fixture by some spelling other than \
            .deterministic(...). `.init()` and a bare construction both leave the two checkers at \
            their live defaults, which is a live TCC and AVFoundation read (SONNY-106 section D). \
            Offenders: \(offenders.joined(separator: " | "))
            """
        )
    }

    /// **The omission form, closed where it is affordable to close it.** A construction that leaves a
    /// defaulted seam out names nothing forbidden, so the token scan is blind to it — that is how F1
    /// shipped. This is the narrow version that catches the real shape: a file that both builds an
    /// `AgentActionExecutor` and names `.showPermissionReadiness` is one plan away from a live read,
    /// and there are exactly three of them. Reverting F1's one-line fix fails here.
    ///
    /// It requires the injected *form*, not the identifier's presence: `permissionReadinessService: .init()`
    /// contains the name and is a live service (PR #72 C1).
    @Test
    func everyExecutorFixtureThatCanDriveReadinessInjectsTheSeam() throws {
        var checked: [String] = []
        var missing: [String] = []

        for target in TestSourceTree.targets {
            for file in try TestSourceTree.swiftFiles(in: target) where file.relativePath != Self.thisFile {
                let code = TestSourceTree.codeLines(of: try TestSourceTree.read(file))
                    .map(\.text)
                    .joined(separator: "\n")
                guard code.contains("AgentActionExecutor("), code.contains("showPermissionReadiness") else { continue }
                checked.append(file.relativePath)
                if !code.contains("permissionReadinessService: .deterministic(") {
                    missing.append(file.relativePath)
                }
            }
        }

        // A rule that matched nothing would pass forever; these three are the population today.
        #expect(checked.count == 3, "expected three readiness-capable executor fixtures, found \(checked)")
        #expect(
            missing.isEmpty,
            """
            \(missing.joined(separator: ", ")) builds an AgentActionExecutor and names \
            .showPermissionReadiness, but injects no deterministic readiness service — so a plan run \
            through that fixture reaches the production default and makes live TCC and AVFoundation \
            reads. Pass permissionReadinessService: .deterministic().
            """
        )
    }

    /// Pins the scan's own premise: the tokens it looks for are the ones that actually name the live
    /// implementations, so a rename in `Sources/` that left this list behind fails here rather than
    /// turning the scan into a no-op that still reports green.
    @Test
    func theForbiddenTokensStillNameTheLiveImplementations() throws {
        let coreDirectory = TestSourceTree.root
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/MacAgentCore")
        let readiness = try String(
            contentsOf: coreDirectory.appendingPathComponent("PermissionReadinessService.swift"),
            encoding: .utf8
        )
        let capture = try String(
            contentsOf: coreDirectory.appendingPathComponent("ScreenCaptureService.swift"),
            encoding: .utf8
        )
        #expect(readiness.contains("public struct SystemMicrophonePermissionChecker"))
        #expect(capture.contains("public struct SystemScreenCapturePermissionChecker"))
        // Both are still the defaults, which is the whole reason a fixture can reach one by omission.
        #expect(readiness.contains("= SystemScreenCapturePermissionChecker()"))
        #expect(readiness.contains("= SystemMicrophonePermissionChecker()"))
        // And every token in the list still names something real, so the list cannot rot into one
        // that matches nothing.
        for token in Self.forbidden {
            let name = String(token.dropLast())
            #expect(
                readiness.contains(name) || capture.contains(name),
                "\(name) is in the forbidden list but names nothing in Sources/MacAgentCore"
            )
        }
    }
}
