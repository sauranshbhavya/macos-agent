import AppKit
import Combine
import MacAgentCore

/// A temporary way into the V2 kernel from today's app, for the packaged-app check of phase 4.
///
/// It runs only when the `SonnyV2Kernel` default is on: `defaults write <bundle id> SonnyV2Kernel
/// -bool YES`, or launch with the arguments `-SonnyV2Kernel YES`.
/// The composer then sends its command to the gateway as a V2 task instead of planning it on the
/// Mac; progress goes to the activity log, and approvals, questions and pauses come up as alerts.
/// Phase 6 rewrites the UI as presentation over `TaskController` and deletes this bridge.
@MainActor
final class V2KernelBridge {
    let controller: TaskController
    private let log: (String) -> Void
    private var watching: AnyCancellable?
    private var shown: Set<String> = []

    static var isRequested: Bool {
        UserDefaults.standard.bool(forKey: "SonnyV2Kernel")
    }

    static func make(client: SonnyBackendClient, log: @escaping (String) -> Void) async -> V2KernelBridge? {
        guard isRequested, let base = await client.backendEnvironment?.baseURL else { return nil }
        let ledgers: any TaskLedgerStoring = (try? FileTaskLedgerStore.inApplicationSupport()) ?? MemoryTaskLedgerStore()
        let checker = SystemScreenCapturePermissionChecker()
        let controller = TaskController(
            url: GatewayEndpoint.sessionURL(base: base),
            transport: URLSessionGatewayTransport(),
            credentials: client,
            identity: .init(
                deviceID: GatewayDeviceIdentity.deviceID(),
                appVersion: String(SonnyClientIdentity.version.prefix(32)),
                osVersion: String(SonnyClientIdentity.platform.prefix(32))
            ),
            ledgers: ledgers,
            capabilities: KernelCapabilities([OpenAppCapability()]),
            screenTools: Set(ScreenToolName.allCases),
            screenFactory: {
                ScreenController(dependencies: .init(driver: { manifest in try CuaDriverLibrary(manifest: manifest) }))
            },
            permissions: {
                .init(
                    accessibility: checker.isAccessibilityTrusted() ? .granted : .denied,
                    screenRecording: checker.hasScreenRecordingPermission() ? .granted : .denied,
                    automation: []
                )
            }
        )
        let bridge = V2KernelBridge(controller: controller, log: log)
        await controller.launch()
        return bridge
    }

    private init(controller: TaskController, log: @escaping (String) -> Void) {
        self.controller = controller
        self.log = log
        watching = controller.$tasks.sink { [weak self] tasks in
            Task { @MainActor in self?.present(tasks) }
        }
    }

    func submit(_ goal: String, mode: AgentInteractionMode) {
        log("V2: \(goal)")
        Task {
            let submission = await controller.submit(TaskRequest(goal: goal, mode: mode))
            if case .failed(_, let failure) = submission { log("V2: \(failure.message)") }
        }
    }

    /// The app's Stop button and emergency stop reach V2 tasks through here.
    func cancelLiveTasks() {
        for task in controller.tasks where !task.phase.isTerminal {
            Task { await controller.cancel(task.id) }
        }
    }

    private func present(_ tasks: [TaskSnapshot]) {
        for task in tasks {
            let key = "\(task.id)-\(task.phase)-\(task.progress ?? "")"
            guard shown.insert(key).inserted else { continue }
            switch task.phase {
            case .running, .acting, .observing, .queued, .connecting, .reconciling:
                if let progress = task.progress { log("V2: \(progress)") }
            case .awaitingApproval(let commit):
                let approved = confirm(commit.preview.title, detail: commit.preview.details.joined(separator: "\n"), yes: "Do it", no: "Don't")
                Task { await controller.decide(task: task.id, action: commit.action, commit: commit.commitID, approved: approved) }
            case .awaitingAnswer(let ask):
                let text = question(ask.question)
                Task { await controller.answer(task: task.id, text: text) }
            case .paused(.outcomeUnknown(_, _, let title)):
                let carryOn = confirm(
                    "Sonny may already have done this: \(title)",
                    detail: "Check whether it happened, then continue or stop.",
                    yes: "Continue",
                    no: "Stop"
                )
                Task { await controller.resolvePause(task: task.id, choice: carryOn ? .continueTask : .stop) }
            case .completed(let summary):
                log("V2 done: \(summary)")
            case .failed(let failure):
                log("V2 failed: \(failure.message)")
            case .cancelled:
                log("V2: stopped")
            }
        }
    }

    private func confirm(_ title: String, detail: String, yes: String, no: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: yes)
        alert.addButton(withTitle: no)
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func question(_ text: String) -> String {
        let alert = NSAlert()
        alert.messageText = text
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Answer")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
        let answer = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return answer.isEmpty ? "No answer" : answer
    }
}
