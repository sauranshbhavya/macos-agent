import Foundation
import MacAgentTestSupport
import Testing
@testable import MacAgentCore

@Suite
@MainActor
struct InstantCommandResolverTests {
    @Test
    func calculatorServiceEvaluatesArithmeticAndConversions() throws {
        let calculator = CalculatorService()

        #expect(try calculator.evaluate("2 + 2 * 3").result == "8")
        #expect(try calculator.evaluate("(2 + 2) * 3").result == "12")
        #expect(try calculator.evaluate("100 cm to m").result == "1 m")
        #expect(try calculator.evaluate("32 f to c").result == "0 C")
    }

    @Test
    func resolverBuildsCalculatorPlanForExplicitAndBareInputs() throws {
        let resolver = InstantCommandResolver(
            snippetStore: UnreachableLocalStores.snippets(),
            recentArtifactStore: UnreachableLocalStores.recentArtifacts(),
            routineStore: UnreachableLocalStores.routines(),
            workspaceStore: UnreachableLocalStores.workspaces()
        )

        guard case .plan(let explicitPlan) = resolver.resolve(command: "calc 2 + 2") else {
            Issue.record("Expected explicit calculator command to resolve locally.")
            return
        }
        #expect(explicitPlan.steps.map(\.operation) == [.calculateUtility])
        #expect(explicitPlan.steps[0].searchQuery == "2 + 2")

        guard case .plan(let barePlan) = resolver.resolve(command: "10 cm to in") else {
            Issue.record("Expected bare conversion command to resolve locally.")
            return
        }
        #expect(barePlan.steps.map(\.operation) == [.calculateUtility])
        #expect(barePlan.steps[0].searchQuery == "10 cm to in")

        #expect(resolver.resolve(command: "Open Safari") == nil)
    }

    @Test
    func resolverClarifiesEmptyCalculatorCommand() throws {
        let resolver = InstantCommandResolver(
            snippetStore: UnreachableLocalStores.snippets(),
            recentArtifactStore: UnreachableLocalStores.recentArtifacts(),
            routineStore: UnreachableLocalStores.routines(),
            workspaceStore: UnreachableLocalStores.workspaces()
        )

        guard case .clarify(let plan) = resolver.resolve(command: "calculate") else {
            Issue.record("Expected empty calculator command to ask a clarification.")
            return
        }

        #expect(plan.steps.map(\.operation) == [.clarify])
        #expect(plan.steps[0].question == "What would you like me to calculate?")
    }

    @Test
    func instantCalculatorBypassesPlannerButUsesRunnerRiskPipeline() async throws {
        let resolver = InstantCommandResolver(
            snippetStore: UnreachableLocalStores.snippets(),
            recentArtifactStore: UnreachableLocalStores.recentArtifacts(),
            routineStore: UnreachableLocalStores.routines(),
            workspaceStore: UnreachableLocalStores.workspaces()
        )
        guard case .plan(let plan) = resolver.resolve(command: "calc 2 + 2 * 3") else {
            Issue.record("Expected calculator command to resolve locally.")
            return
        }

        let logStore = AgentLogStore()
        let usageRecorder = TaskUsageRecorder()
        let runner = AgentRunner(
            planner: FailingPlanner(),
            executor: AgentActionExecutor(
                routineStore: UnreachableLocalStores.routines(),
                workspaceStore: UnreachableLocalStores.workspaces(),
                usageRecorder: usageRecorder,
                clipboardHistoryStore: UnreachableLocalStores.clipboardHistory(),
                snippetStore: UnreachableLocalStores.snippets(),
                recentArtifactStore: UnreachableLocalStores.recentArtifacts(),
                shortcutRunHistoryStore: UnreachableLocalStores.shortcutRunHistory(),
                resumableTaskStore: UnreachableLocalStores.resumableTasks(),
            ),
            logStore: logStore
        )

        let prepared = try runner.prepare(plan: plan, source: .instantResolver)
        #expect(prepared.previews.first?.title == "Calculate")
        #expect(prepared.previews.first?.details.contains("Result: 8") == true)

        let request = try runner.approvalRequest(
            for: prepared,
            logAssessment: true,
            scope: .unscoped,
            context: ApprovalContext(mode: .normal, appControl: .notApplicable)
        )
        #expect(request.assessment.effectiveTier == .tier0)
        #expect(request.requirement == .autoRun)

        let result = try await runner.execute(
            prepared,
            confirmationMessage: "Instant calculator auto-run",
            scope: .unscoped,
            context: ApprovalContext(mode: .normal, appControl: .notApplicable)
        )
        #expect(result.summary == "2 + 2 * 3 = 8.")
        #expect(usageRecorder.snapshot().requestCount == 0)
        #expect(logStore.events.contains { $0.phase == .plan && $0.message == "Resolved command locally" })
        #expect(logStore.events.contains { $0.phase == .risk && $0.message.contains("risk.assessed: Tier 0") })
    }

    /// The sign a person types at the end of a sum (SONNY-281). `2 + 2` was answered here and
    /// `2 + 2 =` was not — the trailing sign fell outside the bare-arithmetic rule's character set,
    /// and the sum reached a planner that has no calculator to offer. The rule now reads the sum the
    /// way the evaluator will, and the plan carries that form so its own summary says `2 + 2`.
    @Test
    func bareArithmeticWithATrailingEqualsSignResolvesToTheCalculator() throws {
        let resolver = InstantCommandResolver(
            snippetStore: UnreachableLocalStores.snippets(),
            recentArtifactStore: UnreachableLocalStores.recentArtifacts(),
            routineStore: UnreachableLocalStores.routines(),
            workspaceStore: UnreachableLocalStores.workspaces()
        )

        for command in ["2 + 2 =", "2 + 2 = ", "2+2=", "2 + 2 = ?", "2 + 2?"] {
            guard case .plan(let plan) = resolver.resolve(command: command) else {
                Issue.record("Expected \(command.debugDescription) to resolve locally as a sum.")
                continue
            }
            let sum = CalculatorService.withoutTrailingEqualsOrQuestionMark(command)
            #expect(plan.steps.map(\.operation) == [.calculateUtility])
            #expect(plan.steps[0].searchQuery == sum)
            #expect(plan.summary == "Calculate \(sum).")
        }

        // The prefixed forms drop it too, so their plan reads the same as the bare one.
        for command in ["= 2 + 2 =", "calc 2 + 2 =", "Calculate 2 + 2 ?"] {
            guard case .plan(let prefixed) = resolver.resolve(command: command) else {
                Issue.record("Expected \(command.debugDescription) to resolve locally as a sum.")
                continue
            }
            #expect(prefixed.steps[0].searchQuery == "2 + 2")
        }

        // A conversion may end the same way.
        guard case .plan(let conversion) = resolver.resolve(command: "10 cm to in =") else {
            Issue.record("Expected the conversion to resolve locally.")
            return
        }
        #expect(conversion.steps[0].searchQuery == "10 cm to in")

        // An interior sign is a statement, not a sum, and stays the planner's.
        #expect(resolver.resolve(command: "2 + 2 = 4") == nil)

        // The sign alone is still the question it always was, not a sum of nothing — and so is a
        // sign with nothing but signs after it, which used to plan a calculation of `=`.
        for command in ["=", "= =", "=?"] {
            guard case .clarify(let question) = resolver.resolve(command: command) else {
                Issue.record("Expected \(command.debugDescription) to ask what to calculate.")
                continue
            }
            #expect(question.steps[0].question == "What would you like me to calculate?")
        }
    }

    /// **A calculation phrased as a sentence is still a calculation** (SONNY-284). Each of these
    /// reached a planner that has no calculator to offer and came back "Calculation is unsupported
    /// by the registered local tools" — the answer a first user got in their first ten minutes.
    ///
    /// Every case asserts the expression the plan carries *and* evaluates it. A resolver that
    /// stripped the filler and handed the evaluator something it refuses would satisfy a
    /// resolver-only assertion while showing the user an error, which is the defect this ticket is
    /// about arriving by a different door.
    ///
    /// `how much is 5 times 5` is the case that pins the longest-phrase-first ordering: stripped by
    /// `how much` it leaves `is 5 times 5`, which matches nothing.
    ///
    /// **The evaluation is not inside the `#expect`** (PR #176 review, F5). `#expect(try …)`
    /// propagates, so one case whose expression throws would end the whole test and every case
    /// after it would go unrun while the output showed a single failure — a table of this size can
    /// lose most of itself and look like one defect. The `guard case .plan` arm above already had
    /// this right with `Issue.record` plus `continue`.
    @Test
    func aCalculationPhrasedAsASentenceResolvesToTheCalculator() {
        let resolver = Self.hermeticResolver()
        let calculator = CalculatorService()

        let cases: [(command: String, expression: String, result: String)] = [
            ("what is 2 + 2", "2 + 2", "4"),
            ("What is 2 + 2?", "2 + 2", "4"),
            ("what's 2+2", "2+2", "4"),
            ("what\u{2019}s 2+2", "2+2", "4"),
            ("whats 2 + 2 =", "2 + 2", "4"),
            ("how much is 5 times 5", "5 times 5", "25"),
            ("How much is 5 times 5?", "5 times 5", "25"),
            ("convert 5 km to miles", "5 km to miles", "3.1068559612 mi"),
            ("5 km in miles please", "5 km in miles", "3.1068559612 mi"),
            ("please calculate 2 + 2", "2 + 2", "4"),
            ("work out 12 * 12", "12 * 12", "144"),
            ("solve 100 / 4 for me", "100 / 4", "25"),
            ("compute (2 + 2) * 3 thanks", "(2 + 2) * 3", "12"),
            ("what is two plus two", "two plus two", "4"),
            ("two plus two", "two plus two", "4"),
            ("ten cm to in", "ten cm to in", "3.937007874 in"),

            // A comma before the politeness word, which is ordinary English typed and the default
            // out of dictation (PR #176 review, F1). The first two reached the planner; the third
            // was answered and carried the comma into the card as `Calculate five times five,.`
            ("What is 5 times 5, please?", "5 times 5", "25"),
            ("what is 2 + 2, please", "2 + 2", "4"),
            ("what is five times five, please", "five times five", "25"),
            // The rest of what a transcriber puts on the end of a sentence.
            ("what is 5 times 5!", "5 times 5", "25"),
            ("what is 2 + 2.", "2 + 2", "4"),

            // The trailing trim runs inside the stripping loop, so a sign the tail-off was hiding
            // still comes off (PR #176 review, F2). Hoisting that call above the loop leaves the
            // rest of this table green and breaks exactly this row.
            ("what's 2+2? thanks", "2+2", "4"),

            // The three filler entries nothing exercised (PR #176 review, F6). Bare `how much` is
            // also the only reason `longestFirst` has anything to do, so pruning it as dead weight
            // would silently make mutant M1's property untestable.
            ("please calc 2 + 2", "2 + 2", "4"),
            ("how much 5 times 5", "5 times 5", "25"),
            ("what is 2 + 2 thank you", "2 + 2", "4"),

            // The `calc`/`calculate`/`=` prefixes take the filler off too. Before this round these
            // planned `2 + 2 please` and answered "Could not calculate that expression: Unexpected
            // token p." — a parser message naming a letter, on the sentence the row above answers.
            ("calculate 2 + 2 please", "2 + 2", "4"),
            ("calculate two plus two please", "two plus two", "4"),
            ("calc 2 + 2, please", "2 + 2", "4"),
            ("= 5 times 5, please", "5 times 5", "25"),

            // A leading `.` is a decimal point, so the sentence trim takes the trailing end only —
            // trimmed at both ends this is `5 + 1` and answers `6`.
            ("what is .5 + 1", ".5 + 1", "1.5"),
            // The two trailing rules interleave, so the trim runs to a fixed point: one pass leaves
            // `2 + 2 ` and the card reads `Calculate 2 + 2 .`
            ("2 + 2 .", "2 + 2", "4")
        ]

        for testCase in cases {
            guard case .plan(let plan) = resolver.resolve(command: testCase.command) else {
                Issue.record("Expected \(testCase.command.debugDescription) to resolve locally.")
                continue
            }
            #expect(plan.steps.map(\.operation) == [.calculateUtility])
            #expect(plan.steps[0].searchQuery == testCase.expression)
            #expect(plan.summary == "Calculate \(testCase.expression).")
            do {
                let evaluated = try calculator.evaluate(testCase.expression)
                #expect(
                    evaluated.result == testCase.result,
                    "\(testCase.command.debugDescription) planned \(testCase.expression.debugDescription)"
                )
            } catch {
                let planned = testCase.expression.debugDescription
                Issue.record(
                    "\(testCase.command.debugDescription) planned \(planned), which the evaluator refused: \(error)"
                )
            }
        }
    }

    /// The other direction, and the constraint the founders attached to SONNY-284 when they triaged
    /// it: widening the calculator's reach must not start swallowing commands that are not
    /// calculations. Every one of these still reaches the planner.
    ///
    /// `convert` is the lead-in that earns most of this list. It is also a real operation here —
    /// `convert_docx_to_pdf` — so it is the one filler word whose shape collides with something the
    /// planner is meant to answer.
    @Test
    func theWidenedCalculatorStillLeavesNonCalculationsToThePlanner() throws {
        let resolver = Self.hermeticResolver()

        let mustReachThePlanner = [
            // A lead-in in front of something that is not a sum.
            "what is my ip address",
            "what is the weather today",
            "what's on my calendar",
            "how much is left on my disk",
            "compute the checksum of this file",
            "solve my merge conflict",
            "please open Safari",
            // The document-conversion verb, in the shapes a user actually types it.
            "convert report.docx to pdf",
            "convert my notes.docx to pdf",
            "convert 5 docs to pdf",
            "convert 3 files in Downloads to pdf",
            // A lead-in with nothing after it is a question for the planner, not a calculation —
            // and not a clarification either, which only the `calc` prefix earns.
            "what is",
            "convert",
            "how much is",
            "please",
            // A number is not a sum, and a statement about one is not a sum either.
            "what is 5 km",
            "what is 2 + 2 = 4",
            "remind me in 5 minutes",
            "open 2 windows",
            "switch to one two three four",
            // Reading spoken words in the *resolver* is new on this path, so the boundary where a
            // word-operator meets ordinary prose is newly load-bearing (PR #176 review, F4).
            "take away the trash",
            "5 minutes over lunch",
            "put 3 into the folder called work",
            // A single-letter unit abbreviation is the whole residual surface of the one-sided
            // conversion guard; these are the shapes where it holds.
            "5 tabs in chrome",
            "move 3 files to Desktop"
        ]

        for command in mustReachThePlanner {
            #expect(
                resolver.resolve(command: command) == nil,
                "\(command.debugDescription) must still fall to the planner."
            )
        }
    }

    /// One side naming a real unit is what separates a conversion the calculator should *refuse*
    /// from a command that was never a conversion (SONNY-284). `5 km to parsecs` deserves "parsecs
    /// is not a supported conversion unit"; `5 docs to pdf` deserves the planner, and used to get
    /// the calculator even with no lead-in in front of it.
    @Test
    func aConversionNamingOneRealUnitStaysTheCalculatorsToRefuse() throws {
        let resolver = Self.hermeticResolver()

        guard case .plan(let plan) = resolver.resolve(command: "convert 5 km to parsecs") else {
            Issue.record("Expected a conversion naming one real unit to resolve locally.")
            return
        }
        #expect(plan.steps.map(\.operation) == [.calculateUtility])
        #expect(plan.steps[0].searchQuery == "5 km to parsecs")
        #expect(throws: CalculatorError.unsupportedUnit("parsecs")) {
            try CalculatorService().evaluate("5 km to parsecs")
        }

        #expect(resolver.resolve(command: "5 docs to pdf") == nil)
        #expect(resolver.resolve(command: "convert 5 docs to pdf") == nil)
        #expect(resolver.resolve(command: "10 files in folder") == nil)

        // **The class this guard removes from the calculator is not docs-shaped** (PR #176 review,
        // F3). Every four-token conversion naming no unit `ConversionUnit` knows goes to the
        // planner now, and most members of that class are ordinary conversion requests rather than
        // commands: on `main` these reached the calculator and were told which token it did not
        // understand. The trade is accepted and recorded in the changelog's Known limitations; it
        // is pinned here so that widening the unit table is a deliberate act with a red test, not
        // a side effect nobody notices.
        for lostToThePlanner in ["10 gb to mb", "2 hours to minutes", "100 usd to eur"] {
            #expect(
                resolver.resolve(command: lostToThePlanner) == nil,
                "\(lostToThePlanner.debugDescription) names no known unit, so it is the planner's."
            )
        }
    }

    /// **After `calc`, a word at the front is part of what the user wrote, not filler in front of
    /// it** (PR #176 fix round). Found by a mutation battery's baseline going red on
    /// `ResumableTaskRunTests.anAnswerThatRestatesTheCommandIsTakenAsTheWholeCommand`, which is in
    /// the other target and about the clarification round trip rather than about the calculator:
    /// when a user answers the `calc` question by restating the prefix, PR #118's F2 tries the
    /// joined candidate `calc Calc 2 + 2` first and picks the answer alone **because the joined one
    /// fails the dry run's evaluation**. A discrimination that works by one candidate failing is
    /// defeated silently by anything that makes it succeed — so this pins the failure as a
    /// property, next to the code that would take it away.
    @Test
    func thePrefixesTakeTrailingFillerOffAndLeaveTheFrontAlone() {
        let resolver = Self.hermeticResolver()

        guard case .plan(let restated) = resolver.resolve(command: "calc Calc 2 + 2") else {
            Issue.record("Expected the prefixed form to plan whatever follows the prefix.")
            return
        }
        #expect(restated.steps[0].searchQuery == "Calc 2 + 2")
        #expect(throws: CalculatorError.self) {
            try CalculatorService().evaluate("Calc 2 + 2")
        }

        // The trailing half still comes off, which is the half this round added.
        guard case .plan(let polite) = resolver.resolve(command: "calculate 2 + 2 please") else {
            Issue.record("Expected the prefixed form to drop the politeness word.")
            return
        }
        #expect(polite.steps[0].searchQuery == "2 + 2")
    }

    /// No live catalog and no live app lookup: this suite's commands are about the calculator, and
    /// the two defaults on the initializer reach the real machine.
    private static func hermeticResolver() -> InstantCommandResolver {
        InstantCommandResolver(
            snippetStore: UnreachableLocalStores.snippets(),
            recentArtifactStore: UnreachableLocalStores.recentArtifacts(),
            routineStore: UnreachableLocalStores.routines(),
            workspaceStore: UnreachableLocalStores.workspaces(),
            shortcutCatalog: NoShortcuts(),
            installedAppResolver: NoInstalledApps()
        )
    }
}

private struct NoShortcuts: ShortcutCatalogProviding {
    func shortcutNames() throws -> [String] { [] }
}

private struct NoInstalledApps: InstalledAppResolving {
    func resolve(_ rawName: String?) -> InstalledApp? { nil }
}

private struct FailingPlanner: Planning {
    func plan(command: String, priorTaskContext: PriorTaskContext?) async throws -> AgentPlan {
        Issue.record("Planner should not be called for an instant calculator command.")
        throw PlannerError.noPlannerRan
    }
}
