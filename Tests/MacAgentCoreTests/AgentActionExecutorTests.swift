import Foundation
import Testing
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

        let assessment = try executor.assessRisk(plan: plan)

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

        let assessment = try executor.assessRisk(plan: openWorkspacePlan(name: "Writing"))

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

        let assessment = try executor.assessRisk(plan: openWorkspacePlan(name: "Research"))

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

        let assessment = try executor.assessRisk(plan: plan)

        #expect(assessment.effectiveTier == .tier2)
        #expect(assessment.approvalRequirement().requiresUserApproval)
        #expect(assessment.approvalCopy?.dataLeavesDevice == false)
    }

    // MARK: - SONNY-29: chain-segmented risk assessment

    /// SONNY-29's concrete failure. `.createLocalDraft` is in `shouldChainWhenRepeated`'s true
    /// list, so two draft steps become a `.chain` and `executeChain` writes both — but `assessRisk`
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

        let assessment = try executor.assessRisk(plan: draftChainPlan(first: first, second: second))

        #expect(assessment.defaultTier == .tier2)
        #expect(assessment.effectiveTier == .tier3)
        #expect(assessment.approvalRequirement() == .explicitApproval)
        #expect(assessment.escalations == [
            CapabilityRiskEscalation(
                fromTier: .tier2,
                toTier: .tier3,
                reason: "Draft output already exists at \(second.path)."
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
            )
        )

        #expect(assessment.effectiveTier == .tier2)
        #expect(assessment.escalations.isEmpty)
        #expect(assessment.approvalRequirement() == .lightweightConfirmation)
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

        let assessment = try executor.assessRisk(plan: draftChainPlan(first: shared, second: shared))

        #expect(assessment.effectiveTier == .tier3)
        #expect(assessment.escalations.count == 1)
        #expect(assessment.escalations.first?.reason == "Draft output already exists at \(shared.path).")
    }

    /// The same defect in the zip capability. `[scan, zip]` on its own is not a chain — repeated
    /// `.largestFiles` steps do not chain, so only one zip is executed *and* assessed, which is
    /// consistent. It takes a chain (here, an `.openApp` step between the two pairs) for
    /// `executeChain` to really create both archives; before segmenting, only the first pair's
    /// output was ever checked for a collision.
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

        let assessment = try executor.assessRisk(plan: plan)

        #expect(assessment.effectiveTier == .tier3)
        #expect(assessment.escalations == [
            CapabilityRiskEscalation(
                fromTier: .tier2,
                toTier: .tier3,
                reason: "Zip output already exists at \(secondZip.path)."
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
            )
        )

        #expect(assessment.effectiveTier == .tier3)
        #expect(assessment.escalations == [
            CapabilityRiskEscalation(
                fromTier: .tier2,
                toTier: .tier3,
                reason: "Markdown output already exists at \(webResearchOutput.path)."
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

        let assessment = try executor.assessRisk(plan: plan)

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

        let assessment = try executor.assessRisk(plan: plan)

        #expect(assessment.effectiveTier == .tier3)
        #expect(assessment.escalations == [
            CapabilityRiskEscalation(
                fromTier: .tier2,
                toTier: .tier3,
                reason: "Zip output already exists at \(zipOutput.path)."
            ),
            CapabilityRiskEscalation(
                fromTier: .tier2,
                toTier: .tier3,
                reason: "Draft output already exists at \(draftOutput.path)."
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

        let assessment = try executor.assessRisk(plan: plan)

        #expect(assessment.defaultTier == .tier2)
        #expect(assessment.effectiveTier == .tier2)
        #expect(assessment.approvalRequirement() == .lightweightConfirmation)
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

        let assessment = try executor.assessRisk(plan: plan)

        #expect(assessment.defaultTier == .tier2)
        #expect(assessment.effectiveTier == .tier3)
        #expect(assessment.approvalRequirement() == .explicitApproval)
        #expect(assessment.escalations == [
            CapabilityRiskEscalation(
                fromTier: .tier2,
                toTier: .tier3,
                reason: "Draft output already exists at \(existingDraft.path)."
            )
        ])
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

        #expect(browserOpener.openedBrowsers == [MacApp(displayName: "Chrome", bundleIdentifier: "com.google.Chrome", aliases: ["Google Chrome"])])
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

        _ = try await runner.execute(prepared, approvalDecision: .approved(.tier2))

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
        try workspaceStore.save(StoredWorkspace(name: "Broken", apps: ["NotAnAllowlistedApp"], urls: []))
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

        // A workspace that exists but holds an app outside the allowlist is a real failure,
        // not a "did you mean" — the user did name something real.
        #expect(throws: MacAppCatalogError.self) {
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
                    description: "Open an app outside the allowlist.",
                    appName: "DefinitelyNotAllowlisted"
                ),
                AgentStep(
                    id: "open-workspace",
                    operation: .openWorkspace,
                    description: "Open workspace.",
                    workspaceName: "writing"
                )
            ]
        )
        #expect(throws: MacAppCatalogError.self) {
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

    @Test
    func openAppPreviewUsesAllowlist() throws {
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

    @Test
    func openAppRejectsUnknownApp() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = makeExecutor(root: root)

        #expect(throws: MacAppCatalogError.appNotAllowed("Untrusted App")) {
            try executor.preview(plan: openAppPlan(appName: "Untrusted App"))
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

    private func makeExecutor(
        root: URL,
        zipArchiver: ZipArchiving = RecordingZipArchiver(),
        documentConverter: DocumentConverting = FakeDocumentConverter(),
        browserOpener: BrowserOpening = NoopBrowserOpener(),
        hackerNewsFetcher: HackerNewsFetching = StaticHackerNewsFetcher(),
        appCatalog: MacAppCatalog = .default,
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
        hotKeyReady: @escaping () -> Bool = { true }
    ) -> AgentActionExecutor {
        AgentActionExecutor(
            whitelist: PathWhitelist(roots: [root]),
            zipArchiver: zipArchiver,
            documentConverter: documentConverter,
            browserOpener: browserOpener,
            hackerNewsFetcher: hackerNewsFetcher,
            appCatalog: appCatalog,
            appSearchURLCatalog: appSearchURLCatalog,
            appOpener: appOpener,
            fileOpener: fileOpener,
            mediaOpener: mediaOpener,
            spotifyPlaybackProvider: spotifyPlaybackProvider,
            appleMusicPlaybackProvider: appleMusicPlaybackProvider,
            finderContextReader: finderContextReader,
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

    /// Two `.createLocalDraft` steps with explicit, independent destinations — the plan
    /// "draft a note at a.md and another at b.md" produces. Both steps really execute
    /// (`shouldChainWhenRepeated` chains repeated drafts), so both have to be assessed.
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

private struct FakeDocumentConverter: DocumentConverting {
    var isAvailable: Bool { true }
    var modeName: String { "Fake converter" }
    var usesMockNaming: Bool { false }

    func convert(_ records: [DocxRecord], log: @escaping (String) -> Void) async throws -> [DocxRecord] {
        var converted: [DocxRecord] = []
        for record in records where !record.skippedBecausePDFExists {
            log("Converting \(record.sourceURL.lastPathComponent)")
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
