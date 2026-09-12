import Foundation
import Testing
import MacAgentTestSupport
@testable import MacAgentCore

/// SONNY-451. `[s]` at the start of a command routes it to screen use: the instant resolver builds
/// the same one-step `vision_session` plan the planner would, with the app read from the command's
/// own words and checked against what is installed, or asks which app when none is named. A
/// command without the prefix takes no new door.
@Suite
struct ScreenUsePrefixTests {
    private static let notes = InstalledApp(displayName: "Notes", bundleIdentifier: "com.apple.Notes", applicationURL: URL(fileURLWithPath: "/System/Applications/Notes.app"))
    private static let mail = InstalledApp(displayName: "Mail", bundleIdentifier: "com.apple.mail", applicationURL: URL(fileURLWithPath: "/System/Applications/Mail.app"))
    private static let chrome = InstalledApp(displayName: "Google Chrome", bundleIdentifier: "com.google.Chrome", applicationURL: URL(fileURLWithPath: "/Applications/Google Chrome.app"))

    private func makeResolver() -> InstantCommandResolver {
        InstantCommandResolver(
            snippetStore: UnreachableLocalStores.snippets(),
            recentArtifactStore: UnreachableLocalStores.recentArtifacts(),
            routineStore: UnreachableLocalStores.routines(),
            workspaceStore: UnreachableLocalStores.workspaces(),
            installedAppResolver: InstalledAppResolver(source: FixedAppSource([Self.notes, Self.mail, Self.chrome]))
        )
    }

    private func plan(_ command: String) throws -> AgentPlan {
        guard case .plan(let plan) = makeResolver().resolve(command: command) else {
            Issue.record("\(command) did not resolve to a plan")
            throw CancellationError()
        }
        return plan
    }

    private func clarification(_ command: String) throws -> String {
        guard case .clarify(let plan) = makeResolver().resolve(command: command),
              let question = plan.steps.first?.question else {
            Issue.record("\(command) did not resolve to a clarification")
            throw CancellationError()
        }
        return question
    }

    @Test
    func thePrefixBuildsOneScreenControlStepNamingTheAppItOpens() throws {
        let plan = try plan("[s] open Notes and make a note called wave 7")

        #expect(plan.steps.map(\.operation) == [.visionSession])
        #expect(plan.steps[0].appName == "Notes")
        #expect(plan.steps[0].visionGoal == "open Notes and make a note called wave 7")
        #expect(plan.requiresConfirmation == false)
    }

    @Test
    func theAppIsReadFromAPrepositionOrALeadingLabel() throws {
        #expect(try plan("[s] archive every newsletter in Mail").steps[0].appName == "Mail")
        #expect(try plan("[s] Notes: make a note called wave 7").steps[0].appName == "Notes")
        // The alias table's canonical spelling, as every summary and workspace key writes it.
        #expect(try plan("[s] find the wave 7 tab in Google Chrome").steps[0].appName == "Chrome")
    }

    @Test
    func thePrefixIsExactSpellingAndCaseInsensitive() throws {
        #expect(try plan("[S] make a note in Notes").steps[0].appName == "Notes")
        #expect(try plan("  [s]   make a note in Notes  ").steps[0].visionGoal == "make a note in Notes")
        // `(s)`, `s:` and a bare `s` are not the prefix; they take no door here and fall through
        // to whatever the rest of the resolver and the planner make of them.
        #expect(makeResolver().resolve(command: "(s) make a note in Notes") == nil)
        #expect(makeResolver().resolve(command: "s make a note in Notes") == nil)
        // Exact spelling: the brackets with the one letter between them and nothing else. A space
        // inside, a doubled letter, a longer word or a missing bracket is not the prefix.
        for nearMiss in ["[ s ] make a note in Notes", "[s make a note in Notes", "[ss] make a note in Notes", "[sync] make a note in Notes", "s] make a note in Notes"] {
            #expect(makeResolver().resolve(command: nearMiss) == nil, "\(nearMiss) was read as the prefix")
        }
        // Trimmed before the rest is read, so the prefix needs no space after it.
        #expect(try plan("[s]make a note in Notes").steps[0].visionGoal == "make a note in Notes")
    }

    @Test
    func aWordAfterAPrepositionThatIsNotAnAppAsksWhichApp() throws {
        let question = try clarification("[s] make a note called wave 7 in the morning")

        #expect(question == "Which app should Sonny control for that?")
    }

    @Test
    func noAppNamedAsksWhichAppAndTheAnswerCompletesTheCommand() throws {
        let request = "[s] make a note called wave 7"
        #expect(try clarification(request) == "Which app should Sonny control for that?")

        // The clarification's answer arrives appended to the request (`ClarifiedCommand.completions`).
        let completed = ClarifiedCommand.completions(request: request, answer: "Notes")
        let plan = try plan(try #require(completed.first))

        #expect(plan.steps[0].appName == "Notes")
        #expect(plan.steps[0].operation == .visionSession)
    }

    @Test
    func anEmptyPrefixAndABareAppNameEachAskForWhatIsMissing() throws {
        #expect(try clarification("[s]") == "What should Sonny do on screen, and in which app?")
        #expect(try clarification("[s] Notes") == "What should Sonny do in Notes?")
    }

    /// The route the founders mean by the "feature flag": without the prefix, a command reaches
    /// screen use only when the planner routes it there. The same sentences take no door here.
    @Test
    func withoutThePrefixTheSameCommandsTakeNoNewDoor() {
        let resolver = makeResolver()

        #expect(resolver.resolve(command: "open Notes and make a note called wave 7") == nil)
        #expect(resolver.resolve(command: "archive every newsletter in Mail") == nil)
        #expect(resolver.resolve(command: "Notes: make a note called wave 7") == nil)
    }

    /// The prefix outranks every other door: `[s] 2 + 2` is a screen-use request, not a sum, so
    /// the user's route wins over the resolver's own reading of the words.
    @Test
    func thePrefixOutranksTheCalculatorAndTheSwitcher() throws {
        #expect(try clarification("[s] 2 + 2") == "Which app should Sonny control for that?")
        #expect(try plan("[s] switch to Mail and archive everything").steps[0].operation == .visionSession)
    }

    /// The scan half: `resolve` has exactly one screen-use door, and it is the first door.
    @Test
    func thePrefixDoorIsTheFirstAndOnlyNewDoorInResolve() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MacAgentCore/InstantCommandResolver.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        let resolveStart = try #require(source.range(of: "public func resolve(command rawCommand: String) -> InstantCommandResolution? {"))
        let body = source[resolveStart.upperBound...]
        let screenUse = try #require(body.range(of: "screenUseResolution(in: command)"))
        let calculator = try #require(body.range(of: "prefixedCalculatorExpression(in: command)"))

        #expect(source.components(separatedBy: "screenUseResolution(in: command)").count - 1 == 1)
        #expect(
            body.distance(from: body.startIndex, to: screenUse.lowerBound)
                < body.distance(from: body.startIndex, to: calculator.lowerBound),
            "the screen-use door comes before the calculator's, which was the first door until SONNY-451"
        )
    }
}
