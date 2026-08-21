import Foundation
import Testing
import MacAgentTestSupport
@testable import MacAgentCore

@Suite
@MainActor
struct AgentActionExecutorTests {
    @Test
    func largestFilesDryRunDoesNotWriteZip() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("small", to: root.appendingPathComponent("small.txt"))
        try write(String(repeating: "x", count: 1024), to: root.appendingPathComponent("large.txt"))
        let output = root.appendingPathComponent("largest.zip")
        let executor = makeExecutor(root: root)

        let preview = try executor.preview(plan: largestPlan(root: root, output: output))

        #expect(preview.first?.writes == [output.path])
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test
    func largestFilesExecutionCreatesZip() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("small", to: root.appendingPathComponent("small.txt"))
        try write(String(repeating: "x", count: 2048), to: root.appendingPathComponent("large.txt"))
        let output = root.appendingPathComponent("largest.zip")
        let executor = makeExecutor(root: root, zipArchiver: ProcessZipArchiver())

        _ = try await executor.execute(plan: largestPlan(root: root, output: output)) { _, _ in }

        #expect(FileManager.default.fileExists(atPath: output.path))
    }

    @Test
    func asyncProcessRunnerCancelsRunningProcess() async throws {
        let task = Task {
            try await AsyncProcessRunner.run(executablePath: "/bin/sleep", arguments: ["5"])
        }

        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected process cancellation to throw CancellationError.")
        } catch is CancellationError {
            return
        } catch {
            Issue.record("Expected CancellationError, got \(error).")
        }
    }

    @Test
    func asyncProcessRunnerCancelledBeforeLaunchDoesNotCrash() async throws {
        // Regression test for a race that twice crashed the whole test process with an
        // uncaught `-[NSConcreteTask terminate]: task not launched` NSException (see
        // docs/sonny-v1-implementation-changelog.md). Cancelling with no delay (unlike
        // `asyncProcessRunnerCancelsRunningProcess`'s 100ms sleep) races `box.cancel()`
        // against the detached task's own launch every iteration, since a detached task does
        // not inherit the parent's cancellation and can be cancelled before it has even created
        // its `Process`. Looping amplifies a race that reproduced only twice across many months
        // of real runs into something this test can catch reliably.
        for _ in 0..<200 {
            let task = Task {
                try await AsyncProcessRunner.run(executablePath: "/bin/sleep", arguments: ["5"])
            }
            task.cancel()

            do {
                _ = try await task.value
                Issue.record("Expected process cancellation to throw CancellationError.")
            } catch is CancellationError {
                continue
            } catch {
                Issue.record("Expected CancellationError, got \(error).")
            }
        }
    }

    @Test
    func asyncProcessRunnerCapturesRealStdout() async throws {
        let result = try await AsyncProcessRunner.run(executablePath: "/bin/echo", arguments: ["hello"])
        #expect(result.terminationStatus == 0)
        #expect(result.output.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
    }

    @Test
    func defaultZipOutputIsStableBetweenPreviewAndExecution() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("small", to: root.appendingPathComponent("small.txt"))
        try write(String(repeating: "x", count: 2048), to: root.appendingPathComponent("large.txt"))
        let executor = makeExecutor(root: root)
        let plan = AgentPlan(
            summary: "Zip largest files.",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "scan",
                    operation: .scanSelectLargestFiles,
                    description: "Scan files",
                    inputPath: root.path,
                    count: 3
                ),
                AgentStep(
                    id: "zip",
                    operation: .createZip,
                    description: "Zip files",
                    inputPath: root.path,
                    count: 3
                )
            ]
        )

        let prepared = try executor.prepare(plan: plan)
        let previewPath = try #require(prepared.previews.first?.writes.first)
        _ = try await executor.execute(plan: prepared.plan) { _, _ in }

        #expect(FileManager.default.fileExists(atPath: previewPath))
    }

    @Test
    func docxDryRunSkipsExistingPDFAndWritesNothing() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("docx-a", to: root.appendingPathComponent("a.docx"))
        try write("existing", to: root.appendingPathComponent("a.pdf"))
        try write("docx-b", to: root.appendingPathComponent("b.docx"))
        let executor = makeExecutor(root: root)

        let preview = try executor.preview(plan: docxPlan(root: root))

        #expect(preview.first?.writes.count == 1)
        #expect(preview.first?.writes.first?.hasSuffix("/\(root.lastPathComponent)/b.pdf") == true)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("b.pdf").path))
    }

    @Test
    func docxExecutionUsesInjectedConverter() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("docx-b", to: root.appendingPathComponent("b.docx"))
        let executor = makeExecutor(root: root, documentConverter: FakeDocumentConverter())

        _ = try await executor.execute(plan: docxPlan(root: root)) { _, _ in }

        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("b.pdf").path))
    }

    @Test
    func finderSelectionInputIsPinnedOnceAcrossPrepareAndExecute() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folderA = root.appendingPathComponent("A", isDirectory: true)
        let folderB = root.appendingPathComponent("B", isDirectory: true)
        try FileManager.default.createDirectory(at: folderA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folderB, withIntermediateDirectories: true)
        try write(String(repeating: "a", count: 2048), to: folderA.appendingPathComponent("from-a.txt"))
        try write(String(repeating: "b", count: 2048), to: folderB.appendingPathComponent("from-b.txt"))

        let reader = SequenceFinderContextReader(responses: [[folderA], [folderB]])
        let archiver = CapturingZipArchiver()
        let executor = makeExecutor(root: root, zipArchiver: archiver, finderContextReader: reader)
        let plan = AgentPlan(
            summary: "Zip largest files in the selected folder.",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "scan",
                    operation: .scanSelectLargestFiles,
                    description: "Scan selected folder",
                    count: 1,
                    contextSource: .finderSelection
                ),
                AgentStep(
                    id: "zip",
                    operation: .createZip,
                    description: "Zip selected folder",
                    contextSource: .finderSelection
                )
            ]
        )

        let prepared = try executor.prepare(plan: plan)
        let result = try await executor.execute(plan: prepared.plan) { _, _ in }

        #expect(reader.callCount == 1)
        #expect(archiver.capturedFiles.map(\.lastPathComponent) == ["from-a.txt"])
        #expect(result.previews.first?.details.contains { $0.contains("from-a.txt") } == true)
        let pinnedInput = prepared.plan.steps.first?.inputPath ?? ""
        #expect(
            URL(fileURLWithPath: pinnedInput).resolvingSymlinksInPath()
                == folderA.resolvingSymlinksInPath()
        )
    }

    @Test
    func runRoutineResultPreviewsReportTheFileActuallyWritten() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let routineStore = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))
        try routineStore.save(
            StoredRoutine(
                name: "Morning Notes",
                steps: [
                    AgentStep(
                        id: "draft",
                        operation: .createLocalDraft,
                        description: "Create note",
                        draftTitle: "Morning Note",
                        draftContent: "Hello"
                    )
                ]
            )
        )
        let clock = TickingClock()
        let executor = makeExecutor(root: root, routineStore: routineStore, now: clock.next)
        let plan = AgentPlan(
            summary: "Run routine Morning Notes.",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "run",
                    operation: .runRoutine,
                    description: "Run routine",
                    routineName: "Morning Notes"
                )
            ]
        )

        let result = try await executor.execute(plan: plan) { _, _ in }

        let reportedWrites = result.previews.flatMap(\.writes)
        #expect(!reportedWrites.isEmpty)
        #expect(reportedWrites.allSatisfy { FileManager.default.fileExists(atPath: $0) })
    }

    @Test
    func chainedRunRoutineThenOpenArtifactUsesTheRealWrittenPath() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let routineStore = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))
        try routineStore.save(
            StoredRoutine(
                name: "Morning Notes",
                steps: [
                    AgentStep(
                        id: "draft",
                        operation: .createLocalDraft,
                        description: "Create note",
                        draftTitle: "Morning Note",
                        draftContent: "Hello"
                    )
                ]
            )
        )
        let clock = TickingClock()
        let fileOpener = RecordingFileOpener()
        let executor = makeExecutor(
            root: root,
            fileOpener: fileOpener,
            routineStore: routineStore,
            now: clock.next
        )
        let plan = AgentPlan(
            summary: "Run routine and open the result.",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "run",
                    operation: .runRoutine,
                    description: "Run routine",
                    routineName: "Morning Notes"
                ),
                AgentStep(
                    id: "open",
                    operation: .openGeneratedArtifact,
                    description: "Open the generated note"
                )
            ]
        )

        _ = try await executor.execute(plan: plan) { _, _ in }

        #expect(fileOpener.openedFiles.count == 1)
        #expect(fileOpener.openedFiles.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    // MARK: - A browser named on the step (SONNY-157)

    private func openURLPlan(_ url: String, browserName: String? = nil) -> AgentPlan {
        AgentPlan(
            summary: "Open \(url).",
            requiresConfirmation: false,
            steps: [
                AgentStep(
                    id: "open",
                    operation: .openURL,
                    description: "Open \(url).",
                    targetURL: url,
                    browserName: browserName
                )
            ]
        )
    }

    /// **The gap SONNY-152 found and refused to close, now closed.** Before this, naming a browser
    /// did nothing: `AgentStep` had no field to carry one, and the only non-nil `preferredBrowser`
    /// anywhere in `Sources/` was the routine path — so "open example.com in Chrome" opened in the
    /// system default and the words "in Chrome" were silently dropped.
    @Test
    func aBrowserNamedOnTheStepIsWhereTheURLOpens() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let opener = RecordingBrowserOpener()
        let executor = makeExecutor(root: root, browserOpener: opener)

        _ = try await executor.execute(plan: openURLPlan("https://example.com", browserName: "Chrome")) { _, _ in }

        #expect(opener.openedURLs == [URL(string: "https://example.com")!])
        #expect(opener.openedBrowsers.map(\.?.bundleIdentifier) == ["com.google.Chrome"])
    }

    /// **SONNY-152's guarantee, pinned at the execution layer rather than only in the prompt.** A
    /// command naming no browser must still reach the system default, which the opener represents as
    /// `nil`. This is the half that must not regress while the other half is being built.
    @Test
    func noBrowserNamedStillOpensInTheSystemDefault() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let opener = RecordingBrowserOpener()
        let executor = makeExecutor(root: root, browserOpener: opener)

        _ = try await executor.execute(plan: openURLPlan("https://example.com")) { _, _ in }

        #expect(opener.openedBrowsers == [nil])
    }

    /// **The step wins over a routine's binding, and the precedence is stated rather than emergent.**
    /// A routine's browser is a default inferred from the apps that routine opens; a name on the step
    /// is what the user said in this command. The more specific instruction wins.
    ///
    /// Exercised through the same `preferredBrowser` parameter `RunRoutineCapabilityAdapter` uses —
    /// the only non-nil caller in `Sources/` — so this is the real collision and not a simulated one.
    @Test
    func aBrowserNamedOnTheStepWinsOverARoutinesBinding() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let opener = RecordingBrowserOpener()
        let executor = makeExecutor(root: root, browserOpener: opener)
        let routineBrowser = MacApp(displayName: "Safari", bundleIdentifier: "com.apple.Safari")

        _ = try await executor.execute(
            plan: openURLPlan("https://example.com", browserName: "Chrome"),
            preferredBrowser: routineBrowser
        ) { _, _ in }

        #expect(opener.openedBrowsers.map(\.?.bundleIdentifier) == ["com.google.Chrome"])
    }

    /// And the routine's binding still applies when the step names nothing — the founder's
    /// 2026-08-04 decision is untouched by this change.
    @Test
    func aRoutinesBindingStillAppliesWhenTheStepNamesNoBrowser() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let opener = RecordingBrowserOpener()
        let executor = makeExecutor(root: root, browserOpener: opener)
        let routineBrowser = MacApp(displayName: "Safari", bundleIdentifier: "com.apple.Safari")

        _ = try await executor.execute(
            plan: openURLPlan("https://example.com"),
            preferredBrowser: routineBrowser
        ) { _, _ in }

        #expect(opener.openedBrowsers.map(\.?.bundleIdentifier) == ["com.apple.Safari"])
    }

    /// **A name that resolves to nothing installed falls back rather than failing.** Same reasoning
    /// `WorkspaceBrowserOpener` already records for a workspace naming an absent browser: a link
    /// opening in the wrong browser beats one that fails mid-open. Here the fallback is the system
    /// default, because no routine binding was in force.
    @Test
    func anUnresolvableBrowserNameFallsBackInsteadOfFailing() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let opener = RecordingBrowserOpener()
        let executor = makeExecutor(root: root, browserOpener: opener)

        _ = try await executor.execute(
            plan: openURLPlan("https://example.com", browserName: "Netscape Navigator")
        ) { _, _ in }

        #expect(opener.openedURLs == [URL(string: "https://example.com")!])
        #expect(opener.openedBrowsers == [nil])
    }

    @Test
    func runRoutineWrappingOpenURLReportsDataLeavingDevice() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let routineStore = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))
        try routineStore.save(
            StoredRoutine(
                name: "Standup",
                steps: [
                    AgentStep(
                        id: "open",
                        operation: .openURL,
                        description: "Open the standup board",
                        targetURL: "https://example.com/standup"
                    )
                ]
            )
        )
        let executor = makeExecutor(root: root, routineStore: routineStore)
        let plan = AgentPlan(
            summary: "Run routine Standup.",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "run",
                    operation: .runRoutine,
                    description: "Run routine",
                    routineName: "Standup"
                )
            ]
        )

        let assessment = try executor.assessRisk(plan: plan, scope: .unscoped)

        #expect(assessment.approvalCopy?.dataLeavesDevice == true)
    }

    /// SONNY-10. `.openWorkspace` used to sit in the flat `dataEgressOperations` set, so *any*
    /// workspace open claimed "Data leaves device: yes" on the approval panel. A workspace is
    /// allowed to hold apps only (`CreateWorkspaceCapabilityAdapter` requires apps *or* URLs), and
    /// launching local apps sends nothing anywhere — the claim was simply false for that shape.
    /// Asserted through the real `assessRisk` copy rather than the private helper, because the
    /// copy line is the only thing a user ever reads.
    @Test
    func openingAnAppsOnlyWorkspaceDoesNotClaimDataLeavesDevice() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaceStore = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        try workspaceStore.save(StoredWorkspace(name: "Writing", apps: ["Safari", "Notes"], urls: []))
        let executor = makeExecutor(root: root, workspaceStore: workspaceStore)

        let assessment = try executor.assessRisk(plan: openWorkspacePlan(name: "Writing"), scope: .unscoped)

        #expect(assessment.approvalCopy?.dataLeavesDevice == false)
        #expect(assessment.effectiveTier == .tier1)
    }

    /// The other half of the same change: a workspace that really does carry URLs must still
    /// report egress. Without this the fix could have been "always no", which is the same defect
    /// pointing the other way.
    @Test
    func openingAWorkspaceCarryingURLsStillReportsDataLeavingDevice() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaceStore = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        try workspaceStore.save(
            StoredWorkspace(name: "Research", apps: ["Safari"], urls: ["https://example.com/board"])
        )
        let executor = makeExecutor(root: root, workspaceStore: workspaceStore)

        let assessment = try executor.assessRisk(plan: openWorkspacePlan(name: "Research"), scope: .unscoped)

        #expect(assessment.approvalCopy?.dataLeavesDevice == true)
    }

    /// The reachable shape the misfire actually showed up in: an apps-only workspace open chained
    /// with a tier-2 step. Alone, `.openWorkspace` is tier 1 and auto-runs, so the copy is never
    /// rendered; it takes a co-occurring tier-2 step to raise the plan to an approval and put the
    /// "Data leaves device" line in front of the user. Nothing in this plan touches the network.
    @Test
    func appsOnlyWorkspaceChainedWithALocalSaveDoesNotClaimDataLeavesDevice() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaceStore = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        try workspaceStore.save(StoredWorkspace(name: "Writing", apps: ["Notes"], urls: []))
        let executor = makeExecutor(root: root, workspaceStore: workspaceStore)
        let plan = AgentPlan(
            summary: "Open my writing workspace and start a draft.",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "open-workspace",
                    operation: .openWorkspace,
                    description: "Open workspace.",
                    workspaceName: "Writing"
                ),
                AgentStep(
                    id: "draft",
                    operation: .createLocalDraft,
                    description: "Create a local draft.",
                    draftTitle: "Notes",
                    draftContent: "Outline for today."
                )
            ]
        )

        let assessment = try executor.assessRisk(plan: plan, scope: .unscoped)

        #expect(assessment.effectiveTier == .tier2)
        // Consequence rule (2026-08-13): a tier-2 local save with nothing destructive auto-runs.
        #expect(RiskApprovalPolicy.default.requirement(for: assessment, context: plannerContext) == .autoRun)
        #expect(assessment.approvalCopy?.dataLeavesDevice == false)
    }

    // MARK: - SONNY-29: chain-segmented risk assessment

    /// SONNY-29's concrete failure. Two draft steps are two units, so they become a `.chain` and
    /// `executeChain` writes both — but `assessRisk`
    /// used to hand the whole plan to the draft adapter exactly once, and the adapter picks its
    /// step with `.first(where:)`. Only the first draft was ever checked, so the second overwrote
    /// an existing file at tier 2, with no collision escalation and no explicit-approval gate.
    ///
    /// The single-element `escalations` assertion is the point: it fails both ways round — red if
    /// the second segment is not assessed, and red if segmentation double-counts the first.
    @Test
    func secondDraftInAChainEscalatesWhenItsOwnOutputAlreadyExists() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("a.md")
        let second = root.appendingPathComponent("b.md")
        try write("existing draft", to: second)
        let executor = makeExecutor(root: root)

        let assessment = try executor.assessRisk(plan: draftChainPlan(first: first, second: second), scope: .unscoped)

        #expect(assessment.defaultTier == .tier2)
        #expect(assessment.effectiveTier == .tier3)
        #expect(RiskApprovalPolicy.default.requirement(for: assessment, context: plannerContext) == .explicitApproval)
        #expect(assessment.escalations == [
            CapabilityRiskEscalation(
                fromTier: .tier2,
                toTier: .tier3,
                reason: "Draft output already exists at \(second.path).",
                consequence: .destructive
            )
        ])
    }

    /// The other direction of the same change: assessing every segment must not invent
    /// escalations. Two drafts whose outputs are both free stay exactly where they were — tier 2,
    /// lightweight confirmation, nothing raised.
    @Test
    func chainedDraftsWithNoExistingOutputsStayAtTierTwo() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = makeExecutor(root: root)

        let assessment = try executor.assessRisk(
            plan: draftChainPlan(
                first: root.appendingPathComponent("a.md"),
                second: root.appendingPathComponent("b.md")
            ),
            scope: .unscoped
        )

        #expect(assessment.effectiveTier == .tier2)
        #expect(assessment.escalations.isEmpty)
        #expect(RiskApprovalPolicy.default.requirement(for: assessment, context: plannerContext) == .autoRun)
    }

    /// Two steps aimed at the same existing file describe one collision, and the approval panel
    /// joins every reason into a single sentence — repeating it reads as a stutter. Pins the
    /// union (not the concatenation) half of the aggregation rule.
    @Test
    func chainedDraftsTargetingTheSameExistingFileRaiseOneEscalation() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = root.appendingPathComponent("shared.md")
        try write("existing draft", to: shared)
        let executor = makeExecutor(root: root)

        let assessment = try executor.assessRisk(plan: draftChainPlan(first: shared, second: shared), scope: .unscoped)

        #expect(assessment.effectiveTier == .tier3)
        #expect(assessment.escalations.count == 1)
        #expect(assessment.escalations.first?.reason == "Draft output already exists at \(shared.path).")
    }

    /// The same defect in the zip capability, in the shape SONNY-29 could reach: an `.openApp` step
    /// between the two pairs makes the plan a chain, so `executeChain` really creates both archives
    /// while — before segmenting — only the first pair's output was ever checked for a collision.
    ///
    /// The interposed step is no longer what makes this a chain. When this test was written, a
    /// *bare* `[scan, zip, scan, zip]` was not a chain at all: only the first pair executed, so only
    /// the first pair being assessed was at least self-consistent. SONNY-34 ended that — both pairs
    /// now execute and both are assessed, pinned by
    /// `theSecondPairOfARepeatedLargestFilesPlanIsRiskAssessedForItsOwnCollision`. This test keeps
    /// its own value as the mixed-chain variant of the same guarantee.
    @Test
    func secondZipSegmentInAChainEscalatesWhenItsOwnOutputAlreadyExists() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(String(repeating: "x", count: 2048), to: root.appendingPathComponent("large.txt"))
        let firstZip = root.appendingPathComponent("first.zip")
        let secondZip = root.appendingPathComponent("second.zip")
        try write("existing zip", to: secondZip)
        let executor = makeExecutor(root: root)
        let plan = AgentPlan(
            summary: "Zip the largest files, open Safari, then zip them again.",
            requiresConfirmation: true,
            steps: [
                AgentStep(id: "scan-1", operation: .scanSelectLargestFiles, description: "Scan files.", inputPath: root.path, count: 3),
                AgentStep(id: "zip-1", operation: .createZip, description: "Zip files.", inputPath: root.path, outputPath: firstZip.path, count: 3),
                AgentStep(id: "open", operation: .openApp, description: "Open Safari.", appName: "Safari"),
                AgentStep(id: "scan-2", operation: .scanSelectLargestFiles, description: "Scan files again.", inputPath: root.path, count: 3),
                AgentStep(id: "zip-2", operation: .createZip, description: "Zip files again.", inputPath: root.path, outputPath: secondZip.path, count: 3)
            ]
        )

        let assessment = try executor.assessRisk(plan: plan, scope: .unscoped)

        #expect(assessment.effectiveTier == .tier3)
        #expect(assessment.escalations == [
            CapabilityRiskEscalation(
                fromTier: .tier2,
                toTier: .tier3,
                reason: "Zip output already exists at \(secondZip.path).",
                consequence: .destructive
            )
        ])
    }

    /// The mixed-chain shape. A Hacker-News-preset segment and a `.webToMarkdown` segment share
    /// one adapter, so the whole-plan call answered `isHackerNewsPreset` first and returned the
    /// preset's path alone — the research note's own output was never checked. Both segments now
    /// get assessed with their own steps.
    @Test
    func webResearchSegmentOfAHackerNewsChainIsAssessedForItsOwnCollision() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let hackerNewsOutput = root.appendingPathComponent("hn.md")
        let webResearchOutput = root.appendingPathComponent("web.md")
        try write("existing markdown", to: webResearchOutput)
        let executor = makeExecutor(root: root)

        let assessment = try executor.assessRisk(
            plan: hackerNewsThenWebResearchPlan(
                hackerNewsOutput: hackerNewsOutput.path,
                webResearchOutput: webResearchOutput.path
            ),
            scope: .unscoped
        )

        #expect(assessment.effectiveTier == .tier3)
        #expect(assessment.escalations == [
            CapabilityRiskEscalation(
                fromTier: .tier2,
                toTier: .tier3,
                reason: "Markdown output already exists at \(webResearchOutput.path).",
                consequence: .destructive
            )
        ])
    }

    /// The resolution half of the same mixed chain. `resolveDefaultOutputs` used to resolve the
    /// first `.writeMarkdown` step and return, so a `.webToMarkdown` step after it kept a nil
    /// output path: the prepared plan, its preview, and the approval copy all named one file while
    /// the run wrote two. Both default paths are now filled in before anything downstream reads
    /// them.
    @Test
    func webResearchSegmentOfAHackerNewsChainResolvesItsOwnDefaultOutputPath() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let executor = makeExecutor(root: root, now: { stamp })

        let prepared = try executor.prepare(
            plan: hackerNewsThenWebResearchPlan(hackerNewsOutput: nil, webResearchOutput: nil)
        )

        let presetPath = try #require(prepared.plan.steps[2].outputPath)
        let researchPath = try #require(prepared.plan.steps[3].outputPath)
        #expect(presetPath.hasSuffix("/hacker-news-\(Timestamp.fileSafe(stamp)).md"))
        #expect(researchPath.hasSuffix("/web-research-\(Timestamp.fileSafe(stamp)).md"))
        #expect(prepared.previews.flatMap(\.writes).sorted() == [presetPath, researchPath].sorted())
    }

    /// Guards the preset half of the both-kinds rewrite: a preset plan that never reaches a
    /// `.writeMarkdown` step still writes, to the default preset path, and that path still has to
    /// be checked. Turning the preset check into "only when there is a write step" would silently
    /// lose this escalation.
    @Test
    func hackerNewsPresetWithNoWriteStepStillAssessesItsDefaultOutput() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        try write(
            "existing markdown",
            to: root.appendingPathComponent("hacker-news-\(Timestamp.fileSafe(stamp)).md")
        )
        let executor = makeExecutor(root: root, now: { stamp })
        let plan = AgentPlan(
            summary: "Open Hacker News.",
            requiresConfirmation: true,
            steps: [
                AgentStep(id: "open-hn", operation: .openHackerNews, description: "Open Hacker News.")
            ]
        )

        let assessment = try executor.assessRisk(plan: plan, scope: .unscoped)

        #expect(assessment.effectiveTier == .tier3)
        #expect(assessment.escalations.count == 1)
        #expect(
            assessment.escalations.first?.reason
                .hasSuffix("/hacker-news-\(Timestamp.fileSafe(stamp)).md.") == true
        )
    }

    /// No-drift pin for the shape that already worked: a chain of *different* operations was
    /// assessed correctly before segmenting, because each adapter got the whole plan and found its
    /// own step in it. Both escalations must survive the rewrite, in step order.
    @Test
    func chainOfDifferentOperationsStillUnionsEveryEscalation() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(String(repeating: "x", count: 2048), to: root.appendingPathComponent("large.txt"))
        let zipOutput = root.appendingPathComponent("archive.zip")
        let draftOutput = root.appendingPathComponent("draft.md")
        try write("existing zip", to: zipOutput)
        try write("existing draft", to: draftOutput)
        let executor = makeExecutor(root: root)
        let plan = AgentPlan(
            summary: "Zip the largest files and start a draft.",
            requiresConfirmation: true,
            steps: [
                AgentStep(id: "scan", operation: .scanSelectLargestFiles, description: "Scan files.", inputPath: root.path, count: 3),
                AgentStep(id: "zip", operation: .createZip, description: "Zip files.", inputPath: root.path, outputPath: zipOutput.path, count: 3),
                AgentStep(
                    id: "draft",
                    operation: .createLocalDraft,
                    description: "Create a local draft.",
                    outputPath: draftOutput.path,
                    draftTitle: "Notes",
                    draftContent: "Outline for today."
                )
            ]
        )

        let assessment = try executor.assessRisk(plan: plan, scope: .unscoped)

        #expect(assessment.effectiveTier == .tier3)
        #expect(assessment.escalations == [
            CapabilityRiskEscalation(
                fromTier: .tier2,
                toTier: .tier3,
                reason: "Zip output already exists at \(zipOutput.path).",
                consequence: .destructive
            ),
            CapabilityRiskEscalation(
                fromTier: .tier2,
                toTier: .tier3,
                reason: "Draft output already exists at \(draftOutput.path).",
                consequence: .destructive
            )
        ])
    }

    /// PR #25 review finding F1, first half. Segmenting fixed more than the collision escalations
    /// the ticket named: because `defaultTier` is the max across segments, a *baseline* tier that
    /// varies per step is now seen too. `InvokeShortcutCapabilityAdapter.assessRisk` demotes to
    /// tier 1 for a Shortcut with a clean observed success and stays tier 2 otherwise, and it
    /// picks its step with `.first(where:)` — so a chain whose first Shortcut is trusted used to
    /// assess the whole plan at tier 1, which under the default policy is `.autoRun`. Both
    /// Shortcuts then ran with no confirmation at all, including the one Sonny has never seen
    /// succeed. This is a raised tier, not an escalation, so it asserts the empty escalations
    /// list too: the mechanism matters, and a future change that delivered this through a
    /// synthetic escalation instead should fail here rather than pass quietly.
    @Test
    func chainWhoseSecondShortcutIsUntrustedAssessesAtTheUntrustedTier() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let history = ShortcutRunHistoryStore(fileURL: root.appendingPathComponent("shortcuts-history.json"))
        try history.recordSuccess(shortcutName: "Trusted Shortcut", at: Date(timeIntervalSince1970: 1_700_000_000))
        let executor = makeExecutor(
            root: root,
            shortcutCatalog: FakeShortcutCatalog(names: ["Trusted Shortcut", "Untrusted Shortcut"]),
            shortcutRunHistoryStore: history
        )
        let plan = AgentPlan(
            summary: "Run both Shortcuts.",
            requiresConfirmation: true,
            steps: [
                AgentStep(id: "shortcut-1", operation: .invokeShortcut, description: "Run the trusted Shortcut.", shortcutName: "Trusted Shortcut"),
                AgentStep(id: "shortcut-2", operation: .invokeShortcut, description: "Run the untrusted Shortcut.", shortcutName: "Untrusted Shortcut")
            ]
        )

        let assessment = try executor.assessRisk(plan: plan, scope: .unscoped)

        #expect(assessment.defaultTier == .tier2)
        #expect(assessment.effectiveTier == .tier2)
        #expect(RiskApprovalPolicy.default.requirement(for: assessment, context: plannerContext) == .autoRun)
        #expect(assessment.escalations.isEmpty)
    }

    /// PR #25 review finding F1, second half, and the highest-value behavior on this branch: a
    /// whole nested plan used to be invisible to the gate. `RunRoutineCapabilityAdapter` resolves
    /// its routine from the first `.runRoutine` step, so a chain running two saved routines
    /// assessed the first one's steps and never called `assessNestedPlan` for the second at all —
    /// the second routine's file collision, and every other condition inside it, simply did not
    /// exist as far as approval was concerned, while `executeChain` ran it. Both aggregation rules
    /// are load-bearing here: the max across segments carries tier 3 out of the second segment,
    /// and the escalation union is what puts the reason in front of the user.
    @Test
    func chainWhoseSecondRoutineCarriesACollisionEscalatesAndNamesIt() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let existingDraft = root.appendingPathComponent("weekly.md")
        try write("existing draft", to: existingDraft)
        let routineStore = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))
        try routineStore.save(
            StoredRoutine(
                name: "Standup",
                steps: [
                    AgentStep(id: "open", operation: .openURL, description: "Open the standup board.", targetURL: "https://example.com/standup")
                ]
            )
        )
        try routineStore.save(
            StoredRoutine(
                name: "Weekly Notes",
                steps: [
                    AgentStep(
                        id: "draft",
                        operation: .createLocalDraft,
                        description: "Start this week's notes.",
                        outputPath: existingDraft.path,
                        draftTitle: "Weekly",
                        draftContent: "Notes for this week."
                    )
                ]
            )
        )
        let executor = makeExecutor(root: root, routineStore: routineStore)
        let plan = AgentPlan(
            summary: "Run both routines.",
            requiresConfirmation: true,
            steps: [
                AgentStep(id: "run-1", operation: .runRoutine, description: "Run routine Standup.", routineName: "Standup"),
                AgentStep(id: "run-2", operation: .runRoutine, description: "Run routine Weekly Notes.", routineName: "Weekly Notes")
            ]
        )

        let assessment = try executor.assessRisk(plan: plan, scope: .unscoped)

        #expect(assessment.defaultTier == .tier2)
        #expect(assessment.effectiveTier == .tier3)
        #expect(RiskApprovalPolicy.default.requirement(for: assessment, context: plannerContext) == .explicitApproval)
        #expect(assessment.escalations == [
            CapabilityRiskEscalation(
                fromTier: .tier2,
                toTier: .tier3,
                reason: "Draft output already exists at \(existingDraft.path).",
                consequence: .destructive
            )
        ])
    }

    // MARK: - SONNY-34: every unit of a repeated non-chaining workflow executes
    //
    // Before this, a plan whose steps all mapped to one of the five workflows that absorb several
    // steps into one adapter call — `.clarify`, `.largestFiles`, `.docx`, `.hackerNews`,
    // `.webResearch` — was handed to that adapter exactly once, and every adapter picks its step
    // with `.first(where:)`. Everything after the first occurrence was dropped with no error, no
    // log line, and no mention in the summary, while the run reported success. Each test below
    // fails loudly on a revert, because each asserts the *second* unit's concrete side effect.

    /// SONNY-34's headline failure, verbatim: "zip the 3 largest files in A and the 3 largest in
    /// B". Both pairs map to `.largestFiles`, so before this the plan was not a chain, one adapter
    /// call selected scan(A) and zip(a), and `b.zip` was never created — while the summary named
    /// `a.zip` as a success.
    ///
    /// Asserted on the archives' real contents rather than on their existence: `CapturingZipArchiver`
    /// records only the last call, so proving *both* ran means proving each archive was built from
    /// its own folder's file. That is also what would catch the subtler wrong fix, where both units
    /// run but the second re-uses the first unit's resolved folder.
    @Test
    func bothZipPairsOfARepeatedLargestFilesPlanCreateTheirOwnArchive() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folderA = root.appendingPathComponent("A", isDirectory: true)
        let folderB = root.appendingPathComponent("B", isDirectory: true)
        try FileManager.default.createDirectory(at: folderA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folderB, withIntermediateDirectories: true)
        try write(String(repeating: "a", count: 2048), to: folderA.appendingPathComponent("from-a.txt"))
        try write(String(repeating: "b", count: 2048), to: folderB.appendingPathComponent("from-b.txt"))
        let zipA = root.appendingPathComponent("a.zip")
        let zipB = root.appendingPathComponent("b.zip")
        let executor = makeExecutor(root: root)

        let result = try await executor.execute(
            plan: twoLargestFilesPairsPlan(folderA: folderA, zipA: zipA, folderB: folderB, zipB: zipB)
        ) { _, _ in }

        #expect(FileManager.default.fileExists(atPath: zipA.path))
        #expect(FileManager.default.fileExists(atPath: zipB.path))
        // Compared as whole arrays rather than by index: a revert leaves one preview, and
        // subscripting it would trap the whole test process instead of failing this one test.
        #expect(result.previews.map(\.writes) == [[zipA.path], [zipB.path]])
        let scannedFiles = result.previews.map { $0.details.joined(separator: " ") }
        #expect(scannedFiles.first?.contains("from-a.txt") == true)
        #expect(scannedFiles.last?.contains("from-b.txt") == true)
        #expect(result.summary.contains("Created a.zip"))
        #expect(result.summary.contains("Created b.zip"))
    }

    /// The assessment half of the same plan, and the reason this matters beyond wasted work: the
    /// second pair's output collision could not raise anything, because the second pair did not
    /// exist as far as any gate was concerned. `assessRisk` walks the units the executor runs, so
    /// making the second pair run is what makes it assessable.
    @Test
    func theSecondPairOfARepeatedLargestFilesPlanIsRiskAssessedForItsOwnCollision() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folderA = root.appendingPathComponent("A", isDirectory: true)
        let folderB = root.appendingPathComponent("B", isDirectory: true)
        try FileManager.default.createDirectory(at: folderA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folderB, withIntermediateDirectories: true)
        try write(String(repeating: "a", count: 2048), to: folderA.appendingPathComponent("from-a.txt"))
        try write(String(repeating: "b", count: 2048), to: folderB.appendingPathComponent("from-b.txt"))
        let zipA = root.appendingPathComponent("a.zip")
        let zipB = root.appendingPathComponent("b.zip")
        try write("existing zip", to: zipB)
        let executor = makeExecutor(root: root)

        let assessment = try executor.assessRisk(
            plan: twoLargestFilesPairsPlan(folderA: folderA, zipA: zipA, folderB: folderB, zipB: zipB),
            scope: .unscoped
        )

        #expect(assessment.effectiveTier == .tier3)
        #expect(RiskApprovalPolicy.default.requirement(for: assessment, context: plannerContext) == .explicitApproval)
        #expect(assessment.escalations == [
            CapabilityRiskEscalation(
                fromTier: .tier2,
                toTier: .tier3,
                reason: "Zip output already exists at \(zipB.path).",
                consequence: .destructive
            )
        ])
    }

    /// The same shape in the DOCX capability. Two `[scan_docx, convert_docx_to_pdf]` pairs over two
    /// folders converted only the first folder's documents.
    @Test
    func bothDocxPairsOfARepeatedConversionPlanConvertTheirOwnFolder() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folderA = root.appendingPathComponent("A", isDirectory: true)
        let folderB = root.appendingPathComponent("B", isDirectory: true)
        try FileManager.default.createDirectory(at: folderA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folderB, withIntermediateDirectories: true)
        try write("docx-a", to: folderA.appendingPathComponent("a.docx"))
        try write("docx-b", to: folderB.appendingPathComponent("b.docx"))
        let executor = makeExecutor(root: root, documentConverter: FakeDocumentConverter())
        let plan = AgentPlan(
            summary: "Convert the Word documents in both folders.",
            requiresConfirmation: true,
            steps: [
                AgentStep(id: "scan-a", operation: .scanDocx, description: "Scan A.", inputPath: folderA.path),
                AgentStep(id: "convert-a", operation: .convertDocxToPDF, description: "Convert A.", inputPath: folderA.path),
                AgentStep(id: "scan-b", operation: .scanDocx, description: "Scan B.", inputPath: folderB.path),
                AgentStep(id: "convert-b", operation: .convertDocxToPDF, description: "Convert B.", inputPath: folderB.path)
            ]
        )

        _ = try await executor.execute(plan: plan) { _, _ in }

        #expect(FileManager.default.fileExists(atPath: folderA.appendingPathComponent("a.pdf").path))
        #expect(FileManager.default.fileExists(atPath: folderB.appendingPathComponent("b.pdf").path))
    }

    /// The same shape in the web-research capability. Two `.webToMarkdown` steps fetched and wrote
    /// one note; the second source was never fetched at all.
    @Test
    func bothWebResearchStepsOfARepeatedPlanFetchAndWriteTheirOwnNote() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstSource = URL(string: "https://example.com/first")!
        let secondSource = URL(string: "https://example.com/second")!
        let firstOutput = root.appendingPathComponent("first.md")
        let secondOutput = root.appendingPathComponent("second.md")
        let pageLoader = webPageLoader(pages: [
            firstSource.absoluteString: readablePage(url: firstSource, title: "First Article"),
            secondSource.absoluteString: readablePage(url: secondSource, title: "Second Article")
        ])
        let synthesizer = StaticWebResearchSynthesizer(
            note: WebResearchNote(title: "Note", summary: "A summary.", keyPoints: [], citations: [])
        )
        let executor = makeExecutor(root: root, webPageLoader: pageLoader, webResearchSynthesizer: synthesizer)
        let plan = AgentPlan(
            summary: "Summarize both articles.",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "research-1",
                    operation: .webToMarkdown,
                    description: "Summarize the first article.",
                    outputPath: firstOutput.path,
                    targetURL: firstSource.absoluteString
                ),
                AgentStep(
                    id: "research-2",
                    operation: .webToMarkdown,
                    description: "Summarize the second article.",
                    outputPath: secondOutput.path,
                    targetURL: secondSource.absoluteString
                )
            ]
        )

        _ = try await executor.execute(plan: plan) { _, _ in }

        #expect(try String(contentsOf: firstOutput).contains("[First Article](https://example.com/first)"))
        #expect(try String(contentsOf: secondOutput).contains("[Second Article](https://example.com/second)"))
        #expect(synthesizer.prompts.count == 2)
    }

    /// A repeated clarification is the one repeat that must not become a chain: a clarification is
    /// a question asked instead of acting, and `execute` refuses the workflow outright. Answering
    /// with the first question while a second went unasked is the same silent drop, so it is
    /// rejected with the error a clarification mixed with real work already gets.
    @Test
    func aPlanWithTwoClarificationStepsIsRejectedRatherThanAnsweringOnlyTheFirst() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = makeExecutor(root: root)
        let plan = AgentPlan(
            summary: "Ask twice.",
            requiresConfirmation: false,
            steps: [
                AgentStep(id: "ask-1", operation: .clarify, description: "Ask which folder.", question: "Which folder?"),
                AgentStep(id: "ask-2", operation: .clarify, description: "Ask which file.", question: "Which file?")
            ]
        )

        #expect(throws: AgentExecutionError.invalidPlan("Clarification must be the only planned step.")) {
            try executor.prepare(plan: plan)
        }
    }

    /// No-drift, and the load-bearing half of the rewrite. `[scan, zip]` reads across both steps
    /// inside one adapter call, so it must stay **one** unit — splitting it would scan with no zip
    /// destination and then zip with no scanned folder. A unit-counting classifier that counted
    /// steps instead of units would break exactly here.
    @Test
    func aSingleScanAndZipPairIsStillOneUnitProducingOneArchive() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(String(repeating: "x", count: 2048), to: root.appendingPathComponent("large.txt"))
        let output = root.appendingPathComponent("largest.zip")
        let executor = makeExecutor(root: root)

        let result = try await executor.execute(plan: largestPlan(root: root, output: output)) { _, _ in }

        #expect(result.previews.map(\.writes) == [[output.path]])
        #expect(result.summary == "Created largest.zip with 1 largest files from \(root.path).")
    }

    /// The same no-drift guarantee for the three-step Hacker News preset, which absorbs three
    /// distinct operations into one unit.
    @Test
    func theHackerNewsPresetIsStillOneUnitWritingOneMarkdownFile() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("hn.md")
        let executor = makeExecutor(root: root)

        let result = try await executor.execute(plan: hnPlan(output: output)) { _, _ in }

        #expect(result.previews.count == 1)
        #expect(result.summary == "Saved 5 Hacker News headlines to \(output.path).")
    }

    /// A run led by a *later* member of its workflow is one unit too. The old segmentation was
    /// anchored at `.openHackerNews` alone, so a preset plan that omits the browser-open step —
    /// `[fetch_hn_headlines, write_markdown]`, which `WebResearchMarkdownCapabilityAdapter` reads
    /// as one preset — would have been cut into two units the adapter never services separately.
    /// Pinning it here is what stops the classifier rewrite from turning one write into two.
    @Test
    func aHackerNewsFetchAndWriteWithNoOpenStepIsStillOneUnit() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("hn.md")
        let executor = makeExecutor(root: root)
        let plan = AgentPlan(
            summary: "Save the Hacker News headlines.",
            requiresConfirmation: true,
            steps: [
                AgentStep(id: "fetch", operation: .fetchHNHeadlines, description: "Fetch headlines.", count: 5),
                AgentStep(id: "write", operation: .writeMarkdown, description: "Write Markdown.", outputPath: output.path, count: 5)
            ]
        )

        let result = try await executor.execute(plan: plan) { _, _ in }

        #expect(result.previews.count == 1)
        #expect(result.summary == "Saved 5 Hacker News headlines to \(output.path).")
    }

    /// And the converse: a repeat inside one workflow's run ends the unit — a *repeat*, meaning what
    /// follows covers the same operations the unit already covers. `[fetch, write, fetch, write]` is
    /// two digests, because `hackerNewsSpec` reads one fetch and one write step per call and would
    /// otherwise drop the second pair — the same first-match drop, one operation deeper than the
    /// plan-level one. The three tests below it guard the other side of that rule: a duplicate that
    /// is *not* a repeat must not cut the unit.
    @Test
    func aRepeatedFetchAndWritePairStartsANewUnit() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstOutput = root.appendingPathComponent("hn-1.md")
        let secondOutput = root.appendingPathComponent("hn-2.md")
        let executor = makeExecutor(root: root)
        let plan = AgentPlan(
            summary: "Save two headline digests.",
            requiresConfirmation: true,
            steps: [
                AgentStep(id: "fetch-1", operation: .fetchHNHeadlines, description: "Fetch headlines.", count: 5),
                AgentStep(id: "write-1", operation: .writeMarkdown, description: "Write the first digest.", outputPath: firstOutput.path, count: 5),
                AgentStep(id: "fetch-2", operation: .fetchHNHeadlines, description: "Fetch headlines again.", count: 3),
                AgentStep(id: "write-2", operation: .writeMarkdown, description: "Write the second digest.", outputPath: secondOutput.path, count: 3)
            ]
        )

        let result = try await executor.execute(plan: plan) { _, _ in }

        #expect(result.previews.count == 2)
        #expect(FileManager.default.fileExists(atPath: firstOutput.path))
        #expect(FileManager.default.fileExists(atPath: secondOutput.path))
        // The second unit's own `count` is honoured — proof it was serviced by its own steps
        // rather than by a re-run of the first unit's.
        #expect(result.summary == "Saved 5 Hacker News headlines to \(firstOutput.path). Saved 3 Hacker News headlines to \(secondOutput.path).")
    }

    // MARK: - SONNY-34 (PR #41 review, F1): a duplicate that is not a repeat must not cut the unit
    //
    // The first draft cut a unit at *any* repeated operation, which ends a unit mid-workflow and
    // leaves a fragment — a bare `[scan]`, `[scan_docx]` or `[fetch]`. No adapter gates on its
    // companion step being present; each manufactures a default and acts. All three plans below were
    // measured producing a second, unrequested effect, and all three are baseline shapes the whole-plan
    // call handled correctly by absorbing the duplicate. They are fixtures now.

    /// A second scan before the zip is planner noise, not a second archive: the plan names one
    /// `create_zip`, so one archive is what the user asked for. Asserted on the *whole* directory
    /// listing rather than on the wanted archive alone — an extra archive beside a correct one is
    /// exactly the failure, and an existence check on the right file cannot see it.
    @Test
    func aScanRepeatedBeforeItsZipStaysOneUnitAndCreatesOneArchive() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folderA = root.appendingPathComponent("A", isDirectory: true)
        try FileManager.default.createDirectory(at: folderA, withIntermediateDirectories: true)
        try write(String(repeating: "a", count: 2048), to: folderA.appendingPathComponent("from-a.txt"))
        let wanted = root.appendingPathComponent("wanted.zip")
        let executor = makeExecutor(root: root)
        let plan = AgentPlan(
            summary: "Zip the largest files in A.",
            requiresConfirmation: true,
            steps: [
                AgentStep(id: "scan-1", operation: .scanSelectLargestFiles, description: "Scan A.", inputPath: folderA.path, count: 3),
                AgentStep(id: "scan-2", operation: .scanSelectLargestFiles, description: "Scan A again.", inputPath: folderA.path, count: 3),
                AgentStep(id: "zip", operation: .createZip, description: "Zip them.", inputPath: folderA.path, outputPath: wanted.path, count: 3)
            ]
        )

        let result = try await executor.execute(plan: plan) { _, _ in }

        #expect(result.previews.map(\.writes) == [[wanted.path]])
        #expect(try FileManager.default.contentsOfDirectory(atPath: folderA.path).filter { $0.hasSuffix(".zip") }.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".zip") } == ["wanted.zip"])
    }

    /// The same for DOCX, where the fragment's second effect also lands in the wrong place: a bare
    /// `[scan_docx]` unit has no convert step to read an output folder from, so it converts into the
    /// source folder — the one directory the user explicitly redirected away from.
    @Test
    func aDocxScanRepeatedBeforeItsConversionStaysOneUnitAndWritesOnePDF() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let documents = root.appendingPathComponent("Documents", isDirectory: true)
        let outputFolder = root.appendingPathComponent("PDFs", isDirectory: true)
        for directory in [documents, outputFolder] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try write("docx", to: documents.appendingPathComponent("memo.docx"))
        let executor = makeExecutor(root: root, documentConverter: FakeDocumentConverter())
        let plan = AgentPlan(
            summary: "Convert the Word documents.",
            requiresConfirmation: true,
            steps: [
                AgentStep(id: "scan-1", operation: .scanDocx, description: "Scan.", inputPath: documents.path),
                AgentStep(id: "scan-2", operation: .scanDocx, description: "Scan again.", inputPath: documents.path),
                AgentStep(id: "convert", operation: .convertDocxToPDF, description: "Convert.", inputPath: documents.path, outputPath: outputFolder.path)
            ]
        )

        let result = try await executor.execute(plan: plan) { _, _ in }

        #expect(result.previews.count == 1)
        #expect(FileManager.default.fileExists(atPath: outputFolder.appendingPathComponent("memo.pdf").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: documents.path) == ["memo.docx"])
    }

    /// The serious one. A bare `[fetch]` fragment runs a whole second Hacker News preset — another
    /// browser open, another fetch, and another Markdown save deriving the same
    /// `hacker-news-<timestamp>` name in the same second, so the second write lands silently on the
    /// first at tier 2, with no collision escalation because at assessment time the file did not
    /// exist. SONNY-35's suffixing cannot reach it: neither fragment carries a `.write_markdown`
    /// step, so no `outputPath` is ever resolved to compare against.
    ///
    /// One unit, so: one open, one file, one sentence.
    @Test
    func aHackerNewsFetchRepeatedBeforeAnyWriteStaysOneUnitAndSavesOnce() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let browserOpener = RecordingBrowserOpener()
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let executor = makeExecutor(root: root, browserOpener: browserOpener, now: { stamp })
        let plan = AgentPlan(
            summary: "Open Hacker News and grab the headlines.",
            requiresConfirmation: true,
            steps: [
                AgentStep(id: "open-hn", operation: .openHackerNews, description: "Open Hacker News."),
                AgentStep(id: "fetch-1", operation: .fetchHNHeadlines, description: "Fetch headlines.", count: 5),
                AgentStep(id: "fetch-2", operation: .fetchHNHeadlines, description: "Fetch headlines again.", count: 5)
            ]
        )

        let result = try await executor.execute(plan: plan) { _, _ in }

        let saved = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("hacker-news-") }
        #expect(saved.count == 1)
        #expect(browserOpener.openedURLs.count == 1)
        #expect(result.previews.count == 1)
        #expect(result.summary == "Saved 5 Hacker News headlines to \(root.appendingPathComponent(saved[0]).path).")
    }

    /// A repeated operation *after* the unit is complete is a trailing fragment, not a repeat, and is
    /// absorbed for the same reason — the adapter drops it, and the plan named one archive.
    @Test
    func aScanTrailingACompletePairStaysInTheSameUnit() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(String(repeating: "x", count: 2048), to: root.appendingPathComponent("large.txt"))
        let output = root.appendingPathComponent("largest.zip")
        let executor = makeExecutor(root: root)
        let plan = AgentPlan(
            summary: "Zip the largest files.",
            requiresConfirmation: true,
            steps: [
                AgentStep(id: "scan", operation: .scanSelectLargestFiles, description: "Scan.", inputPath: root.path, count: 3),
                AgentStep(id: "zip", operation: .createZip, description: "Zip.", inputPath: root.path, outputPath: output.path, count: 3),
                AgentStep(id: "scan-again", operation: .scanSelectLargestFiles, description: "Scan again.", inputPath: root.path, count: 3)
            ]
        )

        let result = try await executor.execute(plan: plan) { _, _ in }

        #expect(result.previews.map(\.writes) == [[output.path]])
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".zip") } == ["largest.zip"])
    }

    // MARK: - SONNY-34 (PR #41 review, F2): a plan with no steps is still a benign no-op

    /// `chainSegments`' guard refuses exactly one unit and nothing else. A plan with no steps
    /// classifies `.chain` — an empty `Set` of workflows is not a count of one — and cuts to no
    /// units, and both chain loops simply do not run. That was the behavior before this branch, an
    /// earlier draft of the guard turned it into a thrown error, and it is reachable in practice:
    /// `RoutineStore.save` accepts a routine with no steps, and `RunRoutineCapabilityAdapter`
    /// previews and assesses that routine's empty nested plan through this same path.
    ///
    /// All four entry points pinned together, because the guard sits under all four.
    @Test
    func aPlanWithNoStepsIsANoOpAcrossEveryEntryPoint() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = makeExecutor(root: root)
        let plan = AgentPlan(summary: "", requiresConfirmation: false, steps: [])

        let previews = try executor.preview(plan: plan)
        let prepared = try executor.prepare(plan: plan)
        let assessment = try executor.assessRisk(plan: plan, scope: .unscoped)
        let result = try await executor.execute(plan: plan) { _, _ in }

        #expect(previews.isEmpty)
        #expect(prepared.previews.isEmpty)
        #expect(prepared.clarificationQuestion == nil)
        #expect(assessment.defaultTier == .tier0)
        #expect(assessment.effectiveTier == .tier0)
        #expect(assessment.escalations.isEmpty)
        #expect(result.summary.isEmpty)
        #expect(result.previews.isEmpty)
    }

    /// The same shape reached the way a user really can reach it: an empty stored routine, run
    /// through `run_routine`, whose nested plan has no steps.
    @Test
    func runningAStoredRoutineWithNoStepsIsANoOpRatherThanAnError() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let routineStore = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))
        try routineStore.save(StoredRoutine(name: "Empty", steps: []))
        let executor = makeExecutor(root: root, routineStore: routineStore)

        let plan = RunRoutineCapabilityAdapter.plan(forRoutineNamed: "Empty")
        let assessment = try executor.assessRisk(plan: plan, scope: .unscoped)
        let result = try await executor.execute(plan: plan) { _, _ in }

        // Tier 2 is `run_routine`'s own default, unmoved by a nested plan that assesses nothing; the
        // trailing space is the outer adapter concatenating an empty nested summary. Both are
        // pre-existing behavior, pinned as measured rather than as hoped — the point of the test is
        // that this path answers at all instead of throwing.
        #expect(assessment.effectiveTier == .tier2)
        #expect(assessment.escalations.isEmpty)
        #expect(result.summary == "Ran routine Empty. ")
    }

    // MARK: - SONNY-35: every unit resolves its own default output path
    //
    // `resolveDefaultOutputs` called each adapter once with the whole plan, and adapters resolve
    // with `.first(where:)`, so every occurrence after the first kept `outputPath == nil` in the
    // prepared plan. Two consequences, and both are pinned below: the preview and the approval
    // copy's "Involves:" line named one file while the run wrote two, and an unresolved default was
    // re-derived independently at assessment time and again at execution time — so the path the
    // risk engine checked for a collision was not the path that got written.

    /// The prepared plan has to name every file the run will write. Two drafts with distinct titles
    /// and no destinations: before this, `prepared.plan.steps[1].outputPath` was nil and the preview
    /// listed one write.
    @Test
    func bothDraftsInAChainResolveTheirOwnDefaultDestination() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let executor = makeExecutor(root: root, now: { stamp })

        let prepared = try executor.prepare(plan: untitledDraftChainPlan(firstTitle: "Alpha", secondTitle: "Beta"))

        let firstPath = try #require(prepared.plan.steps.first?.outputPath)
        let secondPath = try #require(prepared.plan.steps.last?.outputPath)
        #expect(firstPath.hasSuffix("/draft-alpha-\(Timestamp.fileSafe(stamp)).md"))
        #expect(secondPath.hasSuffix("/draft-beta-\(Timestamp.fileSafe(stamp)).md"))
        #expect(prepared.previews.flatMap(\.writes).sorted() == [firstPath, secondPath].sorted())
    }

    /// Resolving both is not enough on its own: two drafts the planner gives no titles both derive
    /// their name from the shared plan summary, and `Timestamp.fileSafe` is second-resolution, so
    /// the two generated names are byte-identical and the second write destroys the first. A
    /// generated destination that an earlier step of the same plan already claimed is suffixed.
    @Test
    func twoDraftsGeneratingTheSameDefaultNameResolveToDistinctFiles() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let executor = makeExecutor(root: root, now: { stamp })

        let prepared = try executor.prepare(plan: untitledDraftChainPlan(firstTitle: nil, secondTitle: nil))
        _ = try await executor.execute(plan: prepared.plan) { _, _ in }

        let firstPath = try #require(prepared.plan.steps.first?.outputPath)
        let secondPath = try #require(prepared.plan.steps.last?.outputPath)
        #expect(firstPath.hasSuffix("/draft-draft-two-notes-\(Timestamp.fileSafe(stamp)).md"))
        #expect(secondPath.hasSuffix("/draft-draft-two-notes-\(Timestamp.fileSafe(stamp))-2.md"))
        #expect(try String(contentsOf: URL(fileURLWithPath: firstPath)).contains("First note."))
        #expect(try String(contentsOf: URL(fileURLWithPath: secondPath)).contains("Second note."))
    }

    /// The disambiguated path is the one the risk engine checks. A file already sitting at the
    /// second draft's suffixed destination raises the collision escalation naming that exact path —
    /// which also proves the suffixing does not sidestep the escalation: it only avoids the plan
    /// colliding with *itself*, never with what is on disk.
    @Test
    func theDisambiguatedSecondDraftPathIsTheOneRiskAssessmentChecks() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let occupied = root.appendingPathComponent("draft-draft-two-notes-\(Timestamp.fileSafe(stamp))-2.md")
        try write("existing draft", to: occupied)
        let executor = makeExecutor(root: root, now: { stamp })

        let assessment = try executor.assessRisk(
            plan: untitledDraftChainPlan(firstTitle: nil, secondTitle: nil),
            scope: .unscoped
        )

        #expect(assessment.effectiveTier == .tier3)
        #expect(assessment.escalations == [
            CapabilityRiskEscalation(
                fromTier: .tier2,
                toTier: .tier3,
                reason: "Draft output already exists at \(occupied.path).",
                consequence: .destructive
            )
        ])
    }

    /// The other half of the never-consult-disk boundary (PR #41 review, SONNY-35 F2).
    /// `unclaimedOutputPath` tests `claimed` twice — once on entry, once per candidate — and the
    /// first mutation battery only covered the candidate test. Teaching the *entry* test about the
    /// filesystem is the more dangerous violation of the same rule: it bumps a first generated
    /// destination that already exists to `-2`, which is exactly how the tier-3 "output already
    /// exists" escalation would be suppressed. No test had a first destination that already existed,
    /// so nothing noticed. This one does.
    @Test
    func aGeneratedDestinationThatAlreadyExistsOnDiskKeepsItsNameAndItsEscalation() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let occupied = root.appendingPathComponent("draft-alpha-\(Timestamp.fileSafe(stamp)).md")
        try write("existing draft", to: occupied)
        let executor = makeExecutor(root: root, now: { stamp })
        let plan = AgentPlan(
            summary: "Draft a note.",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "draft",
                    operation: .createLocalDraft,
                    description: "Create the draft.",
                    draftTitle: "Alpha",
                    draftContent: "A note."
                )
            ]
        )

        let prepared = try executor.prepare(plan: plan)
        let assessment = try executor.assessRisk(plan: plan, scope: .unscoped)

        #expect(prepared.plan.steps.first?.outputPath == occupied.path)
        #expect(assessment.effectiveTier == .tier3)
        #expect(assessment.escalations == [
            CapabilityRiskEscalation(
                fromTier: .tier2,
                toTier: .tier3,
                reason: "Draft output already exists at \(occupied.path).",
                consequence: .destructive
            )
        ])
    }

    /// A destination the plan named itself is never renamed, even when two steps name the same one.
    /// Writing somewhere other than where a plan explicitly said to would be a worse failure than
    /// the collision, and the existing-file case already has its own escalation.
    @Test
    func twoDraftsExplicitlyNamingOneDestinationAreLeftExactlyAsWritten() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = root.appendingPathComponent("shared.md")
        let executor = makeExecutor(root: root)

        let prepared = try executor.prepare(plan: draftChainPlan(first: shared, second: shared))

        #expect(prepared.plan.steps.first?.outputPath == shared.path)
        #expect(prepared.plan.steps.last?.outputPath == shared.path)
    }

    /// The half of SONNY-35 that could not have been fixed inside the adapter. A second
    /// `create_zip` with no destination defaults to a name inside **its own** pair's scan folder;
    /// an adapter handed the whole plan reads the first scan step for both and would answer with
    /// folder A twice.
    @Test
    func theSecondZipUnitsDefaultDestinationComesFromItsOwnScanFolder() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folderA = root.appendingPathComponent("A", isDirectory: true)
        let folderB = root.appendingPathComponent("B", isDirectory: true)
        try FileManager.default.createDirectory(at: folderA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folderB, withIntermediateDirectories: true)
        try write(String(repeating: "a", count: 2048), to: folderA.appendingPathComponent("from-a.txt"))
        try write(String(repeating: "b", count: 2048), to: folderB.appendingPathComponent("from-b.txt"))
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let executor = makeExecutor(root: root, now: { stamp })
        let plan = AgentPlan(
            summary: "Zip the largest files in both folders.",
            requiresConfirmation: true,
            steps: [
                AgentStep(id: "scan-a", operation: .scanSelectLargestFiles, description: "Scan A.", inputPath: folderA.path, count: 3),
                AgentStep(id: "zip-a", operation: .createZip, description: "Zip A.", inputPath: folderA.path, count: 3),
                AgentStep(id: "scan-b", operation: .scanSelectLargestFiles, description: "Scan B.", inputPath: folderB.path, count: 3),
                AgentStep(id: "zip-b", operation: .createZip, description: "Zip B.", inputPath: folderB.path, count: 3)
            ]
        )

        let prepared = try executor.prepare(plan: plan)

        let name = "largest-files-\(Timestamp.fileSafe(stamp)).zip"
        #expect(prepared.plan.steps[1].outputPath == folderA.appendingPathComponent(name).path)
        #expect(prepared.plan.steps[3].outputPath == folderB.appendingPathComponent(name).path)
    }

    /// Two `web_to_markdown` steps with no destinations generate the same default name in the same
    /// second, so without suffixing the second note overwrites the first and the run reports two
    /// saves of one file. Asserted on each file's contents, because two files both containing the
    /// second article would satisfy a bare existence check.
    @Test
    func twoWebResearchStepsWithNoDestinationsWriteTwoDistinctNotes() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstSource = URL(string: "https://example.com/first")!
        let secondSource = URL(string: "https://example.com/second")!
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let pageLoader = webPageLoader(pages: [
            firstSource.absoluteString: readablePage(url: firstSource, title: "First Article"),
            secondSource.absoluteString: readablePage(url: secondSource, title: "Second Article")
        ])
        let executor = makeExecutor(
            root: root,
            webPageLoader: pageLoader,
            webResearchSynthesizer: StaticWebResearchSynthesizer(
                note: WebResearchNote(title: "Note", summary: "A summary.", keyPoints: [], citations: [])
            ),
            now: { stamp }
        )
        let plan = AgentPlan(
            summary: "Summarize both articles.",
            requiresConfirmation: true,
            steps: [
                AgentStep(id: "research-1", operation: .webToMarkdown, description: "Summarize the first article.", targetURL: firstSource.absoluteString),
                AgentStep(id: "research-2", operation: .webToMarkdown, description: "Summarize the second article.", targetURL: secondSource.absoluteString)
            ]
        )

        let prepared = try executor.prepare(plan: plan)
        _ = try await executor.execute(plan: prepared.plan) { _, _ in }

        let firstPath = try #require(prepared.plan.steps.first?.outputPath)
        let secondPath = try #require(prepared.plan.steps.last?.outputPath)
        #expect(firstPath.hasSuffix("/web-research-\(Timestamp.fileSafe(stamp)).md"))
        #expect(secondPath.hasSuffix("/web-research-\(Timestamp.fileSafe(stamp))-2.md"))
        #expect(try String(contentsOf: URL(fileURLWithPath: firstPath)).contains("https://example.com/first"))
        #expect(try String(contentsOf: URL(fileURLWithPath: secondPath)).contains("https://example.com/second"))
    }

    /// The assessment-versus-execution half, with a clock that moves. `TickingClock` mints a new
    /// timestamp on every read, so a destination re-derived after the prepared plan was built lands
    /// somewhere else entirely: the run writes a file nothing assessed, previewed, or named on the
    /// approval panel. Every file the run creates has to be one the prepared plan already named.
    @Test
    func aChainWritesOnlyFilesThePreparedPlanAlreadyNamed() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = TickingClock()
        let executor = makeExecutor(root: root, now: { clock.next() })

        let prepared = try executor.prepare(plan: untitledDraftChainPlan(firstTitle: nil, secondTitle: nil))
        _ = try await executor.execute(plan: prepared.plan) { _, _ in }

        let promised = Set(prepared.plan.steps.compactMap(\.outputPath))
        let written = Set(
            try FileManager.default.contentsOfDirectory(atPath: root.path)
                .filter { $0.hasPrefix("draft-") }
                .map { root.appendingPathComponent($0).path }
        )
        #expect(promised.count == 2)
        #expect(written == promised)
    }

    // MARK: - SONNY-28: two documents never convert onto one PDF
    //
    // `FileInventory.docxFiles` derives each destination from the document's *basename* and
    // `regularFiles(in:)` recurses, so `SubA/report.docx` and `SubB/report.docx` both name
    // `report.pdf` — and with an explicit flat output folder they land in the same directory.
    // `skippedBecausePDFExists` cannot save them: it is evaluated once, at scan time, so against a
    // fresh output folder both answer `false` and both convert. There is no test double for
    // `FileInventory` and none is added: these drive the real one through the executor, with real
    // files in a real temp directory, which is this suite's existing idiom for docx.

    /// SONNY-28's concrete failure. Under the mock converter the second conversion silently
    /// destroyed the first; under the real Word converter its `moveItem` threw and aborted the whole
    /// batch, leaving every later document unprocessed. Both documents now get their own PDF.
    ///
    /// Asserted on the conversion *pairs*, not just on two files existing: a fix that renamed the
    /// destinations but paired them with the wrong sources would pass an existence check.
    @Test
    func twoSameNamedDocxFilesSharingAnOutputFolderConvertToDistinctPDFs() async throws {
        let fixture = try collidingDocxFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let executor = makeExecutor(root: fixture.root, documentConverter: FakeDocumentConverter())

        let result = try await executor.execute(plan: fixture.plan) { _, _ in }

        #expect(FileManager.default.fileExists(atPath: fixture.outputFolder.appendingPathComponent("report.pdf").path))
        #expect(FileManager.default.fileExists(atPath: fixture.outputFolder.appendingPathComponent("report-2.pdf").path))
        // Compared as folder/name tails: the scanned source paths come back canonicalised through
        // the whitelist (`/private/var/...`) while the output folder does not, and that difference
        // is not what this test is about.
        #expect(conversionTails(in: result) == [
            "SubA/report.docx -> PDFs/report.pdf",
            "SubB/report.docx -> PDFs/report-2.pdf"
        ])
    }

    /// A file appearing under a name the user did not ask for has to be said out loud. The run
    /// summary is the only free-text channel that reaches a person, so the note rides there —
    /// deliberately not as a risk escalation, which both approval panels label as *what raised this
    /// above its default tier*.
    @Test
    func aRenamedDocxOutputIsNamedInTheRunSummary() async throws {
        let fixture = try collidingDocxFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let executor = makeExecutor(root: fixture.root, documentConverter: FakeDocumentConverter())

        let result = try await executor.execute(plan: fixture.plan) { _, _ in }

        #expect(result.summary.hasSuffix(
            "Renamed 1 output because another document would produce the same PDF name: report-2.pdf."
        ))
    }

    // MARK: - SONNY-76: a chain's later units know what its earlier units wrote

    /// **The user asked for two PDFs, got one, and was told the second was "skipped because a PDF
    /// already exists" — pointing at the PDF this same run had written seconds earlier.**
    ///
    /// After SONNY-34 a two-folder conversion is two `[scan_docx, convert]` units, so the second
    /// re-scans an output folder the first has already written into. `skippedBecausePDFExists` is
    /// `fileManager.fileExists`, which cannot tell a file that predates the run from one this run
    /// made, so the second document was skipped rather than renamed.
    ///
    /// Asserted on the pairs and on the summary, because the misleading sentence was half the bug:
    /// a fix that produced both PDFs while still calling one "skipped" would leave the user with an
    /// explanation that names a file they never had.
    @Test
    func aSecondUnitRenamesAroundThePDFTheFirstUnitJustWrote() async throws {
        let fixture = try twoFolderChainFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let executor = makeExecutor(root: fixture.root, documentConverter: FakeDocumentConverter())

        let result = try await executor.execute(plan: fixture.plan) { _, _ in }

        #expect(FileManager.default.fileExists(atPath: fixture.outputFolder.appendingPathComponent("report.pdf").path))
        #expect(FileManager.default.fileExists(atPath: fixture.outputFolder.appendingPathComponent("report-2.pdf").path))
        #expect(conversionTails(in: result) == [
            "ClientA/report.docx -> PDFs/report.pdf",
            "ClientB/report.docx -> PDFs/report-2.pdf"
        ])
        #expect(!result.summary.contains("Skipped 1"))
        #expect(result.summary.contains("Renamed 1 output"))
    }

    /// **The skip rule itself is untouched: a PDF that really did predate the run is still skipped.**
    /// This is the half the fix could most easily have broken — treating every existing file as
    /// "ours" would convert over documents the user already had.
    @Test
    func aPDFThatPredatesTheRunIsStillSkipped() async throws {
        let fixture = try twoFolderChainFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try write("pre-existing", to: fixture.outputFolder.appendingPathComponent("report.pdf"))
        let executor = makeExecutor(root: fixture.root, documentConverter: FakeDocumentConverter())

        let result = try await executor.execute(plan: fixture.plan) { _, _ in }

        // Asserted on what the run *did*, not only on a sentence the first unit alone satisfies
        // (PR #65 review, Minor). Both units skip and nothing converts, so a fix that let the second
        // unit convert would still have produced "Skipped 1" and passed the old assertion.
        #expect(result.summary.contains("Skipped 1"))
        #expect(try String(contentsOf: fixture.outputFolder.appendingPathComponent("report.pdf"), encoding: .utf8) == "pre-existing")
        let pdfs = try FileManager.default.contentsOfDirectory(atPath: fixture.outputFolder.path)
            .filter { $0.hasSuffix(".pdf") }
            .sorted()
        #expect(pdfs == ["report.pdf"], "a predating PDF is never renamed around")
        #expect(conversionTails(in: result).isEmpty, "nothing was converted")
    }

    /// **The `locale: nil` half of the fold, pinned where it can be** (PR #65 review, F3).
    ///
    /// The closing comment claimed both rejected strengthenings had a mutation proving them wrong.
    /// Only the `.diacriticInsensitive` half did: changing `locale: nil` to `locale: .current` leaves
    /// the whole suite green, because `.current` is not Turkish on this machine and no test can make
    /// it so. That claim is corrected in the record; this is what can honestly be held.
    ///
    /// The first assertion establishes the trap is real rather than theoretical. The second is a
    /// genuine regression test **on a Turkish-locale machine**, where `.current` would unite these
    /// two names and the shipped fold must not — and is documentation everywhere else. Recorded as a
    /// partial pin rather than presented as a full one.
    @Test
    func theFoldDoesNotUniteTheNamesATurkishLocaleWould() {
        let turkish = Locale(identifier: "tr_TR")
        let foldedTurkish = { (name: String) in name.folding(options: [.caseInsensitive], locale: turkish) }

        #expect(foldedTurkish("İstanbul.pdf") == foldedTurkish("istanbul.pdf"), "the trap this avoids is real")
        #expect(DestinationKey.folded("İstanbul.pdf") != DestinationKey.folded("istanbul.pdf"))
    }

    /// **`RunClaims` folds its own keys, on both of the two ways one gets in** (SONNY-165).
    ///
    /// The destination set's guarantee used to hold only because four call sites in
    /// `FileInventory.docxFiles` each remembered to apply `DestinationKey.folded` before touching it,
    /// while `ConversionClaim` — added one review round later, in the same file — folded inside
    /// itself. Two mechanisms for one rule, agreeing until one is edited. Both are the type's now,
    /// and this holds both doors: the memberwise initializer and `recordWrite`.
    ///
    /// Case is the fold's own business, so the assertions use it rather than a path the caller could
    /// have normalised by hand. `hasWritten` folding its *argument* is the half that makes the four
    /// former call sites able to stop caring.
    @Test
    func runClaimsFoldsDestinationKeysWhicheverDoorTheyComeIn() {
        let built = RunClaims(destinations: ["/tmp/Reports/REPORT.PDF"])
        #expect(built.hasWritten("/tmp/Reports/report.pdf"))
        #expect(!built.hasWritten("/tmp/Reports/report-2.pdf"))

        var recorded = RunClaims.none
        recorded.recordWrite("/tmp/Reports/REPORT.PDF")
        #expect(recorded.hasWritten("/tmp/Reports/report.pdf"))

        // Both doors agree, which is the property that stops the rule having two spellings.
        #expect(built == recorded)
    }

    /// **The preview and the run agree about what the second unit will write.** Threading the claimed
    /// set through `executeChain` alone would have left the approval panel naming `report.pdf` while
    /// the run wrote `report-2.pdf` — a plan promising one file and writing another, which is exactly
    /// what `aChainWritesOnlyFilesThePreparedPlanAlreadyNamed` forbids.
    @Test
    func theChainsPreviewNamesTheRenamedDestinationTheRunWillWrite() throws {
        let fixture = try twoFolderChainFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let executor = makeExecutor(root: fixture.root, documentConverter: FakeDocumentConverter())

        let writes = try executor.preview(plan: fixture.plan).flatMap(\.writes)

        #expect(writes.contains { $0.hasSuffix("PDFs/report.pdf") })
        #expect(writes.contains { $0.hasSuffix("PDFs/report-2.pdf") })
    }

    /// **PROBE A from PR #65's review: two units whose scan scopes overlap, one source document.**
    /// `regularFiles(in:)` recurses, so scanning `Documents` and then `Documents/Sub` finds the same
    /// document twice. Before this fix the second unit saw its preferred destination already claimed
    /// and renamed: one document converted twice, a duplicate PDF the user never asked for, and a
    /// summary announcing a collision with "another document" that does not exist.
    ///
    /// **Both scans are in one command, deliberately.** A second *run* starts with an empty claimed
    /// set and takes the ordinary skip path, which is exactly why this ticket's manual item 2 does not
    /// reach this and why the regression has to be a chain.
    @Test
    func aUnitRescanningGroundAnEarlierUnitCoveredDoesNotConvertTheSameDocumentTwice() async throws {
        let fixture = try overlappingScopeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let executor = makeExecutor(root: fixture.root, documentConverter: FakeDocumentConverter())

        let result = try await executor.execute(plan: fixture.plan) { _, _ in }

        let pdfs = try FileManager.default.contentsOfDirectory(atPath: fixture.sub.path)
            .filter { $0.hasSuffix(".pdf") }
            .sorted()
        #expect(pdfs == ["report.pdf"], "one source document, one PDF")
        #expect(!result.summary.contains("Renamed"), "nothing collided, so nothing may claim a rename")
    }

    /// **PROBE B: the same folder scanned twice.** The degenerate case of the same defect, and the
    /// one a user reaches by asking for the same conversion twice in one sentence.
    @Test
    func aUnitRescanningTheSameFolderDoesNotConvertTheSameDocumentTwice() async throws {
        let fixture = try repeatedScopeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let executor = makeExecutor(root: fixture.root, documentConverter: FakeDocumentConverter())

        let result = try await executor.execute(plan: fixture.plan) { _, _ in }

        let pdfs = try FileManager.default.contentsOfDirectory(atPath: fixture.documents.path)
            .filter { $0.hasSuffix(".pdf") }
            .sorted()
        #expect(pdfs == ["report.pdf"])
        #expect(!result.summary.contains("Renamed"))
    }

    /// And the distinction the fix rests on: a *different* document with the same basename still
    /// renames. Suppressing re-conversion must not suppress the collision handling SONNY-76 added —
    /// these two cases differ only in whether the later unit's source is the same file.
    @Test
    func adifferentDocumentWithTheSameNameStillRenamesAcrossUnits() async throws {
        let fixture = try twoFolderChainFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let executor = makeExecutor(root: fixture.root, documentConverter: FakeDocumentConverter())

        let result = try await executor.execute(plan: fixture.plan) { _, _ in }

        #expect(conversionTails(in: result) == [
            "ClientA/report.docx -> PDFs/report.pdf",
            "ClientB/report.docx -> PDFs/report-2.pdf"
        ])
        #expect(result.summary.contains("Renamed 1 output"))
    }

    /// **PROBE F from PR #65's re-check: the same document, asked for in two different output
    /// folders.** The F1 fix keyed "already converted" on the source alone, so the second unit was
    /// skipped and the user was told a PDF already existed in `Out2` — a folder that was empty. That
    /// is the defect class SONNY-76 exists to fix, one step over: a conversion the user asked for,
    /// silently suppressed, explained by a file that does not exist.
    ///
    /// **Asserted on the files, not on the absence of a skip sentence.** A fix that stopped saying
    /// "Skipped 1" while still not converting would satisfy a summary-only assertion and leave the
    /// user exactly as short of a PDF as before.
    @Test
    func aLaterUnitAskingForTheSameDocumentInAnotherFolderStillConvertsIt() async throws {
        let fixture = try differingOutputFoldersFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let executor = makeExecutor(root: fixture.root, documentConverter: FakeDocumentConverter())

        let result = try await executor.execute(plan: fixture.plan) { _, _ in }

        #expect(FileManager.default.fileExists(
            atPath: fixture.firstOutput.appendingPathComponent("report.pdf").path
        ))
        #expect(
            FileManager.default.fileExists(
                atPath: fixture.secondOutput.appendingPathComponent("report.pdf").path
            ),
            "the second output folder is what the user asked for, and where nothing landed"
        )
        #expect(!result.summary.contains("Skipped 1"), "nothing was skipped, so nothing may say so")
    }

    /// **PROBE E: nested scan scopes, where the inner unit names a different output folder.** The
    /// sentence behind it — "convert the Word docs in Documents, and the ones in Documents/Invoices
    /// into DesktopInvoices". The outer unit's recursive scan reaches the same document first, so the
    /// inner unit was skipped and `DesktopInvoices` stayed empty.
    @Test
    func aNestedRescanIntoAnotherFolderStillConvertsTheDocument() async throws {
        let fixture = try nestedScopeIntoAnotherFolderFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let executor = makeExecutor(root: fixture.root, documentConverter: FakeDocumentConverter())

        let result = try await executor.execute(plan: fixture.plan) { _, _ in }

        #expect(
            FileManager.default.fileExists(
                atPath: fixture.firstOutput.appendingPathComponent("acme.pdf").path
            ),
            "the outer unit's default output, beside its source"
        )
        #expect(
            FileManager.default.fileExists(
                atPath: fixture.secondOutput.appendingPathComponent("acme.pdf").path
            ),
            "the folder the user actually named"
        )
        #expect(!result.summary.contains("No DOCX files needed conversion"))
    }

    /// **The half a narrower pair key would have broken, pinned so it cannot be.** Keying on the
    /// source and the full destination *path* passes both probes above and still reintroduces F1: a
    /// document renamed to `report-2.pdf` because a sibling took `report.pdf` would, on the next
    /// unit's re-scan, compute `report.pdf`, miss its own claim, and convert a second time to
    /// `report-3.pdf`. The shipped key is the destination *folder*, which a rename never changes.
    ///
    /// Green before this fix as well as after — it guards the fix rather than probing the defect,
    /// which is exactly why it is here: it is the case the fix could most easily have broken, and
    /// nothing else in the suite reaches a rename that is then re-scanned.
    @Test
    func aRenamedOutputIsNotConvertedAgainWhenALaterUnitRescansTheSameFolder() async throws {
        let fixture = try collidingBasenamesRescannedFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let executor = makeExecutor(root: fixture.root, documentConverter: FakeDocumentConverter())

        let result = try await executor.execute(plan: fixture.plan) { _, _ in }

        let pdfs = try FileManager.default.contentsOfDirectory(atPath: fixture.outputFolder.path)
            .filter { $0.hasSuffix(".pdf") }
            .sorted()
        #expect(pdfs == ["report-2.pdf", "report.pdf"], "two documents, two PDFs, and no third")
        #expect(result.summary.contains("Renamed 1 output"), "the one real collision is still announced")
    }

    // MARK: - SONNY-79: uniqueness folds the way the filesystem does

    /// **The pre-fix production failure, surviving in a narrow band until now.** `DestinationKey`
    /// compared destinations with `lowercased()`, which leaves `ß` alone while mapping `SS` to `ss`,
    /// so `Straße.pdf` and `STRASSE.pdf` were two keys here and one file on disk. Neither record was
    /// flagged as renamed, both claimed distinct destinations, and the batch then aborted at the
    /// converter with nothing in the summary explaining why — exactly the failure SONNY-28 fixed for
    /// the ASCII case pair, still reachable for this one.
    ///
    /// Driven through the real `FileInventory` against real files, like every other docx test here,
    /// so what is asserted is the volume's answer and not a fold's opinion of it.
    @Test
    func anEszettPairRenamesRatherThanAbortingTheBatch() async throws {
        let fixture = try collidingDocxFixture(nameA: "Straße", nameB: "STRASSE")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let executor = makeExecutor(root: fixture.root, documentConverter: FakeDocumentConverter())

        let result = try await executor.execute(plan: fixture.plan) { _, _ in }

        #expect(conversionTails(in: result) == [
            "SubA/Straße.docx -> PDFs/Straße.pdf",
            "SubB/STRASSE.docx -> PDFs/STRASSE-2.pdf"
        ])
        #expect(result.summary.contains("Renamed 1 output"))
    }

    /// **The control that makes the fold's *shape* testable, not just its strength.** `café` and
    /// `cafe` are two different files on disk, so neither may rename — a document appearing as
    /// `cafe-2.pdf` when nothing collided would be a fabricated rename the summary then announces.
    ///
    /// This is the assertion that fails if someone reaches for a bigger fold. Adding
    /// `.diacriticInsensitive` — which this repo's *search* normalisation uses, correctly, so that a
    /// user typing "cafe" finds "café" — folds these two together and breaks this test. The search
    /// question and the filesystem question are not the same question, and this is where that stops
    /// being an argument and becomes a red suite.
    @Test
    func aDiacriticPairIsTwoFilesAndNeitherRenames() async throws {
        let fixture = try collidingDocxFixture(nameA: "café", nameB: "cafe")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let executor = makeExecutor(root: fixture.root, documentConverter: FakeDocumentConverter())

        let result = try await executor.execute(plan: fixture.plan) { _, _ in }

        #expect(conversionTails(in: result) == [
            "SubA/café.docx -> PDFs/café.pdf",
            "SubB/cafe.docx -> PDFs/cafe.pdf"
        ])
        #expect(!result.summary.contains("Renamed"))
    }

    /// The renamed destination never lands on a real file either — suffixing onto something that
    /// already exists would trade one silent overwrite for another. With `report-2.pdf` already on
    /// disk the second document becomes `report-3.pdf`, and the pre-existing file is left untouched.
    @Test
    func aRenamedDocxDestinationSkipsPastNamesThatAlreadyExistOnDisk() async throws {
        let fixture = try collidingDocxFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let occupied = fixture.outputFolder.appendingPathComponent("report-2.pdf")
        try write("someone else's pdf", to: occupied)
        let executor = makeExecutor(root: fixture.root, documentConverter: FakeDocumentConverter())

        _ = try await executor.execute(plan: fixture.plan) { _, _ in }

        #expect(try String(contentsOf: occupied) == "someone else's pdf")
        #expect(FileManager.default.fileExists(atPath: fixture.outputFolder.appendingPathComponent("report-3.pdf").path))
    }

    /// No-drift on the skip rule, which the rename must not swallow. A document whose *own*
    /// destination already exists is still skipped and still reported as skipped — it does not get
    /// renamed onto a free name and converted anyway, which would be this fix quietly overriding a
    /// deliberate behavior.
    @Test
    func aDocxWhoseOwnPDFAlreadyExistsIsStillSkippedRatherThanRenamed() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("docx-a", to: root.appendingPathComponent("a.docx"))
        try write("existing", to: root.appendingPathComponent("a.pdf"))
        let executor = makeExecutor(root: root, documentConverter: FakeDocumentConverter())

        let result = try await executor.execute(plan: docxPlan(root: root)) { _, _ in }

        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("a-2.pdf").path))
        #expect(try String(contentsOf: root.appendingPathComponent("a.pdf")) == "existing")
        #expect(result.summary == "No DOCX files needed conversion in \(root.path). Skipped 1 existing PDF outputs.")
    }

    /// Two basenames differing only in case are one file on the default macOS volume, so the
    /// uniqueness comparison folds case and Unicode form (PR #41 review, SONNY-28 F1). Comparing raw
    /// paths gave both documents a destination that looked free, neither was flagged as renamed, and
    /// the run then hit the converter's refusal and aborted the batch — the pre-fix production
    /// failure this ticket set out to end, plus pre-fix silence about why.
    ///
    /// Asserted on the completed conversion rather than only on the record shapes, because "the batch
    /// finishes" is the property that was actually lost.
    @Test
    func twoDocxBasenamesDifferingOnlyInCaseStillConvertToDistinctPDFs() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let documents = root.appendingPathComponent("Documents", isDirectory: true)
        let subA = documents.appendingPathComponent("SubA", isDirectory: true)
        let subB = documents.appendingPathComponent("SubB", isDirectory: true)
        let outputFolder = root.appendingPathComponent("PDFs", isDirectory: true)
        for directory in [subA, subB, outputFolder] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try write("docx-a", to: subA.appendingPathComponent("Report.docx"))
        try write("docx-b", to: subB.appendingPathComponent("report.docx"))
        let executor = makeExecutor(root: root, documentConverter: FakeDocumentConverter())
        let plan = AgentPlan(
            summary: "Convert the Word documents to PDF.",
            requiresConfirmation: true,
            steps: [
                AgentStep(id: "scan", operation: .scanDocx, description: "Scan DOCX.", inputPath: documents.path),
                AgentStep(
                    id: "convert",
                    operation: .convertDocxToPDF,
                    description: "Convert DOCX.",
                    inputPath: documents.path,
                    outputPath: outputFolder.path
                )
            ]
        )

        let result = try await executor.execute(plan: plan) { _, _ in }

        #expect(conversionTails(in: result) == [
            "SubA/Report.docx -> PDFs/Report.pdf",
            "SubB/report.docx -> PDFs/report-2.pdf"
        ])
        #expect(result.summary.hasSuffix(
            "Renamed 1 output because another document would produce the same PDF name: report-2.pdf."
        ))
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: outputFolder.path).sorted()
                == ["Report.pdf", "report-2.pdf"]
        )
    }

    /// Mock fidelity, the second half of the user's 2026-08-04 triage. `MockDocumentConverter` wrote
    /// with `.atomic`, which replaces an existing file, while `MicrosoftWordDocumentConverter`
    /// finishes with `moveItem`, which throws — so the one converter a developer exercises had a
    /// different failure mode from the one real users hit, at the exact moment that matters. Both
    /// now refuse. Driven directly rather than through the executor because reaching this path
    /// otherwise needs a process-wide environment variable.
    @Test
    func theMockConverterRefusesToOverwriteAnOccupiedDestinationInsteadOfClobberingIt() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("report.mock.pdf")
        try write("an earlier pdf", to: destination)
        let converter = MockDocumentConverter(enabled: true)
        let record = DocxRecord(
            sourceURL: root.appendingPathComponent("report.docx"),
            destinationURL: destination,
            skippedBecausePDFExists: false
        )

        await #expect(throws: DocumentConversionError.mockWriteFailed(
            "Could not write mock PDF to \(destination.path): a file already exists there."
        )) {
            _ = try await converter.convert([record]) { _ in }
        }
        #expect(try String(contentsOf: destination) == "an earlier pdf")
    }

    /// The same converter still writes normally when the destination is free — the guard above must
    /// refuse a collision, not refuse everything.
    @Test
    func theMockConverterStillWritesWhenTheDestinationIsFree() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("report.mock.pdf")
        let converter = MockDocumentConverter(enabled: true)
        let record = DocxRecord(
            sourceURL: root.appendingPathComponent("report.docx"),
            destinationURL: destination,
            skippedBecausePDFExists: false
        )

        let converted = try await converter.convert([record]) { _ in }

        #expect(converted.map(\.destinationURL) == [destination])
        #expect(try String(contentsOf: destination).contains("Mock PDF placeholder"))
    }

    // MARK: - SONNY-30: an unreadable store cannot pass for an empty one
    //
    // `CreateWorkspaceCapabilityAdapter` and `SaveRoutineCapabilityAdapter` decided "does this name
    // already exist?" with `(try? store.thing(named:)) != nil`, which answers the same for a store
    // that failed to decrypt as for one that simply has no such name. The consequence is the wrong
    // direction of wrong: the tier-3 "already exists and would be replaced" escalation vanishes for
    // exactly the user whose store is broken, and they approve a routine-looking tier-2 save with
    // real saved content in play. `EditWorkspaceTests` pins the same rule for the sibling that
    // always got it right; these two are that adapter's missing counterparts.

    /// A `workspaces.json` that cannot be decrypted has to surface as a failure, not as "no
    /// workspace by that name". Asserted as "threw, and not with an `AutomationStoreError`" — the
    /// enum has no load-failure case, so a `.missingWorkspace` escaping here would mean the
    /// distinction was lost again somewhere between the store and the adapter.
    @Test
    func aCorruptWorkspaceStoreSurfacesRatherThanSuppressingTheReplacementEscalation() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try corruptStore(at: root.appendingPathComponent("workspaces.json"))
        let executor = makeExecutor(root: root)

        var thrown: Error?
        do {
            _ = try executor.assessRisk(plan: createWorkspacePlan(named: "Research"), scope: .unscoped)
        } catch {
            thrown = error
        }

        let error = try #require(thrown)
        #expect(!(error is AutomationStoreError))
    }

    /// The same for `routines.json`.
    @Test
    func aCorruptRoutineStoreSurfacesRatherThanSuppressingTheReplacementEscalation() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try corruptStore(at: root.appendingPathComponent("routines.json"))
        let executor = makeExecutor(root: root)

        var thrown: Error?
        do {
            _ = try executor.assessRisk(plan: saveRoutinePlan(named: "Morning Setup"), scope: .unscoped)
        } catch {
            thrown = error
        }

        let error = try #require(thrown)
        #expect(!(error is AutomationStoreError))
    }

    /// What the added interruption actually says (PR #41 review, SONNY-30 F1). The escalation this
    /// ticket restores is the branch's one deliberate new prompt, so the sentence a user meets is
    /// part of the fix, not decoration — and it was
    /// "The operation couldn't be completed. (CryptoKit.CryptoKitError error 3.)", because
    /// `AES.GCM` throws a type with no `LocalizedError` conformance and `AgentViewModel`'s generic
    /// catch renders `localizedDescription` straight into the task error and into task history.
    ///
    /// Asserted from the executor's throw, which is the string that catch receives.
    @Test
    func aCorruptStoreFailureNamesDecryptionRatherThanACryptoKitErrorCode() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try corruptStore(at: root.appendingPathComponent("routines.json"))
        let executor = makeExecutor(root: root)

        var thrown: Error?
        do {
            _ = try executor.assessRisk(plan: saveRoutinePlan(named: "Morning Setup"), scope: .unscoped)
        } catch {
            thrown = error
        }

        let message = try #require(thrown).localizedDescription
        #expect(message == "A local data file exists but could not be decrypted or decoded.")
        #expect(!message.contains("CryptoKit"))
    }

    /// A blank name is a malformed request whatever the store's health, and the answer must not
    /// depend on whether the file happens to decrypt (PR #41 review, SONNY-30 F3). Driven against the
    /// store directly: both adapters guard the name upstream, so the executor cannot reach it.
    @Test
    func aBlankRoutineNameThrowsMissingNameEvenAgainstAnUnreadableStore() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = root.appendingPathComponent("routines.json")
        try corruptStore(at: storeURL)
        let store = RoutineStore(fileURL: storeURL)

        #expect(throws: AutomationStoreError.missingName("Routine")) {
            _ = try store.findRoutine(named: "   ")
        }
        // The same store, a real name: now the load failure is the honest answer.
        #expect(throws: LocalStorageEncryptionError.self) {
            _ = try store.findRoutine(named: "Morning Setup")
        }
    }

    /// The load-bearing inverse. Surfacing a broken store must not turn a *healthy* store with no
    /// such name into a failure, or every first-time save would break — and it must not invent an
    /// escalation either. A genuinely new workspace stays exactly where it was: tier 2, nothing
    /// raised, lightweight confirmation.
    @Test
    func creatingAWorkspaceThatDoesNotExistYetStaysAtTierTwoWithNoEscalation() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = makeExecutor(root: root)

        let assessment = try executor.assessRisk(plan: createWorkspacePlan(named: "Research"), scope: .unscoped)

        #expect(assessment.defaultTier == .tier2)
        #expect(assessment.effectiveTier == .tier2)
        #expect(assessment.escalations.isEmpty)
        #expect(RiskApprovalPolicy.default.requirement(for: assessment, context: plannerContext) == .autoRun)
    }

    /// And the escalation the `try?` was suppressing still fires when it should: a name that really
    /// is saved, in a store that really does load, raises tier 3 and says why.
    @Test
    func creatingAWorkspaceThatAlreadyExistsStillEscalatesAndNamesIt() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaceStore = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        try workspaceStore.save(StoredWorkspace(name: "Research", apps: ["Safari"], urls: []))
        let executor = makeExecutor(root: root, workspaceStore: workspaceStore)

        let assessment = try executor.assessRisk(plan: createWorkspacePlan(named: "Research"), scope: .unscoped)

        #expect(assessment.effectiveTier == .tier3)
        #expect(assessment.escalations == [
            CapabilityRiskEscalation(
                fromTier: .tier2,
                toTier: .tier3,
                reason: "Workspace named Research already exists and would be replaced.",
                consequence: .destructive
            )
        ])
    }

    /// The routine half of the same inverse pair, collapsed into one test because the routine
    /// adapter's escalation and its no-escalation case share a fixture: save one routine, then
    /// assess a save of that name and of a different name.
    @Test
    func savingARoutineEscalatesOnlyWhenThatNameIsReallyTaken() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let routineStore = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))
        try routineStore.save(
            StoredRoutine(
                name: "Morning Setup",
                steps: [AgentStep(id: "open", operation: .openApp, description: "Open Safari.", appName: "Safari")]
            )
        )
        let executor = makeExecutor(root: root, routineStore: routineStore)

        let taken = try executor.assessRisk(plan: saveRoutinePlan(named: "Morning Setup"), scope: .unscoped)
        let free = try executor.assessRisk(plan: saveRoutinePlan(named: "Evening Wind Down"), scope: .unscoped)

        #expect(taken.effectiveTier == .tier3)
        #expect(taken.escalations == [
            CapabilityRiskEscalation(
                fromTier: .tier2,
                toTier: .tier3,
                reason: "Routine named Morning Setup already exists and would be replaced.",
                consequence: .destructive
            )
        ])
        #expect(free.effectiveTier == .tier2)
        #expect(free.escalations.isEmpty)
    }

    // MARK: - SONNY-24: a routine binds its own browser

    /// Order independence, the half that is not obvious. The founder decision (2026-08-04) is that
    /// the first browser-capable app *anywhere* in the routine binds every URL step, so a URL
    /// sequenced **before** the browser step still binds — the routine's browser is a property of
    /// the routine, not of what has run so far. An order-sensitive reading (option b) was declined
    /// precisely because it makes the same routine behave differently for a reason the user cannot
    /// see in the Routines list.
    @Test
    func aURLStepSequencedBeforeTheBrowserStepStillBindsToTheRoutinesBrowser() async throws {
        let browserOpener = RecordingBrowserOpener()
        let fixture = try await routineFixture(
            named: "Reversed",
            steps: [
                AgentStep(id: "open-github", operation: .openURL, description: "Open GitHub.", targetURL: "https://github.com"),
                AgentStep(id: "open-safari", operation: .openApp, description: "Open Safari.", appName: "Safari")
            ],
            browserOpener: browserOpener
        )
        defer { fixture.cleanUp() }

        _ = try await fixture.executor.execute(plan: RunRoutineCapabilityAdapter.plan(forRoutineNamed: "Reversed")) { _, _ in }

        #expect(browserOpener.openedBrowsers == [MacApp(displayName: "Safari", bundleIdentifier: "com.apple.Safari")])
    }

    /// Two browsers: the first in step order wins. Chrome first, Safari second, so a "last one
    /// wins" implementation returns Safari and fails here.
    ///
    /// It does **not** exclude an alphabetical implementation — "Chrome" sorts before "Safari", so
    /// alphabetical returns the expected value and would pass. Step order and alphabetical order
    /// agree for this pair; separating them needs a fixture whose first browser sorts later, and
    /// the catalog carries only these two browsers today (PR #28, F6 — the earlier comment here
    /// claimed both were excluded, which was simply false).
    @Test
    func aRoutineNamingTwoBrowsersBindsTheFirstOneInStepOrder() async throws {
        let browserOpener = RecordingBrowserOpener()
        let fixture = try await routineFixture(
            named: "Both Browsers",
            steps: [
                AgentStep(id: "open-chrome", operation: .openApp, description: "Open Chrome.", appName: "Chrome"),
                AgentStep(id: "open-safari", operation: .openApp, description: "Open Safari.", appName: "Safari"),
                AgentStep(id: "open-github", operation: .openURL, description: "Open GitHub.", targetURL: "https://github.com")
            ],
            browserOpener: browserOpener
        )
        defer { fixture.cleanUp() }

        _ = try await fixture.executor.execute(plan: RunRoutineCapabilityAdapter.plan(forRoutineNamed: "Both Browsers")) { _, _ in }

        // No `aliases:` on the expectation any more. The routine's browser is resolved through
        // `InstalledAppResolver` since SONNY-82, and an `InstalledApp` carries the identity Launch
        // Services answers with — a display name and a bundle identifier — not the alias-table
        // entry's list of other spellings. Nothing downstream reads `MacApp.aliases`
        // (`WorkspaceBrowserCatalog` keys on the bundle identifier, `AppOpening` takes only the
        // identifier, and the browser opener uses the identifier plus the display name), so the list
        // was incidental to what this test pins: which of two browsers binds, and in what order.
        #expect(browserOpener.openedBrowsers == [MacApp(displayName: "Chrome", bundleIdentifier: "com.google.Chrome")])
    }

    /// A routine that opens an app which is not a browser must be completely unchanged — no
    /// binding, system default, exactly as before this ticket. This is the guard against the fix
    /// over-reaching into "any app the routine opens becomes its browser".
    @Test
    func aRoutineWithNoBrowserStepStillUsesTheSystemDefault() async throws {
        let browserOpener = RecordingBrowserOpener()
        let fixture = try await routineFixture(
            named: "Notes Only",
            steps: [
                AgentStep(id: "open-notes", operation: .openApp, description: "Open Notes.", appName: "Notes"),
                AgentStep(id: "open-github", operation: .openURL, description: "Open GitHub.", targetURL: "https://github.com")
            ],
            browserOpener: browserOpener
        )
        defer { fixture.cleanUp() }

        _ = try await fixture.executor.execute(plan: RunRoutineCapabilityAdapter.plan(forRoutineNamed: "Notes Only")) { _, _ in }

        #expect(browserOpener.openedURLs.map(\.absoluteString) == ["https://github.com"])
        #expect(browserOpener.openedBrowsers == [nil])
    }

    /// Scheduled/unattended parity. A scheduled run executes exactly this plan literal — the
    /// scheduler and the typed command share `RunRoutineCapabilityAdapter.plan(forRoutineNamed:)`
    /// for that reason — through `AgentRunner.execute` carrying the only tier an unattended run can
    /// ever hold, `.approved(.tier2)` (`AgentViewModel`'s scheduled path). Binding happens inside
    /// the executor, below any notion of what triggered the run, so proving it here proves it for
    /// the scheduler without reaching into the UI layer, which this ticket must not touch.
    @Test
    func anUnattendedRunOfTheSameRoutineBindsTheSameBrowser() async throws {
        let browserOpener = RecordingBrowserOpener()
        let fixture = try await routineFixture(
            named: "Morning",
            steps: [
                AgentStep(id: "open-safari", operation: .openApp, description: "Open Safari.", appName: "Safari"),
                AgentStep(id: "open-github", operation: .openURL, description: "Open GitHub.", targetURL: "https://github.com")
            ],
            browserOpener: browserOpener
        )
        defer { fixture.cleanUp() }
        // `plannerProvider` rather than a fake planner type: this plan is built directly, so the
        // provider is never invoked, and the module already carries six duplicate `FailingPlanner`
        // definitions without this adding a seventh.
        let runner = AgentRunner(
            plannerProvider: { throw AgentExecutionError.emptyCommand },
            executor: fixture.executor
        )
        let prepared = try runner.prepare(
            plan: RunRoutineCapabilityAdapter.plan(forRoutineNamed: "Morning"),
            source: .instantResolver
        )

        _ = try await runner.execute(
            prepared,
            approvalDecision: .approved(.tier2),
            scope: .unscoped,
            context: ApprovalContext(mode: .normal, appControl: .notApplicable)
        )

        #expect(browserOpener.openedBrowsers == [MacApp(displayName: "Safari", bundleIdentifier: "com.apple.Safari")])
    }

    /// The routine's browser binds URL opens on the injected browser-opener seam, not only its
    /// `open_url` steps — an app-search URL opened inside a routine that launched Safari belongs in
    /// Safari too. This
    /// is the reading the implementation took of "every URL open inside that routine" — meaning
    /// every URL opened on the injected browser-opener seam, which is where this adapter sits — so it
    /// is pinned rather than left as an accident of which adapter reads `preferredBrowser`.
    ///
    /// Its counterpart is already pinned elsewhere and must stay so: the *standalone* app-search
    /// URL sites assert `[nil]`, because a search URL with no routine around it is still an
    /// ordinary open and keeps the system default.
    @Test
    func aRoutinesAppSearchURLStepAlsoBindsToTheRoutinesBrowser() async throws {
        let browserOpener = RecordingBrowserOpener()
        let fixture = try await routineFixture(
            named: "Search In Safari",
            steps: [
                AgentStep(id: "open-safari", operation: .openApp, description: "Open Safari.", appName: "Safari"),
                AgentStep(
                    id: "search-github",
                    operation: .openAppSearchURL,
                    description: "Open search URL.",
                    appName: "GitHub",
                    searchQuery: "Swift concurrency"
                )
            ],
            browserOpener: browserOpener
        )
        defer { fixture.cleanUp() }

        _ = try await fixture.executor.execute(plan: RunRoutineCapabilityAdapter.plan(forRoutineNamed: "Search In Safari")) { _, _ in }

        #expect(browserOpener.openedBrowsers == [MacApp(displayName: "Safari", bundleIdentifier: "com.apple.Safari")])
    }

    /// PR #28, F2. The Hacker News open was the third adapter edited to read `preferredBrowser`,
    /// and it was the only one whose edit nothing pinned: reverting it to the no-browser shorthand
    /// left the whole suite green, because no test ran an HN step *inside a routine*. The
    /// standalone HN guard proves the opposite direction — that a bare HN open stays on the system
    /// default — and cannot substitute. Same justification the app-search pin already carries.
    @Test
    func aRoutinesHackerNewsStepAlsoBindsToTheRoutinesBrowser() async throws {
        let browserOpener = RecordingBrowserOpener()
        let fixture = try await routineFixture(
            named: "Morning Reading",
            steps: [
                AgentStep(id: "open-safari", operation: .openApp, description: "Open Safari.", appName: "Safari"),
                AgentStep(id: "open-hn", operation: .openHackerNews, description: "Open Hacker News.")
            ],
            browserOpener: browserOpener
        )
        defer { fixture.cleanUp() }

        _ = try await fixture.executor.execute(plan: RunRoutineCapabilityAdapter.plan(forRoutineNamed: "Morning Reading")) { _, _ in }

        #expect(browserOpener.openedURLs.map(\.absoluteString) == ["https://news.ycombinator.com"])
        #expect(browserOpener.openedBrowsers == [MacApp(displayName: "Safari", bundleIdentifier: "com.apple.Safari")])
    }

    /// PR #28, F3. Browser resolution skips app names the catalog cannot resolve rather than
    /// throwing, so that a stale app name fails when *its own step* runs instead of pre-empting
    /// every step with a different error. That skip branch was unpinned, and the reviewer proved it
    /// green when removed.
    ///
    /// Reaching it requires writing past `validateRoutineSteps`, which would reject this routine at
    /// save time — which is exactly why the store-level write is used here. The rejection is
    /// `previewNestedPlan`'s, not the forbidden-operation list's: every step below is a legal
    /// routine operation, and "Ghostwriter 2003" is simply an app name the catalog cannot resolve.
    /// So plain `save` is still the right door after SONNY-52 closed the forbidden-operation half
    /// of that asymmetry; the half that remains open is deliberate, since no store can run a
    /// capability's nested preview.
    @Test
    func anUnresolvableAppNameIsSkippedRatherThanBlockingBrowserResolution() async throws {
        let browserOpener = RecordingBrowserOpener()
        let fixture = try routineFixtureWrittenDirectlyToStore(
            named: "Stale App",
            steps: [
                AgentStep(id: "open-safari", operation: .openApp, description: "Open Safari.", appName: "Safari"),
                AgentStep(id: "open-github", operation: .openURL, description: "Open GitHub.", targetURL: "https://github.com"),
                // Deliberately *after* the URL step. With the unknown app first, its own step throws
                // before any URL opens and the assertions below pass vacuously on an empty array —
                // which is how the first draft of this test proved nothing at all.
                AgentStep(id: "open-ghost", operation: .openApp, description: "Open a retired app.", appName: "Ghostwriter 2003")
            ],
            browserOpener: browserOpener
        )
        defer { fixture.cleanUp() }

        // The unknown step still fails when it runs, so the routine does not complete — but the URL
        // before it has already opened, bound to Safari. Resolution throwing instead of skipping
        // would take the whole run down before any step, leaving this array empty.
        _ = try? await fixture.executor.execute(plan: RunRoutineCapabilityAdapter.plan(forRoutineNamed: "Stale App")) { _, _ in }

        #expect(browserOpener.openedURLs.map(\.absoluteString) == ["https://github.com"])
        #expect(browserOpener.openedBrowsers == [MacApp(displayName: "Safari", bundleIdentifier: "com.apple.Safari")])
    }

    /// An executor plus the temp directory it owns. Returning the root is the point: the earlier
    /// shape returned only the executor, so no caller could delete the directory it had created and
    /// every one of these tests leaked one (PR #28, F7).
    ///
    /// Every caller must `defer { fixture.cleanUp() }`. The first pass at F7 added that line by
    /// pattern-matching the call shape and so missed the one test that hands the executor to an
    /// `AgentRunner` instead of calling it directly — which is why the claim is written here as a
    /// requirement on callers rather than as a description of them.
    private struct RoutineFixture {
        let executor: AgentActionExecutor
        let root: URL

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// Saves a routine through the real `save_routine` path, so the fixture exercises a routine
    /// that genuinely passed `validateRoutineSteps`.
    private func routineFixture(
        named name: String,
        steps: [AgentStep],
        browserOpener: RecordingBrowserOpener
    ) async throws -> RoutineFixture {
        let fixture = try makeRoutineFixture(browserOpener: browserOpener)
        let savePlan = AgentPlan(
            summary: "Teach routine.",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "save-routine",
                    operation: .saveRoutine,
                    description: "Save routine.",
                    routineName: name,
                    routineSteps: steps
                )
            ]
        )
        _ = try await fixture.executor.execute(plan: savePlan) { _, _ in }
        return fixture
    }

    /// Writes the routine straight to the store, bypassing the save capability's own
    /// `previewNestedPlan` check.
    ///
    /// Not a shortcut — it is the only way to build a routine the save capability rejects. It is
    /// still plain `save`, and deliberately so: SONNY-52 moved the *forbidden-operation* list to
    /// `RoutineStore.save`, so the store now refuses those, but the routines these fixtures need
    /// are refused by `previewNestedPlan` (an app name the catalog cannot resolve), which no store
    /// can evaluate without a capability execution context. A routine that carried a forbidden
    /// operation would need `saveBypassingStepValidation` instead.
    private func routineFixtureWrittenDirectlyToStore(
        named name: String,
        steps: [AgentStep],
        browserOpener: RecordingBrowserOpener
    ) throws -> RoutineFixture {
        let fixture = try makeRoutineFixture(browserOpener: browserOpener)
        try RoutineStore(fileURL: fixture.root.appendingPathComponent("routines.json"))
            .save(StoredRoutine(name: name, steps: steps))
        return fixture
    }

    private func makeRoutineFixture(browserOpener: RecordingBrowserOpener) throws -> RoutineFixture {
        let root = try makeDirectory()
        return RoutineFixture(
            executor: makeExecutor(
                root: root,
                browserOpener: browserOpener,
                appOpener: RecordingAppOpener(),
                routineStore: RoutineStore(fileURL: root.appendingPathComponent("routines.json"))
            ),
            root: root
        )
    }

    @Test
    func docxPreviewDestinationNamingMatchesInjectedConverter() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("docx-b", to: root.appendingPathComponent("b.docx"))
        let executor = makeExecutor(root: root, documentConverter: MockDocumentConverter())

        let preview = try executor.preview(plan: docxPlan(root: root))

        #expect(preview.first?.details.contains("Converter: Mock DOCX placeholder") == true)
        #expect(preview.first?.writes.isEmpty == false)
        #expect(preview.first?.writes.allSatisfy { $0.hasSuffix(".mock.pdf") } == true)
    }

    @Test
    func docxPreviewCanUseSelectedFinderFolderContext() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("docx-b", to: root.appendingPathComponent("b.docx"))
        let executor = makeExecutor(
            root: root,
            finderContextReader: FakeFinderContextReader(selection: [root])
        )
        let plan = AgentPlan(
            summary: "Convert selected Finder folder.",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "scan-docx",
                    operation: .scanDocx,
                    description: "Scan selected Finder folder.",
                    contextSource: .finderSelection
                ),
                AgentStep(
                    id: "convert-docx",
                    operation: .convertDocxToPDF,
                    description: "Convert selected Finder folder.",
                    contextSource: .finderSelection
                )
            ]
        )

        let preview = try executor.preview(plan: plan)

        #expect(preview.first?.title == "Convert 1 DOCX files")
        #expect(preview.first?.writes.first?.hasSuffix("/\(root.lastPathComponent)/b.pdf") == true)
    }

    @Test
    func outputFileNormalizerMakesPDFUserReadable() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pdf = root.appendingPathComponent("normalized.pdf")
        try write("%PDF-1.7", to: pdf)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pdf.path)

        OutputFileNormalizer.normalizeUserWritablePDF(at: pdf)

        let attributes = try FileManager.default.attributesOfItem(atPath: pdf.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue & 0o777 == 0o644)
    }

    @Test
    func hackerNewsDryRunDoesNotWriteMarkdown() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("hn.md")
        let executor = makeExecutor(root: root)

        let preview = try executor.preview(plan: hnPlan(output: output))

        #expect(preview.first?.writes == [output.path])
        #expect(preview.first?.opens == ["https://news.ycombinator.com"])
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test
    func hackerNewsExecutionWritesFixtureMarkdown() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("hn.md")
        let browserOpener = RecordingBrowserOpener()
        let executor = makeExecutor(
            root: root,
            browserOpener: browserOpener,
            hackerNewsFetcher: StaticHackerNewsFetcher()
        )

        let result = try await executor.execute(plan: hnPlan(output: output)) { _, _ in }

        let markdown = try String(contentsOf: output)
        #expect(markdown.contains("Fixture headline"))
        #expect(browserOpener.openedURLs.map(\.absoluteString) == ["https://news.ycombinator.com"])
        // Non-workspace caller: the Hacker News link still goes to the system default browser.
        #expect(browserOpener.openedBrowsers == [nil])
        #expect(result.suggestions.contains { suggestion in
            suggestion.title == "Reveal Markdown in Finder" &&
                suggestion.kind == .revealInFinder &&
                suggestion.value == output.path
        })
    }

    @Test
    func webResearchExecutionWritesMarkdownWithSourcesAndSuggestions() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("web-note.md")
        let source = URL(string: "https://example.com/article")!
        let retrievedAt = Date(timeIntervalSince1970: 1_783_526_400)
        let pageLoader = webPageLoader(pages: [
            source.absoluteString: readablePage(
                url: source,
                retrievedAt: retrievedAt,
                title: "Article One"
            )
        ])
        let synthesizer = StaticWebResearchSynthesizer(
            note: WebResearchNote(
                title: "Article One Notes",
                summary: "A concise summary.",
                keyPoints: ["First point"],
                citations: ["Article One citation"]
            )
        )
        let executor = makeExecutor(
            root: root,
            webPageLoader: pageLoader,
            webResearchSynthesizer: synthesizer
        )

        let result = try await executor.execute(plan: webMarkdownPlan(url: source, output: output)) { _, _ in }

        let markdown = try String(contentsOf: output)
        #expect(markdown.contains("# Article One Notes"))
        #expect(markdown.contains("Generated:"))
        #expect(markdown.contains("- [Article One](https://example.com/article)"))
        #expect(markdown.contains("Retrieved: 2026-07-08T16:00:00Z"))
        #expect(markdown.contains("A concise summary."))
        #expect(synthesizer.prompts.count == 1)
        #expect(synthesizer.prompts[0].trustedPlan.steps.map(\.operation) == [.webToMarkdown])
        #expect(result.suggestions.contains { suggestion in
            suggestion.title == "Open Markdown" &&
                suggestion.kind == .openFile &&
                suggestion.value == output.path
        })
        #expect(result.suggestions.contains { suggestion in
            suggestion.title == "Reveal Markdown in Finder" &&
                suggestion.kind == .revealInFinder &&
                suggestion.value == output.path
        })
    }

    @Test
    func webResearchCanWriteComparisonMarkdownForMultipleSources() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("comparison.md")
        let first = URL(string: "https://example.com/one")!
        let second = URL(string: "https://example.com/two")!
        let pageLoader = webPageLoader(pages: [
            first.absoluteString: readablePage(url: first, title: "First Source"),
            second.absoluteString: readablePage(url: second, title: "Second Source")
        ])
        let executor = makeExecutor(
            root: root,
            webPageLoader: pageLoader,
            webResearchSynthesizer: StaticWebResearchSynthesizer(
                note: WebResearchNote(
                    title: "Comparison",
                    summary: "The sources differ.",
                    keyPoints: ["Compare point"],
                    citations: []
                )
            )
        )

        let result = try await executor.execute(
            plan: webComparisonPlan(urls: [first, second], output: output)
        ) { _, _ in }

        let markdown = try String(contentsOf: output)
        #expect(markdown.contains("# Comparison"))
        #expect(markdown.contains("- [First Source](https://example.com/one)"))
        #expect(markdown.contains("- [Second Source](https://example.com/two)"))
        #expect(result.summary == "Saved comparison Markdown for 2 sources to \(output.path).")
    }

    @Test
    func webResearchSynthesizesFromSourcesThatSucceededAndNamesTheSkippedOnes() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("comparison.md")
        let first = URL(string: "https://example.com/one")!
        let second = URL(string: "https://example.com/two")!
        let unreachable = URL(string: "https://example.com/missing")!
        // Only the first two are in the fixture map; the third throws on fetch.
        let pageLoader = webPageLoader(pages: [
            first.absoluteString: readablePage(url: first, title: "First Source"),
            second.absoluteString: readablePage(url: second, title: "Second Source")
        ])
        let executor = makeExecutor(
            root: root,
            webPageLoader: pageLoader,
            webResearchSynthesizer: StaticWebResearchSynthesizer(
                note: WebResearchNote(
                    title: "Comparison",
                    summary: "The reachable sources differ.",
                    keyPoints: ["Compare point"],
                    citations: []
                )
            )
        )

        let result = try await executor.execute(
            plan: webComparisonPlan(urls: [first, second, unreachable], output: output)
        ) { _, _ in }

        let markdown = try String(contentsOf: output)
        #expect(markdown.contains("- [First Source](https://example.com/one)"))
        #expect(markdown.contains("- [Second Source](https://example.com/two)"))
        #expect(markdown.contains("## Skipped Sources"))
        #expect(markdown.contains("https://example.com/missing"))
        #expect(result.summary.contains("Skipped 1 unreachable source"))
        #expect(result.summary.contains("https://example.com/missing"))
    }

    @Test
    func webResearchStillFailsWhenEverySourceIsUnreachable() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("comparison.md")
        let first = URL(string: "https://example.com/one")!
        let second = URL(string: "https://example.com/two")!
        let executor = makeExecutor(
            root: root,
            webPageLoader: webPageLoader(pages: [:]),
            webResearchSynthesizer: StaticWebResearchSynthesizer(
                note: WebResearchNote(
                    title: "Unused",
                    summary: "",
                    keyPoints: [],
                    citations: []
                )
            )
        )

        await #expect(throws: WebResearchError.self) {
            _ = try await executor.execute(
                plan: webComparisonPlan(urls: [first, second], output: output)
            ) { _, _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    /// A "broken URL" reaches one of two different paths, and the distinction matters when
    /// reading live behavior: a *syntactically invalid* URL is rejected while the plan is being
    /// validated, before any fetch happens, so nothing is written; an *unreachable but valid*
    /// URL is skipped per-source and only aborts the step when it was the only source.
    @Test
    func brokenSourceURLsTakeTheRightPathDependingOnHowTheyAreBroken() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let reachable = URL(string: "https://example.com/one")!
        let unreachable = URL(string: "https://example.com/missing")!
        let pageLoader = webPageLoader(pages: [
            reachable.absoluteString: readablePage(url: reachable, title: "First Source")
        ])
        let synthesizer = StaticWebResearchSynthesizer(
            note: WebResearchNote(
                title: "Comparison",
                summary: "Summary.",
                keyPoints: ["Point"],
                citations: []
            )
        )

        // 1. Malformed URL among valid ones: rejected at validation, no partial note written.
        let malformedOutput = root.appendingPathComponent("malformed.md")
        let malformedPlan = AgentPlan(
            summary: "Compare web sources as Markdown.",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "web-comparison",
                    operation: .webToMarkdown,
                    description: "Compare source URLs.",
                    outputPath: malformedOutput.path,
                    sourceURLs: [reachable.absoluteString, "ht!tp://not a url"]
                )
            ]
        )
        let malformedExecutor = makeExecutor(
            root: root,
            webPageLoader: pageLoader,
            webResearchSynthesizer: synthesizer
        )
        await #expect(throws: SafeURLError.self) {
            _ = try await malformedExecutor.execute(plan: malformedPlan) { _, _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: malformedOutput.path))

        // 2. A single valid-but-unreachable source: no partial note, all-sources-failed.
        let singleOutput = root.appendingPathComponent("single.md")
        let singleExecutor = makeExecutor(
            root: root,
            webPageLoader: pageLoader,
            webResearchSynthesizer: synthesizer
        )
        await #expect(throws: WebResearchError.self) {
            _ = try await singleExecutor.execute(
                plan: webComparisonPlan(urls: [unreachable], output: singleOutput)
            ) { _, _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: singleOutput.path))

        // 3. Valid-but-unreachable alongside a reachable one: partial note naming the skip.
        let partialOutput = root.appendingPathComponent("partial.md")
        let partialExecutor = makeExecutor(
            root: root,
            webPageLoader: pageLoader,
            webResearchSynthesizer: synthesizer
        )
        let result = try await partialExecutor.execute(
            plan: webComparisonPlan(urls: [reachable, unreachable], output: partialOutput)
        ) { _, _ in }

        let markdown = try String(contentsOf: partialOutput)
        #expect(markdown.contains("- [First Source](https://example.com/one)"))
        #expect(markdown.contains("## Skipped Sources"))
        #expect(markdown.contains(unreachable.absoluteString))
        #expect(!markdown.contains("- [](https://example.com/missing)"))
        #expect(result.summary.contains("Skipped 1 unreachable source"))
    }

    /// The manual-testing case: "focus on writing" reaches the planner, which invents a
    /// workspace named "writing". That used to fail with "No workspace named writing is saved."
    /// — a technical error about a concept the user never mentioned.
    @Test
    func unknownWorkspaceOrRoutineNameBecomesAClarificationInsteadOfAnError() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaceStore = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        let routineStore = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))
        try workspaceStore.save(StoredWorkspace(name: "Research", apps: ["Safari"], urls: []))
        try routineStore.save(
            StoredRoutine(
                name: "Morning Setup",
                steps: [AgentStep(id: "open", operation: .openApp, description: "Open Safari.", appName: "Safari")]
            )
        )
        let executor = makeExecutor(root: root, routineStore: routineStore, workspaceStore: workspaceStore)

        let workspacePrepared = try executor.prepare(plan: openWorkspacePlan(name: "writing"))
        let workspaceQuestion = try #require(workspacePrepared.clarificationQuestion)
        #expect(workspaceQuestion.contains("writing"))
        #expect(workspaceQuestion.contains("Research"))
        // Rewritten into the same shape the planner emits for a real clarification, so every
        // downstream path treats it identically.
        #expect(workspacePrepared.plan.steps.map(\.operation) == [.clarify])
        #expect(workspacePrepared.previews.first?.title == "Clarification needed")

        let routinePrepared = try executor.prepare(plan: runRoutinePlan(name: "deep work"))
        let routineQuestion = try #require(routinePrepared.clarificationQuestion)
        #expect(routineQuestion.contains("deep work"))
        #expect(routineQuestion.contains("Morning Setup"))
        #expect(routinePrepared.plan.steps.map(\.operation) == [.clarify])
    }

    @Test
    func unknownTargetClarificationSaysSoWhenNothingIsSavedYet() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = makeExecutor(root: root)

        let prepared = try executor.prepare(plan: openWorkspacePlan(name: "writing"))

        let question = try #require(prepared.clarificationQuestion)
        #expect(question.contains("haven't saved any workspaces yet"))
    }

    /// Only the not-found case changes. Everything else these two adapters can fail on must
    /// still fail, or a real problem would be disguised as a friendly question.
    @Test
    func onlyNotFoundBecomesClarificationForWorkspacesAndRoutines() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaceStore = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        let routineStore = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))
        try workspaceStore.save(StoredWorkspace(name: "Research", apps: ["Safari"], urls: ["https://example.com"]))
        try workspaceStore.save(StoredWorkspace(name: "Scope Only", apps: ["NotAnAllowlistedApp"], urls: []))
        try workspaceStore.save(StoredWorkspace(name: "Broken", apps: ["Safari"], urls: ["ftp://example.com"]))
        try routineStore.save(
            StoredRoutine(
                name: "Morning Setup",
                steps: [AgentStep(id: "open", operation: .openApp, description: "Open Safari.", appName: "Safari")]
            )
        )
        let executor = makeExecutor(root: root, routineStore: routineStore, workspaceStore: workspaceStore)

        // A workspace that exists still prepares normally — no clarification.
        let existing = try executor.prepare(plan: openWorkspacePlan(name: "Research"))
        #expect(existing.clarificationQuestion == nil)
        #expect(existing.plan.steps.map(\.operation) == [.openWorkspace])

        let existingRoutine = try executor.prepare(plan: runRoutinePlan(name: "Morning Setup"))
        #expect(existingRoutine.clarificationQuestion == nil)
        #expect(existingRoutine.plan.steps.map(\.operation) == [.runRoutine])

        // A missing name is a different error and must still throw.
        #expect(throws: AutomationStoreError.missingName("Workspace")) {
            _ = try executor.prepare(plan: openWorkspacePlan(name: nil))
        }
        #expect(throws: AutomationStoreError.missingName("Routine")) {
            _ = try executor.prepare(plan: runRoutinePlan(name: "   "))
        }

        // A workspace holding an app Sonny cannot launch is no longer a failure at all. SONNY-44
        // decoupled scope listing from launchability, so that entry is scope-only: it is skipped at
        // open time and the open succeeds. (Before that decision this threw the catalog's
        // membership rejection, which is what made Microsoft Word unlistable.)
        let scopeOnly = try executor.prepare(plan: openWorkspacePlan(name: "Scope Only"))
        #expect(scopeOnly.clarificationQuestion == nil)
        #expect(scopeOnly.plan.steps.map(\.operation) == [.openWorkspace])

        // A workspace that exists but holds a URL `SafeURL` rejects is still a real failure, not a
        // "did you mean" — the user did name something real. `SafeURL` is a capability bound rather
        // than a user-declared boundary, and nothing decoupled it from anything.
        #expect(throws: SafeURLError.unsupportedScheme("ftp")) {
            _ = try executor.prepare(plan: openWorkspacePlan(name: "Broken"))
        }

        // Ordering: an earlier step's real error must still win. Previewing runs in step order,
        // so a bad app in step 1 surfaces instead of step 2's unknown workspace name — the
        // clarification must not pre-empt a genuine problem the user needs to hear about.
        let chainPlan = AgentPlan(
            summary: "Open an app and a workspace.",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "open-app",
                    operation: .openApp,
                    description: "Open an app that is not installed.",
                    appName: "DefinitelyNotInstalled"
                ),
                AgentStep(
                    id: "open-workspace",
                    operation: .openWorkspace,
                    description: "Open workspace.",
                    workspaceName: "writing"
                )
            ]
        )
        #expect(throws: MacAppError.notInstalled("DefinitelyNotInstalled")) {
            _ = try executor.prepare(plan: chainPlan)
        }
    }

    @Test
    func unknownRoutineClarificationAlsoHandlesTheEmptyStoreCase() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = makeExecutor(root: root)

        let prepared = try executor.prepare(plan: runRoutinePlan(name: "deep work"))

        let question = try #require(prepared.clarificationQuestion)
        #expect(question.contains("haven't saved any routines yet"))
        #expect(question.contains("deep work"))
    }

    /// The manual-pass case: "run hehe" with a *workspace* named hehe saved used to list routine
    /// names while ignoring the exact-name workspace the user almost certainly meant.
    @Test
    func unknownRoutineNameMatchingASavedWorkspaceCrossReferencesIt() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaceStore = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        let routineStore = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))
        try workspaceStore.save(StoredWorkspace(name: "Hehe", apps: ["Safari"], urls: []))
        try routineStore.save(
            StoredRoutine(
                name: "bhavya",
                steps: [AgentStep(id: "open", operation: .openApp, description: "Open Safari.", appName: "Safari")]
            )
        )
        let executor = makeExecutor(root: root, routineStore: routineStore, workspaceStore: workspaceStore)

        // Store-normalized identity, so the case-variant query still matches — and the question
        // shows the workspace's stored display name, not the query's casing.
        let prepared = try executor.prepare(plan: runRoutinePlan(name: "hehe"))

        let question = try #require(prepared.clarificationQuestion)
        #expect(question.contains("I don't have a routine called \"hehe\""))
        #expect(question.contains("but you do have a workspace called \"Hehe\""))
        #expect(question.contains("did you mean to open that?"))
        #expect(!question.contains("did you mean one of"))
        #expect(prepared.plan.steps.map(\.operation) == [.clarify])
    }

    @Test
    func unknownWorkspaceNameMatchingASavedRoutineCrossReferencesIt() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaceStore = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        let routineStore = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))
        try workspaceStore.save(StoredWorkspace(name: "Research", apps: ["Safari"], urls: []))
        try routineStore.save(
            StoredRoutine(
                name: "hehe",
                steps: [AgentStep(id: "open", operation: .openApp, description: "Open Safari.", appName: "Safari")]
            )
        )
        let executor = makeExecutor(root: root, routineStore: routineStore, workspaceStore: workspaceStore)

        let prepared = try executor.prepare(plan: openWorkspacePlan(name: "hehe"))

        let question = try #require(prepared.clarificationQuestion)
        #expect(question.contains("I don't have a workspace called \"hehe\""))
        #expect(question.contains("but you do have a routine called \"hehe\""))
        #expect(question.contains("did you mean to run that?"))
        #expect(!question.contains("did you mean one of"))
    }

    /// Exact match only — a populated other store with no exact-name match must not change the
    /// existing same-kind list, and there is deliberately no fuzzy matching.
    @Test
    func crossKindCheckRequiresAnExactMatchAndOtherwiseKeepsTheList() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaceStore = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        let routineStore = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))
        try workspaceStore.save(StoredWorkspace(name: "hehe workspace", apps: ["Safari"], urls: []))
        try routineStore.save(
            StoredRoutine(
                name: "bhavya",
                steps: [AgentStep(id: "open", operation: .openApp, description: "Open Safari.", appName: "Safari")]
            )
        )
        let executor = makeExecutor(root: root, routineStore: routineStore, workspaceStore: workspaceStore)

        let prepared = try executor.prepare(plan: runRoutinePlan(name: "hehe"))

        let question = try #require(prepared.clarificationQuestion)
        #expect(question.contains("did you mean one of: bhavya"))
        #expect(!question.contains("hehe workspace"))
    }

    /// An unreadable *other* store must not turn a good clarification into a thrown error — the
    /// cross-kind check degrades to the same-kind list. (An unreadable *same-kind* store still
    /// throws; that case is pinned separately below.)
    @Test
    func unreadableOtherStoreDegradesToTheSameKindListInsteadOfFailing() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaceURL = root.appendingPathComponent("workspaces.json")
        try Data("this is not valid encrypted or plaintext JSON".utf8).write(to: workspaceURL)
        let routineStore = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))
        try routineStore.save(
            StoredRoutine(
                name: "bhavya",
                steps: [AgentStep(id: "open", operation: .openApp, description: "Open Safari.", appName: "Safari")]
            )
        )
        let executor = makeExecutor(
            root: root,
            routineStore: routineStore,
            workspaceStore: WorkspaceStore(fileURL: workspaceURL)
        )

        let prepared = try executor.prepare(plan: runRoutinePlan(name: "hehe"))

        let question = try #require(prepared.clarificationQuestion)
        #expect(question.contains("did you mean one of: bhavya"))
    }

    /// A store that cannot be read is a load failure, not a not-found — it must keep its own
    /// error rather than being softened into "you haven't saved any".
    @Test
    func unreadableAutomationStoreStillThrowsInsteadOfClarifying() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaceURL = root.appendingPathComponent("workspaces.json")
        try Data("this is not valid encrypted or plaintext JSON".utf8).write(to: workspaceURL)
        let executor = makeExecutor(
            root: root,
            workspaceStore: WorkspaceStore(fileURL: workspaceURL)
        )

        #expect(throws: (any Error).self) {
            _ = try executor.prepare(plan: openWorkspacePlan(name: "writing"))
        }
        do {
            _ = try executor.prepare(plan: openWorkspacePlan(name: "writing"))
        } catch let error as AutomationStoreError {
            Issue.record("A decode failure must not surface as \(error).")
        } catch {
            // Any non-AutomationStoreError (the real decode/decrypt failure) is correct here.
        }
    }

    @Test
    func permissionReadinessReportsRealHotkeyConflict() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = makeExecutor(root: root, hotKeyReady: { false })

        let previews = try executor.preview(plan: permissionReadinessPlan())

        let details = previews.flatMap(\.details)
        #expect(details.contains { $0.contains("Voice hotkey") && $0.contains("Needs action") })
        #expect(details.contains { $0.contains("Another app is using Control-Option-Space") })
    }

    /// **The screen-permission seam is injected, and load-bearing** (SONNY-123).
    ///
    /// Before this, nothing in the suite passed a permission service, so `AgentActionExecutor`'s
    /// default built a live one and the Accessibility and Screen Recording items answered from
    /// whatever this Mac happened to have granted. No assertion flipped on it yet — which is
    /// precisely why it was worth closing rather than leaving: the seam was open, and the next
    /// assertion written against one of these items would have become machine-dependent silently.
    /// That is exactly how SONNY-103 happened, and SONNY-106 section D states the general rule on
    /// the reasoning that a suite whose result changes with the machine running it cannot be
    /// evidence.
    ///
    /// It asserts both directions — a granted checker must produce the granted copy, a refused one
    /// the refused copy — so the service ignoring its injected checker fails here.
    ///
    /// **What it cannot do, established by mutation rather than assumed.** It does not catch
    /// `makeExecutor`'s default being reverted to a live `PermissionReadinessService`. Reverting
    /// that default and running this test passes: both halves pass their checker explicitly, so the
    /// default is never exercised, and even a test that omitted the argument could not tell an
    /// injected `true` from a machine that really has both grants. The first draft of this comment
    /// claimed the opposite; the mutation disproved it.
    ///
    /// So the protection is not detection, it is inheritance: `makeExecutor` now defaults to a
    /// deterministic service, and every test built on it gets machine-independence without asking.
    /// A future test that wants a specific grant state says so at its call site, the way this one
    /// does.
    ///
    /// **The microphone half is closed now, and elsewhere.** It used to be the open half of this:
    /// `microphoneStatus()` called `AVCaptureDevice.authorizationStatus(for: .audio)` directly, with
    /// no seam to inject. SONNY-123 added `MicrophonePermissionChecking`, so `.deterministic()`
    /// states that status too and this executor makes no live authorization read of any kind.
    /// `PermissionReadinessMicrophoneTests` is that seam's own pin — and, unlike this test, it
    /// genuinely detects the seam being ignored, because four authorization cases cannot all be
    /// answered by one live status.
    @Test
    func permissionReadinessAnswersFromTheInjectedCheckerRatherThanThisMac() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let granted = makeExecutor(
            root: root,
            permissionReadinessService: .deterministic(accessibilityTrusted: true, screenRecordingGranted: true)
        )
        let grantedDetails = try granted.preview(plan: permissionReadinessPlan()).flatMap(\.details)
        #expect(grantedDetails.contains { $0.contains("Accessibility is trusted for the current process.") })
        #expect(grantedDetails.contains { $0.contains("Screen Recording is granted.") })

        let refused = makeExecutor(
            root: root,
            permissionReadinessService: .deterministic(accessibilityTrusted: false, screenRecordingGranted: false)
        )
        let refusedDetails = try refused.preview(plan: permissionReadinessPlan()).flatMap(\.details)
        #expect(refusedDetails.contains { $0.contains("Screen-acting tools need Accessibility.") })
        #expect(refusedDetails.contains { $0.contains("Screen-aware tools need Screen Recording.") })
    }

    @Test
    func webResearchSearchQueryUsesInjectedProviderAndWritesMarkdown() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("search-note.md")
        let first = URL(string: "https://example.com/swift-one")!
        let second = URL(string: "https://example.com/swift-two")!
        let searchProvider = StaticWebSearchProvider(results: [
            WebSearchResult(title: "Swift One", url: first, snippet: "First snippet"),
            WebSearchResult(title: "Swift Two", url: second, snippet: "Second snippet")
        ])
        let pageLoader = webPageLoader(pages: [
            first.absoluteString: readablePage(url: first, title: "Swift One"),
            second.absoluteString: readablePage(url: second, title: "Swift Two")
        ])
        let synthesizer = StaticWebResearchSynthesizer(
            note: WebResearchNote(
                title: "Swift Concurrency Research",
                summary: "Search-backed research summary.",
                keyPoints: ["Search point"],
                citations: []
            )
        )
        let executor = makeExecutor(
            root: root,
            webPageLoader: pageLoader,
            webSearchProvider: searchProvider,
            webResearchSynthesizer: synthesizer
        )
        let plan = webSearchPlan(query: "Swift concurrency", output: output, count: 2)

        let preview = try executor.preview(plan: plan)
        #expect(preview.first?.title == "Save web research Markdown")
        #expect(preview.first?.details.contains("Search query: Swift concurrency") == true)
        #expect(preview.first?.writes == [output.path])

        let result = try await executor.execute(plan: plan) { _, _ in }

        let markdown = try String(contentsOf: output)
        #expect(searchProvider.queries == ["Swift concurrency"])
        #expect(searchProvider.limits == [2])
        #expect(markdown.contains("# Swift Concurrency Research"))
        #expect(markdown.contains("- [Swift One](https://example.com/swift-one)"))
        #expect(markdown.contains("- [Swift Two](https://example.com/swift-two)"))
        #expect(synthesizer.prompts[0].trustedPlan.steps[0].searchQuery == "Swift concurrency")
        #expect(result.summary == "Saved web research Markdown for search query \"Swift concurrency\" using 2 sources to \(output.path).")
    }

    /// Partial synthesis can reduce the surviving source count to one — the summary must then say
    /// "1 source", not "1 sources". The skipped-source clause pluralized correctly from the start;
    /// the search base sentence hardcoded the plural, which stayed invisible until a real search
    /// could actually skip a source.
    @Test
    func webResearchSearchSummaryUsesSingularSourceWhenOnlyOneSourceSurvives() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("search-note.md")
        let surviving = URL(string: "https://example.com/alive")!
        let unreachable = URL(string: "https://example.com/dead")!
        let searchProvider = StaticWebSearchProvider(results: [
            WebSearchResult(title: "Alive", url: surviving, snippet: nil),
            WebSearchResult(title: "Dead", url: unreachable, snippet: nil)
        ])
        let pageLoader = webPageLoader(pages: [
            surviving.absoluteString: readablePage(url: surviving, title: "Alive")
        ])
        let synthesizer = StaticWebResearchSynthesizer(
            note: WebResearchNote(
                title: "Single Source",
                summary: "One source survived.",
                keyPoints: [],
                citations: []
            )
        )
        let executor = makeExecutor(
            root: root,
            webPageLoader: pageLoader,
            webSearchProvider: searchProvider,
            webResearchSynthesizer: synthesizer
        )
        let plan = webSearchPlan(query: "single survivor", output: output, count: 2)

        let result = try await executor.execute(plan: plan) { _, _ in }

        #expect(result.summary == "Saved web research Markdown for search query \"single survivor\" using 1 source to \(output.path). Skipped 1 unreachable source: https://example.com/dead.")
    }

    @Test
    func webResearchSearchWithoutConfiguredProviderFailsClearly() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("search-note.md")
        let executor = makeExecutor(
            root: root,
            webResearchSynthesizer: StaticWebResearchSynthesizer(
                note: WebResearchNote(title: "Unused", summary: "Unused", keyPoints: [], citations: [])
            )
        )
        let plan = webSearchPlan(query: "unconfigured provider", output: output)

        let preview = try executor.preview(plan: plan)
        #expect(preview.first?.details.contains("Search query: unconfigured provider") == true)
        await #expect(throws: WebResearchError.searchProviderNotConfigured) {
            try await executor.execute(plan: plan) { _, _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    /// Alias canonicalization at the preview surface: the user typed "Visual Studio Code" and the
    /// preview names VS Code by its canonical spelling and real bundle identifier. Named for the
    /// allowlist until SONNY-82 dissolved it — the behavior this pins was never the allowlist, it was
    /// the alias table underneath, which is the half that survives.
    @Test
    func openAppPreviewCanonicalizesAnAliasToItsRealIdentity() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = makeExecutor(root: root)

        let preview = try executor.preview(plan: openAppPlan(appName: "Visual Studio Code"))

        #expect(preview.first?.opens == ["VS Code"])
        #expect(preview.first?.details.contains("Bundle: com.microsoft.VSCode") == true)
    }

    @Test
    func openAppPreviewSupportsMusicApps() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = makeExecutor(root: root)

        let spotify = try executor.preview(plan: openAppPlan(appName: "Spotify"))
        let appleMusic = try executor.preview(plan: openAppPlan(appName: "Music"))

        #expect(spotify.first?.opens == ["Spotify"])
        #expect(appleMusic.first?.opens == ["Apple Music"])
    }

    /// The only failure left on the launch path, and the sentence it produces.
    ///
    /// This test used to read `appNotAllowed("Untrusted App")` — "Untrusted App is not in the
    /// allowlisted app catalog." — which was the launch gate C12 dissolved: a *refusal*, phrased as
    /// though the user had asked for something they were not permitted. What replaces it is a
    /// statement about the machine. The failing name is one nothing could plausibly install, because
    /// under XCTest the resolver's universe is the alias table's roster and the point of the
    /// assertion is the miss.
    @Test
    func openAppFailsWithNotInstalledCopyForAnAppThisMacDoesNotHave() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = makeExecutor(root: root)

        #expect(throws: MacAppError.notInstalled("Figma")) {
            try executor.preview(plan: openAppPlan(appName: "Figma"))
        }
        #expect(MacAppError.notInstalled("Figma").errorDescription == "Figma isn't installed on this Mac.")
        // A blank name is a different failure and keeps its own wording — the two must not collapse
        // into one message, because only one of them is about the machine.
        #expect(throws: MacAppError.missingAppName) {
            try executor.preview(plan: openAppPlan(appName: "   "))
        }
    }

    @Test
    func openURLAllowsHTTPAndHTTPSOnly() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = makeExecutor(root: root)

        let preview = try executor.preview(plan: openURLPlan(url: "https://github.com"))

        #expect(preview.first?.opens == ["https://github.com"])
        #expect(throws: SafeURLError.unsupportedScheme("ftp")) {
            try executor.preview(plan: openURLPlan(url: "ftp://example.com"))
        }
    }

    @Test
    func openAppSearchURLUsesFixedAllowlistedTemplatesOnly() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let browserOpener = RecordingBrowserOpener()
        let executor = makeExecutor(root: root, browserOpener: browserOpener)

        let preview = try executor.preview(plan: openAppSearchURLPlan(target: "GitHub", query: "Swift concurrency"))

        #expect(preview.first?.title == "Open GitHub search")
        #expect(preview.first?.opens.first == "https://github.com/search?q=Swift%20concurrency")
        #expect(preview.first?.details.contains("Allowed search targets: Google, GitHub, YouTube, Apple Music, Spotify") == true)
        let result = try await executor.execute(plan: openAppSearchURLPlan(target: "GitHub", query: "Swift concurrency")) { _, _ in }

        #expect(browserOpener.openedURLs.map(\.absoluteString) == ["https://github.com/search?q=Swift%20concurrency"])
        // Non-workspace caller: an app search URL still goes to the system default browser.
        #expect(browserOpener.openedBrowsers == [nil])
        #expect(result.summary == "Opened GitHub search for Swift concurrency.")
        #expect(throws: AppSearchURLCatalogError.searchTargetNotAllowed("Untrusted")) {
            try executor.preview(plan: openAppSearchURLPlan(target: "Untrusted", query: "Swift"))
        }
    }

    @Test
    func openAppAndURLExecutionUseInjectedOpeners() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let appOpener = RecordingAppOpener()
        let browserOpener = RecordingBrowserOpener()
        let executor = makeExecutor(root: root, browserOpener: browserOpener, appOpener: appOpener)

        let appResult = try await executor.execute(plan: openAppPlan(appName: "Safari")) { _, _ in }
        let urlResult = try await executor.execute(plan: openURLPlan(url: "https://github.com")) { _, _ in }

        #expect(appOpener.openedBundleIDs == ["com.apple.Safari"])
        #expect(browserOpener.openedURLs.map(\.absoluteString) == ["https://github.com"])
        // Non-workspace caller: a standalone open-URL still goes to the system default browser,
        // even though this same plan pair also opened Safari as an app. Opening a browser app is
        // not what binds a URL to it — only a workspace's saved apps list does that.
        #expect(browserOpener.openedBrowsers == [nil])
        #expect(appResult.summary == "Opened the Safari app.")
        #expect(urlResult.summary == "Opened https://github.com.")
    }

    @Test
    func mediaOpenPreviewShowsProviderAndSong() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = makeExecutor(root: root)

        let appleMusic = try executor.preview(plan: mediaPlan(provider: .appleMusic))
        let spotify = try executor.preview(plan: mediaPlan(provider: .spotify))

        #expect(appleMusic.first?.opens == ["Apple Music"])
        #expect(appleMusic.first?.title == "Play Jimmy Cooks by Drake")
        #expect(appleMusic.first?.details.contains("Playback route: fallback-open") == true)
        #expect(appleMusic.first?.details.contains("Apple Music playback provider not configured.") == true)
        #expect(appleMusic.first?.details.contains("Fallback: open the best matching Apple Music catalog result, or Apple Music search if no match is found.") == true)
        #expect(spotify.first?.opens == ["Spotify"])
        #expect(spotify.first?.details.contains("Playback route: fallback-open") == true)
        #expect(spotify.first?.details.contains("Spotify playback provider not configured.") == true)
        #expect(spotify.first?.details.contains("Fallback: open Spotify search for the requested song or album.") == true)
    }

    @Test
    func mediaOpenPreviewDistinguishesSearchPlayTransferAndFallbackRoutes() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let searchExecutor = makeExecutor(
            root: root,
            spotifyPlaybackProvider: StaticSpotifyPlaybackProvider(
                previewResult: MediaPlaybackRoutePreview(
                    route: .search,
                    detail: "Would search Spotify catalog for Jimmy Cooks by Drake."
                ),
                playResult: .blocked(
                    SpotifyPlaybackFailure(
                        blockers: MediaPlaybackBlockers(catalogMatchBlocked: true),
                        detail: "No Spotify catalog match."
                    )
                )
            )
        )
        let playExecutor = makeExecutor(
            root: root,
            appleMusicPlaybackProvider: StaticAppleMusicPlaybackProvider(
                previewResult: MediaPlaybackRoutePreview(
                    route: .play,
                    detail: "Apple Music can queue and play Good Days."
                ),
                playResult: .started(
                    AppleMusicPlaybackStart(
                        action: .queueAndPlay(catalogID: "good-days"),
                        track: AppleMusicTrackCandidate(catalogID: "good-days", title: "Good Days", artist: "SZA")
                    )
                )
            )
        )
        let transferExecutor = makeExecutor(
            root: root,
            spotifyPlaybackProvider: StaticSpotifyPlaybackProvider(
                previewResult: MediaPlaybackRoutePreview(
                    route: .transferPlayback,
                    detail: "Would transfer playback to Sonny Mac, then play Jimmy Cooks."
                ),
                playResult: .started(
                    SpotifyPlaybackStart(
                        action: .transferAndPlay(uri: "spotify:track:best", deviceID: "mac"),
                        track: SpotifyTrackCandidate(uri: "spotify:track:best", title: "Jimmy Cooks", artists: ["Drake"]),
                        device: SpotifyPlaybackDevice(id: "mac", name: "Sonny Mac", isActive: false)
                    )
                )
            )
        )
        let fallbackExecutor = makeExecutor(root: root)

        let searchPreview = try searchExecutor.preview(plan: mediaPlan(provider: .spotify)).first
        let playPreview = try playExecutor.preview(plan: mediaPlan(provider: .appleMusic, title: "Good Days", artist: "SZA")).first
        let transferPreview = try transferExecutor.preview(plan: mediaPlan(provider: .spotify)).first
        let fallbackPreview = try fallbackExecutor.preview(plan: mediaPlan(provider: .spotify)).first

        #expect(searchPreview?.details.contains("Playback route: search") == true)
        #expect(searchPreview?.details.contains("Would search Spotify catalog for Jimmy Cooks by Drake.") == true)
        #expect(playPreview?.details.contains("Playback route: play") == true)
        #expect(playPreview?.details.contains("Apple Music can queue and play Good Days.") == true)
        #expect(transferPreview?.details.contains("Playback route: transfer-playback") == true)
        #expect(transferPreview?.details.contains("Would transfer playback to Sonny Mac, then play Jimmy Cooks.") == true)
        #expect(fallbackPreview?.details.contains("Playback route: fallback-open") == true)
    }

    @Test
    func mediaOpenExecutionUsesInjectedOpener() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let opener = FakeMediaOpener()
        let executor = makeExecutor(root: root, mediaOpener: opener)

        let result = try await executor.execute(plan: mediaPlan(provider: .appleMusic)) { _, _ in }

        #expect(result.summary == "Apple Music playback unavailable (authorization): Apple Music playback provider not configured. Fallback result: Opened Jimmy Cooks by Drake in Apple Music.")
        #expect(opener.requests == [
            MediaPlaybackRequest(provider: .appleMusic, title: "Jimmy Cooks", artist: "Drake")
        ])
    }

    @Test
    func mediaOpenExecutionFallsBackToInjectedOpenerWhenSpotifyPlaybackIsBlocked() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let opener = FakeMediaOpener()
        let spotifyProvider = StaticSpotifyPlaybackProvider(
            previewResult: MediaPlaybackRoutePreview(
                route: .fallbackOpen,
                detail: "Spotify Premium required.",
                failureReason: .subscriptionPremium
            ),
            playResult: .blocked(
                SpotifyPlaybackFailure(
                    blockers: MediaPlaybackBlockers(subscriptionBlocked: true),
                    detail: "Spotify Premium required."
                )
            )
        )
        let executor = makeExecutor(
            root: root,
            mediaOpener: opener,
            spotifyPlaybackProvider: spotifyProvider
        )

        let result = try await executor.execute(plan: mediaPlan(provider: .spotify)) { _, _ in }

        #expect(result.summary == "Spotify playback unavailable (subscription/Premium): Spotify Premium required. Fallback result: Opened Jimmy Cooks by Drake in Spotify.")
        #expect(opener.requests == [
            MediaPlaybackRequest(provider: .spotify, title: "Jimmy Cooks", artist: "Drake")
        ])
        #expect(spotifyProvider.playRequests == [
            MediaPlaybackRequest(provider: .spotify, title: "Jimmy Cooks", artist: "Drake")
        ])
    }

    @Test
    func mediaOpenExecutionUsesProviderPlaybackWhenAvailable() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let opener = FakeMediaOpener()
        let spotifyProvider = StaticSpotifyPlaybackProvider(
            previewResult: MediaPlaybackRoutePreview(route: .play, detail: "Spotify can play Jimmy Cooks."),
            playResult: .started(
                SpotifyPlaybackStart(
                    action: .play(uri: "spotify:track:best", deviceID: "mac"),
                    track: SpotifyTrackCandidate(uri: "spotify:track:best", title: "Jimmy Cooks", artists: ["Drake"]),
                    device: SpotifyPlaybackDevice(id: "mac", name: "Sonny Mac", isActive: true)
                )
            )
        )
        let appleProvider = StaticAppleMusicPlaybackProvider(
            previewResult: MediaPlaybackRoutePreview(route: .play, detail: "Apple Music can play Good Days."),
            playResult: .started(
                AppleMusicPlaybackStart(
                    action: .queueAndPlay(catalogID: "good-days"),
                    track: AppleMusicTrackCandidate(catalogID: "good-days", title: "Good Days", artist: "SZA")
                )
            )
        )
        let executor = makeExecutor(
            root: root,
            mediaOpener: opener,
            spotifyPlaybackProvider: spotifyProvider,
            appleMusicPlaybackProvider: appleProvider
        )

        let spotify = try await executor.execute(plan: mediaPlan(provider: .spotify)) { _, _ in }
        let appleMusic = try await executor.execute(plan: mediaPlan(provider: .appleMusic, title: "Good Days", artist: "SZA")) { _, _ in }

        #expect(spotify.summary == "Started Spotify playback for Jimmy Cooks by Drake.")
        #expect(appleMusic.summary == "Started Apple Music playback for Good Days by SZA.")
        #expect(opener.requests.isEmpty)
        #expect(spotifyProvider.playRequests == [
            MediaPlaybackRequest(provider: .spotify, title: "Jimmy Cooks", artist: "Drake")
        ])
        #expect(appleProvider.playRequests == [
            MediaPlaybackRequest(provider: .appleMusic, title: "Good Days", artist: "SZA")
        ])
    }

    @Test
    func mediaOpenRequiresProviderAndTitle() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = makeExecutor(root: root)

        #expect(throws: MediaPlaybackError.missingProvider) {
            try executor.preview(plan: mediaPlan(provider: nil))
        }
        #expect(throws: MediaPlaybackError.missingTitle) {
            try executor.preview(plan: mediaPlan(provider: .appleMusic, title: " "))
        }
    }

    @Test
    func clarificationPlanPreparesQuestionWithoutSideEffects() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = makeExecutor(root: root)

        let prepared = try executor.prepare(plan: clarifyPlan())

        #expect(prepared.clarificationQuestion == "Which folder should I scan?")
        #expect(prepared.sideEffects.isEmpty)
    }

    @Test
    func mixedWorkflowPlanExecutesAsChain() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("small", to: root.appendingPathComponent("small.txt"))
        try write(String(repeating: "x", count: 2048), to: root.appendingPathComponent("large.txt"))
        let output = root.appendingPathComponent("largest.zip")
        let appOpener = RecordingAppOpener()
        let executor = makeExecutor(root: root, appOpener: appOpener)
        let plan = AgentPlan(
            summary: "Zip and open app.",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "scan",
                    operation: .scanSelectLargestFiles,
                    description: "Scan files",
                    inputPath: root.path,
                    count: 3
                ),
                AgentStep(
                    id: "zip",
                    operation: .createZip,
                    description: "Zip files",
                    inputPath: root.path,
                    outputPath: output.path,
                    count: 3
                ),
                AgentStep(
                    id: "open",
                    operation: .openApp,
                    description: "Open Safari",
                    appName: "Safari"
                )
            ]
        )

        let result = try await executor.execute(plan: plan) { _, _ in }

        #expect(FileManager.default.fileExists(atPath: output.path))
        #expect(appOpener.openedBundleIDs == ["com.apple.Safari"])
        #expect(result.summary.contains("Created largest.zip"))
        #expect(result.summary.contains("Opened the Safari app."))
    }

    @Test
    func chainPreviewCanRevealFutureGeneratedZip() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("small", to: root.appendingPathComponent("small.txt"))
        try write(String(repeating: "x", count: 2048), to: root.appendingPathComponent("large.txt"))
        let executor = makeExecutor(root: root)
        let plan = AgentPlan(
            summary: "Zip and reveal.",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "scan",
                    operation: .scanSelectLargestFiles,
                    description: "Scan files",
                    inputPath: root.path,
                    count: 3
                ),
                AgentStep(
                    id: "zip",
                    operation: .createZip,
                    description: "Zip files",
                    inputPath: root.path,
                    count: 3
                ),
                AgentStep(
                    id: "reveal",
                    operation: .revealInFinder,
                    description: "Reveal generated zip"
                )
            ]
        )

        let preview = try executor.preview(plan: plan)

        #expect(preview.count == 2)
        #expect(preview[0].writes.first?.contains("largest-files-") == true)
        #expect(preview[1].title == "Reveal in Finder")
        #expect(preview[1].details.first == "Reveal \(preview[0].writes[0])")
        #expect(!FileManager.default.fileExists(atPath: preview[0].writes[0]))
    }

    @Test
    func revealPreviewAllowsFuturePathButExecuteRequiresExistingPath() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let futureOutput = root.appendingPathComponent("future.zip")
        let executor = makeExecutor(root: root)

        let preview = try executor.preview(plan: revealPlan(output: futureOutput))

        #expect(preview.first?.title == "Reveal in Finder")
        #expect(preview.first?.details == ["Reveal \(futureOutput.path)"])
        await #expect(throws: PathValidationError.notFound(futureOutput.path)) {
            try await executor.execute(plan: revealPlan(output: futureOutput)) { _, _ in }
        }
    }

    @Test
    func finderSelectionCanSupplySelectedFolderContext() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("small", to: root.appendingPathComponent("small.txt"))
        try write(String(repeating: "x", count: 2048), to: root.appendingPathComponent("large.txt"))
        let executor = makeExecutor(
            root: root,
            finderContextReader: FakeFinderContextReader(selection: [root])
        )
        let plan = AgentPlan(
            summary: "Zip selected Finder folder.",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "scan",
                    operation: .scanSelectLargestFiles,
                    description: "Scan selected folder",
                    count: 3,
                    contextSource: .finderSelection
                ),
                AgentStep(
                    id: "zip",
                    operation: .createZip,
                    description: "Zip selected folder",
                    count: 3,
                    contextSource: .finderSelection
                )
            ]
        )

        let preview = try executor.preview(plan: plan)

        #expect(preview.first?.title == "Zip 2 largest files")
    }

    @Test
    func permissionReadinessPreviewAndExecutionAreReadOnlyStatusChecks() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = makeExecutor(root: root)

        let prepared = try executor.prepare(plan: permissionReadinessPlan())
        let result = try await executor.execute(plan: permissionReadinessPlan()) { _, _ in }

        #expect(prepared.previews.first?.title == "Permission readiness")
        #expect(prepared.sideEffects.isEmpty)
        #expect(result.previews.first?.title == "Permission readiness")
        #expect(result.previews.first?.details.count == prepared.previews.first?.details.count)
        #expect(result.summary.hasPrefix("Permission readiness checked."))
    }

    @Test
    func routineCanBeSavedAndRun() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let routineStore = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))
        let appOpener = RecordingAppOpener()
        let executor = makeExecutor(root: root, appOpener: appOpener, routineStore: routineStore)
        let savePlan = AgentPlan(
            summary: "Teach routine.",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "save-routine",
                    operation: .saveRoutine,
                    description: "Save routine.",
                    routineName: "Morning Setup",
                    routineSteps: [
                        AgentStep(
                            id: "open-safari",
                            operation: .openApp,
                            description: "Open Safari.",
                            appName: "Safari"
                        ),
                        AgentStep(
                            id: "open-notes",
                            operation: .openApp,
                            description: "Open Notes.",
                            appName: "Notes"
                        )
                    ]
                )
            ]
        )
        let runPlan = AgentPlan(
            summary: "Run routine.",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "run-routine",
                    operation: .runRoutine,
                    description: "Run routine.",
                    routineName: "Morning Setup"
                )
            ]
        )

        _ = try await executor.execute(plan: savePlan) { _, _ in }
        let result = try await executor.execute(plan: runPlan) { _, _ in }

        #expect(appOpener.openedBundleIDs == ["com.apple.Safari", "com.apple.Notes"])
        #expect(result.summary.contains("Ran routine Morning Setup."))
    }

    /// The save capability's half of SONNY-52. Its forbidden-operation list moved to
    /// `StoredRoutine.forbiddenStepOperations` so `RoutineStore.save` could enforce the same rule,
    /// and the contract for that move was that this end behaves identically — but no test asserted
    /// this end's behavior at all before the move, so "unchanged" had nothing to be measured
    /// against. These two pin it: the same error, naming the same operation, from the capability
    /// the user actually reaches.
    @Test
    func savingARoutineThroughTheCapabilityStillRefusesEveryForbiddenOperation() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let routineStore = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))
        let executor = makeExecutor(root: root, routineStore: routineStore)

        for operation in StoredRoutine.forbiddenStepOperations {
            let plan = AgentPlan(
                summary: "Teach routine.",
                requiresConfirmation: true,
                steps: [
                    AgentStep(
                        id: "save-routine",
                        operation: .saveRoutine,
                        description: "Save routine.",
                        routineName: "Morning Setup",
                        routineSteps: [
                            // A legal step first, so this also proves the capability scans past the
                            // head of the list rather than checking only `routineSteps.first`.
                            AgentStep(id: "open-safari", operation: .openApp, description: "Open Safari.", appName: "Safari"),
                            AgentStep(id: "bad", operation: operation, description: "Nope.")
                        ]
                    )
                ]
            )

            await #expect(throws: AutomationStoreError.unsafeRoutineStep(operation.rawValue)) {
                _ = try await executor.execute(plan: plan) { _, _ in }
            }
        }

        #expect(try routineStore.loadAll().isEmpty)
    }

    @Test
    func savingARoutineThroughTheCapabilityStillRefusesNestedRoutineSteps() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let routineStore = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))
        let executor = makeExecutor(root: root, routineStore: routineStore)
        let plan = AgentPlan(
            summary: "Teach routine.",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "save-routine",
                    operation: .saveRoutine,
                    description: "Save routine.",
                    routineName: "Morning Setup",
                    routineSteps: [
                        AgentStep(
                            id: "wrap",
                            operation: .openApp,
                            description: "Open Safari.",
                            appName: "Safari",
                            routineSteps: [
                                AgentStep(id: "open-notes", operation: .openApp, description: "Open Notes.", appName: "Notes")
                            ]
                        )
                    ]
                )
            ]
        )

        await #expect(throws: AutomationStoreError.unsafeRoutineStep("nested routineSteps")) {
            _ = try await executor.execute(plan: plan) { _, _ in }
        }
        #expect(try routineStore.loadAll().isEmpty)
    }

    @Test
    func routineRunUsesNestedDispatchForMixedChains() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let routineStore = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))
        let appOpener = RecordingAppOpener()
        let browserOpener = RecordingBrowserOpener()
        let executor = makeExecutor(
            root: root,
            browserOpener: browserOpener,
            appOpener: appOpener,
            routineStore: routineStore
        )
        let savePlan = AgentPlan(
            summary: "Teach mixed routine.",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "save-routine",
                    operation: .saveRoutine,
                    description: "Save routine.",
                    routineName: "Mixed Launch",
                    routineSteps: [
                        AgentStep(
                            id: "open-safari",
                            operation: .openApp,
                            description: "Open Safari.",
                            appName: "Safari"
                        ),
                        AgentStep(
                            id: "open-github",
                            operation: .openURL,
                            description: "Open GitHub.",
                            targetURL: "https://github.com"
                        )
                    ]
                )
            ]
        )
        let runPlan = AgentPlan(
            summary: "Run routine.",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "run-routine",
                    operation: .runRoutine,
                    description: "Run routine.",
                    routineName: "Mixed Launch"
                )
            ]
        )

        _ = try await executor.execute(plan: savePlan) { _, _ in }
        let result = try await executor.execute(plan: runPlan) { _, _ in }

        #expect(appOpener.openedBundleIDs == ["com.apple.Safari"])
        #expect(browserOpener.openedURLs.map(\.absoluteString) == ["https://github.com"])
        // SONNY-24: the assertion the SONNY-9 review chain predicted would flip. This routine
        // opens Safari, so its URL step now goes to Safari rather than the system default — the
        // co-founder's original surprise, removed. The five *non-routine* callers that carry the
        // same assertion must stay `[nil]`; if any of them flips too, the binding has leaked into
        // the ordinary open-URL path, which is exactly the failure mode this ticket guards.
        #expect(browserOpener.openedBrowsers == [MacApp(displayName: "Safari", bundleIdentifier: "com.apple.Safari")])
        #expect(result.summary == "Ran routine Mixed Launch. Opened the Safari app. Opened https://github.com.")
    }

    @Test
    func workspaceCanBeSavedAndOpened() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaceStore = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        let appOpener = RecordingAppOpener()
        let browserOpener = RecordingBrowserOpener()
        let executor = makeExecutor(
            root: root,
            browserOpener: browserOpener,
            appOpener: appOpener,
            workspaceStore: workspaceStore
        )
        let plans = workspacePlans(name: "Research", apps: ["Safari"], urls: ["https://github.com"])

        _ = try await executor.execute(plan: plans.create) { _, _ in }
        let result = try await executor.execute(plan: plans.open) { _, _ in }

        #expect(appOpener.openedBundleIDs == ["com.apple.Safari"])
        #expect(browserOpener.openedURLs.map(\.absoluteString) == ["https://github.com"])
        #expect(result.summary == "Opened workspace Research with 1 app(s) and 1 URL(s).")
    }

    /// SONNY-9's headline case: a workspace that names Safari must hand its URLs to Safari even
    /// though Chrome is the system default. "Chrome is default" is what the injected opener stands
    /// in for — a `nil` browser reaching it is exactly the shipped bug, since `nil` means "let macOS
    /// pick", and macOS picks Chrome.
    @Test
    func workspaceURLsOpenInTheWorkspacesOwnBrowserRatherThanTheSystemDefault() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaceStore = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        let appOpener = RecordingAppOpener()
        let browserOpener = RecordingBrowserOpener()
        let executor = makeExecutor(
            root: root,
            browserOpener: browserOpener,
            appOpener: appOpener,
            workspaceStore: workspaceStore
        )
        let plans = workspacePlans(name: "Research", apps: ["Safari"], urls: ["https://github.com"])

        _ = try await executor.execute(plan: plans.create) { _, _ in }
        let result = try await executor.execute(plan: plans.open) { _, _ in }

        #expect(browserOpener.openedURLs.map(\.absoluteString) == ["https://github.com"])
        #expect(browserOpener.openedBrowsers.map { $0?.bundleIdentifier } == ["com.apple.Safari"])
        // The browser is opened as an app first, then handed the URL — unchanged ordering.
        #expect(appOpener.openedBundleIDs == ["com.apple.Safari"])
        #expect(result.summary == "Opened workspace Research with 1 app(s) and 1 URL(s).")
    }

    /// The unchanged half of the contract: a workspace with no browser among its apps still opens
    /// its URLs wherever macOS sends them.
    @Test
    func workspaceWithoutABrowserAppStillOpensURLsInTheSystemDefaultBrowser() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaceStore = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        let browserOpener = RecordingBrowserOpener()
        let executor = makeExecutor(
            root: root,
            browserOpener: browserOpener,
            workspaceStore: workspaceStore
        )
        let plans = workspacePlans(name: "Writing", apps: ["Notes"], urls: ["https://github.com"])

        _ = try await executor.execute(plan: plans.create) { _, _ in }
        _ = try await executor.execute(plan: plans.open) { _, _ in }

        #expect(browserOpener.openedURLs.map(\.absoluteString) == ["https://github.com"])
        #expect(browserOpener.openedBrowsers == [nil])
    }

    /// "The workspace's browser" is the first *browser* in the saved apps list, not the first app,
    /// and every URL in the workspace goes to that same one.
    @Test
    func workspaceBrowserIsTheFirstBrowserInTheSavedAppsListNotTheFirstApp() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaceStore = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        let browserOpener = RecordingBrowserOpener()
        let executor = makeExecutor(
            root: root,
            browserOpener: browserOpener,
            workspaceStore: workspaceStore
        )
        let plans = workspacePlans(
            name: "Research",
            apps: ["Notes", "Chrome", "Safari"],
            urls: ["https://github.com", "https://news.ycombinator.com"]
        )

        _ = try await executor.execute(plan: plans.create) { _, _ in }
        _ = try await executor.execute(plan: plans.open) { _, _ in }

        #expect(browserOpener.openedURLs.map(\.absoluteString) == [
            "https://github.com",
            "https://news.ycombinator.com"
        ])
        #expect(browserOpener.openedBrowsers.map { $0?.bundleIdentifier } == [
            "com.google.Chrome",
            "com.google.Chrome"
        ])
    }

    /// End-to-end through the real `WorkspaceBrowserOpener` (both live seams injected): a workspace
    /// naming a browser that cannot be opened still opens its URLs — in the system default — and
    /// records why, rather than failing the run.
    @Test
    func workspaceURLsFallBackToTheDefaultBrowserWhenTheWorkspacesBrowserCannotBeOpened() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaceStore = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        var defaultBrowserURLs: [URL] = []
        var fallbackLogs: [String] = []
        let browserOpener = WorkspaceBrowserOpener(
            openURL: { url in
                defaultBrowserURLs.append(url)
                return true
            },
            openURLInApplication: { _, browser in
                throw AppOpeningError.appNotInstalled(browser.bundleIdentifier)
            },
            logFallback: { fallbackLogs.append($0) }
        )
        let executor = makeExecutor(
            root: root,
            browserOpener: browserOpener,
            workspaceStore: workspaceStore
        )
        let plans = workspacePlans(name: "Research", apps: ["Safari"], urls: ["https://github.com"])

        _ = try await executor.execute(plan: plans.create) { _, _ in }
        let result = try await executor.execute(plan: plans.open) { _, _ in }

        #expect(defaultBrowserURLs.map(\.absoluteString) == ["https://github.com"])
        #expect(fallbackLogs.count == 1)
        #expect(fallbackLogs.first?.contains("Safari") == true)
        #expect(result.summary == "Opened workspace Research with 1 app(s) and 1 URL(s).")
    }

    // MARK: - Scope-only workspace apps (SONNY-44)

    /// The headline of the 2026-08-05 decoupling decision: a workspace may list an app Sonny
    /// cannot launch. Before this, `create_workspace` validated every name through the catalog's
    /// twelve entries and its membership rejection made Microsoft Word unlistable — which is what
    /// would have made every `convert_docx_to_pdf` inside an apps-listing workspace escalate forever
    /// once SONNY-37 wires the verdict in. (SONNY-82 deleted that rejection outright; the name here
    /// is still unlaunchable on a Mac without Word, which is what keeps this case real.)
    @Test
    func aWorkspaceCanListAnAppTheLaunchCatalogDoesNotCarry() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaceStore = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        let executor = makeExecutor(root: root, workspaceStore: workspaceStore)
        let plans = workspacePlans(
            name: "Drafting",
            apps: ["Safari", "Microsoft Word"],
            urls: ["https://github.com"]
        )

        _ = try await executor.execute(plan: plans.create) { _, _ in }

        // Persisted as typed, both entries alike — `docs/sonny-branch-b-plan.md` §7's storage rule.
        // A stored name folded down to `MacAppCatalog.normalize`'s key form would read back as
        // "microsoftword" in the list the user sees, and would buy nothing: `WorkspaceScope.appKey`
        // folds both sides of every comparison through that normalizer anyway.
        let stored = try workspaceStore.workspace(named: "Drafting")
        #expect(stored.apps == ["Safari", "Microsoft Word"])
        #expect(stored.urls == ["https://github.com"])
    }

    /// The acceptance criterion the whole ticket exists for, end to end through the real creation
    /// path, the real store, and the real evaluator: a plan that drives Word is *in scope* for a
    /// workspace that lists it.
    ///
    /// The second half is the mutation guard. Without it this test would pass just as happily if
    /// `verdict(for:)` returned `.inScope` for everything — an identical workspace missing only the
    /// Word entry must read `.outOfScope` for the identical plan.
    @Test
    func aStoredScopeOnlyAppIsInScopeForThePlanThatDrivesIt() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaceStore = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        let executor = makeExecutor(root: root, workspaceStore: workspaceStore)

        _ = try await executor.execute(
            plan: workspacePlans(name: "Drafting", apps: ["Safari", "Microsoft Word"], urls: []).create
        ) { _, _ in }
        _ = try await executor.execute(
            plan: workspacePlans(name: "Browsing", apps: ["Safari"], urls: []).create
        ) { _, _ in }

        // No plan field names Word — `DocumentConverter` AppleScript-drives it from a hardcoded
        // path, and `PlanScopedResources` reports it implicitly.
        let conversion = AgentPlan(
            summary: "Convert the drafts.",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "convert",
                    operation: .convertDocxToPDF,
                    description: "Convert the drafts.",
                    inputPath: "~/Documents/Drafts",
                    outputPath: "~/Documents/Drafts"
                )
            ]
        )

        let listsWord = WorkspaceScopeEvaluator.evaluate(
            plan: conversion,
            scope: WorkspaceScope(workspace: try workspaceStore.workspace(named: "Drafting"))
        )
        let wordFinding = try #require(
            listsWord.findings.first { $0.resource == .app("Microsoft Word") }
        )
        #expect(wordFinding.verdict == .inScope)
        #expect(listsWord.outOfScopeFindings.contains { $0.resource == .app("Microsoft Word") } == false)

        let doesNotListWord = WorkspaceScopeEvaluator.evaluate(
            plan: conversion,
            scope: WorkspaceScope(workspace: try workspaceStore.workspace(named: "Browsing"))
        )
        let unlistedWordFinding = try #require(
            doesNotListWord.findings.first { $0.resource == .app("Microsoft Word") }
        )
        #expect(unlistedWordFinding.verdict == .outOfScope)
    }

    /// Open-time handling, per the SONNY-9 precedent: the catalog apps launch, the scope-only entry
    /// is logged and skipped, and the open itself succeeds. A workspace that fails to open because
    /// it holds a name Sonny cannot launch would re-create the unremediable dead end from the other
    /// direction.
    @Test
    func openingAWorkspaceLaunchesItsCatalogAppsAndSkipsAScopeOnlyEntryWithoutFailing() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaceStore = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        let appOpener = RecordingAppOpener()
        let browserOpener = RecordingBrowserOpener()
        let executor = makeExecutor(
            root: root,
            browserOpener: browserOpener,
            appOpener: appOpener,
            workspaceStore: workspaceStore
        )
        let plans = workspacePlans(
            name: "Drafting",
            apps: ["Safari", "Microsoft Word"],
            urls: ["https://github.com"]
        )

        _ = try await executor.execute(plan: plans.create) { _, _ in }
        var messages: [String] = []
        let result = try await executor.execute(plan: plans.open) { _, message in
            messages.append(message)
        }

        #expect(appOpener.openedBundleIDs == ["com.apple.Safari"])
        #expect(browserOpener.openedURLs.map(\.absoluteString) == ["https://github.com"])
        // Asserted whole, not by substring: SONNY-9's doubled-period bug shipped straight through
        // four `contains`-style assertions.
        #expect(messages.contains("Skipping Microsoft Word — it isn't installed on this Mac; it counts for workspace scope only."))
        // The summary counts what opened *and* names what did not. This is the only one of the three
        // channels a user actually sees, so it carries the whole signal — an honest "1 app(s)" alone
        // would leave them guessing which of the two listed apps started.
        #expect(result.summary == "Opened workspace Drafting with 1 app(s) and 1 URL(s). Microsoft Word isn't installed and was not opened.")
    }

    /// The signal has to arrive somewhere a person looks. `ActionPreview` is rendered by nothing,
    /// and neither is `AgentLogStore` (`AgentRunner`'s own comment says so, and nothing in
    /// `MacAgent` reads `.events`) — `AgentRunResult.summary` is the one free-text channel an
    /// adapter has that both surfaces render, so both workspace summaries carry the note.
    @Test
    func bothWorkspaceSummariesNameTheScopeOnlyAppsAndStaySilentWhenThereAreNone() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaceStore = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        let executor = makeExecutor(root: root, workspaceStore: workspaceStore)

        let scopeOnly = workspacePlans(
            name: "Drafting",
            apps: ["Safari", "Microsoft Word", "Figma"],
            urls: ["https://github.com"]
        )
        let created = try await executor.execute(plan: scopeOnly.create) { _, _ in }
        // The saved count is the full listed count — three apps really were saved. Which of them
        // Sonny cannot open is what the note is for.
        #expect(created.summary == "Saved workspace Drafting with 3 app(s) and 1 URL(s). Microsoft Word and Figma aren't installed on this Mac — counted for workspace scope only.")

        let opened = try await executor.execute(plan: scopeOnly.open) { _, _ in }
        #expect(opened.summary == "Opened workspace Drafting with 1 app(s) and 1 URL(s). Microsoft Word and Figma aren't installed and were not opened.")

        // And an all-catalog workspace's summaries are byte-identical to what they were before any
        // of this existed — the note appears only when it has something to say.
        let allCatalog = workspacePlans(name: "Browsing", apps: ["Safari"], urls: ["https://github.com"])
        let plainCreate = try await executor.execute(plan: allCatalog.create) { _, _ in }
        let plainOpen = try await executor.execute(plan: allCatalog.open) { _, _ in }
        #expect(plainCreate.summary == "Saved workspace Browsing with 1 app(s) and 1 URL(s).")
        #expect(plainOpen.summary == "Opened workspace Browsing with 1 app(s) and 1 URL(s).")
    }

    /// The newly reachable state nothing pinned: every entry scope-only, so the run opens nothing.
    /// Creation's only remaining guard is "at least one app or URL", so this workspace is trivially
    /// creatable now.
    ///
    /// The summary keeps the ordinary format and lets the note explain the zero, rather than
    /// branching into a separate "nothing to open" string — a second format is a second thing to
    /// keep true, and a bare "with 0 app(s) and 0 URL(s)" is the part that would read as a failure
    /// without the sentence after it.
    @Test
    func aWorkspaceWhoseEveryAppIsScopeOnlyOpensNothingAndSaysSo() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaceStore = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        let appOpener = RecordingAppOpener()
        let browserOpener = RecordingBrowserOpener()
        let executor = makeExecutor(
            root: root,
            browserOpener: browserOpener,
            appOpener: appOpener,
            workspaceStore: workspaceStore
        )
        let plans = workspacePlans(name: "Drafting", apps: ["Microsoft Word"], urls: [])

        _ = try await executor.execute(plan: plans.create) { _, _ in }
        let preview = try #require(try executor.preview(plan: plans.open).first)
        let result = try await executor.execute(plan: plans.open) { _, _ in }

        #expect(preview.opens.isEmpty)
        #expect(appOpener.openedBundleIDs.isEmpty)
        #expect(browserOpener.openedURLs.isEmpty)
        // Succeeds rather than throwing — a workspace of nothing but scope-only entries is a legal
        // boundary, not a broken launcher.
        #expect(result.summary == "Opened workspace Drafting with 0 app(s) and 0 URL(s). Microsoft Word isn't installed and was not opened.")
    }

    /// The adapter's own comment promises the skip is logged "between the entries around it", which
    /// is what makes the log readable as a launch sequence. Nothing pinned it: the one test with a
    /// sandwiched scope-only entry captured no messages, and the one that captured messages put the
    /// entry last and asserted membership rather than position. Batching the skips into a second
    /// pass would have kept both green.
    @Test
    func scopeOnlySkipsAreLoggedInTheWorkspacesOwnOrderNotBatchedAtTheEnd() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaceStore = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        let executor = makeExecutor(root: root, workspaceStore: workspaceStore)
        let plans = workspacePlans(
            name: "Drafting",
            apps: ["Safari", "Microsoft Word", "Notes"],
            urls: []
        )

        _ = try await executor.execute(plan: plans.create) { _, _ in }
        var messages: [String] = []
        _ = try await executor.execute(plan: plans.open) { _, message in
            messages.append(message)
        }

        // Whole sequence, in order — the skip sits where the entry sits.
        #expect(messages == [
            "Opening Safari",
            "Skipping Microsoft Word — it isn't installed on this Mac; it counts for workspace scope only.",
            "Opening Notes",
            "Opened workspace"
        ])
    }

    /// Repeats and awkward names, both newly reachable: before this ticket any unresolvable name was
    /// a hard failure, so neither could be stored at all.
    ///
    /// The comma case is the subtle one. With a plain `", "` join, one app named "Foo, Bar" and two
    /// apps named "Foo" and "Bar" produce the identical sentence. The singular/plural verb plus the
    /// "and" join tells them apart without quoting anything.
    @Test
    func theScopeOnlyNoteDeduplicatesRepeatsAndDoesNotBlurACommaInAName() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaceStore = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        let executor = makeExecutor(root: root, workspaceStore: workspaceStore)

        let repeated = workspacePlans(
            name: "Repeats",
            apps: ["Microsoft Word", "Microsoft Word"],
            urls: []
        )
        let repeatedResult = try await executor.execute(plan: repeated.create) { _, _ in }
        // Named once in the note; still two saved entries, so the count stays 2.
        #expect(repeatedResult.summary == "Saved workspace Repeats with 2 app(s) and 0 URL(s). Microsoft Word isn't installed on this Mac — counted for workspace scope only.")

        let oneCommaName = workspacePlans(name: "One Name", apps: ["Foo, Bar"], urls: [])
        let oneResult = try await executor.execute(plan: oneCommaName.create) { _, _ in }
        #expect(oneResult.summary == "Saved workspace One Name with 1 app(s) and 0 URL(s). Foo, Bar isn't installed on this Mac — counted for workspace scope only.")

        let twoNames = workspacePlans(name: "Two Names", apps: ["Foo", "Bar"], urls: [])
        let twoResult = try await executor.execute(plan: twoNames.create) { _, _ in }
        #expect(twoResult.summary == "Saved workspace Two Names with 2 app(s) and 0 URL(s). Foo and Bar aren't installed on this Mac — counted for workspace scope only.")

        // Three or more take the serial join, so the last name never merges into the one before it.
        let threeNames = workspacePlans(name: "Three Names", apps: ["Foo", "Bar", "Baz"], urls: [])
        let threeResult = try await executor.execute(plan: threeNames.create) { _, _ in }
        #expect(threeResult.summary == "Saved workspace Three Names with 3 app(s) and 0 URL(s). Foo, Bar and Baz aren't installed on this Mac — counted for workspace scope only.")
    }

    /// The preview declares side effects, so it must not claim an open that cannot happen. The
    /// `details` line is the opposite case: it describes what the workspace *contains*, where a
    /// scope-only entry genuinely belongs.
    @Test
    func theOpenPreviewDoesNotClaimItWillOpenAScopeOnlyApp() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaceStore = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        let executor = makeExecutor(root: root, workspaceStore: workspaceStore)
        let plans = workspacePlans(
            name: "Drafting",
            apps: ["Safari", "Microsoft Word"],
            urls: ["https://github.com"]
        )

        _ = try await executor.execute(plan: plans.create) { _, _ in }
        let preview = try #require(try executor.preview(plan: plans.open).first)

        #expect(preview.opens == ["Safari", "https://github.com"])
        #expect(preview.details.contains("Apps: Safari, Microsoft Word"))
        #expect(preview.details.contains("Microsoft Word isn't installed on this Mac — counted for workspace scope only."))
    }

    /// The typo guard. It cannot tell "Microsft Word" from "Microsoft Word" — nothing can, once the
    /// catalog is no longer the authority — so the entire mitigation is that the name is *said out
    /// loud* at the moment it is typed rather than sitting silently inside a boundary. Both halves
    /// are pinned: it appears when a name is scope-only, and it stays absent when every name
    /// resolves.
    @Test
    func theScopeOnlyNoteNamesEveryUnlaunchableAppAndIsAbsentWhenEveryNameResolves() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaceStore = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        let executor = makeExecutor(root: root, workspaceStore: workspaceStore)

        let withScopeOnly = workspacePlans(
            name: "Drafting",
            apps: ["Safari", "Microsoft Word", "Figma"],
            urls: []
        )
        let noted = try #require(try executor.preview(plan: withScopeOnly.create).first)
        #expect(noted.details == [
            "Apps: Safari, Microsoft Word, Figma",
            "URLs: none",
            "Microsoft Word and Figma aren't installed on this Mac — counted for workspace scope only."
        ])

        // And on the channel the user actually sees: nothing in `MacAgent` renders an
        // `ActionPreview`, so the act log is where this reaches a real person.
        var messages: [String] = []
        _ = try await executor.execute(plan: withScopeOnly.create) { _, message in
            messages.append(message)
        }
        #expect(messages.contains("Microsoft Word and Figma aren't installed on this Mac — counted for workspace scope only."))

        let allCatalog = workspacePlans(name: "Browsing", apps: ["Safari", "Chrome"], urls: [])
        let silent = try #require(try executor.preview(plan: allCatalog.create).first)
        #expect(silent.details == ["Apps: Safari, Chrome", "URLs: none"])

        var catalogMessages: [String] = []
        _ = try await executor.execute(plan: allCatalog.create) { _, message in
            catalogMessages.append(message)
        }
        #expect(catalogMessages.contains { $0.contains("workspace scope only") } == false)
    }

    /// A name the catalog cannot resolve is now fine; a *blank* one is still a hard failure. Without
    /// this, dropping the catalog gate would let "" into an apps list, where `WorkspaceScope`
    /// classifies it as an inert entry that can never match anything — a boundary that quietly does
    /// nothing, which is the one outcome the scope model refuses to produce.
    @Test
    func aBlankWorkspaceAppNameIsStillRejected() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaceStore = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        let executor = makeExecutor(root: root, workspaceStore: workspaceStore)
        let plans = workspacePlans(name: "Drafting", apps: ["Safari", "   "], urls: [])

        await #expect(throws: MacAppError.missingAppName) {
            _ = try await executor.execute(plan: plans.create) { _, _ in }
        }
        #expect(throws: (any Error).self) {
            _ = try workspaceStore.workspace(named: "Drafting")
        }
    }

    /// Stored trimmed, so speech-to-text padding does not become part of the boundary the user reads
    /// back. The fold beyond trimming stays where it already lives, in the evaluator.
    @Test
    func workspaceAppNamesAreStoredTrimmed() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaceStore = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        let executor = makeExecutor(root: root, workspaceStore: workspaceStore)
        let plans = workspacePlans(name: "Drafting", apps: ["  Microsoft Word  ", " Safari "], urls: [])

        _ = try await executor.execute(plan: plans.create) { _, _ in }

        #expect(try workspaceStore.workspace(named: "Drafting").apps == ["Microsoft Word", "Safari"])
    }

    /// A scope-only entry must not disturb SONNY-9's browser selection. "The workspace's browser" is
    /// the first *browser* among the apps that can actually launch, and a skipped entry ahead of one
    /// neither becomes the browser nor shifts which app does.
    @Test
    func aScopeOnlyEntryDoesNotChangeWhichBrowserAWorkspaceUses() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaceStore = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        let appOpener = RecordingAppOpener()
        let browserOpener = RecordingBrowserOpener()
        let executor = makeExecutor(
            root: root,
            browserOpener: browserOpener,
            appOpener: appOpener,
            workspaceStore: workspaceStore
        )
        // Word first (skipped) and Notes ahead of Chrome (launchable, not a browser), so the answer
        // is only Chrome if *both* rules hold: scope-only entries drop out of the candidate list,
        // and the browser is the first browser rather than the first app.
        let plans = workspacePlans(
            name: "Drafting",
            apps: ["Microsoft Word", "Notes", "Chrome"],
            urls: ["https://github.com"]
        )

        _ = try await executor.execute(plan: plans.create) { _, _ in }
        _ = try await executor.execute(plan: plans.open) { _, _ in }

        #expect(appOpener.openedBundleIDs == ["com.apple.Notes", "com.google.Chrome"])
        #expect(browserOpener.openedBrowsers.map { $0?.bundleIdentifier } == ["com.google.Chrome"])
    }

    private func workspacePlans(
        name: String,
        apps: [String],
        urls: [String]
    ) -> (create: AgentPlan, open: AgentPlan) {
        let create = AgentPlan(
            summary: "Create workspace.",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "create-workspace",
                    operation: .createWorkspace,
                    description: "Create workspace.",
                    workspaceName: name,
                    workspaceApps: apps,
                    workspaceURLs: urls
                )
            ]
        )
        let open = AgentPlan(
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
        return (create, open)
    }

    @Test
    func createLocalDraftWritesWhitelistedMarkdownAndSuggestsOpenReveal() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("draft.md")
        let executor = makeExecutor(root: root)

        let result = try await executor.execute(plan: localDraftPlan(output: output)) { _, _ in }

        let markdown = try String(contentsOf: output)
        #expect(markdown.contains("# Follow Up"))
        #expect(markdown.contains("Draft body."))
        #expect(result.suggestions.contains { suggestion in
            suggestion.title == "Open Draft" &&
                suggestion.kind == .openFile &&
                suggestion.value == output.path
        })
        #expect(result.suggestions.contains { suggestion in
            suggestion.title == "Reveal Draft in Finder" &&
                suggestion.kind == .revealInFinder &&
                suggestion.value == output.path
        })
    }

    @Test
    func openGeneratedArtifactUsesInjectedFileOpenerAndRejectsOutsideWhitelist() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let artifact = root.appendingPathComponent("artifact.md")
        try write("artifact", to: artifact)
        let fileOpener = RecordingFileOpener()
        let executor = makeExecutor(root: root, fileOpener: fileOpener)

        let result = try await executor.execute(plan: openGeneratedArtifactPlan(output: artifact)) { _, _ in }

        #expect(fileOpener.openedFiles == [artifact.standardizedFileURL])
        #expect(result.summary == "Opened generated artifact \(artifact.path).")
        #expect(throws: PathValidationError.outsideWhitelist("/private/tmp/not-allowed.md", [root.path])) {
            try executor.preview(plan: openGeneratedArtifactPlan(output: URL(fileURLWithPath: "/private/tmp/not-allowed.md")))
        }
    }

    @Test
    func chainCanOpenFutureGeneratedArtifact() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("draft.md")
        let fileOpener = RecordingFileOpener()
        let executor = makeExecutor(root: root, fileOpener: fileOpener)
        let plan = AgentPlan(
            summary: "Create and open draft.",
            requiresConfirmation: true,
            steps: [
                localDraftStep(output: output),
                AgentStep(
                    id: "open-artifact",
                    operation: .openGeneratedArtifact,
                    description: "Open generated draft."
                )
            ]
        )

        let preview = try executor.preview(plan: plan)
        let result = try await executor.execute(plan: plan) { _, _ in }

        #expect(preview.count == 2)
        #expect(preview[1].details == ["Open \(output.path)"])
        #expect(fileOpener.openedFiles == [output.standardizedFileURL])
        #expect(result.summary.contains("Created local draft"))
        #expect(result.summary.contains("Opened generated artifact"))
    }

    private var plannerContext: ApprovalContext {
        ApprovalContext(mode: .normal, appControl: .notApplicable)
    }

    private func makeExecutor(
        root: URL,
        zipArchiver: ZipArchiving = RecordingZipArchiver(),
        documentConverter: DocumentConverting = FakeDocumentConverter(),
        browserOpener: BrowserOpening = NoopBrowserOpener(),
        hackerNewsFetcher: HackerNewsFetching = StaticHackerNewsFetcher(),
        appCatalog: MacAppCatalog = .default,
        // Defaults to the process-appropriate resolver, which under XCTest holds exactly the alias
        // table's roster — the pre-dissolution universe, so every test written before SONNY-82 keeps
        // the answers it was written against. A test about the open universe injects the app it means.
        installedAppResolver: any InstalledAppResolving = InstalledAppResolver.shared,
        appSearchURLCatalog: AppSearchURLCatalog = .default,
        appOpener: AppOpening = NoopAppOpener(),
        fileOpener: FileOpening = NoopFileOpener(),
        mediaOpener: MediaOpening = FakeMediaOpener(),
        spotifyPlaybackProvider: (any SpotifyPlaybackProviding)? = nil,
        appleMusicPlaybackProvider: (any AppleMusicPlaybackProviding)? = nil,
        finderContextReader: FinderContextReading = FakeFinderContextReader(selection: []),
        routineStore: RoutineStore? = nil,
        workspaceStore: WorkspaceStore? = nil,
        webPageLoader: PublicWebPageLoader? = nil,
        webSearchProvider: (any WebSearchProviding)? = nil,
        webResearchSynthesizer: (any WebResearchSynthesizing)? = nil,
        // Defaulted to an empty fake, never the production `ProcessShortcutCatalog`: resolving a
        // Shortcut name shells out to `shortcuts list`, and no test should be one typo away from
        // enumerating the developer's real Shortcuts library.
        shortcutCatalog: any ShortcutCatalogProviding = FakeShortcutCatalog(names: []),
        shortcutRunHistoryStore: ShortcutRunHistoryStore? = nil,
        now: @escaping () -> Date = Date.init,
        hotKeyReady: @escaping () -> Bool = { true },
        permissionReadinessService: PermissionReadinessService = .deterministic()
    ) -> AgentActionExecutor {
        AgentActionExecutor(
            whitelist: PathWhitelist(roots: [root]),
            zipArchiver: zipArchiver,
            documentConverter: documentConverter,
            browserOpener: browserOpener,
            hackerNewsFetcher: hackerNewsFetcher,
            appCatalog: appCatalog,
            installedAppResolver: installedAppResolver,
            appSearchURLCatalog: appSearchURLCatalog,
            appOpener: appOpener,
            fileOpener: fileOpener,
            mediaOpener: mediaOpener,
            spotifyPlaybackProvider: spotifyPlaybackProvider,
            appleMusicPlaybackProvider: appleMusicPlaybackProvider,
            finderContextReader: finderContextReader,
            permissionReadinessService: permissionReadinessService,
            routineStore: routineStore ?? RoutineStore(fileURL: root.appendingPathComponent("routines.json")),
            workspaceStore: workspaceStore ?? WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json")),
            webPageLoader: webPageLoader,
            webSearchProvider: webSearchProvider,
            webResearchSynthesizer: webResearchSynthesizer,
            shortcutCatalog: shortcutCatalog,
            shortcutRunHistoryStore: shortcutRunHistoryStore
                ?? ShortcutRunHistoryStore(fileURL: root.appendingPathComponent("shortcuts-history.json")),
            now: now,
            hotKeyReady: hotKeyReady
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
                    description: "Scan files",
                    inputPath: root.path,
                    count: 3
                ),
                AgentStep(
                    id: "zip",
                    operation: .createZip,
                    description: "Zip files",
                    inputPath: root.path,
                    outputPath: output.path,
                    count: 3
                )
            ]
        )
    }

    /// A store file that claims to be encrypted and is not: a real `SONNYENC1` header over
    /// ciphertext that cannot authenticate. The recipe `EditWorkspaceTests` uses, so both SONNY-30
    /// pins induce the failure the same way.
    private func corruptStore(at url: URL) throws {
        var corrupt = LocalStorageEncryption.fileHeader
        corrupt.append(Data(repeating: 0x00, count: 64))
        try corrupt.write(to: url, options: .atomic)
    }

    private func createWorkspacePlan(named name: String) -> AgentPlan {
        AgentPlan(
            summary: "Create a workspace called \(name).",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "create-workspace",
                    operation: .createWorkspace,
                    description: "Save the workspace.",
                    workspaceName: name,
                    workspaceApps: ["Safari"]
                )
            ]
        )
    }

    private func saveRoutinePlan(named name: String) -> AgentPlan {
        AgentPlan(
            summary: "Teach Sonny a routine called \(name).",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "save-routine",
                    operation: .saveRoutine,
                    description: "Save the routine.",
                    routineName: name,
                    routineSteps: [
                        AgentStep(id: "open", operation: .openApp, description: "Open Safari.", appName: "Safari")
                    ]
                )
            ]
        )
    }

    /// Every `source -> destination` pair a run reported, each side shortened to `folder/name`.
    private func conversionTails(in result: AgentRunResult) -> [String] {
        result.previews.flatMap(\.conversions).map { conversion in
            conversion
                .components(separatedBy: " -> ")
                .map { side in
                    let url = URL(fileURLWithPath: side)
                    return "\(url.deletingLastPathComponent().lastPathComponent)/\(url.lastPathComponent)"
                }
                .joined(separator: " -> ")
        }
    }

    /// SONNY-28's fixture: `SubA/report.docx` and `SubB/report.docx` scanned together into one flat
    /// output folder — "convert the Word docs in ~/Documents to PDF and put them in ~/Desktop/PDFs".
    /// Both documents' basenames produce `report.pdf` in the same directory.
    private struct OverlappingScopeFixture {
        let root: URL
        let documents: URL
        let sub: URL
        let plan: AgentPlan
    }

    private struct CollidingDocxFixture {
        let root: URL
        let subA: URL
        let subB: URL
        let outputFolder: URL
        let plan: AgentPlan
    }

    /// Two folders, one output folder, one document of the same name in each — expressed as a chain
    /// of two `[scan_docx, convert]` units, which is what a two-folder conversion becomes after
    /// SONNY-34 and what makes this different from `collidingDocxFixture`'s single scan.
    /// Nested scopes: `[scan(Documents), convert] + [scan(Documents/Sub), convert]`, one document.
    private func overlappingScopeFixture() throws -> OverlappingScopeFixture {
        let root = try makeDirectory()
        let documents = root.appendingPathComponent("Documents", isDirectory: true)
        let sub = documents.appendingPathComponent("Sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try write("docx", to: sub.appendingPathComponent("report.docx"))
        return OverlappingScopeFixture(
            root: root,
            documents: documents,
            sub: sub,
            plan: AgentPlan(
                summary: "Convert the Word documents to PDF.",
                requiresConfirmation: true,
                steps: docxPair("outer", documents) + docxPair("inner", sub)
            )
        )
    }

    /// The degenerate case: `[scan(Documents), convert] + [scan(Documents), convert]`.
    private func repeatedScopeFixture() throws -> OverlappingScopeFixture {
        let root = try makeDirectory()
        let documents = root.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        try write("docx", to: documents.appendingPathComponent("report.docx"))
        return OverlappingScopeFixture(
            root: root,
            documents: documents,
            sub: documents,
            plan: AgentPlan(
                summary: "Convert the Word documents to PDF.",
                requiresConfirmation: true,
                steps: docxPair("first", documents) + docxPair("second", documents)
            )
        )
    }

    /// One `[scan_docx, convert]` unit over `folder`, with no explicit output folder so each PDF
    /// lands beside its source — which is what makes both units name the same destination.
    private func docxPair(_ id: String, _ folder: URL) -> [AgentStep] {
        [
            AgentStep(id: "scan-\(id)", operation: .scanDocx, description: "Scan DOCX.", inputPath: folder.path),
            AgentStep(id: "convert-\(id)", operation: .convertDocxToPDF, description: "Convert DOCX.", inputPath: folder.path)
        ]
    }

    private struct DifferingOutputFixture {
        let root: URL
        let firstOutput: URL
        let secondOutput: URL
        let plan: AgentPlan
    }

    /// PROBE F: one folder scanned twice, into two *different* explicit output folders.
    private func differingOutputFoldersFixture() throws -> DifferingOutputFixture {
        let root = try makeDirectory()
        let documents = root.appendingPathComponent("Documents", isDirectory: true)
        let first = root.appendingPathComponent("Out1", isDirectory: true)
        let second = root.appendingPathComponent("Out2", isDirectory: true)
        for directory in [documents, first, second] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try write("docx", to: documents.appendingPathComponent("report.docx"))

        func pair(_ id: String, _ output: URL) -> [AgentStep] {
            [
                AgentStep(id: "scan-\(id)", operation: .scanDocx, description: "Scan DOCX.", inputPath: documents.path),
                AgentStep(
                    id: "convert-\(id)",
                    operation: .convertDocxToPDF,
                    description: "Convert DOCX.",
                    inputPath: documents.path,
                    outputPath: output.path
                )
            ]
        }

        return DifferingOutputFixture(
            root: root,
            firstOutput: first,
            secondOutput: second,
            plan: AgentPlan(
                summary: "Convert the Word documents into both folders.",
                requiresConfirmation: true,
                steps: pair("first", first) + pair("second", second)
            )
        )
    }

    /// PROBE E: `[scan(Documents), convert]` — default output, beside the source — followed by
    /// `[scan(Documents/Invoices), convert -> DesktopInvoices]`. The outer scan recurses, so both
    /// units see the same document and only the second names a folder.
    private func nestedScopeIntoAnotherFolderFixture() throws -> DifferingOutputFixture {
        let root = try makeDirectory()
        let documents = root.appendingPathComponent("Documents", isDirectory: true)
        let invoices = documents.appendingPathComponent("Invoices", isDirectory: true)
        let desktopInvoices = root.appendingPathComponent("DesktopInvoices", isDirectory: true)
        for directory in [invoices, desktopInvoices] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try write("docx", to: invoices.appendingPathComponent("acme.docx"))

        return DifferingOutputFixture(
            root: root,
            firstOutput: invoices,
            secondOutput: desktopInvoices,
            plan: AgentPlan(
                summary: "Convert the Word documents to PDF.",
                requiresConfirmation: true,
                steps: [
                    AgentStep(id: "scan-outer", operation: .scanDocx, description: "Scan DOCX.", inputPath: documents.path),
                    AgentStep(
                        id: "convert-outer",
                        operation: .convertDocxToPDF,
                        description: "Convert DOCX.",
                        inputPath: documents.path
                    ),
                    AgentStep(id: "scan-inner", operation: .scanDocx, description: "Scan DOCX.", inputPath: invoices.path),
                    AgentStep(
                        id: "convert-inner",
                        operation: .convertDocxToPDF,
                        description: "Convert DOCX.",
                        inputPath: invoices.path,
                        outputPath: desktopInvoices.path
                    )
                ]
            )
        )
    }

    /// Two documents sharing a basename in nested folders, one flat output folder, scanned twice —
    /// so the first unit renames one output and the second unit re-scans both.
    private func collidingBasenamesRescannedFixture() throws -> CollidingDocxFixture {
        let root = try makeDirectory()
        let documents = root.appendingPathComponent("Documents", isDirectory: true)
        let subA = documents.appendingPathComponent("SubA", isDirectory: true)
        let subB = documents.appendingPathComponent("SubB", isDirectory: true)
        let outputFolder = root.appendingPathComponent("PDFs", isDirectory: true)
        for directory in [subA, subB, outputFolder] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try write("docx-a", to: subA.appendingPathComponent("report.docx"))
        try write("docx-b", to: subB.appendingPathComponent("report.docx"))

        func pair(_ id: String) -> [AgentStep] {
            [
                AgentStep(id: "scan-\(id)", operation: .scanDocx, description: "Scan DOCX.", inputPath: documents.path),
                AgentStep(
                    id: "convert-\(id)",
                    operation: .convertDocxToPDF,
                    description: "Convert DOCX.",
                    inputPath: documents.path,
                    outputPath: outputFolder.path
                )
            ]
        }

        return CollidingDocxFixture(
            root: root,
            subA: subA,
            subB: subB,
            outputFolder: outputFolder,
            plan: AgentPlan(
                summary: "Convert the Word documents to PDF.",
                requiresConfirmation: true,
                steps: pair("first") + pair("second")
            )
        )
    }

    private func twoFolderChainFixture() throws -> CollidingDocxFixture {
        let root = try makeDirectory()
        let clientA = root.appendingPathComponent("ClientA", isDirectory: true)
        let clientB = root.appendingPathComponent("ClientB", isDirectory: true)
        let outputFolder = root.appendingPathComponent("PDFs", isDirectory: true)
        for directory in [clientA, clientB, outputFolder] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try write("docx-a", to: clientA.appendingPathComponent("report.docx"))
        try write("docx-b", to: clientB.appendingPathComponent("report.docx"))

        func pair(_ id: String, _ folder: URL) -> [AgentStep] {
            [
                AgentStep(id: "scan-\(id)", operation: .scanDocx, description: "Scan DOCX.", inputPath: folder.path),
                AgentStep(
                    id: "convert-\(id)",
                    operation: .convertDocxToPDF,
                    description: "Convert DOCX.",
                    inputPath: folder.path,
                    outputPath: outputFolder.path
                )
            ]
        }

        return CollidingDocxFixture(
            root: root,
            subA: clientA,
            subB: clientB,
            outputFolder: outputFolder,
            plan: AgentPlan(
                summary: "Convert the Word documents in both folders to PDF.",
                requiresConfirmation: true,
                steps: pair("a", clientA) + pair("b", clientB)
            )
        )
    }

    private func collidingDocxFixture(nameA: String = "report", nameB: String = "report") throws -> CollidingDocxFixture {
        let root = try makeDirectory()
        let documents = root.appendingPathComponent("Documents", isDirectory: true)
        let subA = documents.appendingPathComponent("SubA", isDirectory: true)
        let subB = documents.appendingPathComponent("SubB", isDirectory: true)
        let outputFolder = root.appendingPathComponent("PDFs", isDirectory: true)
        for directory in [subA, subB, outputFolder] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try write("docx-a", to: subA.appendingPathComponent("\(nameA).docx"))
        try write("docx-b", to: subB.appendingPathComponent("\(nameB).docx"))

        return CollidingDocxFixture(
            root: root,
            subA: subA,
            subB: subB,
            outputFolder: outputFolder,
            plan: AgentPlan(
                summary: "Convert the Word documents to PDF.",
                requiresConfirmation: true,
                steps: [
                    AgentStep(id: "scan", operation: .scanDocx, description: "Scan DOCX.", inputPath: documents.path),
                    AgentStep(
                        id: "convert",
                        operation: .convertDocxToPDF,
                        description: "Convert DOCX.",
                        inputPath: documents.path,
                        outputPath: outputFolder.path
                    )
                ]
            )
        )
    }

    /// Two `.createLocalDraft` steps with **no** destinations — "draft a note about X and another
    /// about Y", the plan SONNY-35 describes. Titles are a parameter because whether the planner
    /// supplies them is exactly what decides whether the two generated names collide.
    private func untitledDraftChainPlan(firstTitle: String?, secondTitle: String?) -> AgentPlan {
        AgentPlan(
            summary: "Draft two notes.",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "draft-1",
                    operation: .createLocalDraft,
                    description: "Create the first draft.",
                    draftTitle: firstTitle,
                    draftContent: "First note."
                ),
                AgentStep(
                    id: "draft-2",
                    operation: .createLocalDraft,
                    description: "Create the second draft.",
                    draftTitle: secondTitle,
                    draftContent: "Second note."
                )
            ]
        )
    }

    /// Two complete `[scan_select_largest_files, create_zip]` pairs over two folders, with nothing
    /// between them — SONNY-34's headline plan shape. Explicit destinations, so the plan says
    /// unambiguously that two archives were asked for.
    private func twoLargestFilesPairsPlan(folderA: URL, zipA: URL, folderB: URL, zipB: URL) -> AgentPlan {
        AgentPlan(
            summary: "Zip the largest files in both folders.",
            requiresConfirmation: true,
            steps: [
                AgentStep(id: "scan-a", operation: .scanSelectLargestFiles, description: "Scan A.", inputPath: folderA.path, count: 3),
                AgentStep(id: "zip-a", operation: .createZip, description: "Zip A.", inputPath: folderA.path, outputPath: zipA.path, count: 3),
                AgentStep(id: "scan-b", operation: .scanSelectLargestFiles, description: "Scan B.", inputPath: folderB.path, count: 3),
                AgentStep(id: "zip-b", operation: .createZip, description: "Zip B.", inputPath: folderB.path, outputPath: zipB.path, count: 3)
            ]
        )
    }

    /// Two `.createLocalDraft` steps with explicit, independent destinations — the plan
    /// "draft a note at a.md and another at b.md" produces. Both steps really execute
    /// (a draft step is its own unit, so two of them chain), so both have to be assessed.
    private func draftChainPlan(first: URL, second: URL) -> AgentPlan {
        AgentPlan(
            summary: "Draft two notes.",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "draft-1",
                    operation: .createLocalDraft,
                    description: "Create the first draft.",
                    outputPath: first.path,
                    draftTitle: "First",
                    draftContent: "First note."
                ),
                AgentStep(
                    id: "draft-2",
                    operation: .createLocalDraft,
                    description: "Create the second draft.",
                    outputPath: second.path,
                    draftTitle: "Second",
                    draftContent: "Second note."
                )
            ]
        )
    }

    /// A Hacker-News-preset segment followed by a `.webToMarkdown` segment: two workflows, so the
    /// plan chains, and both segments are owned by `WebResearchMarkdownCapabilityAdapter`.
    private func hackerNewsThenWebResearchPlan(
        hackerNewsOutput: String?,
        webResearchOutput: String?
    ) -> AgentPlan {
        AgentPlan(
            summary: "Save the Hacker News headlines and a research note.",
            requiresConfirmation: true,
            steps: [
                AgentStep(id: "open-hn", operation: .openHackerNews, description: "Open Hacker News."),
                AgentStep(id: "fetch-hn", operation: .fetchHNHeadlines, description: "Fetch headlines.", count: 5),
                AgentStep(
                    id: "write-hn",
                    operation: .writeMarkdown,
                    description: "Save the headlines.",
                    outputPath: hackerNewsOutput
                ),
                AgentStep(
                    id: "research",
                    operation: .webToMarkdown,
                    description: "Summarize the article.",
                    outputPath: webResearchOutput,
                    targetURL: "https://example.com/article"
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
                    description: "Scan DOCX",
                    inputPath: root.path
                ),
                AgentStep(
                    id: "convert",
                    operation: .convertDocxToPDF,
                    description: "Convert DOCX",
                    inputPath: root.path
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
                    description: "Open HN",
                    targetURL: "https://news.ycombinator.com"
                ),
                AgentStep(
                    id: "fetch",
                    operation: .fetchHNHeadlines,
                    description: "Fetch headlines",
                    count: 5,
                    targetURL: "https://news.ycombinator.com"
                ),
                AgentStep(
                    id: "write",
                    operation: .writeMarkdown,
                    description: "Write Markdown",
                    outputPath: output.path,
                    count: 5
                )
            ]
        )
    }

    private func webMarkdownPlan(url: URL, output: URL) -> AgentPlan {
        AgentPlan(
            summary: "Summarize the article as Markdown.",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "web",
                    operation: .webToMarkdown,
                    description: "Summarize web article.",
                    outputPath: output.path,
                    targetURL: url.absoluteString
                )
            ]
        )
    }

    // MARK: - Workspace scope wired into risk assessment (SONNY-37)
    //
    // Every escalation path below carries its inverse in the same file, and the inverses are the
    // load-bearing half. A scope check that stops running fails *silently* — the symptom is a
    // prompt that never fires, which no manual test stumbles on by accident — so each of these is
    // mutation-checked in the dangerous direction: break the verdict handling and the test proving
    // a prompt still fires must go red, not just the one proving it stays quiet.

    /// AC1 — an in-scope resource changes nothing at all. Asserted on the whole assessment rather
    /// than the tier, so an escalation appearing with an unchanged tier would still fail.
    @Test
    func anInScopeResourceUnderAScopedWorkspaceAssessesExactlyAsUnscoped() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = makeExecutor(root: root)
        let plan = openURLPlan(url: "https://github.com/sonny")
        let scope = WorkspaceScope(
            workspace: StoredWorkspace(name: "Research", apps: [], urls: ["https://github.com"])
        )

        var expected = try executor.assessRisk(plan: plan, scope: .unscoped)
        #expect(expected.scopeVerdict == nil)
        // Everything except the new roll-up must be identical; the roll-up itself is asserted.
        expected.scopeVerdict = .inScope

        #expect(try executor.assessRisk(plan: plan, scope: .scoped(scope)) == expected)
    }

    /// AC2 — the escalation exists, reaches tier 3, and its reason names both the resource and the
    /// workspace. Asserted on the literal string: "not empty" would pass for any wording.
    @Test
    func anOutOfScopeHostEscalatesToTierThreeAndNamesTheHostAndTheWorkspace() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = makeExecutor(root: root)
        let plan = openURLPlan(url: "https://example.com/page")
        let scope = WorkspaceScope(
            workspace: StoredWorkspace(name: "Research", apps: [], urls: ["https://github.com"])
        )

        let assessment = try executor.assessRisk(plan: plan, scope: .scoped(scope))

        #expect(assessment.effectiveTier == .tier3)
        #expect(assessment.escalations.count == 1)
        #expect(assessment.escalations.first?.toTier == .tier3)
        #expect(assessment.escalations.first?.reason == "example.com is not part of the Research workspace.")
        #expect(assessment.scopeVerdict == .outOfScope)
    }

    /// AC3 — **the laundering hole.** A routine is a stored list of steps, so without the scope
    /// forwarding into `assessNestedPlan` a task bound to a workspace could run a routine whose
    /// steps write anywhere at all, and the boundary would report nothing. The routine's own step
    /// is what is out of scope here; the plan names only the routine.
    @Test
    func aRoutineWhoseStepsLeaveTheWorkspaceEscalatesRatherThanLaunderingThroughTheNesting() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let routineStore = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))
        try routineStore.save(
            StoredRoutine(
                name: "Leaky",
                steps: [
                    AgentStep(
                        id: "leak",
                        operation: .openURL,
                        description: "Open an unrelated site.",
                        targetURL: "https://example.com/page"
                    )
                ]
            )
        )
        let executor = makeExecutor(root: root, routineStore: routineStore)
        let scope = WorkspaceScope(
            workspace: StoredWorkspace(name: "Research", apps: [], urls: ["https://github.com"])
        )

        let assessment = try executor.assessRisk(plan: runRoutinePlan(name: "Leaky"), scope: .scoped(scope))

        #expect(assessment.effectiveTier == .tier3)
        #expect(assessment.escalations.contains {
            $0.reason == "example.com is not part of the Research workspace."
        })
        // The roll-up has to travel back out of the nesting too. On *this* shape, losing the forward
        // yields `.unconstrained` — the outer plan's only step is `run_routine`, which classifies as
        // `.none`, so the fold falls to its bottom element. Wrong, but inert. The shape where losing
        // it is dangerous is the mixed one below.
        #expect(assessment.scopeVerdict == .outOfScope)
    }

    /// The shape that makes the nested roll-up forward load-bearing rather than merely tidy.
    ///
    /// One in-scope step beside the leaky routine, so the *outer* plan's own findings roll up
    /// `.inScope` on their own. Drop the forward and that is the answer the assessment ships —
    /// `.inScope`, on a plan Sonny has just escalated for writing outside the boundary. Row C's
    /// recorded rule is that in-scope tier 3 drops to a lightweight confirmation, so the first
    /// consumer of this field would lighten the very prompt this ticket raised.
    @Test
    func aLeakyRoutineBesideAnInScopeStepStillRollsUpOutOfScope() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let routineStore = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))
        try routineStore.save(
            StoredRoutine(
                name: "Leaky",
                steps: [
                    AgentStep(
                        id: "leak",
                        operation: .openURL,
                        description: "Open an unrelated site.",
                        targetURL: "https://example.com/page"
                    )
                ]
            )
        )
        let executor = makeExecutor(root: root, routineStore: routineStore)
        let plan = AgentPlan(
            summary: "Open GitHub, then run the routine.",
            requiresConfirmation: true,
            steps: [
                AgentStep(id: "in-scope", operation: .openURL, description: "In scope.", targetURL: "https://github.com/sonny"),
                AgentStep(id: "run", operation: .runRoutine, description: "Run the routine.", routineName: "Leaky")
            ]
        )
        let scope = WorkspaceScope(
            workspace: StoredWorkspace(name: "Research", apps: [], urls: ["https://github.com"])
        )

        let assessment = try executor.assessRisk(plan: plan, scope: .scoped(scope))

        #expect(assessment.scopeVerdict == .outOfScope)
        #expect(assessment.escalations.contains {
            $0.reason == "example.com is not part of the Research workspace."
        })
        #expect(assessment.effectiveTier == .tier3)
    }

    /// F1 — **saving a routine is scope-neutral.** `PlanScopedResources`' `.saveRoutine` case records
    /// the rule: saving touches one file inside Sonny's own store, and the routine's steps are
    /// scoped when it actually runs. Forwarding the caller's scope into the save's nested assessment
    /// reintroduced exactly what that classifier declined, one layer up — "teach Sonny a routine
    /// that opens example.com" inside a workspace escalated to tier 3 and prompted about a URL
    /// nothing in the plan would open.
    ///
    /// Asserted on the whole assessment against the real unscoped one, so a spurious escalation, a
    /// tier bump, or a roll-up appearing out of nowhere all fail.
    @Test
    func savingARoutineIsScopeNeutralAndAssessesIdenticallyUnderAnyScope() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = makeExecutor(root: root)
        let plan = saveRoutinePlan(
            name: "Teachable",
            steps: [
                AgentStep(
                    id: "leak",
                    operation: .openURL,
                    description: "Open an unrelated site.",
                    targetURL: "https://example.com/page"
                )
            ]
        )
        let scope = WorkspaceScope(
            workspace: StoredWorkspace(name: "Research", apps: [], urls: ["https://github.com"])
        )

        let unscoped = try executor.assessRisk(plan: plan, scope: .unscoped)
        #expect(unscoped.escalations.isEmpty)
        #expect(unscoped.effectiveTier == .tier2)

        var expected = unscoped
        // `save_routine` contributes no findings of its own, so a plan containing only one rolls up
        // the fold's bottom element. What must *not* appear is an escalation.
        expected.scopeVerdict = .unconstrained

        #expect(try executor.assessRisk(plan: plan, scope: .scoped(scope)) == expected)
    }

    /// The second F1 probe shape: the save sits beside a step that really is scope-relevant. The
    /// sibling must be scoped normally while the save contributes nothing scope-wise, and the
    /// roll-up must agree with the escalations shipped next to it — a `(tier3, .inScope)` pair, or
    /// an `.inScope` roll-up on a plan carrying an out-of-scope reason, is the contradiction this
    /// finding was about.
    @Test
    func aSaveRoutineBesideAnOutOfScopeStepEscalatesOnlyForTheSibling() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = makeExecutor(root: root)
        let plan = AgentPlan(
            summary: "Open a site, then teach a routine.",
            requiresConfirmation: true,
            steps: [
                AgentStep(id: "out", operation: .openURL, description: "Out of scope.", targetURL: "https://elsewhere.example/page"),
                AgentStep(
                    id: "save",
                    operation: .saveRoutine,
                    description: "Teach a routine.",
                    routineName: "Teachable",
                    routineSteps: [
                        AgentStep(
                            id: "leak",
                            operation: .openURL,
                            description: "Open an unrelated site.",
                            targetURL: "https://example.com/page"
                        )
                    ]
                )
            ]
        )
        let scope = WorkspaceScope(
            workspace: StoredWorkspace(name: "Research", apps: [], urls: ["https://github.com"])
        )

        let assessment = try executor.assessRisk(plan: plan, scope: .scoped(scope))

        // Exactly one reason, and it is the sibling's own URL — never the routine's stored step.
        #expect(assessment.escalations.map(\.reason) == [
            "elsewhere.example is not part of the Research workspace."
        ])
        // And the roll-up agrees with it rather than contradicting it.
        #expect(assessment.scopeVerdict == .outOfScope)
        #expect(assessment.effectiveTier == .tier3)
    }

    /// F5 — a blank app name in a stored record must not render a subjectless sentence. The two
    /// sides of the comparison disagree about it on purpose: `WorkspaceScope.init` records a blank
    /// entry as inert, while `verdict(for: .app(""))` answers `.outOfScope` whenever the bound
    /// workspace lists any app. Unfiltered, that produced " is not part of the Research workspace."
    /// in the approval panel.
    @Test
    func aBlankAppNameInAStoredWorkspaceRecordNeverBecomesASubjectlessEscalation() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaceStore = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        let bound = StoredWorkspace(name: "Research", apps: ["Safari"], urls: [])
        try workspaceStore.save(bound)
        // Written straight to the store: `WorkspaceStore.save` validates nothing about apps, which is
        // exactly why this is reachable once SONNY-40/41 add record-writing surfaces.
        try workspaceStore.save(StoredWorkspace(name: "Broken", apps: ["   ", "Slack"], urls: []))
        let executor = makeExecutor(root: root, workspaceStore: workspaceStore)

        let assessment = try executor.assessRisk(
            plan: openWorkspacePlan(name: "Broken"),
            scope: .scoped(WorkspaceScope(workspace: bound))
        )

        // Slack still escalates; the blank entry contributes nothing at all.
        #expect(assessment.escalations.map(\.reason) == [
            "Slack is not part of the Research workspace."
        ])
        #expect(assessment.escalations.allSatisfy { !$0.reason.hasPrefix(" ") })
    }

    private func saveRoutinePlan(name: String, steps: [AgentStep]) -> AgentPlan {
        AgentPlan(
            summary: "Save routine.",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "save-routine",
                    operation: .saveRoutine,
                    description: "Save routine.",
                    routineName: name,
                    routineSteps: steps
                )
            ]
        )
    }

    /// AC4 — `open_workspace`'s resources come from the **stored record**, not the step. The step
    /// carries no `workspaceApps`/`workspaceURLs` at all (those are `create_workspace`'s fields), so
    /// a test that populated the step would prove nothing.
    @Test
    func openingADifferentWorkspaceEscalatesOnThatRecordsOwnAppsAndURLs() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaceStore = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        try workspaceStore.save(
            StoredWorkspace(name: "Research", apps: ["Safari"], urls: ["https://github.com"])
        )
        try workspaceStore.save(
            StoredWorkspace(name: "Social", apps: ["Slack"], urls: ["https://example.com"])
        )
        let executor = makeExecutor(root: root, workspaceStore: workspaceStore)
        let scope = WorkspaceScope(
            workspace: StoredWorkspace(name: "Research", apps: ["Safari"], urls: ["https://github.com"])
        )

        let assessment = try executor.assessRisk(plan: openWorkspacePlan(name: "Social"), scope: .scoped(scope))

        #expect(assessment.effectiveTier == .tier3)
        #expect(assessment.escalations.map(\.reason) == [
            "Slack is not part of the Research workspace.",
            "example.com is not part of the Research workspace."
        ])
    }

    /// AC4's mirror, and one of the inverses that matters most: opening the workspace you are
    /// already inside is in scope by construction and must be completely silent.
    @Test
    func openingTheBoundWorkspaceItselfProducesNoScopeEscalationAtAll() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaceStore = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        let record = StoredWorkspace(name: "Research", apps: ["Safari"], urls: ["https://github.com"])
        try workspaceStore.save(record)
        let executor = makeExecutor(root: root, workspaceStore: workspaceStore)

        let assessment = try executor.assessRisk(
            plan: openWorkspacePlan(name: "Research"),
            scope: .scoped(WorkspaceScope(workspace: record))
        )

        #expect(assessment.escalations.isEmpty)
        #expect(assessment.effectiveTier == .tier1)
        #expect(assessment.scopeVerdict == .inScope)
    }

    /// A workspace name that resolves to nothing yields no resources rather than an escalation —
    /// the run fails at execution anyway, and a scope prompt about a workspace that does not exist
    /// would be a second, wrong explanation of the same problem.
    @Test
    func openingAWorkspaceThatDoesNotExistProducesNoScopeEscalation() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaceStore = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        let record = StoredWorkspace(name: "Research", apps: ["Safari"], urls: ["https://github.com"])
        try workspaceStore.save(record)
        let executor = makeExecutor(root: root, workspaceStore: workspaceStore)

        let assessment = try executor.assessRisk(
            plan: openWorkspacePlan(name: "Nonexistent"),
            scope: .scoped(WorkspaceScope(workspace: record))
        )

        #expect(assessment.escalations.isEmpty)
        #expect(assessment.scopeVerdict == .unconstrained)
    }

    /// AC5 and AC9 together, because they are different states that must both come out unchanged
    /// and only one of them is obvious. `.unscoped` is "no workspace bound". `.unconstrained` is a
    /// workspace that simply says nothing about this kind — which is the state **every** stored
    /// workspace is in for file locations today, so it is the most-exercised path this change will
    /// ever take in production.
    @Test
    func neitherUnscopedNorAnUnconstrainedKindChangesTheAssessment() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = makeExecutor(root: root)
        let plan = openURLPlan(url: "https://example.com/page")

        let unscoped = try executor.assessRisk(plan: plan, scope: .unscoped)
        #expect(unscoped.escalations.isEmpty)
        #expect(unscoped.scopeVerdict == nil)

        // Apps listed, no URLs — so the web-domain kind is unconfigured and this plan's only
        // resource is compared against nothing.
        let appsOnly = WorkspaceScope(
            workspace: StoredWorkspace(name: "Research", apps: ["Safari"], urls: [])
        )
        var expected = unscoped
        expected.scopeVerdict = .unconstrained

        #expect(try executor.assessRisk(plan: plan, scope: .scoped(appsOnly)) == expected)
    }

    /// AC6 — scope raises and never lowers. A tier-3 fixture that is entirely in scope stays tier 3;
    /// if a verdict could lower a tier, in-scope tier-3 work would run unattended with nobody
    /// present, because the unattended gate compares against a fixed `.approved(.tier2)`.
    @Test
    func anInScopeTierThreeFixtureKeepsItsTierBecauseScopeNeverLowersOne() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("draft.md")
        try write("existing", to: output)
        let executor = makeExecutor(root: root)
        let plan = localDraftPlan(output: output)
        // The whitelist has to be the test's own root, not the default one. `WorkspaceScope` walks
        // its file locations through `PathWhitelist` and records anything outside it as *inert* —
        // workspace scope narrows the global whitelist and never widens it — so a temp-dir path
        // under the default (~/Desktop, ~/Documents) whitelist would be dropped, leaving the file
        // kind `.unconstrained` and this test asserting nothing about in-scope behavior.
        let scope = WorkspaceScope(
            workspace: StoredWorkspace(
                name: "Research",
                apps: [],
                urls: [],
                fileLocations: [root.path]
            ),
            whitelist: PathWhitelist(roots: [root])
        )

        let assessment = try executor.assessRisk(plan: plan, scope: .scoped(scope))

        // Tier 3 from the pre-existing overwrite escalation, not from scope.
        #expect(assessment.effectiveTier == .tier3)
        #expect(assessment.scopeVerdict == .inScope)
        #expect(assessment.escalations.count == 1)
        #expect(assessment.escalations.first?.reason.contains("already exists") == true)
        #expect(assessment.escalations.allSatisfy { !$0.reason.contains("not part of") })
    }

    /// AC7 — **the SONNY-29 proof.** Two steps of the same operation, only the second out of scope.
    /// Every adapter picks its step with `.first(where:)`, so a scope check built on the
    /// pre-segmentation shape would compare the first URL and never see the second.
    @Test
    func aSecondStepOfTheSameOperationIsStillScopeCheckedNotShadowedByTheFirst() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = makeExecutor(root: root)
        let plan = AgentPlan(
            summary: "Open two sites.",
            requiresConfirmation: true,
            steps: [
                AgentStep(id: "a", operation: .openURL, description: "In scope.", targetURL: "https://github.com/sonny"),
                AgentStep(id: "b", operation: .openURL, description: "Out of scope.", targetURL: "https://example.com/page")
            ]
        )
        let scope = WorkspaceScope(
            workspace: StoredWorkspace(name: "Research", apps: [], urls: ["https://github.com"])
        )

        let assessment = try executor.assessRisk(plan: plan, scope: .scoped(scope))

        #expect(assessment.escalations.map(\.reason) == ["example.com is not part of the Research workspace."])
        #expect(assessment.effectiveTier == .tier3)
    }

    /// AC8 — an opaque step never escalates on scope grounds, because there is nothing to compare,
    /// and it must never let its plan roll up `.inScope`: Sonny cannot see what a Shortcut touches,
    /// so the plan it sits in can never earn a boundary it was never checked against.
    @Test
    func anOpaqueStepProducesNoEscalationAndBlocksAnInScopeRollUp() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = makeExecutor(root: root, shortcutCatalog: FakeShortcutCatalog(names: ["Trusted Shortcut"]))
        let plan = AgentPlan(
            summary: "Run a Shortcut.",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "shortcut",
                    operation: .invokeShortcut,
                    description: "Run the Shortcut.",
                    shortcutName: "Trusted Shortcut"
                )
            ]
        )
        let scope = WorkspaceScope(
            workspace: StoredWorkspace(name: "Research", apps: [], urls: ["https://github.com"])
        )

        let assessment = try executor.assessRisk(plan: plan, scope: .scoped(scope))

        #expect(assessment.escalations.allSatisfy { !$0.reason.contains("not part of") })
        #expect(assessment.scopeVerdict == .opaque)
        #expect(assessment.scopeVerdict != .inScope)
    }

    /// AC10 — one escalation per *distinct* resource, and no more than the cap. The single-host test
    /// above exercises neither rule: it has one resource and one escalation, so it would pass with
    /// no dedup and no cap at all.
    @Test
    func repeatedAndSurplusOutOfScopeResourcesAreDeduplicatedAndCapped() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = makeExecutor(root: root)
        let plan = AgentPlan(
            summary: "Open several sites.",
            requiresConfirmation: true,
            steps: [
                AgentStep(id: "a", operation: .openURL, description: "One.", targetURL: "https://one.example/page"),
                AgentStep(id: "b", operation: .openURL, description: "One again.", targetURL: "https://one.example/other"),
                AgentStep(id: "c", operation: .openURL, description: "Two.", targetURL: "https://two.example/page"),
                AgentStep(id: "d", operation: .openURL, description: "Three.", targetURL: "https://three.example/page"),
                AgentStep(id: "e", operation: .openURL, description: "Four.", targetURL: "https://four.example/page")
            ]
        )
        let scope = WorkspaceScope(
            workspace: StoredWorkspace(name: "Research", apps: [], urls: ["https://github.com"])
        )

        let assessment = try executor.assessRisk(plan: plan, scope: .scoped(scope))

        // Four distinct hosts across five steps, capped at three: the repeat collapses and the
        // surplus is dropped, in first-seen order.
        #expect(assessment.escalations.map(\.reason) == [
            "one.example is not part of the Research workspace.",
            "two.example is not part of the Research workspace.",
            "three.example is not part of the Research workspace."
        ])
        #expect(assessment.effectiveTier == .tier3)
    }

    /// SONNY-59 — **the shape the whole ticket is about, asserted end to end.**
    ///
    /// The plan names no folder at all: it comes from the Finder selection, which the resolve phase
    /// reads over Apple Events and pins onto both steps *before* this same `assessRisk` call
    /// classifies anything. The workspace lists the folder, so the pinned path is in scope and the
    /// only thing left to escalate on is the Finder control itself — the consequence the founder
    /// accepted on 2026-08-06 ("selection-driven zips/scans escalate in apps-configured workspaces
    /// that do not list Finder").
    ///
    /// `reader.callCount == 1` is what makes this a real proof rather than a restatement of the unit
    /// test: it shows the selection genuinely *was* read inside this call, so the step Finder is
    /// reported for is the pinned one. A classifier keyed on "`contextSource` **and** no `inputPath`"
    /// reports nothing here — the pin filled `inputPath` in two lines earlier — while still passing
    /// every classifier test written from an unresolved step. This test is the one that would go red.
    @Test
    func aSelectionDrivenZipEscalatesOnFinderEvenThoughTheResolvePhaseAlreadyPinnedTheFolder() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Client", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let reader = SequenceFinderContextReader(responses: [[folder]])
        let executor = makeExecutor(root: root, finderContextReader: reader)
        let scope = WorkspaceScope(
            workspace: StoredWorkspace(
                name: "Client Alpha",
                apps: ["Safari"],
                urls: [],
                fileLocations: [folder.path]
            ),
            whitelist: PathWhitelist(roots: [root])
        )

        let assessment = try executor.assessRisk(plan: selectionDrivenZipPlan(), scope: .scoped(scope))

        #expect(reader.callCount == 1)
        #expect(assessment.escalations.map(\.reason) == ["Finder is not part of the Client Alpha workspace."])
        #expect(assessment.escalations.first?.toTier == .tier3)
        #expect(assessment.effectiveTier == .tier3)
        #expect(assessment.scopeVerdict == .outOfScope)
    }

    /// The counter-pin: the same plan against a workspace that *does* list Finder. Without it, the
    /// test above passes for a classifier that escalates selection-driven zips for any reason at all
    /// — a bug that would make the feature unusable in exactly the workspaces it is meant for.
    @Test
    func aSelectionDrivenZipStaysInScopeInAWorkspaceThatListsFinder() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Client", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let executor = makeExecutor(
            root: root,
            finderContextReader: FakeFinderContextReader(selection: [folder])
        )
        let scope = WorkspaceScope(
            workspace: StoredWorkspace(
                name: "Client Alpha",
                apps: ["Safari", "Finder"],
                urls: [],
                fileLocations: [folder.path]
            ),
            whitelist: PathWhitelist(roots: [root])
        )

        let assessment = try executor.assessRisk(plan: selectionDrivenZipPlan(), scope: .scoped(scope))

        #expect(assessment.escalations.isEmpty)
        #expect(assessment.effectiveTier == .tier2)
        #expect(assessment.scopeVerdict == .inScope)
    }

    /// **SONNY-73 — Finder named on a run that never contacted Finder, pooled shape.**
    ///
    /// `pinningSelectedDirectoryInput` pools its inputs across the plan's matching steps and takes
    /// the two independently: the primary path is the first non-empty `inputPath` among them, the
    /// context source the first non-nil. So a scan carrying an explicit folder with no
    /// `contextSource`, beside a zip carrying `contextSource` with no folder, is satisfied from the
    /// scan's path — `selectedDirectoryPath` returns it before it ever looks at `contextSource` —
    /// and the Apple-Events reader is never called. The back-fill wrote the path onto the zip and
    /// left its `contextSource` in place, so the classifier reported Finder anyway. Both steps
    /// individually satisfy the planner's Finder-context rule, so per-step planner compliance does
    /// not exclude the shape.
    ///
    /// `reader.callCount == 0` and the absent escalation are the two halves of the same claim, and
    /// the test needs both: zero reads alone was already true before the fix, and it is precisely
    /// what made the escalation false.
    @Test
    func aPooledExplicitPathDoesNotReportFinderWhenFinderWasNeverContacted() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Client", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let decoy = root.appendingPathComponent("Decoy", isDirectory: true)
        try FileManager.default.createDirectory(at: decoy, withIntermediateDirectories: true)

        // A selection is available. Nothing may reach for it, and the folder it would hand back is
        // deliberately not the one the plan names, so a read that did happen would be visible in the
        // escalations as well as in the call count.
        let reader = SequenceFinderContextReader(responses: [[decoy]])
        let executor = makeExecutor(root: root, finderContextReader: reader)
        let scope = WorkspaceScope(
            workspace: StoredWorkspace(
                name: "Client Alpha",
                apps: ["Safari"],
                urls: [],
                fileLocations: [folder.path]
            ),
            whitelist: PathWhitelist(roots: [root])
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

        let assessment = try executor.assessRisk(plan: plan, scope: .scoped(scope))

        #expect(reader.callCount == 0)
        #expect(assessment.escalations.map(\.reason) == [])
        #expect(assessment.scopeVerdict == .inScope)
        #expect(assessment.effectiveTier == .tier2)
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

    private func openWorkspacePlan(name: String?) -> AgentPlan {
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

    private func runRoutinePlan(name: String?) -> AgentPlan {
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

    private func webComparisonPlan(urls: [URL], output: URL) -> AgentPlan {
        AgentPlan(
            summary: "Compare web sources as Markdown.",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "web-comparison",
                    operation: .webToMarkdown,
                    description: "Compare source URLs.",
                    outputPath: output.path,
                    sourceURLs: urls.map(\.absoluteString)
                )
            ]
        )
    }

    private func webSearchPlan(query: String, output: URL, count: Int? = nil) -> AgentPlan {
        AgentPlan(
            summary: "Research a topic as Markdown.",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "web-search",
                    operation: .webToMarkdown,
                    description: "Research topic.",
                    outputPath: output.path,
                    count: count,
                    searchQuery: query
                )
            ]
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

    private func openAppSearchURLPlan(target: String, query: String) -> AgentPlan {
        AgentPlan(
            summary: "Open search.",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "search-url",
                    operation: .openAppSearchURL,
                    description: "Open search URL.",
                    appName: target,
                    searchQuery: query
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

    private func localDraftPlan(output: URL) -> AgentPlan {
        AgentPlan(
            summary: "Create local draft.",
            requiresConfirmation: true,
            steps: [localDraftStep(output: output)]
        )
    }

    private func localDraftStep(output: URL) -> AgentStep {
        AgentStep(
            id: "draft",
            operation: .createLocalDraft,
            description: "Create draft.",
            outputPath: output.path,
            draftTitle: "Follow Up",
            draftContent: "Draft body."
        )
    }

    private func mediaPlan(
        provider: MediaProvider?,
        title: String = "Jimmy Cooks",
        artist: String = "Drake"
    ) -> AgentPlan {
        AgentPlan(
            summary: "Open a song result.",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "play-media",
                    operation: .playMedia,
                    description: "Open the requested song result.",
                    targetURL: nil,
                    mediaProvider: provider,
                    mediaTitle: title,
                    mediaArtist: artist
                )
            ]
        )
    }

    private func revealPlan(output: URL) -> AgentPlan {
        AgentPlan(
            summary: "Reveal a file.",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "reveal",
                    operation: .revealInFinder,
                    description: "Reveal generated output",
                    outputPath: output.path
                )
            ]
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
                    description: "Show readiness"
                )
            ]
        )
    }

    private func clarifyPlan() -> AgentPlan {
        AgentPlan(
            summary: "Need clarification.",
            requiresConfirmation: false,
            steps: [
                AgentStep(
                    id: "clarify",
                    operation: .clarify,
                    description: "Ask which folder to scan.",
                    question: "Which folder should I scan?"
                )
            ]
        )
    }

    private func write(_ string: String, to url: URL) throws {
        try string.data(using: .utf8)?.write(to: url)
    }
}

private struct RecordingZipArchiver: ZipArchiving {
    func createArchive(sourceFolder: URL, files: [URL], outputURL: URL) async throws {
        try "fake zip".data(using: .utf8)?.write(to: outputURL)
    }
}

/// Refuses an occupied destination, like both shipped converters do — `MicrosoftWordDocumentConverter`
/// via `moveItem` and `MockDocumentConverter` via its own guard. Without this the double was the one
/// converter in the process that would silently clobber, so the fidelity argument the branch makes for
/// the shipped mock did not extend to the double the docx tests actually run against, and a
/// reintroduced shared destination would have been caught only by an output assertion rather than at
/// the write. (PR #41 review, SONNY-28 "one note, not a finding".)
private struct FakeDocumentConverter: DocumentConverting {
    var isAvailable: Bool { true }
    var modeName: String { "Fake converter" }
    var usesMockNaming: Bool { false }

    func convert(_ records: [DocxRecord], log: @escaping (String) -> Void) async throws -> [DocxRecord] {
        var converted: [DocxRecord] = []
        for record in records where !record.skippedBecausePDFExists {
            log("Converting \(record.sourceURL.lastPathComponent)")
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

@MainActor
private final class StaticSpotifyPlaybackProvider: SpotifyPlaybackProviding {
    var previewResult: MediaPlaybackRoutePreview
    var playResult: SpotifyPlaybackResult
    private(set) var playRequests: [MediaPlaybackRequest] = []

    init(previewResult: MediaPlaybackRoutePreview, playResult: SpotifyPlaybackResult) {
        self.previewResult = previewResult
        self.playResult = playResult
    }

    func preview(_ request: MediaPlaybackRequest) -> MediaPlaybackRoutePreview {
        previewResult
    }

    func play(_ request: MediaPlaybackRequest) async -> SpotifyPlaybackResult {
        playRequests.append(request)
        return playResult
    }
}

@MainActor
private final class StaticAppleMusicPlaybackProvider: AppleMusicPlaybackProviding {
    var previewResult: MediaPlaybackRoutePreview
    var playResult: AppleMusicPlaybackResult
    private(set) var playRequests: [MediaPlaybackRequest] = []

    init(previewResult: MediaPlaybackRoutePreview, playResult: AppleMusicPlaybackResult) {
        self.previewResult = previewResult
        self.playResult = playResult
    }

    func preview(_ request: MediaPlaybackRequest) -> MediaPlaybackRoutePreview {
        previewResult
    }

    func play(_ request: MediaPlaybackRequest) async -> AppleMusicPlaybackResult {
        playRequests.append(request)
        return playResult
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

/// Advances two seconds per call so every `Timestamp.fileSafe` read mints a different name —
/// any code path that re-derives a "default" output name after the fact becomes visible.
private final class TickingClock {
    private var current = Date(timeIntervalSince1970: 1_783_526_400)

    func next() -> Date {
        defer { current = current.addingTimeInterval(2) }
        return current
    }
}

/// Returns a different Finder selection on each call, so a test can prove the selection is
/// resolved exactly once and pinned rather than re-read live at every phase.
private final class SequenceFinderContextReader: FinderContextReading, @unchecked Sendable {
    private let lock = NSLock()
    private let responses: [[URL]]
    private var calls = 0

    init(responses: [[URL]]) {
        self.responses = responses
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func selectedItems() throws -> [URL] {
        lock.lock()
        defer {
            calls += 1
            lock.unlock()
        }
        return responses[min(calls, responses.count - 1)]
    }
}

@MainActor
private final class CapturingZipArchiver: ZipArchiving {
    private(set) var capturedFiles: [URL] = []
    private(set) var capturedOutputURL: URL?

    func createArchive(sourceFolder: URL, files: [URL], outputURL: URL) async throws {
        capturedFiles = files
        capturedOutputURL = outputURL
        try "fake zip".data(using: .utf8)?.write(to: outputURL)
    }
}

private struct StaticHackerNewsFetcher: HackerNewsFetching {
    func topHeadlines(limit: Int) async throws -> [HackerNewsHeadline] {
        (1...limit).map { index in
            HackerNewsHeadline(title: "Fixture headline \(index)", url: "https://example.com/\(index)")
        }
    }
}

private func webPageLoader(pages: [String: ReadableWebPage]) -> PublicWebPageLoader {
    PublicWebPageLoader(
        fetcher: StaticWebPageFetcher(pages: pages),
        robotsChecker: AllowingRobotsChecker(),
        extractor: StaticReadableWebExtractor(pages: pages)
    )
}

private func readablePage(
    url: URL,
    retrievedAt: Date = Date(timeIntervalSince1970: 1_783_526_400),
    title: String
) -> ReadableWebPage {
    ReadableWebPage(
        sourceURL: url,
        retrievedAt: retrievedAt,
        title: title,
        author: "Fixture Author",
        publishedDate: "2026-07-08",
        headings: [title],
        links: [],
        images: [],
        citations: ["Fixture citation"],
        readableText: "Readable content for \(title)."
    )
}

@MainActor
private struct StaticWebPageFetcher: WebPageFetching {
    var pages: [String: ReadableWebPage]

    func fetch(_ url: URL) async throws -> FetchedWebPage {
        guard let page = pages[url.absoluteString] else {
            throw WebResearchError.noReadableContent(url.absoluteString)
        }
        return FetchedWebPage(
            requestedURL: url,
            html: page.readableText,
            retrievedAt: page.retrievedAt
        )
    }
}

@MainActor
private struct AllowingRobotsChecker: RobotsTXTChecking {
    func canFetch(_ url: URL, userAgent: String) async throws -> Bool {
        true
    }
}

private struct StaticReadableWebExtractor: ReadableWebExtracting {
    var pages: [String: ReadableWebPage]

    func extract(html: String, sourceURL: URL, retrievedAt: Date) throws -> ReadableWebPage {
        guard let page = pages[sourceURL.absoluteString] else {
            throw WebResearchError.noReadableContent(sourceURL.absoluteString)
        }
        return page
    }
}

@MainActor
private final class StaticWebResearchSynthesizer: WebResearchSynthesizing {
    var note: WebResearchNote
    private(set) var prompts: [WebResearchSynthesisPrompt] = []

    init(note: WebResearchNote) {
        self.note = note
    }

    func synthesize(prompt: WebResearchSynthesisPrompt) async throws -> WebResearchNote {
        prompts.append(prompt)
        return note
    }
}

@MainActor
private final class StaticWebSearchProvider: WebSearchProviding {
    var results: [WebSearchResult]
    private(set) var queries: [String] = []
    private(set) var limits: [Int] = []

    init(results: [WebSearchResult]) {
        self.results = results
    }

    func search(query: String, limit: Int) async throws -> [WebSearchResult] {
        queries.append(query)
        limits.append(limit)
        return Array(results.prefix(max(limit, 0)))
    }
}
