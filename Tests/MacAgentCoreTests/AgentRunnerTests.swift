import Foundation
import MacAgentTestSupport
import Testing
@testable import MacAgentCore

@Suite
@MainActor
struct AgentRunnerTests {
    @Test
    func tierOneTypedCommandAutoRunsWithoutApprovalDecision() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let appOpener = RecordingAppOpener()
        let runner = AgentRunner(
            planner: StaticPlanner(plan: openAppPlan(appName: "Safari")),
            executor: makeExecutor(root: root, appOpener: appOpener)
        )

        let prepared = try await runner.prepare(command: "Open Safari")
        let request = try runner.approvalRequest(for: prepared, scope: .unscoped, context: approvalContext(for: prepared))
        let result = try await runner.execute(
            prepared,
            confirmationMessage: "Typed command auto-approved execution",
            scope: .unscoped,
            context: approvalContext(for: prepared)
        )

        #expect(request.assessment.effectiveTier == .tier1)
        #expect(request.requirement == .autoRun)
        #expect(appOpener.openedBundleIDs == ["com.apple.Safari"])
        #expect(result.summary == "Opened the Safari app.")
    }

    @Test
    func tierOneVoiceCommandAutoRunsWithoutApprovalDecision() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let browserOpener = RecordingBrowserOpener()
        let runner = AgentRunner(
            planner: StaticPlanner(plan: openURLPlan(url: "https://github.com")),
            executor: makeExecutor(root: root, browserOpener: browserOpener)
        )

        let prepared = try await runner.prepare(command: "Open GitHub")
        let request = try runner.approvalRequest(for: prepared, scope: .unscoped, context: approvalContext(for: prepared))
        let result = try await runner.execute(
            prepared,
            confirmationMessage: "Voice command auto-approved execution",
            scope: .unscoped,
            context: approvalContext(for: prepared)
        )

        #expect(request.assessment.effectiveTier == .tier1)
        #expect(request.requirement == .autoRun)
        #expect(browserOpener.openedURLs.map(\.absoluteString) == ["https://github.com"])
        // Non-workspace caller: a standalone open-URL still goes to the system default browser.
        #expect(browserOpener.openedBrowsers == [nil])
        #expect(result.summary == "Opened https://github.com.")
    }

    @Test
    func appSearchURLTierOneAutoRunsWithoutApprovalDecision() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let browserOpener = RecordingBrowserOpener()
        let runner = AgentRunner(
            planner: StaticPlanner(plan: openAppSearchURLPlan()),
            executor: makeExecutor(root: root, browserOpener: browserOpener)
        )

        let prepared = try await runner.prepare(command: "Search GitHub for Swift concurrency")
        let request = try runner.approvalRequest(for: prepared, scope: .unscoped, context: approvalContext(for: prepared))
        let result = try await runner.execute(prepared, scope: .unscoped, context: approvalContext(for: prepared))

        #expect(request.assessment.effectiveTier == .tier1)
        #expect(request.requirement == .autoRun)
        #expect(request.approvalCopy.dataLeavesDevice == true)
        #expect(browserOpener.openedURLs.map(\.absoluteString) == ["https://github.com/search?q=Swift%20concurrency"])
        // Non-workspace caller: an app search URL still goes to the system default browser.
        #expect(browserOpener.openedBrowsers == [nil])
        #expect(result.summary == "Opened GitHub search for Swift concurrency.")
    }

    @Test
    func openGeneratedArtifactTierOneAutoRunsWithoutApprovalDecision() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let artifact = root.appendingPathComponent("artifact.md")
        try write("artifact", to: artifact)
        let fileOpener = RecordingFileOpener()
        let runner = AgentRunner(
            planner: StaticPlanner(plan: openGeneratedArtifactPlan(output: artifact)),
            executor: makeExecutor(root: root, fileOpener: fileOpener)
        )

        let prepared = try await runner.prepare(command: "Open the generated artifact")
        let request = try runner.approvalRequest(for: prepared, scope: .unscoped, context: approvalContext(for: prepared))
        let result = try await runner.execute(prepared, scope: .unscoped, context: approvalContext(for: prepared))

        #expect(request.assessment.effectiveTier == .tier1)
        #expect(request.requirement == .autoRun)
        #expect(fileOpener.openedFiles == [artifact.standardizedFileURL])
        #expect(result.summary == "Opened generated artifact \(artifact.path).")
    }

    @Test
    func tierZeroCommandAutoRunsWithoutApprovalDecision() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = AgentRunner(
            planner: StaticPlanner(plan: permissionReadinessPlan()),
            executor: makeExecutor(root: root)
        )

        let prepared = try await runner.prepare(command: "Check Sonny permissions")
        let request = try runner.approvalRequest(for: prepared, scope: .unscoped, context: approvalContext(for: prepared))
        let result = try await runner.execute(prepared, scope: .unscoped, context: approvalContext(for: prepared))

        #expect(request.assessment.effectiveTier == .tier0)
        #expect(request.requirement == .autoRun)
        #expect(result.summary.hasPrefix("Permission readiness checked."))
    }

    /// The gate-before-execute ordering, kept on the escalation that still gates: under the
    /// consequence rule (2026-08-13) a collision-free tier-2 zip auto-runs, so the pause this test
    /// pins is the *destructive* one — the output already exists — and nothing executes until the
    /// user answers it. (Before the rule this test used a plain tier-2 confirmation for the same
    /// ordering claim; the claim is unchanged, the fixture had to move to what still asks.)
    @Test
    func aDestructiveCollisionRequiresApprovalBeforeRunnerExecutes() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("small", to: root.appendingPathComponent("small.txt"))
        try write(String(repeating: "x", count: 2048), to: root.appendingPathComponent("large.txt"))
        let output = root.appendingPathComponent("largest.zip")
        try write("existing zip", to: output)
        let zipArchiver = RecordingZipArchiver()
        let runner = AgentRunner(
            planner: StaticPlanner(plan: largestPlan(root: root, output: output)),
            executor: makeExecutor(root: root, zipArchiver: zipArchiver)
        )

        let prepared = try await runner.prepare(command: "Zip the largest files")
        let request = try runner.approvalRequest(for: prepared, scope: .unscoped, context: approvalContext(for: prepared))

        do {
            _ = try await runner.execute(prepared, scope: .unscoped, context: approvalContext(for: prepared))
            Issue.record("Expected the destructive collision to require approval.")
        } catch RiskApprovalError.approvalRequired(let approvalRequest) {
            #expect(approvalRequest.requirement == .explicitApproval)
            #expect(approvalRequest.assessment.effectiveTier == .tier3)
        } catch {
            Issue.record("Expected approvalRequired, got \(error).")
        }

        #expect(request.assessment.effectiveTier == .tier3)
        #expect(request.requirement == .explicitApproval)
        #expect(request.assessment.escalations.map(\.consequence) == [.destructive])
        #expect(zipArchiver.createdArchives.isEmpty)

        _ = try await runner.execute(
            prepared,
            approvalDecision: .approved(answering: request),
            confirmationMessage: "User approved the overwrite",
            scope: .unscoped,
            context: approvalContext(for: prepared)
        )

        #expect(zipArchiver.createdArchives == [output])
        #expect(FileManager.default.fileExists(atPath: output.path))
    }

    /// SONNY-447. A plan the planner refused reaches the runner as one unsupported step whose
    /// description is the model's reason; `prepare` throws with that reason kept on the error and
    /// this repository's sentence as what the user reads.
    @Test
    func aRefusedPlanThrowsSonnysOwnSentenceAndKeepsThePlannersReason() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let reason = "Unsupported: there is no registered weather lookup tool available."
        let plan = AgentPlan(
            summary: "Unsupported request.",
            requiresConfirmation: false,
            steps: [AgentStep(id: "unsupported", operation: .unsupported, description: reason)]
        )
        let runner = AgentRunner(planner: StaticPlanner(plan: plan), executor: makeExecutor(root: root))

        do {
            _ = try await runner.prepare(command: "what is the weather today")
            Issue.record("Expected the refusal to throw.")
        } catch let error as AgentExecutionError {
            #expect(error == .unsupported(reason))
            #expect(error.localizedDescription == "Sonny can't do that yet.")
        } catch {
            Issue.record("Expected AgentExecutionError.unsupported, got \(error).")
        }
    }

    /// **The planner's reason reaches the act log, through both `prepare` doors** (SONNY-447,
    /// PR #232's fresh review, F1). The ticket asks for the reason to stay in the act log so a
    /// trace says why; the branch's first version had taken it out of that log and tested none.
    /// The log carries the reason once per refusal and never the user's sentence in its place;
    /// the pre-built door is driven too, because the runner's one funnel is what makes the two
    /// doors one path.
    @Test
    func aRefusedPlansReasonReachesTheActLog() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let reason = "Unsupported: there is no registered weather lookup tool available."
        let plan = AgentPlan(
            summary: "Unsupported request.",
            requiresConfirmation: false,
            steps: [AgentStep(id: "unsupported", operation: .unsupported, description: reason)]
        )
        let logStore = AgentLogStore()
        let runner = AgentRunner(planner: StaticPlanner(plan: plan), executor: makeExecutor(root: root), logStore: logStore)

        await #expect(throws: AgentExecutionError.unsupported(reason)) {
            _ = try await runner.prepare(command: "what is the weather today")
        }
        let typed = logStore.events.map(\.message)
        #expect(typed.filter { $0 == "The planner refused this request: \(reason)" }.count == 1, "\(typed)")
        #expect(!typed.contains { $0.contains(AgentExecutionError.unsupportedRequestSentence) }, "the user's sentence stood in for the reason: \(typed)")

        #expect(throws: AgentExecutionError.unsupported(reason)) {
            _ = try runner.prepare(plan: plan)
        }
        let prebuilt = logStore.events.map(\.message)
        #expect(prebuilt.filter { $0 == "The planner refused this request: \(reason)" }.count == 1, "\(prebuilt)")
    }

    /// SONNY-445. The widget's result panel draws its file chip off the first `.openFile`
    /// suggestion and nothing else, and the zip emitted Reveal alone — so a zipped result showed
    /// its path in a sentence and no chip (the founders' pass, test 9). Open first, at the archive,
    /// then Reveal at the same path, the order the draft and web-research adapters use.
    @Test
    func aZipResultCarriesOpenFirstAndRevealAtTheArchivePath() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("small", to: root.appendingPathComponent("small.txt"))
        try write(String(repeating: "x", count: 2048), to: root.appendingPathComponent("large.txt"))
        let output = root.appendingPathComponent("largest.zip")
        let zipArchiver = RecordingZipArchiver()
        let runner = AgentRunner(
            planner: StaticPlanner(plan: largestPlan(root: root, output: output)),
            executor: makeExecutor(root: root, zipArchiver: zipArchiver)
        )

        let prepared = try await runner.prepare(command: "Zip the largest files")
        let result = try await runner.execute(prepared, scope: .unscoped, context: approvalContext(for: prepared))

        #expect(result.suggestions.map(\.kind) == [.openFile, .revealInFinder])
        #expect(result.suggestions.map(\.value) == [output.path, output.path])
        #expect(result.suggestions.first?.title == "Open zip")
    }

    /// The follow-up-correction machinery is the subject: the planner receives the correction and
    /// the prior context, and the refined plan is the one that runs. Under the consequence rule a
    /// collision-free tier-2 zip auto-runs, so the corrected plan executes without a prompt — the
    /// gating half this test used to carry now lives with the destructive fixtures.
    @Test
    func followUpCorrectionRefinesLargestFilesPlanAndAutoRunsUnderTheConsequenceRule() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let originalFolder = root.appendingPathComponent("MacAgentDemo")
        let correctedFolder = root.appendingPathComponent("MacAgentDocs")
        try FileManager.default.createDirectory(at: originalFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: correctedFolder, withIntermediateDirectories: true)
        try write("small", to: correctedFolder.appendingPathComponent("small.txt"))
        try write(String(repeating: "x", count: 2048), to: correctedFolder.appendingPathComponent("large.txt"))
        let output = root.appendingPathComponent("corrected-largest.zip")
        let zipArchiver = RecordingZipArchiver()
        let priorContext = PriorTaskContext(
            command: "Find the 3 largest files in \(originalFolder.path) and zip them.",
            plan: largestPlan(root: originalFolder, output: root.appendingPathComponent("original-largest.zip")),
            outcome: PriorTaskOutcome(status: .completed, summary: "Created original-largest.zip."),
            createdAt: Date(timeIntervalSince1970: 2_000)
        )
        let planner = RecordingPlanner(plan: largestPlan(root: correctedFolder, output: output))
        let runner = AgentRunner(
            planner: planner,
            executor: makeExecutor(root: root, zipArchiver: zipArchiver)
        )

        let command = "use \(correctedFolder.path) instead"
        let prepared = try await runner.prepare(command: command, priorTaskContext: priorContext)
        let request = try runner.approvalRequest(for: prepared, scope: .unscoped, context: approvalContext(for: prepared))

        #expect(planner.receivedCommand == command)
        #expect(planner.receivedPriorTaskContext == priorContext)
        #expect(prepared.plan.steps.first?.inputPath == correctedFolder.path)
        #expect(request.assessment.effectiveTier == .tier2)
        #expect(request.requirement == .autoRun)

        _ = try await runner.execute(prepared, scope: .unscoped, context: approvalContext(for: prepared))

        #expect(zipArchiver.createdArchives == [output])
        #expect(FileManager.default.fileExists(atPath: output.path))
    }

    @Test
    func unrelatedCommandCanIgnoreEligiblePriorContextAndPrepareFreshPlan() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let originalFolder = root.appendingPathComponent("MacAgentDemo")
        try FileManager.default.createDirectory(at: originalFolder, withIntermediateDirectories: true)
        let priorContext = PriorTaskContext(
            command: "Find the 3 largest files in \(originalFolder.path) and zip them.",
            plan: largestPlan(root: originalFolder, output: root.appendingPathComponent("original-largest.zip")),
            outcome: PriorTaskOutcome(status: .completed, summary: "Created original-largest.zip."),
            createdAt: Date(timeIntervalSince1970: 2_000)
        )
        let planner = RecordingPlanner(plan: openAppPlan(appName: "Safari"))
        let runner = AgentRunner(
            planner: planner,
            executor: makeExecutor(root: root)
        )

        let prepared = try await runner.prepare(command: "Open Safari", priorTaskContext: priorContext)

        #expect(planner.receivedPriorTaskContext == priorContext)
        #expect(prepared.plan.steps.map(\.operation) == [.openApp])
        #expect(prepared.plan.steps.first?.inputPath == nil)
        #expect(prepared.plan.summary == "Open Safari.")
    }

    @Test
    func runnerRefusesTierFourBeforeExecutorExecution() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = try CapabilityRegistry(adapters: [
            StaticTierOpenURLAdapter(defaultRiskTier: .tier4)
        ])
        let runner = AgentRunner(
            planner: StaticPlanner(plan: openURLPlan(url: "https://example.com")),
            executor: makeExecutor(root: root, capabilityRegistry: registry)
        )

        let prepared = try await runner.prepare(command: "Open example")
        let request = try runner.approvalRequest(for: prepared, scope: .unscoped, context: approvalContext(for: prepared))

        do {
            _ = try await runner.execute(
                prepared,
                approvalDecision: .approved(.tier4),
                confirmationMessage: "User approved Tier 4 action",
                scope: .unscoped,
                context: approvalContext(for: prepared)
            )
            Issue.record("Expected tier 4 execution to be refused.")
        } catch RiskApprovalError.refused(let approvalRequest) {
            #expect(approvalRequest.assessment.effectiveTier == .tier4)
        } catch {
            Issue.record("Expected refused, got \(error).")
        }

        #expect(request.requirement == .refuse)
    }

    @Test
    func executorAssessRiskUsesHighestStaticTierInMixedPlan() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("largest.zip")
        let executor = makeExecutor(root: root)
        let plan = AgentPlan(
            summary: "Zip files and open Safari.",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "scan",
                    operation: .scanSelectLargestFiles,
                    description: "Scan files.",
                    inputPath: root.path,
                    count: 3
                ),
                AgentStep(
                    id: "zip",
                    operation: .createZip,
                    description: "Zip files.",
                    inputPath: root.path,
                    outputPath: output.path,
                    count: 3
                ),
                AgentStep(
                    id: "open",
                    operation: .openApp,
                    description: "Open Safari.",
                    appName: "Safari"
                )
            ]
        )

        let assessment = try executor.assessRisk(plan: plan, scope: .unscoped)

        #expect(assessment.defaultTier == .tier2)
        #expect(assessment.effectiveTier == .tier2)
        #expect(assessment.escalations.isEmpty)
        #expect(RiskApprovalPolicy.default.requirement(for: assessment, context: ApprovalContext(mode: .normal, appControl: .notApplicable)) == .autoRun)
        #expect(assessment.approvalCopy?.involvedResource.contains(output.path) == true)
    }

    @Test
    func existingZipOutputEscalatesToTierThreeAndLogsRiskEvent() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("small", to: root.appendingPathComponent("small.txt"))
        try write(String(repeating: "x", count: 2048), to: root.appendingPathComponent("large.txt"))
        let output = root.appendingPathComponent("largest.zip")
        try write("existing zip", to: output)
        let logStore = AgentLogStore()
        let runner = AgentRunner(
            planner: StaticPlanner(plan: largestPlan(root: root, output: output)),
            executor: makeExecutor(root: root),
            logStore: logStore
        )

        let prepared = try await runner.prepare(command: "Zip the largest files")
        let request = try runner.approvalRequest(for: prepared, logAssessment: true, scope: .unscoped, context: approvalContext(for: prepared))

        #expect(request.assessment.defaultTier == .tier2)
        #expect(request.assessment.effectiveTier == .tier3)
        #expect(request.requirement == .explicitApproval)
        #expect(request.assessment.escalations == [
            CapabilityRiskEscalation(
                fromTier: .tier2,
                toTier: .tier3,
                reason: "Zip output already exists at \(output.path).",
                consequence: .destructive
            )
        ])
        #expect(logStore.events.contains { event in
            event.phase == .risk && event.message.contains("risk.escalated")
        })
    }

    /// AC11 (SONNY-37) — a scope escalation has to be its own logged trace event, not a silent
    /// internal decision (spec §11.1A). `logRiskAssessment` already emits one `risk.escalated` per
    /// escalation, so this asserts the wiring rather than adding any, and it asserts the *whole*
    /// line: a `contains("risk.escalated")` check would pass on any escalation from any source and
    /// prove nothing about scope.
    ///
    /// Under the consequence rule (2026-08-13) the out-of-scope escalation is advisory: the
    /// assessment still rises to tier 3 and the `risk.escalated` line still fires — the log stays
    /// honest — but the requirement is `.autoRun`, and the sentence reaches the user on the
    /// ran-without-asking trace instead of a prompt.
    @Test
    func anOutOfScopePlanEscalatesThroughTheOrdinaryGateAndLogsItsOwnRiskEvent() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let logStore = AgentLogStore()
        let plan = AgentPlan(
            summary: "Open a site.",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "open",
                    operation: .openURL,
                    description: "Open an unrelated site.",
                    targetURL: "https://example.com/page"
                )
            ]
        )
        let runner = AgentRunner(
            planner: StaticPlanner(plan: plan),
            executor: makeExecutor(root: root),
            logStore: logStore
        )
        let scope = TaskWorkspaceScope.scoped(
            WorkspaceScope(workspace: StoredWorkspace(name: "Research", apps: [], urls: ["https://github.com"]))
        )

        let prepared = try await runner.prepare(command: "Open example.com")
        let request = try runner.approvalRequest(for: prepared, logAssessment: true, scope: scope, context: approvalContext(for: prepared))

        #expect(request.assessment.effectiveTier == .tier3)
        #expect(request.requirement == .autoRun)
        #expect(request.assessment.escalations.map(\.consequence) == [.advisory])
        #expect(request.assessment.scopeVerdict == .outOfScope)
        #expect(logStore.events.contains { event in
            event.phase == .risk
                && event.message == "risk.escalated: Tier 1 -> Tier 3: example.com is not part of the Research workspace."
        })
        // The pre-existing summary event still fires alongside it, unchanged.
        #expect(logStore.events.contains { event in
            event.phase == .risk && event.message.hasPrefix("risk.assessed:")
        })
    }

    /// The inverse, at the same level: an unscoped run of the identical plan must stay exactly as it
    /// was — no scope escalation, no scope trace line, and the ordinary auto-run requirement.
    @Test
    func theSamePlanUnscopedLogsNoScopeEventAndKeepsItsOriginalRequirement() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let logStore = AgentLogStore()
        let plan = AgentPlan(
            summary: "Open a site.",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "open",
                    operation: .openURL,
                    description: "Open an unrelated site.",
                    targetURL: "https://example.com/page"
                )
            ]
        )
        let runner = AgentRunner(
            planner: StaticPlanner(plan: plan),
            executor: makeExecutor(root: root),
            logStore: logStore
        )

        let prepared = try await runner.prepare(command: "Open example.com")
        let request = try runner.approvalRequest(for: prepared, logAssessment: true, scope: .unscoped, context: approvalContext(for: prepared))

        #expect(request.assessment.scopeVerdict == nil)
        #expect(request.assessment.escalations.isEmpty)
        #expect(request.assessment.effectiveTier == .tier1)
        #expect(logStore.events.allSatisfy { !$0.message.contains("not part of") })
    }

    @Test
    func staleTierTwoApprovalDoesNotAuthorizeLaterTierThreeEscalation() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("small", to: root.appendingPathComponent("small.txt"))
        try write(String(repeating: "x", count: 2048), to: root.appendingPathComponent("large.txt"))
        let output = root.appendingPathComponent("largest.zip")
        let zipArchiver = RecordingZipArchiver()
        let runner = AgentRunner(
            planner: StaticPlanner(plan: largestPlan(root: root, output: output)),
            executor: makeExecutor(root: root, zipArchiver: zipArchiver)
        )

        let prepared = try await runner.prepare(command: "Zip the largest files")
        let originalRequest = try runner.approvalRequest(for: prepared, scope: .unscoped, context: approvalContext(for: prepared))
        try write("appeared after approval", to: output)

        do {
            _ = try await runner.execute(
                prepared,
                approvalDecision: .approved(originalRequest.assessment.effectiveTier),
                confirmationMessage: "User approved Tier 2 action",
                scope: .unscoped,
                context: approvalContext(for: prepared)
            )
            Issue.record("Expected later escalation to require a fresh approval.")
        } catch RiskApprovalError.approvalRequired(let newRequest) {
            #expect(originalRequest.assessment.effectiveTier == .tier2)
            #expect(newRequest.assessment.effectiveTier == .tier3)
            #expect(newRequest.requirement == .explicitApproval)
        } catch {
            Issue.record("Expected approvalRequired, got \(error).")
        }

        #expect(zipArchiver.createdArchives.isEmpty)
    }

    /// SONNY-62, reproduced at the runner: the approval names one tier-3 reason, a *different*
    /// tier-3 reason lands while the prompt sits open, and the guard's tier comparison passes.
    ///
    /// The observed run this is built from (2026-08-06) approved an out-of-scope destination and
    /// then silently replaced a file that appeared in the meantime. Both halves are here — the scope
    /// escalation the user answered, and the already-exists escalation they never saw — because the
    /// bug needs exactly that pair to show itself: one reason each, same tier, disjoint causes.
    @Test
    func anApprovalForOneTierThreeReasonDoesNotAuthorizeADifferentTierThreeReason() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("small", to: root.appendingPathComponent("small.txt"))
        try write(String(repeating: "x", count: 2048), to: root.appendingPathComponent("large.txt"))
        let output = root.appendingPathComponent("largest.zip")
        let zipArchiver = RecordingZipArchiver()
        let browserOpener = RecordingBrowserOpener()
        let logStore = AgentLogStore()
        let runner = AgentRunner(
            planner: StaticPlanner(plan: zipAndOpenURLPlan(root: root, output: output, url: "https://example.com/page")),
            executor: makeExecutor(root: root, zipArchiver: zipArchiver, browserOpener: browserOpener),
            logStore: logStore
        )
        let scope = TaskWorkspaceScope.scoped(
            WorkspaceScope(workspace: StoredWorkspace(name: "Research", apps: [], urls: ["https://github.com"]))
        )

        let prepared = try await runner.prepare(command: "Zip the largest files and open the site")
        let answered = try runner.approvalRequest(for: prepared, scope: scope, context: approvalContext(for: prepared))

        // The prompt the user actually read named one reason, and it was not the file.
        #expect(answered.assessment.effectiveTier == .tier3)
        #expect(answered.assessment.escalations.map(\.reason) == [
            "example.com is not part of the Research workspace."
        ])

        // The drift — the same `touch` the manual pass performed while the panel was open.
        try write("appeared while the prompt was open", to: output)

        do {
            _ = try await runner.execute(
                prepared,
                approvalDecision: .approved(answering: answered),
                confirmationMessage: "User approved Tier 3 action",
                scope: scope,
                context: approvalContext(for: prepared)
            )
            Issue.record("Expected the unseen second reason to re-arm the approval.")
        } catch RiskApprovalError.approvalRequired(let rearmed) {
            // Equal tiers — which is precisely why the old guard let this through.
            #expect(rearmed.assessment.effectiveTier == answered.assessment.effectiveTier)
            #expect(rearmed.requirement == .explicitApproval)
            #expect(Set(rearmed.assessment.escalations.map(\.reason)) == [
                "Zip output already exists at \(output.path).",
                "example.com is not part of the Research workspace."
            ])
        } catch {
            Issue.record("Expected approvalRequired, got \(error).")
        }

        // Nothing ran: not the archive the user never consented to replacing, and not the site
        // whose approval was being borrowed.
        #expect(zipArchiver.createdArchives.isEmpty)
        #expect(browserOpener.openedURLs.isEmpty)
        #expect(try String(contentsOf: output, encoding: .utf8) == "appeared while the prompt was open")
        // The trace names the reason that was not covered, and only that one — an approval re-armed
        // for a reason nobody logs is the same invisible failure in a quieter form.
        #expect(logStore.events.contains { event in
            event.phase == .risk
                && event.message == "risk.rearmed: reasons not covered by the approval: Zip output already exists at \(output.path)."
        })
    }

    /// The negative half of the test above: `risk.rearmed` is a claim that a *consent* was exceeded,
    /// so the very first prompt for a tier-3 action must not carry it — nobody had approved anything
    /// yet for the drift to have escaped.
    ///
    /// `AgentRunner.execute`'s gate reaches the same `else` branch for `.notRequested` as for a
    /// consent that fell short, and the only thing telling those apart is the `if case .approved`
    /// binding around the trace. Nothing pinned that until this test: PR #46's review ran a ninth
    /// mutation emitting the line on the `.notRequested` path too — so every ordinary first-time
    /// approval logs a re-arm that never happened — and it survived the whole suite.
    ///
    /// **The assertion only means something on a denial that carries reasons.** A tier-2
    /// `.notRequested` denial raises no escalations at all, so that mutation logs nothing there
    /// either and a test built on one would pass against both trees. Hence an already-existing
    /// output: tier 3, one reason, and no consent in hand.
    @Test
    func aFirstTimeApprovalPromptIsNotTracedAsAReArm() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("small", to: root.appendingPathComponent("small.txt"))
        try write(String(repeating: "x", count: 2048), to: root.appendingPathComponent("large.txt"))
        let output = root.appendingPathComponent("largest.zip")
        try write("existing zip", to: output)
        let zipArchiver = RecordingZipArchiver()
        let logStore = AgentLogStore()
        let runner = AgentRunner(
            planner: StaticPlanner(plan: largestPlan(root: root, output: output)),
            executor: makeExecutor(root: root, zipArchiver: zipArchiver),
            logStore: logStore
        )

        let prepared = try await runner.prepare(command: "Zip the largest files")
        let request = try runner.approvalRequest(for: prepared, scope: .unscoped, context: approvalContext(for: prepared))
        // Reasons exist to be mislabelled. Without this the expectation below is vacuous.
        #expect(request.assessment.effectiveTier == .tier3)
        #expect(request.assessment.escalations.map(\.reason) == [
            "Zip output already exists at \(output.path)."
        ])

        do {
            _ = try await runner.execute(prepared, scope: .unscoped, context: approvalContext(for: prepared))
            Issue.record("Expected the tier-3 assessment to require approval.")
        } catch RiskApprovalError.approvalRequired(let denied) {
            #expect(denied.requirement == .explicitApproval)
        } catch {
            Issue.record("Expected approvalRequired, got \(error).")
        }

        // The gate ran, and it wrote to *this* store — otherwise the absence below would only prove
        // the runner was logging somewhere else.
        #expect(logStore.events.contains { event in
            event.phase == .confirm && event.message == "Approval required for Tier 3"
        })
        #expect(!logStore.events.contains { $0.message.hasPrefix("risk.rearmed") })
        #expect(zipArchiver.createdArchives.isEmpty)
        #expect(try String(contentsOf: output, encoding: .utf8) == "existing zip")
    }

    /// The re-arm is one extra question, not a loop: the fresh prompt carries the new reason, and
    /// answering *that* one executes.
    @Test
    func answeringTheReArmedPromptExecutesRatherThanReArmingAgain() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("small", to: root.appendingPathComponent("small.txt"))
        try write(String(repeating: "x", count: 2048), to: root.appendingPathComponent("large.txt"))
        let output = root.appendingPathComponent("largest.zip")
        let zipArchiver = RecordingZipArchiver()
        let browserOpener = RecordingBrowserOpener()
        let runner = AgentRunner(
            planner: StaticPlanner(plan: zipAndOpenURLPlan(root: root, output: output, url: "https://example.com/page")),
            executor: makeExecutor(root: root, zipArchiver: zipArchiver, browserOpener: browserOpener)
        )
        let scope = TaskWorkspaceScope.scoped(
            WorkspaceScope(workspace: StoredWorkspace(name: "Research", apps: [], urls: ["https://github.com"]))
        )

        let prepared = try await runner.prepare(command: "Zip the largest files and open the site")
        let answered = try runner.approvalRequest(for: prepared, scope: scope, context: approvalContext(for: prepared))
        try write("appeared while the prompt was open", to: output)

        var rearmed: RiskApprovalRequest?
        do {
            _ = try await runner.execute(prepared, approvalDecision: .approved(answering: answered), scope: scope, context: approvalContext(for: prepared))
            Issue.record("Expected the unseen second reason to re-arm the approval.")
        } catch RiskApprovalError.approvalRequired(let request) {
            rearmed = request
        }

        let secondAnswer = try #require(rearmed)
        let result = try await runner.execute(
            prepared,
            approvalDecision: .approved(answering: secondAnswer),
            scope: scope,
            context: approvalContext(for: prepared)
        )

        #expect(result.summary.isEmpty == false)
        #expect(zipArchiver.createdArchives.count == 1)
        #expect(browserOpener.openedURLs.map(\.absoluteString) == ["https://example.com/page"])
    }

    /// Subset, not equality — a reason that *went away* is strictly less than what was consented to,
    /// so re-asking would be a prompt with nothing new in it.
    @Test
    func anApprovalStillCoversAnAssessmentWhoseReasonDisappeared() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("small", to: root.appendingPathComponent("small.txt"))
        try write(String(repeating: "x", count: 2048), to: root.appendingPathComponent("large.txt"))
        let output = root.appendingPathComponent("largest.zip")
        try write("existing zip", to: output)
        let zipArchiver = RecordingZipArchiver()
        let browserOpener = RecordingBrowserOpener()
        let runner = AgentRunner(
            planner: StaticPlanner(plan: zipAndOpenURLPlan(root: root, output: output, url: "https://example.com/page")),
            executor: makeExecutor(root: root, zipArchiver: zipArchiver, browserOpener: browserOpener)
        )
        let scope = TaskWorkspaceScope.scoped(
            WorkspaceScope(workspace: StoredWorkspace(name: "Research", apps: [], urls: ["https://github.com"]))
        )

        let prepared = try await runner.prepare(command: "Zip the largest files and open the site")
        let answered = try runner.approvalRequest(for: prepared, scope: scope, context: approvalContext(for: prepared))
        #expect(Set(answered.assessment.escalations.map(\.reason)) == [
            "Zip output already exists at \(output.path).",
            "example.com is not part of the Research workspace."
        ])

        // The file is gone by execution time, so the replace reason no longer applies.
        try FileManager.default.removeItem(at: output)

        _ = try await runner.execute(prepared, approvalDecision: .approved(answering: answered), scope: scope, context: approvalContext(for: prepared))

        #expect(zipArchiver.createdArchives.count == 1)
        #expect(browserOpener.openedURLs.map(\.absoluteString) == ["https://example.com/page"])
    }

    /// The pre-SONNY-62 escalation case, on the decision shape the app actually writes back now: a
    /// tier-2 prompt the user answered still does not authorize a tier-3 escalation that lands
    /// afterwards.
    ///
    /// It does *not* isolate the tier half of the guard, and the mutation battery is what proved
    /// that rather than the reading: with the tier ceiling deleted from `authorizes(_:)`, this test
    /// still passes. The reason is structural — a fixed plan's default tier cannot move, so at this
    /// level a tier only ever rises *by* an escalation, and the escalation's reason arrives in the
    /// same assessment. The tier half is isolated by `staleTierTwoApprovalDoesNotAuthorize...`
    /// above, which approves a standing grant that has no reason check at all, and by
    /// `RiskApprovalTests.aHigherTierIsNeverAuthorizedAndALowerOneStillIs`, which can pin a tier and
    /// a reason set independently because it builds the assessment directly.
    @Test
    func aTierTwoPromptAnsweredByTheUserDoesNotAuthorizeALaterTierThreeEscalation() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("small", to: root.appendingPathComponent("small.txt"))
        try write(String(repeating: "x", count: 2048), to: root.appendingPathComponent("large.txt"))
        let output = root.appendingPathComponent("largest.zip")
        let zipArchiver = RecordingZipArchiver()
        let runner = AgentRunner(
            planner: StaticPlanner(plan: largestPlan(root: root, output: output)),
            executor: makeExecutor(root: root, zipArchiver: zipArchiver)
        )

        let prepared = try await runner.prepare(command: "Zip the largest files")
        let answered = try runner.approvalRequest(for: prepared, scope: .unscoped, context: approvalContext(for: prepared))
        #expect(answered.assessment.effectiveTier == .tier2)
        #expect(answered.assessment.escalations.isEmpty)

        try write("appeared after approval", to: output)

        do {
            _ = try await runner.execute(
                prepared,
                approvalDecision: .approved(answering: answered),
                confirmationMessage: "User approved Tier 2 action",
                scope: .unscoped,
                context: approvalContext(for: prepared)
            )
            Issue.record("Expected later escalation to require a fresh approval.")
        } catch RiskApprovalError.approvalRequired(let rearmed) {
            #expect(rearmed.assessment.effectiveTier == .tier3)
            #expect(rearmed.requirement == .explicitApproval)
        } catch {
            Issue.record("Expected approvalRequired, got \(error).")
        }

        #expect(zipArchiver.createdArchives.isEmpty)
    }

    @Test
    func existingHackerNewsMarkdownOutputEscalatesToTierThree() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("hn.md")
        try write("existing markdown", to: output)
        let runner = AgentRunner(
            planner: StaticPlanner(plan: hnPlan(output: output)),
            executor: makeExecutor(root: root)
        )

        let prepared = try await runner.prepare(command: "Save Hacker News to Markdown")
        let request = try runner.approvalRequest(for: prepared, scope: .unscoped, context: approvalContext(for: prepared))

        #expect(request.assessment.defaultTier == .tier2)
        #expect(request.assessment.effectiveTier == .tier3)
        #expect(request.requirement == .explicitApproval)
        #expect(request.assessment.escalations.first?.reason == "Markdown output already exists at \(output.path).")
    }

    @Test
    func existingWebResearchMarkdownOutputEscalatesAndMarksDataLeavingDevice() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("web.md")
        try write("existing markdown", to: output)
        let runner = AgentRunner(
            planner: StaticPlanner(plan: webMarkdownPlan(output: output)),
            executor: makeExecutor(root: root)
        )

        let prepared = try await runner.prepare(command: "Summarize this article as Markdown")
        let request = try runner.approvalRequest(for: prepared, scope: .unscoped, context: approvalContext(for: prepared))

        #expect(request.assessment.defaultTier == .tier2)
        #expect(request.assessment.effectiveTier == .tier3)
        #expect(request.requirement == .explicitApproval)
        #expect(request.approvalCopy.dataLeavesDevice == true)
        #expect(request.assessment.escalations.first?.reason == "Markdown output already exists at \(output.path).")
    }

    @Test
    func existingWebSearchMarkdownOutputUsesWebResearchRiskPath() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("search.md")
        try write("existing markdown", to: output)
        let runner = AgentRunner(
            planner: StaticPlanner(plan: webSearchPlan(output: output)),
            executor: makeExecutor(root: root)
        )

        let prepared = try await runner.prepare(command: "Research Swift concurrency as Markdown")
        let request = try runner.approvalRequest(for: prepared, scope: .unscoped, context: approvalContext(for: prepared))

        #expect(request.assessment.defaultTier == .tier2)
        #expect(request.assessment.effectiveTier == .tier3)
        #expect(request.requirement == .explicitApproval)
        #expect(request.approvalCopy.dataLeavesDevice == true)
        #expect(request.approvalCopy.involvedResource.contains("Search: Swift concurrency"))
        #expect(request.assessment.escalations.first?.reason == "Markdown output already exists at \(output.path).")
    }

    @Test
    func existingLocalDraftOutputEscalatesToTierThree() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("draft.md")
        try write("existing draft", to: output)
        let runner = AgentRunner(
            planner: StaticPlanner(plan: localDraftPlan(output: output)),
            executor: makeExecutor(root: root)
        )

        let prepared = try await runner.prepare(command: "Create a local draft")
        let request = try runner.approvalRequest(for: prepared, scope: .unscoped, context: approvalContext(for: prepared))

        #expect(request.assessment.defaultTier == .tier2)
        #expect(request.assessment.effectiveTier == .tier3)
        #expect(request.requirement == .explicitApproval)
        #expect(request.approvalCopy.dataLeavesDevice == false)
        #expect(request.assessment.escalations.first?.reason == "Draft output already exists at \(output.path).")
    }

    @Test
    func replacingExistingRoutineEscalatesToTierThree() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let routineStore = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))
        try routineStore.save(StoredRoutine(name: "Morning Setup", steps: [openAppStep(id: "existing-open")]))
        let runner = AgentRunner(
            planner: StaticPlanner(plan: saveRoutinePlan(name: "Morning Setup")),
            executor: makeExecutor(root: root, routineStore: routineStore)
        )

        let prepared = try await runner.prepare(command: "Teach my morning setup")
        let request = try runner.approvalRequest(for: prepared, scope: .unscoped, context: approvalContext(for: prepared))

        #expect(request.assessment.effectiveTier == .tier3)
        #expect(request.requirement == .explicitApproval)
        #expect(request.assessment.escalations.first?.reason == "Routine named Morning Setup already exists and would be replaced.")
    }

    @Test
    func replacingExistingWorkspaceEscalatesToTierThree() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaceStore = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        try workspaceStore.save(StoredWorkspace(name: "Research", apps: ["Safari"], urls: []))
        let runner = AgentRunner(
            planner: StaticPlanner(plan: createWorkspacePlan(name: "Research")),
            executor: makeExecutor(root: root, workspaceStore: workspaceStore)
        )

        let prepared = try await runner.prepare(command: "Create a research workspace")
        let request = try runner.approvalRequest(for: prepared, scope: .unscoped, context: approvalContext(for: prepared))

        #expect(request.assessment.effectiveTier == .tier3)
        #expect(request.requirement == .explicitApproval)
        #expect(request.assessment.escalations.first?.reason == "Workspace named Research already exists and would be replaced.")
    }

    @Test
    func docxExistingPDFSkipDoesNotEscalate() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("docx", to: root.appendingPathComponent("a.docx"))
        try write("existing pdf", to: root.appendingPathComponent("a.pdf"))
        let runner = AgentRunner(
            planner: StaticPlanner(plan: docxPlan(root: root)),
            executor: makeExecutor(root: root, documentConverter: FakeDocumentConverter())
        )

        let prepared = try await runner.prepare(command: "Convert DOCX files")
        let request = try runner.approvalRequest(for: prepared, scope: .unscoped, context: approvalContext(for: prepared))

        #expect(request.assessment.defaultTier == .tier2)
        #expect(request.assessment.effectiveTier == .tier2)
        #expect(request.assessment.escalations.isEmpty)
        #expect(request.requirement == .autoRun)
    }

    @Test
    func mediaOpenTierOneAutoRunsWithoutApprovalDecision() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let mediaOpener = FakeMediaOpener()
        let runner = AgentRunner(
            planner: StaticPlanner(plan: mediaPlan()),
            executor: makeExecutor(root: root, mediaOpener: mediaOpener)
        )

        let prepared = try await runner.prepare(command: "Open Bad Habit on Apple Music")
        let request = try runner.approvalRequest(for: prepared, scope: .unscoped, context: approvalContext(for: prepared))
        let result = try await runner.execute(prepared, scope: .unscoped, context: approvalContext(for: prepared))

        #expect(request.assessment.effectiveTier == .tier1)
        #expect(request.assessment.escalations.isEmpty)
        #expect(request.requirement == .autoRun)
        #expect(mediaOpener.requests == [
            MediaPlaybackRequest(provider: .appleMusic, title: "Bad Habit", artist: "Steve Lacy")
        ])
        #expect(result.summary == "Apple Music playback unavailable (authorization): Apple Music playback provider not configured. Fallback result: Opened Bad Habit by Steve Lacy in Apple Music.")
    }

    @Test
    func finderSelectionTierZeroAutoRunsWithoutApprovalDecision() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let selected = root.appendingPathComponent("selected.txt")
        try write("selected", to: selected)
        let runner = AgentRunner(
            planner: StaticPlanner(plan: finderSelectionPlan()),
            executor: makeExecutor(
                root: root,
                finderContextReader: FakeFinderContextReader(selection: [selected])
            )
        )

        let prepared = try await runner.prepare(command: "What is selected in Finder?")
        let request = try runner.approvalRequest(for: prepared, scope: .unscoped, context: approvalContext(for: prepared))
        let result = try await runner.execute(prepared, scope: .unscoped, context: approvalContext(for: prepared))

        #expect(request.assessment.effectiveTier == .tier0)
        #expect(request.requirement == .autoRun)
        #expect(result.summary == "Selected in Finder: selected.txt.")
    }

    @Test
    func revealInFinderTierOneAutoRunsWithoutApprovalDecision() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let missingPath = root.appendingPathComponent("future-output.zip")
        let runner = AgentRunner(
            planner: StaticPlanner(plan: revealPlan(path: missingPath)),
            executor: makeExecutor(root: root)
        )

        let prepared = try await runner.prepare(command: "Reveal the output in Finder")
        let request = try runner.approvalRequest(for: prepared, scope: .unscoped, context: approvalContext(for: prepared))

        do {
            _ = try await runner.execute(prepared, scope: .unscoped, context: approvalContext(for: prepared))
            Issue.record("Expected reveal execution to reach the adapter and reject the missing path.")
        } catch PathValidationError.notFound(let path) {
            #expect(path == missingPath.path)
        } catch {
            Issue.record("Expected missing path after auto-run gating, got \(error).")
        }

        #expect(request.assessment.effectiveTier == .tier1)
        #expect(request.requirement == .autoRun)
    }

    @Test
    func openWorkspaceTierOneAutoRunsWithoutApprovalDecision() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaceStore = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        try workspaceStore.save(StoredWorkspace(name: "Research", apps: ["Safari"], urls: ["https://github.com"]))
        let appOpener = RecordingAppOpener()
        let browserOpener = RecordingBrowserOpener()
        let runner = AgentRunner(
            planner: StaticPlanner(plan: openWorkspacePlan(name: "Research")),
            executor: makeExecutor(
                root: root,
                browserOpener: browserOpener,
                appOpener: appOpener,
                workspaceStore: workspaceStore
            )
        )

        let prepared = try await runner.prepare(command: "Open my research workspace")
        let request = try runner.approvalRequest(for: prepared, scope: .unscoped, context: approvalContext(for: prepared))
        let result = try await runner.execute(prepared, scope: .unscoped, context: approvalContext(for: prepared))

        #expect(request.assessment.effectiveTier == .tier1)
        #expect(request.requirement == .autoRun)
        #expect(appOpener.openedBundleIDs == ["com.apple.Safari"])
        #expect(browserOpener.openedURLs.map(\.absoluteString) == ["https://github.com"])
        // Browser targeting survives the full prepare/assess/approve path, not just direct execution.
        #expect(browserOpener.openedBrowsers.map { $0?.bundleIdentifier } == ["com.apple.Safari"])
        #expect(result.summary == "Opened workspace Research with 1 app(s) and 1 URL(s).")
    }

    @Test
    func runRoutineTierTwoAutoRunsItsNestedExecutionUnderTheConsequenceRule() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let routineStore = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))
        try routineStore.save(StoredRoutine(name: "Morning Setup", steps: [openAppStep(id: "open-safari")]))
        let appOpener = RecordingAppOpener()
        let runner = AgentRunner(
            planner: StaticPlanner(plan: runRoutinePlan(name: "Morning Setup")),
            executor: makeExecutor(root: root, appOpener: appOpener, routineStore: routineStore)
        )

        let prepared = try await runner.prepare(command: "Run my morning setup")
        let request = try runner.approvalRequest(for: prepared, scope: .unscoped, context: approvalContext(for: prepared))

        // Consequence rule (2026-08-13): a tier-2 routine with nothing destructive in it runs
        // without asking — trusted or not — and the nested execution really happens. The
        // destructive nested pause keeps its own coverage in
        // `runRoutineRiskAssessmentFoldsNestedEscalations` below.
        #expect(request.assessment.effectiveTier == .tier2)
        #expect(request.requirement == .autoRun)

        let result = try await runner.execute(
            prepared,
            scope: .unscoped,
            context: approvalContext(for: prepared)
        )

        #expect(appOpener.openedBundleIDs == ["com.apple.Safari"])
        #expect(result.summary == "Ran routine Morning Setup. Opened the Safari app.")
    }

    @Test
    func runRoutineRiskAssessmentFoldsNestedEscalations() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("small", to: root.appendingPathComponent("small.txt"))
        try write(String(repeating: "x", count: 2048), to: root.appendingPathComponent("large.txt"))
        let output = root.appendingPathComponent("routine-largest.zip")
        try write("existing zip", to: output)
        let routineStore = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))
        try routineStore.save(StoredRoutine(name: "Archive Big Files", steps: largestPlan(root: root, output: output).steps))
        let zipArchiver = RecordingZipArchiver()
        let logStore = AgentLogStore()
        let runner = AgentRunner(
            planner: StaticPlanner(plan: runRoutinePlan(name: "Archive Big Files")),
            executor: makeExecutor(root: root, zipArchiver: zipArchiver, routineStore: routineStore),
            logStore: logStore
        )

        let prepared = try await runner.prepare(command: "Run my archive routine")
        let request = try runner.approvalRequest(for: prepared, logAssessment: true, scope: .unscoped, context: approvalContext(for: prepared))

        #expect(request.assessment.defaultTier == .tier2)
        #expect(request.assessment.effectiveTier == .tier3)
        #expect(request.requirement == .explicitApproval)
        #expect(request.assessment.escalations == [
            CapabilityRiskEscalation(
                fromTier: .tier2,
                toTier: .tier3,
                reason: "Zip output already exists at \(output.path).",
                consequence: .destructive
            )
        ])
        #expect(logStore.events.contains { event in
            event.phase == .risk && event.message.contains("risk.escalated")
        })

        do {
            _ = try await runner.execute(
                prepared,
                approvalDecision: .approved(.tier2),
                confirmationMessage: "Stale approval",
                scope: .unscoped,
                context: approvalContext(for: prepared)
            )
            Issue.record("Expected nested routine escalation to require explicit approval.")
        } catch RiskApprovalError.approvalRequired(let approvalRequest) {
            #expect(approvalRequest.assessment.effectiveTier == .tier3)
        } catch {
            Issue.record("Expected approvalRequired, got \(error).")
        }

        #expect(zipArchiver.createdArchives.isEmpty)
    }

    @Test
    func saveRoutineRiskAssessmentFoldsNestedEscalations() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("small", to: root.appendingPathComponent("small.txt"))
        try write(String(repeating: "x", count: 2048), to: root.appendingPathComponent("large.txt"))
        let output = root.appendingPathComponent("routine-largest.zip")
        try write("existing zip", to: output)
        let routineStore = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))
        let zipArchiver = RecordingZipArchiver()
        let runner = AgentRunner(
            planner: StaticPlanner(plan: saveRoutinePlanWithNestedZip(name: "Archive Big Files", root: root, output: output)),
            executor: makeExecutor(root: root, zipArchiver: zipArchiver, routineStore: routineStore)
        )

        let prepared = try await runner.prepare(command: "Teach Sonny a routine that zips the largest files")
        let request = try runner.approvalRequest(for: prepared, logAssessment: true, scope: .unscoped, context: approvalContext(for: prepared))

        #expect(request.assessment.defaultTier == .tier2)
        #expect(request.assessment.effectiveTier == .tier3)
        #expect(request.requirement == .explicitApproval)
        // SONNY-33 reframed this sentence and deliberately left everything around it alone: same
        // tiers, same `.destructive` class, same prompt. The reason now says when the overwrite
        // would happen, because it is not this save that would do it.
        #expect(request.assessment.escalations.contains(
            CapabilityRiskEscalation(
                fromTier: .tier2,
                toTier: .tier3,
                reason: "When run, this routine will need approval: Zip output already exists at \(output.path).",
                consequence: .destructive
            )
        ))

        do {
            _ = try await runner.execute(
                prepared,
                approvalDecision: .approved(.tier2),
                confirmationMessage: "Stale approval",
                scope: .unscoped,
                context: approvalContext(for: prepared)
            )
            Issue.record("Expected nested save-routine escalation to require explicit approval.")
        } catch RiskApprovalError.approvalRequired(let approvalRequest) {
            #expect(approvalRequest.assessment.effectiveTier == .tier3)
        } catch {
            Issue.record("Expected approvalRequired, got \(error).")
        }

        #expect(try routineStore.loadAll().isEmpty)
    }

    /// The chain is assessed and gated as ONE unit before any segment executes. The fixture's
    /// pause moved to what still asks under the consequence rule — the zip output pre-exists, so
    /// the whole chain carries a destructive escalation — and the claim is unchanged: neither the
    /// archive nor the reveal happens until the one approval is answered, and answering it runs
    /// both segments.
    @Test
    func zipThenRevealChainIsRiskAssessedAndGatedAsOneUnit() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("small", to: root.appendingPathComponent("small.txt"))
        try write(String(repeating: "x", count: 2048), to: root.appendingPathComponent("large.txt"))
        let output = root.appendingPathComponent("largest.zip")
        try write("existing zip", to: output)
        let marker = root.appendingPathComponent("revealed-marker.txt")
        let zipArchiver = RecordingZipArchiver()
        let registry = try CapabilityRegistry(adapters: [
            LargestFilesZipCapabilityAdapter(),
            RecordingRevealInFinderAdapter(markerURL: marker)
        ])
        let runner = AgentRunner(
            planner: StaticPlanner(plan: zipThenRevealPlan(root: root, output: output)),
            executor: makeExecutor(root: root, zipArchiver: zipArchiver, capabilityRegistry: registry)
        )

        let prepared = try await runner.prepare(command: "Zip the largest files and reveal the zip")
        let request = try runner.approvalRequest(for: prepared, scope: .unscoped, context: approvalContext(for: prepared))

        do {
            _ = try await runner.execute(prepared, scope: .unscoped, context: approvalContext(for: prepared))
            Issue.record("Expected zip plus reveal chain to require one approval before any segment executes.")
        } catch RiskApprovalError.approvalRequired(let approvalRequest) {
            #expect(approvalRequest.assessment.effectiveTier == .tier3)
            #expect(approvalRequest.requirement == .explicitApproval)
        } catch {
            Issue.record("Expected approvalRequired, got \(error).")
        }

        #expect(request.assessment.effectiveTier == .tier3)
        #expect(request.requirement == .explicitApproval)
        #expect(zipArchiver.createdArchives.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: marker.path))

        let result = try await runner.execute(
            prepared,
            approvalDecision: .approved(answering: request),
            scope: .unscoped,
            context: approvalContext(for: prepared)
        )

        #expect(zipArchiver.createdArchives == [output])
        #expect(FileManager.default.fileExists(atPath: output.path))
        #expect(try String(contentsOf: marker, encoding: .utf8) == output.path)
        // Three files, not two: the pre-existing zip that carries the destructive escalation is
        // itself the third file the scan finds.
        #expect(result.summary == "Created largest.zip with 3 largest files from \(root.path). Revealed \(output.path) in Finder.")
    }

    /// **SONNY-33's defect, at the sentence a user reads** (founder decision 2026-08-04, option (a)).
    ///
    /// The fold above is true at assessment time and attributed to the wrong action: a save writes
    /// `routines.json` and nothing else, so "Draft output already exists at …/weekly.md." described a
    /// file this button would not touch. Asserted through `AgentRunner.approvalRequest` rather than
    /// the adapter, because the framing only matters where it is rendered, and this is the call the
    /// widget and Command Center panels both read from.
    ///
    /// The negative half is the point of the test. The bare sentence must be *gone*, not merely
    /// accompanied — a fix that appended an advisory beside the original save-attributed wording
    /// would satisfy a `contains` check on the new string and leave the defect on screen.
    @Test
    func aNestedCollisionIsFramedAsWhenRunRatherThanAsTheSaveOwnRisk() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let draftOutput = root.appendingPathComponent("weekly.md")
        try write("last week's note", to: draftOutput)
        let routineStore = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))
        let runner = AgentRunner(
            planner: StaticPlanner(
                plan: saveRoutinePlanWithNestedDraft(name: "Weekly Note", output: draftOutput)
            ),
            executor: makeExecutor(root: root, routineStore: routineStore)
        )

        let prepared = try await runner.prepare(command: "Teach Sonny a routine that drafts my weekly note")
        let request = try runner.approvalRequest(for: prepared, logAssessment: true, scope: .unscoped, context: approvalContext(for: prepared))

        #expect(request.assessment.escalations.map(\.reason) == [
            "When run, this routine will need approval: Draft output already exists at \(draftOutput.path)."
        ])
        // The save-attributed framing is gone rather than joined by a second sentence.
        let rendered = request.assessment.escalations.map(\.reason).joined(separator: " ")
        #expect(!rendered.hasPrefix("Draft output already exists"))

        // Tier math and prompt unchanged by the reframe — the advisory keeps its teeth.
        #expect(request.assessment.defaultTier == .tier2)
        #expect(request.assessment.effectiveTier == .tier3)
        #expect(request.requirement == .explicitApproval)
        #expect(request.assessment.escalations.allSatisfy { $0.consequence == .destructive })
    }

    /// The other side of the same line: the save *does* have one risk of its own — replacing a
    /// routine the user already built — and that sentence is correctly attributed already. A reframe
    /// applied one line lower, or to the whole list instead of the folded part, would tell the user
    /// that replacing this routine is something that happens later. It happens when they press the
    /// button.
    @Test
    func theSaveOwnReplacementWarningKeepsItsOwnFrameBesideAReframedNestedOne() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let draftOutput = root.appendingPathComponent("weekly.md")
        try write("last week's note", to: draftOutput)
        let routineStore = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))
        try routineStore.save(StoredRoutine(name: "Weekly Note", steps: [openAppStep(id: "open-safari")]))
        let runner = AgentRunner(
            planner: StaticPlanner(
                plan: saveRoutinePlanWithNestedDraft(name: "Weekly Note", output: draftOutput)
            ),
            executor: makeExecutor(root: root, routineStore: routineStore)
        )

        let prepared = try await runner.prepare(command: "Teach Sonny a routine that drafts my weekly note")
        let request = try runner.approvalRequest(for: prepared, logAssessment: true, scope: .unscoped, context: approvalContext(for: prepared))

        #expect(request.assessment.escalations.map(\.reason) == [
            "When run, this routine will need approval: Draft output already exists at \(draftOutput.path).",
            "Routine named Weekly Note already exists and would be replaced."
        ])
    }

    /// **SONNY-73 over the real two-phase dispatch, which is where its fix could break SONNY-59.**
    ///
    /// `AgentRunner.prepare` resolves the plan and hands the *resolved* plan to `approvalRequest`,
    /// which resolves it again — so `FinderSelectionResolver.pinningSelectedDirectoryInput` runs
    /// twice over one run, and on the second pass every matching step already carries the
    /// `inputPath` the first pass pinned from the live selection. A clearing rule keyed on "this
    /// resolution was satisfied from an explicit path" answers *true* on that second pass and
    /// deletes the Finder report from a run that genuinely did read the selection. Every existing
    /// test stays green while it happens, because they all call `assessRisk` once, on a raw plan.
    ///
    /// So the rule is keyed on the steps the pin *back-fills*, which is the one signal that
    /// distinguishes the two: in the genuine case the declaring step arrives with no path and is
    /// back-filled on the first pass and nothing is back-filled on the second, while in the pooled
    /// case the declaring step is the one being back-filled. This test is the guard on that.
    @Test
    func aSelectionDrivenZipStillReportsFinderThroughPrepareThenApproval() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Client", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write("contents", to: folder.appendingPathComponent("a.txt"))

        let reader = CountingFinderContextReader(selection: [folder])
        // The planner is never consulted: `prepare(plan:source:)` is the pre-built entry point.
        let runner = AgentRunner(
            planner: StaticPlanner(plan: selectionDrivenZipPlan()),
            executor: makeExecutor(root: root, finderContextReader: reader)
        )
        let scope = TaskWorkspaceScope.scoped(
            WorkspaceScope(
                workspace: StoredWorkspace(
                    name: "Client Alpha",
                    apps: ["Safari"],
                    urls: [],
                    fileLocations: [folder.path]
                ),
                whitelist: PathWhitelist(roots: [root])
            )
        )

        let prepared = try runner.prepare(plan: selectionDrivenZipPlan(), source: .planner)
        let request = try runner.approvalRequest(
            for: prepared,
            scope: scope,
            context: approvalContext(for: prepared)
        )

        #expect(reader.callCount >= 1, "a selection-driven plan must actually read the selection")
        #expect(request.assessment.escalations.map(\.reason) == ["Finder is not part of the Client Alpha workspace."])
        #expect(request.assessment.scopeVerdict == .outOfScope)
    }

    /// The same two-phase path for the shape SONNY-73 is actually about: a scan carrying an explicit
    /// folder beside a zip carrying only `contextSource`. Finder is never contacted, and the report
    /// has to stay absent across both resolutions rather than only the first.
    @Test
    func aPooledExplicitPathReportsNoFinderThroughPrepareThenApproval() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Client", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write("contents", to: folder.appendingPathComponent("a.txt"))
        let decoy = root.appendingPathComponent("Decoy", isDirectory: true)
        try FileManager.default.createDirectory(at: decoy, withIntermediateDirectories: true)

        // A counting reader rather than a plain fake: the decoy makes a read *visible in the
        // escalations*, which is a real signal but a consequence rather than the fact. The count is
        // the fact, and this test's whole claim is about it (SONNY-185, PR #79 coverage note 2).
        let reader = CountingFinderContextReader(selection: [decoy])
        let runner = AgentRunner(
            planner: StaticPlanner(plan: selectionDrivenZipPlan()),
            executor: makeExecutor(root: root, finderContextReader: reader)
        )
        let scope = TaskWorkspaceScope.scoped(
            WorkspaceScope(
                workspace: StoredWorkspace(
                    name: "Client Alpha",
                    apps: ["Safari"],
                    urls: [],
                    fileLocations: [folder.path]
                ),
                whitelist: PathWhitelist(roots: [root])
            )
        )
        let plan = AgentPlan(
            summary: "Zip the largest files in that folder.",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "scan",
                    operation: .scanSelectLargestFiles,
                    description: "Scan the folder.",
                    inputPath: folder.path,
                    count: 1
                ),
                AgentStep(
                    id: "zip",
                    operation: .createZip,
                    description: "Zip the selected folder.",
                    contextSource: .finderSelection
                )
            ]
        )

        let prepared = try runner.prepare(plan: plan, source: .planner)
        let request = try runner.approvalRequest(
            for: prepared,
            scope: scope,
            context: approvalContext(for: prepared)
        )

        #expect(reader.callCount == 0, "Finder was contacted for a plan satisfied from an explicit path")
        #expect(request.assessment.escalations.map(\.reason) == [])
        #expect(request.assessment.scopeVerdict == .inScope)
    }

    /// **SONNY-185's shape, over the same two-phase dispatch.** A single step carrying both the
    /// `contextSource` declaration *and* its own folder. `selectedDirectoryPath` returns
    /// `primary ?? secondary` before it so much as looks at `contextSource`, so the plan is
    /// satisfied from that folder and the Apple-Events reader is never called — and until this
    /// ticket the step kept its marker through both passes and `PlanScopedResources` named Finder
    /// for a run that never touched it. SONNY-73's clearing cannot reach it: that rule is keyed on
    /// the steps the pin *back-fills*, and this step is back-filled by nothing.
    ///
    /// The fix is a second field rather than a cleverer rule, because after the first pass this step
    /// and a genuine declaring step the pin filled in are byte-identical. Asserted three ways: the
    /// reader was never called, no Finder escalation survives either resolution, and the resolved
    /// plan carries no `resolvedFromFinderSelection` on the step that declared it.
    @Test
    func aDeclaringStepWithItsOwnFolderReportsNoFinderThroughPrepareThenApproval() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Client", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write("contents", to: folder.appendingPathComponent("a.txt"))
        let decoy = root.appendingPathComponent("Decoy", isDirectory: true)
        try FileManager.default.createDirectory(at: decoy, withIntermediateDirectories: true)

        // A selection is available and is deliberately not the folder the plan names, so a read that
        // happened would be visible in the escalations as well as in the count.
        let reader = CountingFinderContextReader(selection: [decoy])
        let runner = AgentRunner(
            planner: StaticPlanner(plan: selectionDrivenZipPlan()),
            executor: makeExecutor(root: root, finderContextReader: reader)
        )
        let plan = AgentPlan(
            summary: "Zip the largest files in the selected folder.",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "scan",
                    operation: .scanSelectLargestFiles,
                    description: "Scan the selected folder.",
                    inputPath: folder.path,
                    count: 1,
                    contextSource: .finderSelection
                ),
                AgentStep(
                    id: "zip",
                    operation: .createZip,
                    description: "Zip it.",
                    inputPath: folder.path,
                    outputPath: folder.appendingPathComponent("largest.zip").path
                )
            ]
        )

        let prepared = try runner.prepare(plan: plan, source: .planner)
        let request = try runner.approvalRequest(
            for: prepared,
            scope: Self.clientAlphaScope(root: root, folder: folder),
            context: approvalContext(for: prepared)
        )

        #expect(reader.callCount == 0, "Finder was contacted for a plan that named its own folder")
        #expect(request.assessment.escalations.map(\.reason) == [])
        #expect(request.assessment.scopeVerdict == .inScope)
        // The declaration survives — it is the planner's, and nothing here rewrites it. What is
        // absent is the resolver's fact, which is the half the classifier now requires.
        let scan = try #require(prepared.plan.steps.first { $0.id == "scan" })
        #expect(scan.contextSource == .finderSelection)
        #expect(scan.resolvedFromFinderSelection == nil)
    }

    /// The genuine selection, asserted on the pin itself rather than only on its consequence — the
    /// half that would be missing if `resolvedFromFinderSelection` were simply never written and
    /// everything below it silently passed for the wrong reason.
    @Test
    func aGenuineSelectionPinsTheFinderReadOntoEveryStepItBackFills() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Client", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write("contents", to: folder.appendingPathComponent("a.txt"))

        let reader = CountingFinderContextReader(selection: [folder])
        let runner = AgentRunner(
            planner: StaticPlanner(plan: selectionDrivenZipPlan()),
            executor: makeExecutor(root: root, finderContextReader: reader)
        )

        let prepared = try runner.prepare(plan: selectionDrivenZipPlan(), source: .planner)
        let request = try runner.approvalRequest(
            for: prepared,
            scope: Self.clientAlphaScope(root: root, folder: folder),
            context: approvalContext(for: prepared)
        )

        #expect(reader.callCount >= 1, "a selection-driven plan must actually read the selection")
        #expect(prepared.plan.steps.allSatisfy { $0.resolvedFromFinderSelection == true })
        #expect(prepared.plan.steps.allSatisfy { $0.inputPath == folder.path })
        #expect(request.assessment.escalations.map(\.reason) == ["Finder is not part of the Client Alpha workspace."])
        #expect(request.assessment.scopeVerdict == .outOfScope)
    }

    // MARK: - The docx pair, which shares every line of the resolver above
    //
    // `DocxConversionCapabilityAdapter.resolveDefaultOutputs` calls the same
    // `FinderSelectionResolver.pinningSelectedDirectoryInput` with `[.scanDocx, .convertDocxToPDF]`,
    // and `PlanScopedResources` routes all four operations through the same `finderSelectionApp`.
    // Every test written for SONNY-73 and every one above uses the zip pair, so a future change to
    // the pin could only ever be caught on one of its two callers (PR #79 cycle-1 review, coverage
    // note 1). These three are the docx counterparts, one per shape.

    /// The genuine selection, docx. Word is named because the converter drives it; Finder is named
    /// because the selection really was read.
    @Test
    func aSelectionDrivenDocxConversionStillReportsFinderThroughPrepareThenApproval() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Client", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write("contents", to: folder.appendingPathComponent("a.docx"))

        let reader = CountingFinderContextReader(selection: [folder])
        let runner = AgentRunner(
            planner: StaticPlanner(plan: selectionDrivenDocxPlan()),
            executor: makeExecutor(root: root, finderContextReader: reader)
        )

        let prepared = try runner.prepare(plan: selectionDrivenDocxPlan(), source: .planner)
        let request = try runner.approvalRequest(
            for: prepared,
            scope: Self.clientAlphaScope(root: root, folder: folder),
            context: approvalContext(for: prepared)
        )

        #expect(reader.callCount >= 1)
        #expect(prepared.plan.steps.allSatisfy { $0.resolvedFromFinderSelection == true })
        #expect(request.assessment.escalations.map(\.reason).contains("Finder is not part of the Client Alpha workspace."))
        #expect(request.assessment.scopeVerdict == .outOfScope)
    }

    /// The pooled shape SONNY-73 fixed, docx: a scan carrying an explicit folder beside a convert
    /// carrying only `contextSource`. Finder is never contacted and never reported.
    @Test
    func aPooledExplicitPathDocxReportsNoFinderThroughPrepareThenApproval() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Client", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write("contents", to: folder.appendingPathComponent("a.docx"))
        let decoy = root.appendingPathComponent("Decoy", isDirectory: true)
        try FileManager.default.createDirectory(at: decoy, withIntermediateDirectories: true)

        let reader = CountingFinderContextReader(selection: [decoy])
        let runner = AgentRunner(
            planner: StaticPlanner(plan: selectionDrivenDocxPlan()),
            executor: makeExecutor(root: root, finderContextReader: reader)
        )
        let plan = AgentPlan(
            summary: "Convert the documents in that folder.",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "scan-docx",
                    operation: .scanDocx,
                    description: "Scan the folder.",
                    inputPath: folder.path
                ),
                AgentStep(
                    id: "convert",
                    operation: .convertDocxToPDF,
                    description: "Convert the selected folder's documents.",
                    contextSource: .finderSelection
                )
            ]
        )

        let prepared = try runner.prepare(plan: plan, source: .planner)
        let request = try runner.approvalRequest(
            for: prepared,
            scope: Self.clientAlphaScope(root: root, folder: folder),
            context: approvalContext(for: prepared)
        )

        #expect(reader.callCount == 0)
        #expect(!request.assessment.escalations.map(\.reason).contains("Finder is not part of the Client Alpha workspace."))
    }

    /// SONNY-185's shape, docx: one step carrying both the declaration and its own folder.
    @Test
    func aDeclaringDocxStepWithItsOwnFolderReportsNoFinderThroughPrepareThenApproval() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Client", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write("contents", to: folder.appendingPathComponent("a.docx"))
        let decoy = root.appendingPathComponent("Decoy", isDirectory: true)
        try FileManager.default.createDirectory(at: decoy, withIntermediateDirectories: true)

        let reader = CountingFinderContextReader(selection: [decoy])
        let runner = AgentRunner(
            planner: StaticPlanner(plan: selectionDrivenDocxPlan()),
            executor: makeExecutor(root: root, finderContextReader: reader)
        )
        let plan = AgentPlan(
            summary: "Convert the documents in the selected folder.",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "scan-docx",
                    operation: .scanDocx,
                    description: "Scan the selected folder.",
                    inputPath: folder.path,
                    contextSource: .finderSelection
                ),
                AgentStep(
                    id: "convert",
                    operation: .convertDocxToPDF,
                    description: "Convert them.",
                    inputPath: folder.path
                )
            ]
        )

        let prepared = try runner.prepare(plan: plan, source: .planner)
        let request = try runner.approvalRequest(
            for: prepared,
            scope: Self.clientAlphaScope(root: root, folder: folder),
            context: approvalContext(for: prepared)
        )

        #expect(reader.callCount == 0, "Finder was contacted for a plan that named its own folder")
        #expect(!request.assessment.escalations.map(\.reason).contains("Finder is not part of the Client Alpha workspace."))
        let scan = try #require(prepared.plan.steps.first { $0.id == "scan-docx" })
        #expect(scan.contextSource == .finderSelection)
        #expect(scan.resolvedFromFinderSelection == nil)
    }

    /// A workspace whose only file location is `folder`, so Finder — an app it does not name — is
    /// the resource an escalation would be about.
    private static func clientAlphaScope(root: URL, folder: URL) -> TaskWorkspaceScope {
        .scoped(
            WorkspaceScope(
                workspace: StoredWorkspace(
                    name: "Client Alpha",
                    apps: ["Safari"],
                    urls: [],
                    fileLocations: [folder.path]
                ),
                whitelist: PathWhitelist(roots: [root])
            )
        )
    }

    /// A scan_docx/convert pair carrying no `inputPath` at all — the folder is whatever is selected.
    private func selectionDrivenDocxPlan() -> AgentPlan {
        AgentPlan(
            summary: "Convert the documents in the selected folder.",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "scan-docx",
                    operation: .scanDocx,
                    description: "Scan the selected folder.",
                    contextSource: .finderSelection
                ),
                AgentStep(
                    id: "convert",
                    operation: .convertDocxToPDF,
                    description: "Convert the selected folder's documents.",
                    contextSource: .finderSelection
                )
            ]
        )
    }

    /// A scan/zip pair carrying no `inputPath` at all — the folder is whatever is selected in Finder.
    private func selectionDrivenZipPlan() -> AgentPlan {
        AgentPlan(
            summary: "Zip the largest files in the selected folder.",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "scan",
                    operation: .scanSelectLargestFiles,
                    description: "Scan the selected folder.",
                    count: 1,
                    contextSource: .finderSelection
                ),
                AgentStep(
                    id: "zip",
                    operation: .createZip,
                    description: "Zip the selected folder.",
                    contextSource: .finderSelection
                )
            ]
        )
    }

    /// **SONNY-163, measured before it was fixed.** A chain whose second unit is a `run_routine`
    /// converting a document into a folder an earlier unit of the same chain has already written to.
    ///
    /// Before the fix, `previewNestedPlan`/`executeNestedPlan` handed the routine's plan `RunClaims`
    /// of `.none`, so the routine's unit could not tell "this run wrote that PDF two seconds ago"
    /// from "that PDF predates this run" — and took the skip branch, which is for the second. The
    /// probe run recorded on SONNY-163 produced: both units previewing the *same* destination path,
    /// then "No DOCX files needed conversion in …/B. Skipped 1 existing PDF outputs.", with one file
    /// in the output folder. The user is told their second document was skipped for a file they
    /// never had, and is a PDF short — the exact sentence SONNY-76 exists to prevent, reached
    /// through the routine door instead of the chain door.
    ///
    /// Both halves are asserted because they fail differently: the preview half is a plan that
    /// promises one file twice, and the execute half is the missing document.
    @Test
    func aRoutineUnitOfAChainInheritsWhatEarlierUnitsOfThatChainClaimed() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folderA = root.appendingPathComponent("A", isDirectory: true)
        let folderB = root.appendingPathComponent("B", isDirectory: true)
        let output = root.appendingPathComponent("Out", isDirectory: true)
        for directory in [folderA, folderB, output] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        // The same basename in both folders, converting into one shared output folder: the shape
        // where "already claimed by this run" and "predates this run" give different answers.
        try write("docx a", to: folderA.appendingPathComponent("report.docx"))
        try write("docx b", to: folderB.appendingPathComponent("report.docx"))

        let routineStore = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))
        try routineStore.save(
            StoredRoutine(
                name: "Convert B",
                steps: [
                    AgentStep(id: "scan-b", operation: .scanDocx, description: "Scan B.", inputPath: folderB.path),
                    AgentStep(id: "convert-b", operation: .convertDocxToPDF, description: "Convert B.", outputPath: output.path)
                ]
            )
        )
        let plan = AgentPlan(
            summary: "Convert A, then run the routine that converts B.",
            requiresConfirmation: true,
            steps: [
                AgentStep(id: "scan-a", operation: .scanDocx, description: "Scan A.", inputPath: folderA.path),
                AgentStep(id: "convert-a", operation: .convertDocxToPDF, description: "Convert A.", outputPath: output.path),
                AgentStep(id: "run", operation: .runRoutine, description: "Run routine.", routineName: "Convert B")
            ]
        )
        let runner = AgentRunner(
            planner: StaticPlanner(plan: plan),
            executor: makeExecutor(root: root, documentConverter: WritingDocumentConverter(), routineStore: routineStore)
        )

        let prepared = try runner.prepare(plan: plan, source: .planner)

        // The preview promises two distinct files, not the same one twice.
        let promised = prepared.previews.flatMap(\.writes)
        #expect(promised.count == 2)
        #expect(Set(promised).count == 2)
        #expect(promised.contains(output.appendingPathComponent("report.pdf").path))
        #expect(promised.contains(output.appendingPathComponent("report-2.pdf").path))

        let result = try await runner.execute(
            prepared,
            approvalDecision: .approved(.tier3),
            scope: .unscoped,
            context: ApprovalContext(mode: .normal, appControl: .notApplicable)
        )

        // And the run converts both documents rather than skipping one for a PDF this run made.
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).sorted() == ["report-2.pdf", "report.pdf"])
        #expect(!result.summary.contains("Skipped 1 existing PDF outputs"))
        #expect(result.summary.contains("another document would produce the same PDF name"))
        // What the run wrote is exactly what the prepared plan named — the invariant
        // `aChainWritesOnlyFilesThePreparedPlanAlreadyNamed` states, held across the routine door.
        #expect(Set(result.previews.flatMap(\.writes)) == Set(promised))
    }

    /// The counter-pin: a routine run on its own still starts from no claims. `RunClaims` documents
    /// the set as empty for a single-unit plan, and threading the outer value must not turn a plain
    /// "run my convert routine" into a run that believes something was already written.
    @Test
    func aRoutineRunOnItsOwnStillStartsFromNoClaims() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folderB = root.appendingPathComponent("B", isDirectory: true)
        let output = root.appendingPathComponent("Out", isDirectory: true)
        for directory in [folderB, output] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try write("docx b", to: folderB.appendingPathComponent("report.docx"))

        let routineStore = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))
        try routineStore.save(
            StoredRoutine(
                name: "Convert B",
                steps: [
                    AgentStep(id: "scan-b", operation: .scanDocx, description: "Scan B.", inputPath: folderB.path),
                    AgentStep(id: "convert-b", operation: .convertDocxToPDF, description: "Convert B.", outputPath: output.path)
                ]
            )
        )
        let runner = AgentRunner(
            planner: StaticPlanner(plan: RunRoutineCapabilityAdapter.plan(forRoutineNamed: "Convert B")),
            executor: makeExecutor(root: root, documentConverter: WritingDocumentConverter(), routineStore: routineStore)
        )

        let prepared = try runner.prepare(plan: RunRoutineCapabilityAdapter.plan(forRoutineNamed: "Convert B"), source: .planner)
        let result = try await runner.execute(
            prepared,
            approvalDecision: .approved(.tier3),
            scope: .unscoped,
            context: ApprovalContext(mode: .normal, appControl: .notApplicable)
        )

        // The preferred name, not a rename: nothing was claimed before this routine ran.
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path) == ["report.pdf"])
        #expect(!result.summary.contains("another document would produce the same PDF name"))
    }

    private func makeExecutor(
        root: URL,
        zipArchiver: ZipArchiving = RecordingZipArchiver(),
        documentConverter: DocumentConverting = FakeDocumentConverter(),
        browserOpener: BrowserOpening = NoopBrowserOpener(),
        appOpener: AppOpening = NoopAppOpener(),
        fileOpener: FileOpening = NoopFileOpener(),
        mediaOpener: MediaOpening = FakeMediaOpener(),
        finderContextReader: FinderContextReading = FakeFinderContextReader(selection: []),
        routineStore: RoutineStore? = nil,
        workspaceStore: WorkspaceStore? = nil,
        capabilityRegistry: CapabilityRegistry = .revealingNowhere
    ) -> AgentActionExecutor {
        AgentActionExecutor(
            whitelist: PathWhitelist(roots: [root]),
            zipArchiver: zipArchiver,
            documentConverter: documentConverter,
            browserOpener: browserOpener,
            appOpener: appOpener,
            fileOpener: fileOpener,
            mediaOpener: mediaOpener,
            finderContextReader: finderContextReader,
            // Not optional decoration: `tierZeroCommandAutoRunsWithoutApprovalDecision` drives a
            // `.showPermissionReadiness` plan through this executor, which reaches
            // `PermissionReadinessCapabilityAdapter` and calls `currentStatus`. Without this the
            // production default builds a live service and the run makes real `AXIsProcessTrusted()`
            // and `AVCaptureDevice.authorizationStatus` reads — the last live reads in the suite
            // (SONNY-123 PR #72 F1).
            permissionReadinessService: .deterministic(),
            routineStore: routineStore ?? RoutineStore(fileURL: root.appendingPathComponent("routines.json")),
            workspaceStore: workspaceStore ?? WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json")),
            clipboardHistoryStore: UnreachableLocalStores.clipboardHistory(),
            snippetStore: UnreachableLocalStores.snippets(),
            recentArtifactStore: UnreachableLocalStores.recentArtifacts(),
            shortcutRunHistoryStore: UnreachableLocalStores.shortcutRunHistory(),
            resumableTaskStore: UnreachableLocalStores.resumableTasks(),
            capabilityRegistry: capabilityRegistry
        )
    }

    private func openAppPlan(appName: String) -> AgentPlan {
        AgentPlan(
            summary: "Open \(appName).",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "open-app",
                    operation: .openApp,
                    description: "Open \(appName).",
                    appName: appName
                )
            ]
        )
    }

    private func openURLPlan(url: String) -> AgentPlan {
        AgentPlan(
            summary: "Open \(url).",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "open-url",
                    operation: .openURL,
                    description: "Open \(url).",
                    targetURL: url
                )
            ]
        )
    }

    private func openAppSearchURLPlan() -> AgentPlan {
        AgentPlan(
            summary: "Open GitHub search.",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "search-url",
                    operation: .openAppSearchURL,
                    description: "Open GitHub search.",
                    appName: "GitHub",
                    searchQuery: "Swift concurrency"
                )
            ]
        )
    }

    private func openGeneratedArtifactPlan(output: URL) -> AgentPlan {
        AgentPlan(
            summary: "Open generated artifact.",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "open-artifact",
                    operation: .openGeneratedArtifact,
                    description: "Open generated artifact.",
                    outputPath: output.path
                )
            ]
        )
    }

    private func largestPlan(root: URL, output: URL) -> AgentPlan {
        AgentPlan(
            summary: "Zip largest files.",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "scan",
                    operation: .scanSelectLargestFiles,
                    description: "Scan files.",
                    inputPath: root.path,
                    count: 3
                ),
                AgentStep(
                    id: "zip",
                    operation: .createZip,
                    description: "Zip files.",
                    inputPath: root.path,
                    outputPath: output.path,
                    count: 3
                )
            ]
        )
    }

    /// A zip chain plus an unrelated open — two units, so the plan can carry two independent
    /// escalation causes at the same tier: the archive's own already-exists check, and the workspace
    /// boundary the URL crosses.
    private func zipAndOpenURLPlan(root: URL, output: URL, url: String) -> AgentPlan {
        var plan = largestPlan(root: root, output: output)
        plan.steps.append(
            AgentStep(
                id: "open-url",
                operation: .openURL,
                description: "Open \(url).",
                targetURL: url
            )
        )
        return plan
    }

    private func hnPlan(output: URL) -> AgentPlan {
        AgentPlan(
            summary: "Save HN headlines.",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "open",
                    operation: .openHackerNews,
                    description: "Open HN.",
                    targetURL: "https://news.ycombinator.com"
                ),
                AgentStep(
                    id: "fetch",
                    operation: .fetchHNHeadlines,
                    description: "Fetch headlines.",
                    count: 5,
                    targetURL: "https://news.ycombinator.com"
                ),
                AgentStep(
                    id: "write",
                    operation: .writeMarkdown,
                    description: "Write Markdown.",
                    outputPath: output.path,
                    count: 5
                )
            ]
        )
    }

    private func webMarkdownPlan(output: URL) -> AgentPlan {
        AgentPlan(
            summary: "Summarize web article as Markdown.",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "web",
                    operation: .webToMarkdown,
                    description: "Create web Markdown.",
                    outputPath: output.path,
                    targetURL: "https://example.com/article"
                )
            ]
        )
    }

    private func webSearchPlan(output: URL) -> AgentPlan {
        AgentPlan(
            summary: "Research Swift concurrency as Markdown.",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "web-search",
                    operation: .webToMarkdown,
                    description: "Research Swift concurrency.",
                    outputPath: output.path,
                    searchQuery: "Swift concurrency"
                )
            ]
        )
    }

    private func localDraftPlan(output: URL) -> AgentPlan {
        AgentPlan(
            summary: "Create local draft.",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "draft",
                    operation: .createLocalDraft,
                    description: "Create draft.",
                    outputPath: output.path,
                    draftTitle: "Follow Up",
                    draftContent: "Draft body."
                )
            ]
        )
    }

    private func saveRoutinePlan(name: String) -> AgentPlan {
        AgentPlan(
            summary: "Teach routine.",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "save-routine",
                    operation: .saveRoutine,
                    description: "Save routine.",
                    routineName: name,
                    routineSteps: [openAppStep(id: "open-safari")]
                )
            ]
        )
    }

    private func saveRoutinePlanWithNestedZip(name: String, root: URL, output: URL) -> AgentPlan {
        AgentPlan(
            summary: "Teach routine.",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "save-routine",
                    operation: .saveRoutine,
                    description: "Save routine.",
                    routineName: name,
                    routineSteps: largestPlan(root: root, output: output).steps
                )
            ]
        )
    }

    /// A `create_local_draft` nested step rather than the zip one above, deliberately: the reframe is
    /// a `map` over whatever the fold carries, and a second adapter's sentence is what shows that
    /// rather than a comment saying so.
    private func saveRoutinePlanWithNestedDraft(name: String, output: URL) -> AgentPlan {
        AgentPlan(
            summary: "Teach routine.",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "save-routine",
                    operation: .saveRoutine,
                    description: "Save routine.",
                    routineName: name,
                    routineSteps: [
                        AgentStep(
                            id: "draft",
                            operation: .createLocalDraft,
                            description: "Draft the weekly note.",
                            outputPath: output.path,
                            draftTitle: "Weekly",
                            draftContent: "This week."
                        )
                    ]
                )
            ]
        )
    }

    private func createWorkspacePlan(name: String) -> AgentPlan {
        AgentPlan(
            summary: "Create workspace.",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "create-workspace",
                    operation: .createWorkspace,
                    description: "Create workspace.",
                    workspaceName: name,
                    workspaceApps: ["Safari"],
                    workspaceURLs: ["https://github.com"]
                )
            ]
        )
    }

    private func openWorkspacePlan(name: String) -> AgentPlan {
        AgentPlan(
            summary: "Open workspace.",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "open-workspace",
                    operation: .openWorkspace,
                    description: "Open workspace.",
                    workspaceName: name
                )
            ]
        )
    }

    private func runRoutinePlan(name: String) -> AgentPlan {
        AgentPlan(
            summary: "Run routine.",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "run-routine",
                    operation: .runRoutine,
                    description: "Run routine.",
                    routineName: name
                )
            ]
        )
    }

    private func docxPlan(root: URL) -> AgentPlan {
        AgentPlan(
            summary: "Convert DOCX files.",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "scan",
                    operation: .scanDocx,
                    description: "Scan DOCX.",
                    inputPath: root.path
                ),
                AgentStep(
                    id: "convert",
                    operation: .convertDocxToPDF,
                    description: "Convert DOCX.",
                    inputPath: root.path
                )
            ]
        )
    }

    private func mediaPlan() -> AgentPlan {
        AgentPlan(
            summary: "Open Bad Habit.",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "play-media",
                    operation: .playMedia,
                    description: "Open Bad Habit.",
                    mediaProvider: .appleMusic,
                    mediaTitle: "Bad Habit",
                    mediaArtist: "Steve Lacy"
                )
            ]
        )
    }

    private func finderSelectionPlan() -> AgentPlan {
        AgentPlan(
            summary: "Show Finder selection.",
            requiresConfirmation: false,
            steps: [
                AgentStep(
                    id: "finder-selection",
                    operation: .getFinderSelection,
                    description: "Show Finder selection."
                )
            ]
        )
    }

    private func revealPlan(path: URL) -> AgentPlan {
        AgentPlan(
            summary: "Reveal output.",
            requiresConfirmation: false,
            steps: [
                AgentStep(
                    id: "reveal",
                    operation: .revealInFinder,
                    description: "Reveal output.",
                    outputPath: path.path
                )
            ]
        )
    }

    private func zipThenRevealPlan(root: URL, output: URL) -> AgentPlan {
        AgentPlan(
            summary: "Zip largest files and reveal the zip.",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "scan",
                    operation: .scanSelectLargestFiles,
                    description: "Scan files.",
                    inputPath: root.path,
                    count: 3
                ),
                AgentStep(
                    id: "zip",
                    operation: .createZip,
                    description: "Zip files.",
                    inputPath: root.path,
                    outputPath: output.path,
                    count: 3
                ),
                AgentStep(
                    id: "reveal",
                    operation: .revealInFinder,
                    description: "Reveal the generated zip."
                )
            ]
        )
    }

    private func openAppStep(id: String) -> AgentStep {
        AgentStep(
            id: id,
            operation: .openApp,
            description: "Open Safari.",
            appName: "Safari"
        )
    }

    private func permissionReadinessPlan() -> AgentPlan {
        AgentPlan(
            summary: "Show permission readiness.",
            requiresConfirmation: false,
            steps: [
                AgentStep(
                    id: "permissions",
                    operation: .showPermissionReadiness,
                    description: "Show readiness."
                )
            ]
        )
    }

    private func write(_ string: String, to url: URL) throws {
        try string.data(using: .utf8)?.write(to: url)
    }

    private func approvalContext(for prepared: PreparedAgentRun) -> ApprovalContext {
        ApprovalContext(mode: .normal, appControl: .notApplicable)
    }
}

private struct StaticPlanner: Planning {
    var plan: AgentPlan

    func plan(command: String, priorTaskContext: PriorTaskContext?) async throws -> AgentPlan {
        plan
    }
}

@MainActor
private final class RecordingPlanner: Planning {
    var plan: AgentPlan
    private(set) var receivedCommand: String?
    private(set) var receivedPriorTaskContext: PriorTaskContext?

    init(plan: AgentPlan) {
        self.plan = plan
    }

    func plan(command: String, priorTaskContext: PriorTaskContext?) async throws -> AgentPlan {
        receivedCommand = command
        receivedPriorTaskContext = priorTaskContext
        return plan
    }
}

@MainActor
private final class RecordingZipArchiver: ZipArchiving {
    private(set) var createdArchives: [URL] = []

    func createArchive(sourceFolder: URL, files: [URL], outputURL: URL) async throws {
        createdArchives.append(outputURL)
        try "fake zip".data(using: .utf8)?.write(to: outputURL)
    }
}

private struct NoopBrowserOpener: BrowserOpening {
    func open(_ url: URL, using browser: MacApp?) async throws {}
}

@MainActor
private final class RecordingBrowserOpener: BrowserOpening {
    private(set) var openedURLs: [URL] = []
    /// Parallel to `openedURLs`: the browser each open was targeted at, `nil` for the system default.
    private(set) var openedBrowsers: [MacApp?] = []

    func open(_ url: URL, using browser: MacApp?) async throws {
        openedURLs.append(url)
        openedBrowsers.append(browser)
    }
}

private struct NoopAppOpener: AppOpening {
    func open(bundleIdentifier: String) async throws {}
}

private struct NoopFileOpener: FileOpening {
    func openFile(_ url: URL) async throws {}
}

/// Writes its outputs, unlike `FakeDocumentConverter`, and refuses an occupied destination the way
/// both shipped converters do. SONNY-163's shape needs both: the second unit's "does this PDF
/// already exist?" check is only meaningful once the first unit's PDF is really on disk.
private struct WritingDocumentConverter: DocumentConverting {
    var isAvailable: Bool { true }
    var modeName: String { "Writing fake converter" }
    var usesMockNaming: Bool { false }

    func convert(_ records: [DocxRecord], log: @escaping (String) -> Void) async throws -> [DocxRecord] {
        var converted: [DocxRecord] = []
        for record in records where !record.skippedBecausePDFExists {
            guard !FileManager.default.fileExists(atPath: record.destinationURL.path) else {
                throw DocumentConversionError.conversionFailed(
                    "Could not move exported PDF to \(record.destinationURL.path): a file already exists there."
                )
            }
            try "fake pdf".data(using: .utf8)?.write(to: record.destinationURL)
            converted.append(record)
        }
        return converted
    }
}

private struct FakeDocumentConverter: DocumentConverting {
    var isAvailable: Bool { true }
    var modeName: String { "Fake converter" }
    var usesMockNaming: Bool { false }

    func convert(_ records: [DocxRecord], log: @escaping (String) -> Void) async throws -> [DocxRecord] {
        records.filter { !$0.skippedBecausePDFExists }
    }
}

@MainActor
private final class RecordingAppOpener: AppOpening {
    private(set) var openedBundleIDs: [String] = []

    func open(bundleIdentifier: String) async throws {
        openedBundleIDs.append(bundleIdentifier)
    }
}

@MainActor
private final class RecordingFileOpener: FileOpening {
    private(set) var openedFiles: [URL] = []

    func openFile(_ url: URL) async throws {
        openedFiles.append(url.standardizedFileURL)
    }
}

@MainActor
private final class FakeMediaOpener: MediaOpening {
    private(set) var requests: [MediaPlaybackRequest] = []

    func open(_ request: MediaPlaybackRequest) async throws -> String {
        requests.append(request)
        return "Opened \(request.displayTitle) in \(request.provider.displayName)."
    }
}

private struct FakeFinderContextReader: FinderContextReading {
    var selection: [URL]

    func selectedItems() throws -> [URL] {
        guard !selection.isEmpty else {
            throw FinderContextError.noSelection
        }
        return selection
    }
}

/// The same fake, counting its calls — so a two-phase test can assert Finder contact *directly*
/// rather than inferring it from what a decoy folder would have done to the escalations.
///
/// The decoy inference is a real signal and the tests below keep it: a read that happened would
/// resolve to a folder outside the workspace and show up in the escalations. But it is a
/// consequence, not the fact, and this ticket's whole subject is a classifier that reported Finder
/// for a run that never touched it — so the count is worth asserting where the claim is made
/// (SONNY-185, from PR #79's cycle-1 review, coverage note 2).
private final class CountingFinderContextReader: FinderContextReading, @unchecked Sendable {
    private let lock = NSLock()
    private let selection: [URL]
    private var calls = 0

    init(selection: [URL]) {
        self.selection = selection
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func selectedItems() throws -> [URL] {
        lock.lock()
        calls += 1
        lock.unlock()
        guard !selection.isEmpty else {
            throw FinderContextError.noSelection
        }
        return selection
    }
}

private struct RecordingRevealInFinderAdapter: CapabilityAdapter {
    var markerURL: URL

    var metadata: CapabilityMetadata {
        RevealInFinderCapabilityAdapter.metadata
    }

    func preview(plan: AgentPlan, context: CapabilityExecutionContext) throws -> [ActionPreview] {
        let path = try revealPath(in: plan, context: context)
        return [
            ActionPreview(
                title: "Reveal in Finder",
                details: ["Reveal \(path)"],
                opens: ["Finder"]
            )
        ]
    }

    func execute(
        plan: AgentPlan,
        context: CapabilityExecutionContext,
        log: @escaping (AgentPhase, String) -> Void
    ) async throws -> AgentRunResult {
        let previews = try preview(plan: plan, context: context)
        let path = try revealPath(in: plan, context: context)
        log(.act, "Revealing \(path) in Finder")
        try path.data(using: .utf8)?.write(to: markerURL)
        log(.summarize, "Revealed in Finder")
        return AgentRunResult(plan: plan, previews: previews, summary: "Revealed \(path) in Finder.")
    }

    private func revealPath(in plan: AgentPlan, context: CapabilityExecutionContext) throws -> String {
        guard let step = plan.steps.first(where: { $0.operation == .revealInFinder }) else {
            throw AgentExecutionError.invalidPlan("reveal_in_finder step is missing.")
        }
        guard let rawPath = step.outputPath ?? step.inputPath else {
            throw AgentExecutionError.invalidPlan("reveal_in_finder needs outputPath or a previous chained artifact.")
        }
        let url = try context.whitelist.validateInsideWhitelist(rawPath)
        return url.path
    }
}

private struct StaticTierOpenURLAdapter: CapabilityAdapter {
    var defaultRiskTier: CapabilityRiskTier

    var metadata: CapabilityMetadata {
        CapabilityMetadata(
            id: "local.test.static-tier-open-url",
            displayName: "Static tier open URL",
            description: "Test adapter for a static risk tier.",
            operations: [.openURL],
            plannerTools: [
                AgentTool(
                    operation: .openURL,
                    name: "Static tier open URL",
                    description: "Test adapter for a static risk tier.",
                    requiredFields: ["targetURL"],
                    sideEffects: ["open browser"],
                    dryRunBehavior: "Preview test URL."
                )
            ],
            defaultRiskTier: defaultRiskTier
        )
    }

    func preview(plan: AgentPlan, context: CapabilityExecutionContext) throws -> [ActionPreview] {
        [
            ActionPreview(
                title: "Static tier URL",
                details: ["Preview only"],
                opens: ["https://example.com"]
            )
        ]
    }

    func execute(
        plan: AgentPlan,
        context: CapabilityExecutionContext,
        log: @escaping (AgentPhase, String) -> Void
    ) async throws -> AgentRunResult {
        AgentRunResult(
            plan: plan,
            previews: try preview(plan: plan, context: context),
            summary: "Executed static tier URL."
        )
    }
}
