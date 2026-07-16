import Foundation
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
        let request = try runner.approvalRequest(for: prepared)
        let result = try await runner.execute(
            prepared,
            confirmationMessage: "Typed command auto-approved execution"
        )

        #expect(request.assessment.effectiveTier == .tier1)
        #expect(request.requirement == .autoRun)
        #expect(appOpener.openedBundleIDs == ["com.apple.Safari"])
        #expect(result.summary == "Opened Safari.")
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
        let request = try runner.approvalRequest(for: prepared)
        let result = try await runner.execute(
            prepared,
            confirmationMessage: "Voice command auto-approved execution"
        )

        #expect(request.assessment.effectiveTier == .tier1)
        #expect(request.requirement == .autoRun)
        #expect(browserOpener.openedURLs.map(\.absoluteString) == ["https://github.com"])
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
        let request = try runner.approvalRequest(for: prepared)
        let result = try await runner.execute(prepared)

        #expect(request.assessment.effectiveTier == .tier1)
        #expect(request.requirement == .autoRun)
        #expect(request.approvalCopy.dataLeavesDevice == true)
        #expect(browserOpener.openedURLs.map(\.absoluteString) == ["https://github.com/search?q=Swift%20concurrency"])
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
        let request = try runner.approvalRequest(for: prepared)
        let result = try await runner.execute(prepared)

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
        let request = try runner.approvalRequest(for: prepared)
        let result = try await runner.execute(prepared)

        #expect(request.assessment.effectiveTier == .tier0)
        #expect(request.requirement == .autoRun)
        #expect(result.summary.hasPrefix("Permission readiness checked."))
    }

    @Test
    func tierTwoCommandRequiresApprovalBeforeRunnerExecutes() async throws {
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
        let request = try runner.approvalRequest(for: prepared)

        do {
            _ = try await runner.execute(prepared)
            Issue.record("Expected tier 2 execution to require approval.")
        } catch RiskApprovalError.approvalRequired(let approvalRequest) {
            #expect(approvalRequest.requirement == .lightweightConfirmation)
            #expect(approvalRequest.assessment.effectiveTier == .tier2)
        } catch {
            Issue.record("Expected approvalRequired, got \(error).")
        }

        #expect(request.assessment.effectiveTier == .tier2)
        #expect(request.requirement == .lightweightConfirmation)
        #expect(zipArchiver.createdArchives.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: output.path))

        _ = try await runner.execute(
            prepared,
            approvalDecision: .approved(request.assessment.effectiveTier),
            confirmationMessage: "User approved Tier 2 action"
        )

        #expect(zipArchiver.createdArchives == [output])
        #expect(FileManager.default.fileExists(atPath: output.path))
    }

    @Test
    func followUpCorrectionRefinesLargestFilesPlanAndStillRequiresApproval() async throws {
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
        let request = try runner.approvalRequest(for: prepared)

        #expect(planner.receivedCommand == command)
        #expect(planner.receivedPriorTaskContext == priorContext)
        #expect(prepared.plan.steps.first?.inputPath == correctedFolder.path)
        #expect(request.assessment.effectiveTier == .tier2)
        #expect(request.requirement == .lightweightConfirmation)

        do {
            _ = try await runner.execute(prepared)
            Issue.record("Expected corrected tier 2 plan to require approval.")
        } catch RiskApprovalError.approvalRequired(let approvalRequest) {
            #expect(approvalRequest.assessment.effectiveTier == .tier2)
        } catch {
            Issue.record("Expected approvalRequired, got \(error).")
        }

        #expect(zipArchiver.createdArchives.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: output.path))

        _ = try await runner.execute(
            prepared,
            approvalDecision: .approved(request.assessment.effectiveTier),
            confirmationMessage: "User approved corrected Tier 2 action"
        )

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
        let request = try runner.approvalRequest(for: prepared)

        do {
            _ = try await runner.execute(
                prepared,
                approvalDecision: .approved(.tier4),
                confirmationMessage: "User approved Tier 4 action"
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

        let assessment = try executor.assessRisk(plan: plan)

        #expect(assessment.defaultTier == .tier2)
        #expect(assessment.effectiveTier == .tier2)
        #expect(assessment.escalations.isEmpty)
        #expect(assessment.approvalRequirement() == .lightweightConfirmation)
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
        let request = try runner.approvalRequest(for: prepared, logAssessment: true)

        #expect(request.assessment.defaultTier == .tier2)
        #expect(request.assessment.effectiveTier == .tier3)
        #expect(request.requirement == .explicitApproval)
        #expect(request.assessment.escalations == [
            CapabilityRiskEscalation(
                fromTier: .tier2,
                toTier: .tier3,
                reason: "Zip output already exists at \(output.path)."
            )
        ])
        #expect(logStore.events.contains { event in
            event.phase == .risk && event.message.contains("risk.escalated")
        })
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
        let originalRequest = try runner.approvalRequest(for: prepared)
        try write("appeared after approval", to: output)

        do {
            _ = try await runner.execute(
                prepared,
                approvalDecision: .approved(originalRequest.assessment.effectiveTier),
                confirmationMessage: "User approved Tier 2 action"
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
        let request = try runner.approvalRequest(for: prepared)

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
        let request = try runner.approvalRequest(for: prepared)

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
        let request = try runner.approvalRequest(for: prepared)

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
        let request = try runner.approvalRequest(for: prepared)

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
        let request = try runner.approvalRequest(for: prepared)

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
        let request = try runner.approvalRequest(for: prepared)

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
        let request = try runner.approvalRequest(for: prepared)

        #expect(request.assessment.defaultTier == .tier2)
        #expect(request.assessment.effectiveTier == .tier2)
        #expect(request.assessment.escalations.isEmpty)
        #expect(request.requirement == .lightweightConfirmation)
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
        let request = try runner.approvalRequest(for: prepared)
        let result = try await runner.execute(prepared)

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
        let request = try runner.approvalRequest(for: prepared)
        let result = try await runner.execute(prepared)

        #expect(request.assessment.effectiveTier == .tier0)
        #expect(request.requirement == .autoRun)
        #expect(result.summary == "Finder selection contains 1 whitelisted item(s).")
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
        let request = try runner.approvalRequest(for: prepared)

        do {
            _ = try await runner.execute(prepared)
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
        let request = try runner.approvalRequest(for: prepared)
        let result = try await runner.execute(prepared)

        #expect(request.assessment.effectiveTier == .tier1)
        #expect(request.requirement == .autoRun)
        #expect(appOpener.openedBundleIDs == ["com.apple.Safari"])
        #expect(browserOpener.openedURLs.map(\.absoluteString) == ["https://github.com"])
        #expect(result.summary == "Opened workspace Research with 1 app(s) and 1 URL(s).")
    }

    @Test
    func runRoutineTierTwoRequiresApprovalBeforeNestedExecution() async throws {
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
        let request = try runner.approvalRequest(for: prepared)

        do {
            _ = try await runner.execute(prepared)
            Issue.record("Expected run routine to require approval.")
        } catch RiskApprovalError.approvalRequired(let approvalRequest) {
            #expect(approvalRequest.requirement == .lightweightConfirmation)
            #expect(approvalRequest.assessment.effectiveTier == .tier2)
        } catch {
            Issue.record("Expected approvalRequired, got \(error).")
        }

        #expect(request.assessment.effectiveTier == .tier2)
        #expect(request.requirement == .lightweightConfirmation)
        #expect(appOpener.openedBundleIDs.isEmpty)

        let result = try await runner.execute(
            prepared,
            approvalDecision: .approved(request.assessment.effectiveTier)
        )

        #expect(appOpener.openedBundleIDs == ["com.apple.Safari"])
        #expect(result.summary == "Ran routine Morning Setup. Opened Safari.")
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
        let request = try runner.approvalRequest(for: prepared, logAssessment: true)

        #expect(request.assessment.defaultTier == .tier2)
        #expect(request.assessment.effectiveTier == .tier3)
        #expect(request.requirement == .explicitApproval)
        #expect(request.assessment.escalations == [
            CapabilityRiskEscalation(
                fromTier: .tier2,
                toTier: .tier3,
                reason: "Zip output already exists at \(output.path)."
            )
        ])
        #expect(logStore.events.contains { event in
            event.phase == .risk && event.message.contains("risk.escalated")
        })

        do {
            _ = try await runner.execute(
                prepared,
                approvalDecision: .approved(.tier2),
                confirmationMessage: "Stale approval"
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
        let request = try runner.approvalRequest(for: prepared, logAssessment: true)

        #expect(request.assessment.defaultTier == .tier2)
        #expect(request.assessment.effectiveTier == .tier3)
        #expect(request.requirement == .explicitApproval)
        #expect(request.assessment.escalations.contains(
            CapabilityRiskEscalation(
                fromTier: .tier2,
                toTier: .tier3,
                reason: "Zip output already exists at \(output.path)."
            )
        ))

        do {
            _ = try await runner.execute(
                prepared,
                approvalDecision: .approved(.tier2),
                confirmationMessage: "Stale approval"
            )
            Issue.record("Expected nested save-routine escalation to require explicit approval.")
        } catch RiskApprovalError.approvalRequired(let approvalRequest) {
            #expect(approvalRequest.assessment.effectiveTier == .tier3)
        } catch {
            Issue.record("Expected approvalRequired, got \(error).")
        }

        #expect(try routineStore.loadAll().isEmpty)
    }

    @Test
    func zipThenRevealChainIsRiskAssessedAndGatedAsOneUnit() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("small", to: root.appendingPathComponent("small.txt"))
        try write(String(repeating: "x", count: 2048), to: root.appendingPathComponent("large.txt"))
        let output = root.appendingPathComponent("largest.zip")
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
        let request = try runner.approvalRequest(for: prepared)

        do {
            _ = try await runner.execute(prepared)
            Issue.record("Expected zip plus reveal chain to require one approval before any segment executes.")
        } catch RiskApprovalError.approvalRequired(let approvalRequest) {
            #expect(approvalRequest.assessment.effectiveTier == .tier2)
            #expect(approvalRequest.requirement == .lightweightConfirmation)
        } catch {
            Issue.record("Expected approvalRequired, got \(error).")
        }

        #expect(request.assessment.effectiveTier == .tier2)
        #expect(request.requirement == .lightweightConfirmation)
        #expect(zipArchiver.createdArchives.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: marker.path))

        let result = try await runner.execute(
            prepared,
            approvalDecision: .approved(request.assessment.effectiveTier)
        )

        #expect(zipArchiver.createdArchives == [output])
        #expect(FileManager.default.fileExists(atPath: output.path))
        #expect(try String(contentsOf: marker, encoding: .utf8) == output.path)
        #expect(result.summary == "Created largest.zip with 2 largest files from \(root.path). Revealed \(output.path) in Finder.")
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
        capabilityRegistry: CapabilityRegistry = .default
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
            routineStore: routineStore ?? RoutineStore(fileURL: root.appendingPathComponent("routines.json")),
            workspaceStore: workspaceStore ?? WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json")),
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
    func open(_ url: URL) async throws {}
}

@MainActor
private final class RecordingBrowserOpener: BrowserOpening {
    private(set) var openedURLs: [URL] = []

    func open(_ url: URL) async throws {
        openedURLs.append(url)
    }
}

private struct NoopAppOpener: AppOpening {
    func open(bundleIdentifier: String) async throws {}
}

private struct NoopFileOpener: FileOpening {
    func openFile(_ url: URL) async throws {}
}

private struct FakeDocumentConverter: DocumentConverting {
    var isAvailable: Bool { true }
    var modeName: String { "Fake converter" }

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
