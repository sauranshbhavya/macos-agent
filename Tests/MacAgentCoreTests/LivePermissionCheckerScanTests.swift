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
@Suite
struct LivePermissionCheckerScanTests {
    /// Constructions that hand a test whatever this Mac has granted. `PermissionReadinessService()`
    /// is listed with its empty parentheses on purpose — the same initializer *with* arguments is
    /// how `deterministic(...)` builds the safe one.
    private static let forbidden = [
        "SystemScreenCapturePermissionChecker(",
        "SystemMicrophonePermissionChecker(",
        "PermissionReadinessService()"
    ]

    @Test
    func noTestSourceConstructsALivePermissionChecker() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        var scannedFileCount = 0
        var offenders: [String] = []

        for target in ["MacAgentCoreTests", "MacAgentTests"] {
            let directory = testsDirectory.appendingPathComponent(target)
            let files = try FileManager.default
                .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "swift" }
            // Guards against a silently empty scan: a wrong path would otherwise pass by finding
            // nothing, which is the failure mode a source-scan test is most likely to have.
            #expect(files.count > 20, "\(target) should hold far more than 20 test files")

            for file in files where file.lastPathComponent != URL(fileURLWithPath: #filePath).lastPathComponent {
                scannedFileCount += 1
                let source = try String(contentsOf: file, encoding: .utf8)
                for (index, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                    // Comments name these types constantly — this file included, and every doc
                    // comment explaining why the seam exists. A scan that counted prose would be
                    // unusable, and the narrower `grep -v "//"` this repo was bitten by once drops
                    // any line *containing* a comment, which would hide a real construction that
                    // carries a trailing note.
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.hasPrefix("//") else { continue }
                    for token in Self.forbidden where line.contains(token) {
                        offenders.append("\(target)/\(file.lastPathComponent):\(index + 1) — \(token)")
                    }
                }
            }
        }

        #expect(scannedFileCount > 50)
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

    /// **What the scan cannot do, stated so it is not mistaken for a boundary.** It is textual. A
    /// typealias, a stored metatype, or a construction split across two lines all evade it, and
    /// nothing here stops production code from defaulting to the live checkers — which is exactly
    /// what production should do. It raises the cost of the accident it is aimed at (a fixture
    /// written without the seam in mind) and does not pretend to be a barrier against intent.
    ///
    /// This second test pins the scan's own premise: the tokens it looks for are the ones that
    /// actually name the live implementations, so a rename in `Sources/` that left this list behind
    /// fails here rather than turning the scan into a no-op that still reports green.
    @Test
    func theForbiddenTokensStillNameTheLiveImplementations() throws {
        #expect(SystemScreenCapturePermissionChecker() is any ScreenCapturePermissionChecking)
        #expect(SystemMicrophonePermissionChecker() is any MicrophonePermissionChecking)

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
    }
}
