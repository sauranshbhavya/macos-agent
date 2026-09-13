import Foundation
import Testing
import MacAgentTestSupport
@testable import MacAgentCore

/// SONNY-451. `[s]` at the start of a command routes it to screen use: the instant resolver builds
/// the `vision_session` plan the planner would — opening the app first when it is not running —
/// with the app read from the command's own words and checked against what is installed, or asks
/// for what is missing, and the answer to that question stays on the prefixed route. A command
/// without the prefix takes no new door.
@Suite
struct ScreenUsePrefixTests {
    private static let notes = InstalledApp(displayName: "Notes", bundleIdentifier: "com.apple.Notes", applicationURL: URL(fileURLWithPath: "/System/Applications/Notes.app"))
    private static let mail = InstalledApp(displayName: "Mail", bundleIdentifier: "com.apple.mail", applicationURL: URL(fileURLWithPath: "/System/Applications/Mail.app"))
    private static let chrome = InstalledApp(displayName: "Google Chrome", bundleIdentifier: "com.google.Chrome", applicationURL: URL(fileURLWithPath: "/Applications/Google Chrome.app"))
    private static let slack = InstalledApp(displayName: "Slack", bundleIdentifier: "com.tinyspeck.slackmacgap", applicationURL: URL(fileURLWithPath: "/Applications/Slack.app"))
    private static let music = InstalledApp(displayName: "Music", bundleIdentifier: "com.apple.Music", applicationURL: URL(fileURLWithPath: "/System/Applications/Music.app"))

    private static let installed = InstalledAppResolver(source: FixedAppSource([notes, mail, chrome, slack, music]))

    private func makeResolver(running: Set<String>? = nil) -> InstantCommandResolver {
        InstantCommandResolver(
            snippetStore: UnreachableLocalStores.snippets(),
            recentArtifactStore: UnreachableLocalStores.recentArtifacts(),
            routineStore: UnreachableLocalStores.routines(),
            workspaceStore: UnreachableLocalStores.workspaces(),
            installedAppResolver: Self.installed,
            runningAppBundleIdentifiers: running
        )
    }

    /// The name the installed-app resolver gives an app, which is what a question or a plan says.
    private func displayName(_ name: String) throws -> String {
        try #require(Self.installed.resolve(name)).displayName
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

    /// **An app that is not running is opened first, by an ordinary `open_app` step** (PR #238's
    /// F1). A session never starts its target — its first activation fails with "Is it running?" —
    /// so the headline command failed whenever Notes was closed. Running, or not known, it is the
    /// one session step; the running list is matched whatever the case of its identifiers.
    @Test
    func anAppThatIsNotRunningIsOpenedBeforeItsSession() throws {
        let command = "[s] open Notes and make a note called wave 7"

        guard case .plan(let closed)? = makeResolver(running: ["com.apple.mail"]).resolve(command: command) else {
            Issue.record("\(command) did not resolve to a plan with Notes closed")
            return
        }
        #expect(closed.steps.map(\.operation) == [.openApp, .visionSession])
        #expect(closed.steps.map(\.appName) == ["Notes", "Notes"])
        #expect(closed.steps[1].visionGoal == "open Notes and make a note called wave 7")

        guard case .plan(let open)? = makeResolver(running: ["COM.APPLE.NOTES"]).resolve(command: command) else {
            Issue.record("\(command) did not resolve to a plan with Notes running")
            return
        }
        #expect(open.steps.map(\.operation) == [.visionSession])
    }

    /// **The answer to each of the door's questions stays on the prefixed route** (PR #238's F4). The
    /// answer used to be appended, so `[s] Notes` answered `make a note` read as `[s] Notes make a
    /// note`, the door asked again, and the view model sent the exchange to the planner. Each
    /// question here is answered the way a person would, and each completion is a prefixed command
    /// the door turns into the session or, when the answer still lacks something, into its next
    /// question — never into nothing.
    @Test
    func eachQuestionsNaturalAnswerStaysOnThePrefixedRoute() throws {
        let resolver = makeResolver()

        // Which app, answered with the app.
        let noApp = "[s] make a note called wave 7"
        #expect(try clarification(noApp) == "Which app should Sonny control for that?")
        let withApp = try plan(try #require(resolver.screenUseCompletion(request: noApp, answer: "Notes")))
        #expect(withApp.steps.map(\.appName) == ["Notes"])
        #expect(withApp.steps[0].visionGoal?.contains("make a note called wave 7") == true)
        // …or with a preposition and a full stop, the way it is often typed.
        let typed = try plan(try #require(resolver.screenUseCompletion(request: noApp, answer: "in Notes.")))
        #expect(typed.steps.map(\.appName) == ["Notes"])

        // What to do, answered with the goal.
        #expect(try clarification("[s] Notes") == "What should Sonny do in Notes?")
        let withGoal = try plan(try #require(resolver.screenUseCompletion(request: "[s] Notes", answer: "make a note")))
        #expect(withGoal.steps.map(\.appName) == ["Notes"])
        #expect(withGoal.steps[0].visionGoal?.contains("make a note") == true)

        // Both, answered with both.
        #expect(try clarification("[s]") == "What should Sonny do on screen, and in which app?")
        let withBoth = try plan(try #require(resolver.screenUseCompletion(request: "[s]", answer: "make a note in Notes")))
        #expect(withBoth.steps.map(\.appName) == ["Notes"])

        // Both, answered with only one: the door asks for the other, still on the prefixed route.
        let onlyApp = try #require(resolver.screenUseCompletion(request: "[s]", answer: "Notes"))
        #expect(try clarification(onlyApp) == "What should Sonny do in Notes?")
        let onlyGoal = try #require(resolver.screenUseCompletion(request: "[s]", answer: "make a note"))
        #expect(try clarification(onlyGoal) == "Which app should Sonny control for that?")

        // Not the door's question, so not the door's to complete.
        #expect(resolver.screenUseCompletion(request: "= ", answer: "2 + 2") == nil)
        #expect(resolver.screenUseCompletion(request: "[s] make a note in Notes", answer: "Mail") == nil)
    }

    @Test
    func anEmptyPrefixAndABareAppNameEachAskForWhatIsMissing() throws {
        #expect(try clarification("[s]") == "What should Sonny do on screen, and in which app?")
        #expect(try clarification("[s] Notes") == "What should Sonny do in Notes?")
    }

    /// **An app's alias alone asks what to do, as its name alone does** (PR #238's F8). The check
    /// compared the words with the app's display name, so `[s] Google Chrome` started a session whose
    /// whole goal was "Google Chrome" and spent an allowance run on nothing.
    @Test
    func anAliasOfAnAppAloneAsksWhatToDoInIt() throws {
        let chrome = try displayName("Chrome")
        #expect(try clarification("[s] Google Chrome") == "What should Sonny do in \(chrome)?")
        #expect(try clarification("[s] Chrome") == "What should Sonny do in \(chrome)?")
        let music = try displayName("Music")
        #expect(try clarification("[s] Music") == "What should Sonny do in \(music)?")
    }

    /// **Two apps in one sentence ask which, rather than taking one** (PR #238's F9). The last
    /// preposition's app used to win, so this command went to Music — which Normal mode controls
    /// without asking, being on the starter list. A label names the app outright and is not a guess,
    /// so it still wins; one app named twice is still one app.
    @Test
    func twoAppsInOneSentenceAskWhichRatherThanPickingOne() throws {
        let twoApps = "[s] tell the team in Slack that I am listening to Music"
        let question = try clarification(twoApps)
        #expect(question == "Which app should Sonny control for that: \(try displayName("Music")) or \(try displayName("Slack"))?")

        let answered = try plan(try #require(makeResolver().screenUseCompletion(request: twoApps, answer: "Slack")))
        #expect(answered.steps.map(\.appName) == [try displayName("Slack")])

        #expect(try plan("[s] Slack: tell the team I am listening to Music").steps.map(\.appName) == [try displayName("Slack")])
        #expect(try plan("[s] find the wave 7 tab in Google Chrome").steps.count == 1)
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
