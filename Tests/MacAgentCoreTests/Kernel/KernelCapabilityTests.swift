import Foundation
import Testing
@testable import MacAgentCore
import MacAgentTestSupport

/// Mail as the AppleScript templates see it: drafts by id, and a send that can hang.
final class FakeMail: AppleScriptRunning, @unchecked Sendable {
    struct Draft: Equatable {
        var to: [String]
        var cc: [String]
        var subject: String
        var body: String
    }

    private let lock = NSLock()
    private var drafts: [Int: Draft] = [:]
    private var nextID = 41
    private(set) var sent: [Int] = []
    var sendHangs = false
    /// What the send script answers, as Mail's `send` result reaches it.
    var sendReply = MailCapabilities.sentReply

    var draftIDs: [Int] { lock.withLock { Array(drafts.keys) } }

    func edit(_ id: Int, _ change: (inout Draft) -> Void) {
        lock.withLock { change(&drafts[id]!) }
    }

    func run(_ script: String, arguments: [String], timeout: TimeInterval) async throws -> String {
        if script == MailCapabilities.composeScript {
            let toCount = Int(arguments[2])!
            let draft = Draft(
                to: Array(arguments[3..<(3 + toCount)]),
                cc: Array(arguments[(3 + toCount)...]),
                subject: arguments[0],
                body: arguments[1]
            )
            return lock.withLock {
                nextID += 1
                drafts[nextID] = draft
                return String(nextID)
            }
        }
        guard let id = Int(arguments[0]), let draft = lock.withLock({ drafts[id] }) else {
            throw AppleScriptRunError.failed("Can't get outgoing message")
        }
        if script == MailCapabilities.readScript {
            return [draft.subject, draft.body, draft.to.joined(separator: "\n"), draft.cc.joined(separator: "\n")]
                .joined(separator: MailCapabilities.separator)
        }
        if script == MailCapabilities.sendScript {
            if sendHangs { throw AppleScriptRunError.timedOut }
            if sendReply != MailCapabilities.sentReply { return sendReply }
            lock.withLock { sent.append(id) }
            return sendReply
        }
        throw AppleScriptRunError.failed("unknown script")
    }
}

@MainActor
struct CapabilityFixture {
    let root: URL
    let capabilities: KernelCapabilities
    let routines: RoutineGoalStore
    let mail: FakeMail

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KernelCapabilityTests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let whitelist = PathWhitelist(roots: [root])
        let context = CapabilityTestContext.make(installed: [], whitelist: whitelist)
        routines = RoutineGoalStore(fileURL: nil)
        mail = FakeMail()
        capabilities = StandardCapabilities.all(
            context: { context },
            finderRevealer: { _ in },
            routines: routines,
            appleScript: mail
        )
    }

    func capability(_ name: String) throws -> any Capability {
        guard let found = capabilities.capability(name: name, version: 1) else { throw KernelTestFailure("no \(name)") }
        return found
    }

    func run(_ name: String, _ args: [String: JSONValue]) async throws -> (PreparedAction, CapabilityOutcome) {
        let capability = try capability(name)
        let prepared = try await capability.prepare(actionID: ActionID(), args: args)
        return (prepared, await capability.execute(prepared))
    }
}

@Suite(.serialized)
@MainActor
struct KernelCapabilityTests {
    @Test
    func theMacServesEveryOperationInTheContract() throws {
        let contracts = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("contracts/v2/operations")
        let names = try FileManager.default.contentsOfDirectory(atPath: contracts.path)
            .filter { $0.hasSuffix(".v1.schema.json") }
            .map { String($0.dropLast(".v1.schema.json".count)) }
            .sorted()
        let served = try CapabilityFixture().capabilities.manifestOperations.map(\.name).sorted()
        #expect(served == names)
    }

    @Test
    func writeFileSavesTheTextAndReplacingItIsDestructive() async throws {
        let fixture = try CapabilityFixture()
        let path = fixture.root.appendingPathComponent("plan.md").path
        let (first, outcome) = try await fixture.run("write_file", ["content": .string("# Plan\nbuy milk"), "path": .string(path)])
        #expect(first.effect == .create)
        #expect(outcome.status == .done)
        #expect(try String(contentsOfFile: path, encoding: .utf8).contains("buy milk"))

        let again = try await fixture.capability("write_file").prepare(actionID: ActionID(), args: ["content": .string("other"), "path": .string(path)])
        #expect(again.effect == .destructive)
    }

    @Test
    func aReminderWithNoTimeIsRefusedWithTheQuestionThePlannerShouldAsk() async throws {
        let fixture = try CapabilityFixture()
        let reminder = try fixture.capability("create_reminder")
        let thrown = await #expect(throws: CapabilityPrepareError.self) {
            _ = try await reminder.prepare(actionID: ActionID(), args: ["title": .string("call the bank")])
        }
        #expect(thrown == .invalidArguments("When should Sonny remind you?"))
    }

    @Test
    func renameKeepsTheFolderAndIsDestructive() async throws {
        let fixture = try CapabilityFixture()
        let source = fixture.root.appendingPathComponent("scan1.pdf")
        try Data("pdf".utf8).write(to: source)
        let (prepared, outcome) = try await fixture.run("rename", ["path": .string(source.path), "new_name": .string("invoice.pdf")])
        #expect(prepared.effect == .destructive)
        #expect(outcome.status == .done)
        #expect(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("invoice.pdf").path))
    }

    @Test
    func findingTheLargestFilesChangesNothingAndZippingThemMakesAnArchive() async throws {
        let fixture = try CapabilityFixture()
        for (name, size) in [("big.bin", 5000), ("mid.bin", 3000), ("small.bin", 10)] {
            try Data(count: size).write(to: fixture.root.appendingPathComponent(name))
        }
        let (found, listing) = try await fixture.run("find_largest_files", ["folder": .string(fixture.root.path), "count": .number(2)])
        #expect(found.effect == .observe)
        #expect(listing.evidence?.contains("big.bin") == true)
        #expect(listing.evidence?.contains("small.bin") == false)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).filter { $0.hasSuffix(".zip") }.isEmpty)

        let archive = fixture.root.appendingPathComponent("largest.zip").path
        let (_, zipped) = try await fixture.run("zip_largest_files", ["folder": .string(fixture.root.path), "count": .number(2), "output_path": .string(archive)])
        #expect(zipped.status == .done)
        #expect(FileManager.default.fileExists(atPath: archive))
    }

    @Test
    func aPathOutsideTheAllowedFoldersIsRefused() async throws {
        let fixture = try CapabilityFixture()
        await #expect(throws: CapabilityPrepareError.self) {
            try await fixture.capability("rename").prepare(actionID: ActionID(), args: ["path": .string("/etc/hosts"), "new_name": .string("x")])
        }
    }

    @Test
    func aRoutineIsSavedAsAGoalAndReplacingOneIsDestructive() async throws {
        let fixture = try CapabilityFixture()
        let (first, outcome) = try await fixture.run("save_routine", ["name": .string("Morning"), "goal": .string("Open my calendar and mail")])
        #expect(first.effect == .create)
        #expect(outcome.status == .done)
        #expect(await fixture.routines.routine(named: "morning")?.goal == "Open my calendar and mail")
        let replacing = try await fixture.capability("save_routine").prepare(actionID: ActionID(), args: ["name": .string("Morning"), "goal": .string("x")])
        #expect(replacing.effect == .destructive)
    }

    @Test
    func composingMailLeavesAnUnsentDraftAndBadAddressesAreRefused() async throws {
        let fixture = try CapabilityFixture()
        let (prepared, outcome) = try await fixture.run("compose_mail", [
            "to": .array([.string("sam@example.com")]), "subject": .string("Lunch"), "body": .string("Friday?"),
        ])
        #expect(prepared.effect == .create)
        #expect(outcome.evidence?.contains("Draft 42") == true)
        #expect(fixture.mail.sent.isEmpty)
        await #expect(throws: CapabilityPrepareError.self) {
            try await fixture.capability("compose_mail").prepare(actionID: ActionID(), args: [
                "to": .array([.string("not an address")]), "subject": .string(""), "body": .string(""),
            ])
        }
    }
}

/// Milestone B through the kernel: the approval covers the exact message, a change voids it, and a
/// send that may have gone out is never tried again.
@Suite(.serialized)
@MainActor
struct MailKernelTests {
    func controller(_ gateway: ScriptedGateway, _ fixture: CapabilityFixture) -> TaskController {
        TaskController(
            url: URL(string: "ws://gateway.test/v2/session")!,
            transport: gateway,
            credentials: FixedGatewayCredentials(),
            identity: .init(deviceID: DeviceID(), appVersion: "2.0.0", osVersion: "26.0"),
            ledgers: MemoryTaskLedgerStore(),
            capabilities: fixture.capabilities,
            permissions: { .init(accessibility: .granted, screenRecording: .granted, automation: []) },
            backoff: GatewayBackoff(base: 0.01, cap: 0.05, jitter: { 0 }),
            connectTimeout: 60
        )
    }

    func draft(_ fixture: CapabilityFixture) async throws -> Int {
        let (_, outcome) = try await fixture.run("compose_mail", [
            "to": .array([.string("sam@example.com")]), "subject": .string("Lunch"), "body": .string("Friday at noon?"),
        ])
        guard outcome.status == .done, let id = fixture.mail.draftIDs.first else { throw KernelTestFailure("no draft") }
        return id
    }

    func approval(_ tasks: TaskController, _ task: TaskID) async -> PreparedCommit? {
        var found: PreparedCommit?
        _ = await eventually {
            if case .awaitingApproval(let commit) = tasks.snapshot(task)?.phase { found = commit; return true }
            return false
        }
        return found
    }

    @Test
    func theApprovalShowsTheExactMessageAndSendsItOnce() async throws {
        let fixture = try CapabilityFixture()
        let id = try await draft(fixture)
        let gateway = ScriptedGateway()
        let tasks = controller(gateway, fixture)
        await tasks.launch()
        let task = try await startedTask(tasks, TaskRequest(goal: "Send it", mode: .normal))
        _ = try await gateway.next("task.start")
        let action = ActionID()
        await gateway.send(task, propose([call("send_mail", action, effect: .external, args: ["draft": .string(String(id))])]), re: 1)
        let commit = try #require(await approval(tasks, task))
        #expect(commit.preview.details.contains("To: sam@example.com"))
        #expect(commit.preview.details.contains("Friday at noon?"))
        await tasks.decide(task: task, action: action, commit: commit.commitID, approved: true)
        let outcome = try await gateway.next("outcome")
        #expect(results(of: outcome).map(\.status) == [.done])
        #expect(fixture.mail.sent == [id])
    }

    @Test
    func changingTheDraftAfterTheApprovalVoidsIt() async throws {
        let fixture = try CapabilityFixture()
        let id = try await draft(fixture)
        let gateway = ScriptedGateway()
        let tasks = controller(gateway, fixture)
        await tasks.launch()
        let task = try await startedTask(tasks, TaskRequest(goal: "Send it", mode: .normal))
        _ = try await gateway.next("task.start")
        let action = ActionID()
        await gateway.send(task, propose([call("send_mail", action, effect: .external, args: ["draft": .string(String(id))])]), re: 1)
        let commit = try #require(await approval(tasks, task))
        fixture.mail.edit(id) { $0.to = ["everyone@example.com"] }
        await tasks.decide(task: task, action: action, commit: commit.commitID, approved: true)
        let outcome = try await gateway.next("outcome")
        #expect(results(of: outcome).map(\.status) == [.stale])
        #expect(fixture.mail.sent.isEmpty)
    }

    @Test
    func aSendMailDoesNotConfirmIsUnknownAndPauses() async throws {
        for reply in ["unsure: Mail said it couldn't send it", "unsure -609: Connection is invalid."] {
            let fixture = try CapabilityFixture()
            let id = try await draft(fixture)
            fixture.mail.sendReply = reply
            let gateway = ScriptedGateway()
            let tasks = controller(gateway, fixture)
            await tasks.launch()
            let task = try await startedTask(tasks, TaskRequest(goal: "Send it", mode: .normal))
            _ = try await gateway.next("task.start")
            let action = ActionID()
            await gateway.send(task, propose([call("send_mail", action, effect: .external, args: ["draft": .string(String(id))])]), re: 1)
            let commit = try #require(await approval(tasks, task))
            await tasks.decide(task: task, action: action, commit: commit.commitID, approved: true)
            #expect(await eventually {
                if case .paused(.outcomeUnknown(action, .external, _)) = tasks.snapshot(task)?.phase { return true }
                return false
            })
            await tasks.shutDown()
        }
    }

    @Test
    func aSendThatTimesOutIsUnknownPausesAndIsNeverTriedAgain() async throws {
        let fixture = try CapabilityFixture()
        let id = try await draft(fixture)
        fixture.mail.sendHangs = true
        let gateway = ScriptedGateway()
        let tasks = controller(gateway, fixture)
        await tasks.launch()
        let task = try await startedTask(tasks, TaskRequest(goal: "Send it", mode: .normal))
        _ = try await gateway.next("task.start")
        let action = ActionID()
        await gateway.send(task, propose([call("send_mail", action, effect: .external, args: ["draft": .string(String(id))])]), re: 1)
        let commit = try #require(await approval(tasks, task))
        await tasks.decide(task: task, action: action, commit: commit.commitID, approved: true)
        #expect(await eventually {
            if case .paused(.outcomeUnknown(action, .external, _)) = tasks.snapshot(task)?.phase { return true }
            return false
        })
        #expect(await gateway.unread("outcome").isEmpty)
        fixture.mail.sendHangs = false
        await tasks.resolvePause(task: task, choice: .continueTask)
        let outcome = try await gateway.next("outcome")
        #expect(results(of: outcome).map(\.status) == [.outcomeUnknown])
        #expect(fixture.mail.sent.isEmpty)
    }
}

/// The translation every adapter-backed operation makes: its contract fixtures' typed arguments
/// become the step the V1 adapter reads. The adapters' own bodies are covered by their V1 tests.
@Suite
@MainActor
struct AdapterArgumentTests {
    static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("contracts/v2/fixtures/operations")

    static func args(_ operation: String, _ kind: String) throws -> [[String: JSONValue]] {
        let directory = fixtures.appendingPathComponent("\(operation).v1/\(kind)")
        return try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted().map { name in
            try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: directory.appendingPathComponent(name)))
        }
    }

    func adapterCapability(_ name: String) throws -> AdapterCapability {
        let found = try CapabilityFixture().capabilities.capability(name: name, version: 1)
        guard let adapter = found as? AdapterCapability else { throw KernelTestFailure("\(name) is not adapter-backed") }
        return adapter
    }

    @Test(arguments: [
        "switch_app", "open_url", "open_app_search", "play_media", "open_file", "reveal_in_finder",
        "get_finder_selection", "find_largest_files", "zip_largest_files", "find_docx", "convert_docx_to_pdf",
        "write_file", "rename", "read_calendar", "create_reminder", "run_shortcut", "save_snippet",
        "check_permissions", "start_watching",
    ])
    func everyValidFixtureBecomesASteps(_ operation: String) throws {
        let capability = try adapterCapability(operation)
        for args in try Self.args(operation, "valid") {
            let steps = try capability.steps(args)
            #expect(!steps.isEmpty, "\(operation) produced no step for \(args)")
            #expect(steps.allSatisfy { capability.adapter.metadata.operations.contains($0.operation) })
        }
    }

    @Test
    func theArgumentsLandInTheFieldsTheAdaptersRead() throws {
        let rename = try adapterCapability("rename").steps(["path": .string("~/a.pdf"), "new_name": .string("b.pdf")])
        #expect(rename.map(\.operation) == [.rename])
        #expect(rename.first?.inputPath == "~/a.pdf")
        #expect(rename.first?.newName == "b.pdf")

        let zip = try adapterCapability("zip_largest_files").steps(["folder": .string("~/Downloads"), "count": .number(5), "output_path": .string("~/big.zip")])
        #expect(zip.map(\.operation) == [.scanSelectLargestFiles, .createZip])
        #expect(zip.first?.inputPath == "~/Downloads")
        #expect(zip.first?.count == 5)
        #expect(zip.last?.outputPath == "~/big.zip")

        let reminder = try adapterCapability("create_reminder").steps(["title": .string("Call"), "time": .string("09:00"), "day": .string("Monday")])
        #expect(reminder.first?.reminderTitle == "Call")
        #expect(reminder.first?.reminderTime == "09:00")
        #expect(reminder.first?.calendarDay == "Monday")

        let media = try adapterCapability("play_media").steps(["provider": .string("apple_music"), "title": .string("Blue")])
        #expect(media.first?.mediaProvider == .appleMusic)

        let snippet = try adapterCapability("save_snippet").steps(["trigger": .string(";addr"), "text": .string("1 Loop")])
        #expect(snippet.first?.searchQuery == ";addr")
        #expect(snippet.first?.draftContent == "1 Loop")
    }

    @Test
    func aMissingRequiredArgumentIsRefusedBeforeTheAdapterSeesIt() throws {
        #expect(throws: CapabilityPrepareError.self) { try adapterCapability("rename").steps(["path": .string("~/a.pdf")]) }
        #expect(throws: CapabilityPrepareError.self) { try adapterCapability("play_media").steps(["provider": .string("tidal"), "title": .string("x")]) }
        #expect(throws: CapabilityPrepareError.self) { try adapterCapability("create_reminder").steps(["title": .string("x"), "minutes_from_now": .number(1.5)]) }
    }
}
