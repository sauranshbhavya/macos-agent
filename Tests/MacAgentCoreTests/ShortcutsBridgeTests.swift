import Foundation
import MacAgentTestSupport
import Testing
@testable import MacAgentCore

@Suite
@MainActor
struct ShortcutsBridgeTests {
    @Test
    func instantResolverBuildsShortcutPlanAndClarifiesUnknownNames() throws {
        let resolver = InstantCommandResolver(
            snippetStore: UnreachableLocalStores.snippets(),
            recentArtifactStore: UnreachableLocalStores.recentArtifacts(),
            shortcutCatalog: FakeShortcutCatalog(names: ["Morning Routine"])
        )

        guard case .plan(let plan) = resolver.resolve(command: "run my Morning Routine shortcut") else {
            Issue.record("Expected known Shortcut command to resolve locally.")
            return
        }
        #expect(plan.steps.map(\.operation) == [.invokeShortcut])
        #expect(plan.steps[0].shortcutName == "Morning Routine")

        guard case .clarify(let clarifyPlan) = resolver.resolve(command: "run Missing shortcut") else {
            Issue.record("Expected unknown Shortcut command to ask a clarification.")
            return
        }
        #expect(clarifyPlan.steps.map(\.operation) == [.clarify])
        #expect(clarifyPlan.steps[0].question?.contains("Missing") == true)
    }

    /// A Shortcut whose own name starts with a possessive, which this path could not reach before
    /// (PR #106 review, F3).
    ///
    /// Two separate defects meet here. SONNY-242 widened the shared article list to four words while
    /// this site still discarded the original candidate, so "run our standup shortcut" stopped
    /// finding *Our Standup* — and, with a *Standup* also installed, silently ran the wrong one,
    /// which is the worse half. The `my`/`the` version of the same hazard predates SONNY-242
    /// entirely: *My Standup* was never findable. Keeping the original beside the stripped one
    /// closes both, and the last assertion pins the ordering that makes the silent-wrong-Shortcut
    /// case impossible — the exact name wins over the stripped one.
    @Test
    func aShortcutNamedWithAPossessiveIsFoundByItsOwnName() throws {
        let resolver = InstantCommandResolver(
            snippetStore: UnreachableLocalStores.snippets(),
            recentArtifactStore: UnreachableLocalStores.recentArtifacts(),
            shortcutCatalog: FakeShortcutCatalog(names: ["Our Standup", "My Standup", "Standup"])
        )

        for command in ["run our standup shortcut", "run my standup shortcut"] {
            guard case .plan(let plan)? = resolver.resolve(command: command) else {
                Issue.record("Expected \(command) to resolve locally.")
                return
            }
            #expect(plan.steps.map(\.operation) == [.invokeShortcut])
            #expect(plan.steps.first?.shortcutName == (command.contains("our") ? "Our Standup" : "My Standup"))
        }

        // The stripped candidate is still tried, and still second: with no exact match the article
        // comes off and `Standup` is reached.
        guard case .plan(let stripped)? = resolver.resolve(command: "run the standup shortcut") else {
            Issue.record("Expected the stripped candidate to resolve.")
            return
        }
        #expect(stripped.steps.first?.shortcutName == "Standup")
    }

    /// The clarification a miss produces is unchanged by the candidate list: it names the stripped
    /// spelling, exactly as it did when that was the only candidate.
    @Test
    func aMissStillNamesTheStrippedSpellingInItsQuestion() throws {
        let resolver = InstantCommandResolver(
            snippetStore: UnreachableLocalStores.snippets(),
            recentArtifactStore: UnreachableLocalStores.recentArtifacts(),
            shortcutCatalog: FakeShortcutCatalog(names: ["Morning Routine"])
        )

        guard case .clarify(let plan)? = resolver.resolve(command: "run my Missing shortcut") else {
            Issue.record("Expected an unknown Shortcut to ask a clarification.")
            return
        }
        let question = try #require(plan.steps.first?.question)
        #expect(question.contains("named Missing"))
        #expect(!question.contains("my Missing"))
    }




    @Test
    func processInvokerUsesFixedShortcutsCommandAndTemporaryInputPath() async throws {
        let runner = CapturingShortcutProcessRunner()
        let invoker = ProcessShortcutInvoker(processRunner: runner)

        _ = try await invoker.invokeShortcut(name: "Resize Image", input: "hello world")

        #expect(runner.executablePaths == ["/usr/bin/shortcuts"])
        let arguments = try #require(runner.arguments.first)
        #expect(arguments.prefix(2) == ["run", "Resize Image"])
        #expect(arguments.contains("--input-path"))
        #expect(runner.capturedInput == "hello world")
    }




    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShortcutsBridgeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }



    private func shortcutPlan(name: String, input: String? = nil) -> AgentPlan {
        AgentPlan(
            summary: "Run Shortcut \(name).",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "shortcut",
                    operation: .invokeShortcut,
                    description: "Run Shortcut \(name).",
                    shortcutName: name,
                    shortcutInput: input
                )
            ]
        )
    }
}

/// Internal rather than file-private: `AgentActionExecutorTests` needs the same fake to assess a
/// chain of Shortcut steps, and the real catalog shells out to `shortcuts list` on every call, so
/// a second copy of this would be a second thing to keep honest.
struct FakeShortcutCatalog: ShortcutCatalogProviding {
    var names: [String]

    func shortcutNames() throws -> [String] {
        names
    }
}

/// Counts catalog reads. The real catalog shells out to `shortcuts list` on every call, so a
/// duplicate resolution inside one execute is a real, avoidable subprocess spawn.
private final class CountingShortcutCatalog: ShortcutCatalogProviding, @unchecked Sendable {
    private let lock = NSLock()
    private let names: [String]
    private var reads = 0

    init(names: [String]) {
        self.names = names
    }

    var readCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return reads
    }

    func shortcutNames() throws -> [String] {
        lock.lock()
        reads += 1
        lock.unlock()
        return names
    }
}

private struct ShortcutInvocation: Equatable {
    var name: String
    var input: String?
}

private final class FakeShortcutInvoker: ShortcutInvoking, @unchecked Sendable {
    private var results: [ProcessResult]
    private(set) var invocations: [ShortcutInvocation] = []

    init(results: [ProcessResult]) {
        self.results = results
    }

    func invokeShortcut(name: String, input: String?) async throws -> ProcessResult {
        invocations.append(ShortcutInvocation(name: name, input: input))
        if results.isEmpty {
            return ProcessResult(terminationStatus: 0, output: "")
        }
        return results.removeFirst()
    }
}

private final class CapturingShortcutProcessRunner: ShortcutProcessRunning, @unchecked Sendable {
    private(set) var executablePaths: [String] = []
    private(set) var arguments: [[String]] = []
    private(set) var capturedInput: String?

    func run(executablePath: String, arguments: [String]) async throws -> ProcessResult {
        executablePaths.append(executablePath)
        self.arguments.append(arguments)
        if let inputPathIndex = arguments.firstIndex(of: "--input-path"),
           inputPathIndex + 1 < arguments.count {
            capturedInput = try String(contentsOfFile: arguments[inputPathIndex + 1], encoding: .utf8)
        }
        return ProcessResult(terminationStatus: 0, output: "ok")
    }
}

