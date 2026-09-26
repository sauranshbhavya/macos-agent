import Foundation
import Testing
@testable import MacAgent
@testable import MacAgentCore

/// What a task's state posts to Notification Center, which keeps it after Sonny quits.
@MainActor
struct TaskNotifierTests {
    private func snapshot(_ phase: TaskPhase, isPrivate: Bool) -> TaskSnapshot {
        TaskSnapshot(id: TaskID(), goal: "Look up my test results", origin: .composer, isPrivate: isPrivate, phase: phase, progress: nil, actions: [])
    }

    @Test
    func aPrivateTasksNotificationsCarryNothingOfTheTask() {
        let ask = AskBody(question: "Which clinic sent the results?")
        let phases: [TaskPhase] = [
            .awaitingAnswer(ask),
            .paused(.outcomeUnknown(action: ActionID(), effect: .external, title: "Email the results to Dr Rao")),
            .completed(summary: "Your cholesterol is 5.2."),
            .failed(TaskFailure(reason: nil, message: "The clinic portal refused Sonny.")),
        ]
        for phase in phases {
            let event = TaskNotifier.event(for: snapshot(phase, isPrivate: true))
            #expect(event != nil)
            for word in ["clinic", "cholesterol", "Rao"] {
                #expect(event?.body.contains(word) == false, "\(word) reached a notification")
                #expect(event?.key.contains(word) == false, "\(word) reached a notification's key")
            }
        }
    }

    @Test
    func anOrdinaryTaskSaysWhatItIs() {
        let event = TaskNotifier.event(for: snapshot(.completed(summary: "Your cholesterol is 5.2."), isPrivate: false))
        #expect(event?.body == "Your cholesterol is 5.2.")
        #expect(event?.kind == .taskFinished)
    }
}
