import Foundation
import Testing
@testable import MacAgentCore
import MacAgentTestSupport

/// A capability whose result carries whatever text the test gives it, the way a shortcut's output,
/// a calendar title or osascript's stderr would.
private struct EchoCapability: Capability {
    let name = "echo"
    let version = 1
    let evidence: String
    let error: String?

    func prepare(actionID: ActionID, args: [String: JSONValue]) async throws -> PreparedAction {
        PreparedAction(
            actionID: actionID,
            effect: .observe,
            targetIdentity: "echo",
            content: "",
            preview: ApprovalPreview(title: "echo", details: []),
            retry: .never,
            payload: ()
        )
    }

    func execute(_ prepared: PreparedAction) async -> CapabilityOutcome {
        if let error { return .failed(.executionError, error) }
        return .done(evidence)
    }
}

/// V2 plan section 7.4: text `SecretTextDetector` finds never leaves the Mac, whatever produced it.
@Suite(.serialized)
@MainActor
struct SecurityFloorTests {
    static let token = "ghp_" + String(repeating: "a1B2", count: 9)

    @Test
    func aSecretInAnOperationsResultIsMaskedBeforeItReachesTheGateway() async throws {
        let gateway = ScriptedGateway()
        let controller = makeController(gateway, capabilities: [
            EchoCapability(evidence: "Shortcut said: token \(Self.token) and password: hunter2", error: nil),
        ])
        await controller.launch()
        let task = try await startedTask(controller, TaskRequest(goal: "Run my shortcut", mode: .normal))
        _ = try await gateway.next("task.start")
        await gateway.send(task, propose([call("echo", effect: .observe)]), re: 1)
        let evidence = try #require(results(of: try await gateway.next("outcome")).first?.evidence)
        #expect(!evidence.contains(Self.token))
        #expect(!evidence.contains("hunter2"))
        #expect(evidence.contains(SecretTextDetector.maskReplacement))
    }

    @Test
    func aSecretInAnOperationsErrorIsMaskedBeforeItReachesTheGateway() async throws {
        let gateway = ScriptedGateway()
        let controller = makeController(gateway, capabilities: [
            EchoCapability(evidence: "", error: "osascript: auth failed for \(Self.token)"),
        ])
        await controller.launch()
        let task = try await startedTask(controller, TaskRequest(goal: "Run it", mode: .normal))
        _ = try await gateway.next("task.start")
        await gateway.send(task, propose([call("echo", effect: .observe)]), re: 1)
        let message = try #require(results(of: try await gateway.next("outcome")).first?.error?.message)
        #expect(!message.contains(Self.token))
        #expect(message.contains(SecretTextDetector.maskReplacement))
    }

    @Test
    func aSecretInTheGoalOrAnAnswerIsMaskedBeforeItReachesTheGateway() async throws {
        let gateway = ScriptedGateway()
        let controller = makeController(gateway, capabilities: [])
        await controller.launch()
        let task = try await startedTask(controller, TaskRequest(goal: "Save my key \(Self.token) in Notes", mode: .normal))
        let start = try await gateway.next("task.start")
        guard case .taskStart(let body) = start.payload else { throw KernelTestFailure("not a task.start") }
        #expect(!body.goal.contains(Self.token))
        #expect(body.goal.hasPrefix("Save my key "))

        await gateway.send(task, .ask(AskBody(question: "Which note?")), re: 1)
        #expect(await eventually {
            if case .awaitingAnswer = controller.snapshot(task)?.phase { return true }
            return false
        })
        await controller.answer(task: task, text: "The one with password: hunter2")
        let answer = try await gateway.next("answer")
        guard case .answer(let reply) = answer.payload else { throw KernelTestFailure("not an answer") }
        #expect(!reply.text.contains("hunter2"))
    }

    @Test
    func aSecretInTheFrontAppsNameOrASelectedFilesPathNeverReachesTheGateway() async throws {
        let gateway = ScriptedGateway()
        let controller = makeController(gateway, capabilities: [])
        await controller.launch()
        let secretPath = "/Users/me/Desktop/\(Self.token).txt"
        var request = TaskRequest(goal: "Tidy these", mode: .normal)
        request.context = TaskStartBody.Context(
            frontmostApp: WireAppRef(bundleID: "com.example.vault", name: "Vault \(Self.token)"),
            finderSelection: ["/Users/me/Desktop/report.pdf", secretPath]
        )
        _ = try await startedTask(controller, request)
        let start = try await gateway.next("task.start")
        guard case .taskStart(let body) = start.payload else { throw KernelTestFailure("not a task.start") }
        #expect(body.context.frontmostApp?.name.contains(Self.token) == false)
        #expect(body.context.frontmostApp?.bundleID == "com.example.vault")
        #expect(body.context.finderSelection == ["/Users/me/Desktop/report.pdf"])
    }

    @Test
    func aSecretThatCrossesTheLengthLimitIsMaskedNotCutInHalf() {
        let text = String(repeating: "x", count: 20) + " " + Self.token
        let cut = text.maskedAndClipped(toUTF16: 30)
        #expect(!cut.contains("ghp_"))
        #expect(cut.utf16.count <= 30)
    }
}
