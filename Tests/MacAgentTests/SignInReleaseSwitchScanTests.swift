import Foundation
import Testing
@testable import MacAgent

/// **The staging pointer exists in debug builds only, demonstrated rather than asserted.**
///
/// SONNY-106's "no environment variable is required for anything" has to stay true of every build a
/// user runs, so the override's two keys, its reader and its use all sit inside `#if DEBUG` and are
/// not compiled into a release binary at all. Three things hold that, and only the first two are
/// tests:
///
/// 1. **The compiler.** The keys are *declared* inside the conditional, so a release-build caller
///    cannot name them — it does not compile. That is enforcement, and by construction no test can
///    exhibit it: code that fails to compile cannot be written down here to fail.
/// 2. **This scan**, which holds the population: every mention of the override anywhere under
///    `Sources/` lies inside an active `#if DEBUG`, and the file set is exactly one file. The rule
///    itself is run over held samples below, so it can be shown to flag what it names rather than
///    only to pass against the current tree.
/// 3. **The built product.** At `main` plus this branch, `swift build -c release` then
///    `strings .build/release/MacAgent | grep -c <key>` answers **0** for both keys, while the same
///    over `.build/debug/MacAgent` answers **1** for each. That is the consequence the two above
///    are for; it is recorded on the ticket and in the changelog rather than run here, because a
///    release build inside the test suite would cost four minutes per run.
@Suite
@MainActor
struct SignInReleaseSwitchScanTests {
    /// Everything that names the debug-only pointer. The two string literals are what a `strings`
    /// sweep of the release binary looks for; the three identifiers are what a release build would
    /// have to be able to resolve.
    static let overrideTokens = [
        "\"SONNY_BACKEND_BASE_URL\"",
        "\"SonnyBackendBaseURL\"",
        "overrideEnvironmentVariable",
        "overrideDefaultsKey",
        "normalizedOverride"
    ]

    @Test
    func everyMentionOfTheStagingPointerInSourcesIsInsideIfDebug() throws {
        var offenders: [String] = []
        var files: Set<String> = []
        var mentions = 0

        for url in try MacAgentSource.appSourceFiles() + MacAgentSource.coreSourceFiles() {
            let source = try MacAgentSource.read(url)
            let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let guarded = ConditionalRegionScan.debugGuardedLines(of: lines)
            for (index, line) in lines.enumerated() {
                guard Self.overrideTokens.contains(where: line.contains) else { continue }
                mentions += 1
                files.insert(url.lastPathComponent)
                if !guarded[index] {
                    offenders.append("\(url.lastPathComponent):\(index + 1) \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }

        // A walker that found nothing reads exactly like a tree with nothing to find.
        #expect(mentions >= 5, "the scan saw \(mentions) mentions — too few to be the real declaration")
        #expect(files == ["SonnyBackendEnvironment.swift"], "the pointer is named in \(files.sorted())")
        #expect(offenders.isEmpty, "outside #if DEBUG:\n\(offenders.joined(separator: "\n"))")
    }

    /// **The rule, run over held samples, so it can be shown to flag what it names** — the shape
    /// `LocalStoreInjectionScanTests` adopted after a mutant survived a guard that only ever ran
    /// against the real tree.
    @Test
    func theScanFlagsAMentionOutsideIfDebugAndAcceptsOneInside() {
        let inside = ConditionalRegionScan.debugGuardedLines(of: [
            "enum Host {",
            "#if DEBUG",
            "    let key = \"SONNY_BACKEND_BASE_URL\"",
            "#endif",
            "}"
        ])
        #expect(inside == [false, false, true, false, false])

        // The `#else` of a `#if DEBUG` is the release branch, and a key there ships.
        let elseBranch = ConditionalRegionScan.debugGuardedLines(of: [
            "#if DEBUG",
            "    let a = 1",
            "#else",
            "    let key = \"SONNY_BACKEND_BASE_URL\"",
            "#endif"
        ])
        #expect(elseBranch == [false, true, false, false, false])

        // After the `#endif`, nothing is guarded — the mistake a naive "the file contains #if DEBUG"
        // check cannot see.
        let afterEndif = ConditionalRegionScan.debugGuardedLines(of: [
            "#if DEBUG",
            "    let a = 1",
            "#endif",
            "let key = \"SONNY_BACKEND_BASE_URL\""
        ])
        #expect(afterEndif == [false, true, false, false])

        // A different conditional is not this one, however deeply it nests.
        let otherConditional = ConditionalRegionScan.debugGuardedLines(of: [
            "#if os(macOS)",
            "    let key = \"SONNY_BACKEND_BASE_URL\"",
            "#endif"
        ])
        #expect(otherConditional == [false, false, false])

        // Nesting inside a `#if DEBUG` stays guarded.
        let nested = ConditionalRegionScan.debugGuardedLines(of: [
            "#if DEBUG",
            "#if os(macOS)",
            "    let key = \"SONNY_BACKEND_BASE_URL\"",
            "#endif",
            "#endif"
        ])
        #expect(nested == [false, false, true, false, false])
    }

    /// The scan reads comment-stripped text (`MacAgentSource.read`), so a doc comment that names the
    /// key outside the conditional — which this file's own header does — is not a false positive.
    @Test
    func aCommentNamingTheKeyIsNotCountedAsAMention() throws {
        let source = try MacAgentSource.read(
            MacAgentSource.coreSourceDirectory.appendingPathComponent("SonnyBackendEnvironment.swift")
        )
        #expect(!source.contains("defaults write com.sonny.MacAgent"))
        #expect(source.contains("#if DEBUG"))
    }
}

/// Which lines of a Swift file sit inside an *active* `#if DEBUG`.
///
/// Deliberately strict: only a bare `#if DEBUG` guards, an `#else` never does, and any other
/// condition never does. A looser reading would have to decide what `#if DEBUG && os(macOS)` means,
/// and a scan that guesses is a scan whose failures are arguments rather than facts. Nothing in this
/// tree writes one, and if something does, this refuses it and the author says so out loud.
enum ConditionalRegionScan {
    static func debugGuardedLines(of lines: [String]) -> [Bool] {
        var stack: [Bool] = []
        var result: [Bool] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#if ") || trimmed == "#if" {
                stack.append(trimmed == "#if DEBUG")
                result.append(false)
            } else if trimmed.hasPrefix("#elseif") {
                if !stack.isEmpty { stack[stack.count - 1] = trimmed == "#elseif DEBUG" }
                result.append(false)
            } else if trimmed == "#else" {
                if !stack.isEmpty { stack[stack.count - 1] = false }
                result.append(false)
            } else if trimmed == "#endif" {
                if !stack.isEmpty { stack.removeLast() }
                result.append(false)
            } else {
                result.append(stack.contains(true))
            }
        }
        return result
    }
}
