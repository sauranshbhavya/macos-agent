import Foundation
import Testing
@testable import MacAgentCore

/// **No test may construct a live permission checker** (SONNY-123).
///
/// The reason this exists rather than a convention: the seams are *defaulted*, so a fixture that
/// reaches for the live service is a call that compiles, passes, and reads exactly like every other
/// fixture. SONNY-103 was one instance found by accident. SONNY-106 section D states the rule; this
/// test is the thing that enforces it, and it is the only mechanism here that can, because the
/// deterministic default is a state a real Mac can also be in — a runtime assertion cannot tell an
/// injected grant from a granted machine, so the property has to be pinned in the source.
///
/// **Measured, not assumed.** Reverting `makeExecutor`'s readiness default to
/// `PermissionReadinessService()` and reverting `VisionTestContext`'s the same way are two mutants
/// that survive the entire suite without this test, and die with it.
///
/// Scanning both target directories from one file is deliberate: the property is about the whole
/// suite, and a per-target copy is a copy that can be deleted from one target and still look
/// enforced.
///
/// **What this cannot do, stated so it is not mistaken for a boundary.** It is textual, and three
/// forms evade it:
///
/// 1. **Omission** — a constructor that leaves a defaulted seam out entirely puts no forbidden token
///    on any line. This is not hypothetical and is the form that actually shipped:
///    `AgentRunnerTests.makeExecutor` built an `AgentActionExecutor` without
///    `permissionReadinessService` and drove a readiness plan through it, and this scan could not
///    see it (PR #72 F1). Omission is not closable here without requiring the parameter at all 37
///    executor constructions in the suite, most of which never touch a readiness path. What closes
///    it instead is the probe recorded on the ticket: patching the live checkers to print a marker
///    and running the whole suite single-threaded, which enumerates every live read rather than
///    guessing at their shape.
/// 2. **Indirection** — a typealias, a stored metatype, or a construction split across lines.
/// 3. **A new defaulted seam** that nobody adds to `forbidden`. `theForbiddenTokensStillNameTheLiveImplementations`
///    catches a *rename* of the two that exist; it cannot catch a third being introduced.
///
/// It raises the cost of the accident it is aimed at and does not pretend to be a barrier against
/// intent.
@Suite
struct LivePermissionCheckerScanTests {
    /// Constructions that hand a test whatever this Mac has granted.
    ///
    /// `PermissionReadinessService(` is listed **with no closing parenthesis**, which is a change
    /// from the first version and the point of PR #72's F3. Matching the argument-free
    /// `PermissionReadinessService()` let *partial* injection through — a call naming
    /// `screenPermissionChecker` and leaving `microphonePermissionChecker` at its live default is a
    /// live authorization read that matched no token. Both checkers are defaulted, so any direct
    /// construction can be partial; the only safe rule is that tests do not call this initializer at
    /// all. `deterministic(...)` is the one way in, and its own file is the one exemption.
    static let forbidden = [
        "SystemScreenCapturePermissionChecker(",
        "SystemMicrophonePermissionChecker(",
        "PermissionReadinessService("
    ]

    /// The single file allowed to construct a readiness service directly, target-qualified because
    /// both targets carry a file of this name and only this one is exempt.
    private static let constructionSite = (target: "MacAgentCoreTests", fileName: "DeterministicPermissions.swift")

    /// The matching rule, as a pure function so a fixture can hold it.
    ///
    /// Comments name these types constantly — this file included, and every doc comment explaining
    /// why the seam exists. A scan that counted prose would be unusable. It skips comment-*prefixed*
    /// lines and deliberately not every line *containing* `//`: the narrower `grep -v "//"` this
    /// repo was bitten by during row C drops a real construction that carries a trailing note.
    static func offenders(inSource source: String, label: String) -> [String] {
        var found: [String] = []
        for (index, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("//") else { continue }
            for token in forbidden where line.contains(token) {
                found.append("\(label):\(index + 1) — \(token)")
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
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let thisFileName = URL(fileURLWithPath: #filePath).lastPathComponent
        var scannedFileCount = 0
        var offenders: [String] = []

        for target in ["MacAgentCoreTests", "MacAgentTests"] {
            let directory = testsDirectory.appendingPathComponent(target)
            let files = try FileManager.default
                .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "swift" }
            let names = Set(files.map(\.lastPathComponent))
            // Guards against a silently empty scan, which is a source scan's classic failure. Named
            // files rather than a count near the real one: the previous `> 20` floor sat three files
            // above this target's actual 23 and would have tripped on an ordinary consolidation
            // (PR #72 F3).
            #expect(names.contains("DeterministicPermissions.swift"), "\(target) is not the directory this expects")
            #expect(names.contains("UnprivilegedProcess.swift"), "\(target) is not the directory this expects")

            for file in files where file.lastPathComponent != thisFileName {
                let isExemptConstructionSite = target == Self.constructionSite.target
                    && file.lastPathComponent == Self.constructionSite.fileName
                guard !isExemptConstructionSite else { continue }
                scannedFileCount += 1
                offenders += Self.offenders(
                    inSource: try String(contentsOf: file, encoding: .utf8),
                    label: "\(target)/\(file.lastPathComponent)"
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
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .appendingPathComponent(Self.constructionSite.fileName),
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

    /// **The omission form, closed where it is affordable to close it.** A construction that leaves a
    /// defaulted seam out names nothing forbidden, so the token scan is blind to it — that is how F1
    /// shipped. Requiring the parameter at all 37 executor constructions in the suite would be
    /// disproportionate, since most never touch a readiness path. This is the narrow version that
    /// catches the real shape: a file that both builds an `AgentActionExecutor` and names
    /// `.showPermissionReadiness` is one plan away from a live read, and there are exactly three of
    /// them. Reverting F1's one-line fix fails here; nothing else in the suite notices it.
    @Test
    func everyExecutorFixtureThatCanDriveReadinessInjectsTheSeam() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let thisFileName = URL(fileURLWithPath: #filePath).lastPathComponent
        var checked: [String] = []
        var missing: [String] = []

        for target in ["MacAgentCoreTests", "MacAgentTests"] {
            let files = try FileManager.default
                .contentsOfDirectory(
                    at: testsDirectory.appendingPathComponent(target),
                    includingPropertiesForKeys: nil
                )
                .filter { $0.pathExtension == "swift" && $0.lastPathComponent != thisFileName }
            for file in files {
                let code = try String(contentsOf: file, encoding: .utf8)
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                    .joined(separator: "\n")
                guard code.contains("AgentActionExecutor("), code.contains("showPermissionReadiness") else { continue }
                checked.append("\(target)/\(file.lastPathComponent)")
                if !code.contains("permissionReadinessService") {
                    missing.append("\(target)/\(file.lastPathComponent)")
                }
            }
        }

        // A rule that matched nothing would pass forever; these three are the population today.
        #expect(checked.count == 3, "expected three readiness-capable executor fixtures, found \(checked)")
        #expect(
            missing.isEmpty,
            """
            \(missing.joined(separator: ", ")) builds an AgentActionExecutor and names \
            .showPermissionReadiness, but injects no readiness service — so a plan run through that \
            fixture reaches the production default and makes live TCC and AVFoundation reads. Pass \
            permissionReadinessService: .deterministic().
            """
        )
    }

    /// Pins the scan's own premise: the tokens it looks for are the ones that actually name the live
    /// implementations, so a rename in `Sources/` that left this list behind fails here rather than
    /// turning the scan into a no-op that still reports green.
    ///
    /// This replaced two `#expect(SystemScreenCapturePermissionChecker() is any ScreenCapturePermissionChecking)`
    /// assertions, which were true by declaration and were the branch's only new compiler warnings —
    /// `warning: 'is' test is always true`, twice (PR #72 F6).
    @Test
    func theForbiddenTokensStillNameTheLiveImplementations() throws {
        let coreDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
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
