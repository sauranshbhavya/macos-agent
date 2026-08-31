import Foundation
import MacAgentTestSupport
import Testing
@testable import MacAgentCore

/// A job over many items that remembers its place (row 13, SONNY-235).
///
/// Every assertion about running a job goes through the real `prepare` and the real `execute`, never
/// through the resolver or the chain walk called directly: what is being pinned is that a plan
/// declaring a job is *dispatched* as one unit per item by the executor's ordinary segmentation, and
/// a test that called `PlanItemJobResolver.expanding` and inspected its output would pin nothing
/// about that.
@Suite
@MainActor
struct ItemJobTests {
    // MARK: - How a plan expresses "for each of these"

    /// The carrying decision, observed rather than described: a plan declaring a job arrives at the
    /// executor as one template step and leaves `prepare` as one copy per item, each carrying its own
    /// item and its own item index.
    @Test
    func aJobOverAFoldersFilesIsPreparedAsOneStepGroupPerItem() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("one", to: root.appendingPathComponent("b.pdf"))
        try write("two", to: root.appendingPathComponent("a.pdf"))
        try write("three", to: root.appendingPathComponent("notes.txt"))
        try write("four", to: root.appendingPathComponent(".hidden.pdf"))

        let executor = makeExecutor(root: root)
        let prepared = try executor.prepare(plan: shortcutJob(over: root))

        // Sorted by path, so the order is stable across runs — which is what lets a resumed job line
        // its stored progress up with a freshly resolved list.
        #expect(prepared.plan.itemJob?.items == [
            root.appendingPathComponent("a.pdf").path,
            root.appendingPathComponent("b.pdf").path
        ])
        #expect(prepared.plan.steps.map(\.id) == ["run#1", "run#2"])
        #expect(prepared.plan.steps.map(\.itemIndex) == [0, 1])
        #expect(prepared.plan.steps.map(\.shortcutInput) == [
            root.appendingPathComponent("a.pdf").path,
            root.appendingPathComponent("b.pdf").path
        ])
        // The `.txt` and the dotfile are the controls: without them "two items" would be equally
        // true of a resolver that returned everything and one that returned the right things.
        #expect(prepared.plan.steps.count == 2)
    }

    /// A job over folders, where each item is handed to a capability that scans it — the second of
    /// the two item kinds, and the one that proves the item field reaches a multi-step unit.
    @Test
    func aJobOverFoldersPutsEachFolderIntoEveryStepOfItsUnit() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("alpha")
        let second = root.appendingPathComponent("beta")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try write("doc", to: first.appendingPathComponent("report.docx"))
        try write("doc", to: second.appendingPathComponent("memo.docx"))

        let executor = makeExecutor(root: root)
        let prepared = try executor.prepare(plan: docxJob(over: root))

        #expect(prepared.plan.steps.map(\.id) == ["scan#1", "convert#1", "scan#2", "convert#2"])
        #expect(prepared.plan.steps.map(\.itemIndex) == [0, 0, 1, 1])
        #expect(prepared.plan.steps.map(\.inputPath) == [first.path, first.path, second.path, second.path])
    }

    /// **Resolved once and pinned.** A second `prepare` of a prepared plan re-reads nothing, so the
    /// list the user approved is the list that runs — the resume path re-prepares the stored plan,
    /// and a folder that gained a file in between must not join the job.
    @Test
    func preparingAJobASecondTimeDoesNotResolveItAgain() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("one", to: root.appendingPathComponent("a.pdf"))

        let executor = makeExecutor(root: root)
        let first = try executor.prepare(plan: shortcutJob(over: root))
        #expect(first.plan.itemJob?.items.count == 1)

        try write("two", to: root.appendingPathComponent("b.pdf"))
        let second = try executor.prepare(plan: first.plan)

        #expect(second.plan.itemJob?.items == first.plan.itemJob?.items)
        #expect(second.plan.steps.map(\.id) == ["run#1"])
        // The control: the folder really did gain a file, so an executor that re-resolved would have
        // found two. Preparing the *original* plan again does find two.
        let reResolved = try executor.prepare(plan: shortcutJob(over: root))
        #expect(reResolved.plan.itemJob?.items.count == 2)
    }

    /// A job that never went through `prepare` is refused at both other doors rather than quietly
    /// resolving a second list there.
    @Test
    func anUnpreparedJobIsRefusedByAssessmentAndByExecution() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("one", to: root.appendingPathComponent("a.pdf"))
        let executor = makeExecutor(root: root)

        #expect(throws: PlanItemJobError.notPrepared) {
            _ = try executor.assessRisk(plan: shortcutJob(over: root), scope: .unscoped)
        }
        await #expect(throws: PlanItemJobError.notPrepared) {
            _ = try await executor.execute(plan: shortcutJob(over: root)) { _, _ in }
        }

        // The control: the *prepared* plan passes both doors. Without it, "throws" would be equally
        // true of a job that could never run at all.
        let prepared = try executor.prepare(plan: shortcutJob(over: root))
        _ = try executor.assessRisk(plan: prepared.plan, scope: .unscoped)
        _ = try await executor.execute(plan: prepared.plan) { _, _ in }
    }

    /// A plan that is not a job is untouched by every one of the rules above.
    @Test
    func aPlanThatIsNotAJobIsUnchangedByPreparation() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = makeExecutor(root: root)

        let plan = AgentPlan(
            summary: "Work out a number.",
            requiresConfirmation: false,
            steps: [AgentStep(id: "calc", operation: .calculateUtility, description: "2 + 2", searchQuery: "2 + 2")]
        )
        let prepared = try executor.prepare(plan: plan)

        #expect(prepared.plan.itemJob == nil)
        #expect(prepared.plan.steps.map(\.id) == ["calc"])
        #expect(prepared.plan.steps.map(\.itemIndex) == [nil])
    }

    // MARK: - One approval covers the job

    /// The founder's decision of 2026-08-31 — one approval for the whole job — implemented by the
    /// shape rather than by a change to the rule. Forty items assess as the same tier one does,
    /// because the expanded plan is one plan and `assessRisk` has never counted steps.
    @Test
    func aJobOfManyItemsIsAssessedOnceAndAtTheSameTierAsOne() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("one", to: root.appendingPathComponent("a.pdf"))
        let executor = makeExecutor(root: root)
        let single = try executor.prepare(plan: shortcutJob(over: root))
        let singleAssessment = try executor.assessRisk(plan: single.plan, scope: .unscoped)

        for name in ["b", "c", "d", "e"] {
            try write(name, to: root.appendingPathComponent("\(name).pdf"))
        }
        let many = try executor.prepare(plan: shortcutJob(over: root))
        let manyAssessment = try executor.assessRisk(plan: many.plan, scope: .unscoped)

        #expect(many.plan.itemJob?.items.count == 5)
        #expect(manyAssessment.effectiveTier == singleAssessment.effectiveTier)
        #expect(manyAssessment.escalations.map(\.reason) == singleAssessment.escalations.map(\.reason))
    }

    // MARK: - What happens when one item fails

    /// **Skip and continue**, on the real dispatch path: the item after the failure runs, and the
    /// failure is reported as its own item rather than as the whole job.
    @Test
    func oneItemFailingDoesNotStopTheItemsAfterIt() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["a", "b", "c"] {
            try write(name, to: root.appendingPathComponent("\(name).pdf"))
        }
        let invoker = RecordingShortcutInvoker(failingOnInputContaining: "b.pdf")
        let executor = makeExecutor(root: root, shortcutInvoker: invoker)

        let prepared = try executor.prepare(plan: shortcutJob(over: root))
        let result = try await executor.execute(plan: prepared.plan) { _, _ in }

        // Every item was attempted, the failure included.
        #expect(invoker.inputs.map { ($0 as NSString).lastPathComponent } == ["a.pdf", "b.pdf", "c.pdf"])
        #expect(result.itemJobFailures.map(\.itemIndex) == [1])
        #expect(result.itemJobFailures.first?.item == root.appendingPathComponent("b.pdf").path)
        #expect(result.summary.contains("2 of 3 files"))
        #expect(result.summary.contains("b.pdf"))
    }

    /// The control for the assertion above, and the one that makes "two failures were recorded" mean
    /// something: the same job with nothing failing records none, and says so.
    @Test
    func aJobInWhichNothingFailsRecordsNoFailuresAndSaysSo() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["a", "b", "c"] {
            try write(name, to: root.appendingPathComponent("\(name).pdf"))
        }
        let invoker = RecordingShortcutInvoker()
        let executor = makeExecutor(root: root, shortcutInvoker: invoker)

        let prepared = try executor.prepare(plan: shortcutJob(over: root))
        let result = try await executor.execute(plan: prepared.plan) { _, _ in }

        #expect(invoker.inputs.count == 3)
        #expect(result.itemJobFailures.isEmpty)
        #expect(result.summary == "Worked through all 3 files.")
    }

    /// **A stop is not a failed item.** Swallowing a cancellation the way an item failure is
    /// swallowed would turn the stop control into a button that works through the rest of the job
    /// and reports every remaining item as a failure.
    @Test
    func stoppingAJobEndsItRatherThanFailingTheRemainingItems() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["a", "b", "c"] {
            try write(name, to: root.appendingPathComponent("\(name).pdf"))
        }
        let invoker = RecordingShortcutInvoker(cancellingOnInputContaining: "b.pdf")
        let executor = makeExecutor(root: root, shortcutInvoker: invoker)

        let prepared = try executor.prepare(plan: shortcutJob(over: root))
        await #expect(throws: CancellationError.self) {
            _ = try await executor.execute(plan: prepared.plan) { _, _ in }
        }

        // The third item was never started. The control is the test above, where the same invoker
        // shape failing rather than cancelling did reach it.
        #expect(invoker.inputs.map { ($0 as NSString).lastPathComponent } == ["a.pdf", "b.pdf"])
    }

    /// A plan that is not a job still stops on the first error, exactly as it did before this
    /// branch: skip-and-continue is a job's rule and nothing else's.
    @Test
    func anOrdinaryChainStillStopsAtItsFirstFailure() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("one", to: root.appendingPathComponent("a.pdf"))
        let invoker = RecordingShortcutInvoker(failingOnInputContaining: "a.pdf")
        let opener = RecordingBrowserOpener()
        let executor = makeExecutor(root: root, shortcutInvoker: invoker, browserOpener: opener)

        let plan = AgentPlan(
            summary: "Run the Shortcut, then open a page.",
            requiresConfirmation: false,
            steps: [
                AgentStep(
                    id: "run",
                    operation: .invokeShortcut,
                    description: "Run it.",
                    shortcutName: "Summarise",
                    shortcutInput: root.appendingPathComponent("a.pdf").path
                ),
                AgentStep(
                    id: "url",
                    operation: .openURL,
                    description: "Open the page.",
                    targetURL: "https://example.com/page"
                )
            ]
        )
        await #expect(throws: (any Error).self) {
            _ = try await executor.execute(plan: plan) { _, _ in }
        }
        #expect(opener.opened.isEmpty)
    }

    // MARK: - Items that cannot even be prepared

    /// **The defect this section exists for, in the shape it was found in.** `prepare` previews every
    /// unit before anything is approved, and a preview reaches into the item — a document conversion
    /// refuses a folder with nothing to convert. So three folders, one of them without a Word
    /// document, used to die at `prepare` with a message about that one folder: no approval prompt,
    /// no partial run, the other two untouched. The item is dropped and named now, and the other two
    /// are previewed, approved and run.
    @Test
    func aFolderThatCannotBePreviewedIsDroppedRatherThanKillingTheWholeJob() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["alpha", "beta", "gamma"] {
            let folder = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // `beta` holds no Word document at all, which is what its preview refuses.
            if name != "beta" {
                try write("doc", to: folder.appendingPathComponent("report.docx"))
            }
        }
        let executor = makeExecutor(root: root)

        let prepared = try executor.prepare(plan: docxJob(over: root))

        // The item list is still the whole three — the job is over three folders, one of which
        // cannot be done — and only its *steps* are gone.
        #expect(prepared.plan.itemJob?.items.count == 3)
        #expect(prepared.plan.itemJob?.unavailableItems.map(\.itemIndex) == [1])
        #expect(prepared.plan.steps.map(\.itemIndex) == [0, 0, 2, 2])
        let named = try #require(prepared.plan.itemJob?.unavailableItems.first)
        #expect(named.item == root.appendingPathComponent("beta").path)
        #expect(named.message.contains("beta"))

        // And it runs: the two good folders are converted and the third is reported, not silently
        // missing.
        let result = try await executor.execute(plan: prepared.plan) { _, _ in }
        #expect(result.itemJobFailures.map(\.itemIndex) == [1])
        #expect(result.summary.contains("2 of 3 folders"))
        #expect(result.summary.contains("beta"))
    }

    /// The control for the test above, and the one that makes "one was dropped" mean something: the
    /// same job with a document in every folder drops nothing and runs all three.
    @Test
    func aJobWhoseEveryItemPreviewsKeepsEveryItem() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["alpha", "beta", "gamma"] {
            let folder = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try write("doc", to: folder.appendingPathComponent("report.docx"))
        }
        let executor = makeExecutor(root: root)

        let prepared = try executor.prepare(plan: docxJob(over: root))

        #expect(prepared.plan.itemJob?.unavailableItems.isEmpty == true)
        #expect(prepared.plan.steps.map(\.itemIndex) == [0, 0, 1, 1, 2, 2])
        let result = try await executor.execute(plan: prepared.plan) { _, _ in }
        #expect(result.itemJobFailures.isEmpty)
        #expect(result.summary == "Worked through all 3 folders.")
    }

    /// **A job in which nothing can be done says so at the door**, with the message that explains the
    /// folder the user pointed at, rather than asking for approval to do nothing.
    @Test
    func aJobWhoseEveryItemIsUnavailableIsRefusedWithTheFirstItemsOwnReason() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["alpha", "beta"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(name),
                withIntermediateDirectories: true
            )
        }
        let executor = makeExecutor(root: root)

        do {
            _ = try executor.prepare(plan: docxJob(over: root))
            Issue.record("a job in which no item can be prepared should have been refused")
        } catch let error as PlanItemJobError {
            guard case .everyItemUnavailable(let detail) = error else {
                Issue.record("expected everyItemUnavailable, got \(error)")
                return
            }
            #expect(detail.contains("alpha"))
            #expect(detail.contains(".docx"))
        }
    }

    /// A job that is down to one item still takes the chain walk, so it keeps the job's own summary
    /// and its own arithmetic instead of falling through to a single adapter call that knows nothing
    /// about items.
    @Test
    func aJobWithOneItemLeftIsStillDispatchedAsAJob() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("one", to: root.appendingPathComponent("a.pdf"))
        let invoker = RecordingShortcutInvoker()
        let executor = makeExecutor(root: root, shortcutInvoker: invoker)

        let prepared = try executor.prepare(plan: shortcutJob(over: root))
        #expect(prepared.plan.steps.count == 1)
        let result = try await executor.execute(plan: prepared.plan) { _, _ in }

        #expect(invoker.inputs.count == 1)
        // The job's sentence, not `InvokeShortcutCapabilityAdapter`'s "Ran Shortcut Summarise."
        #expect(result.summary == "Worked through all 1 files.")
    }

    /// **The rest of a failed item is skipped, not attempted** — the second half of skip-and-continue,
    /// and the one a one-step template cannot see. A mutant removing the skip survived the suite at
    /// `369cbc3` (R3); this is the test it named.
    ///
    /// A later unit of an item was written to act on what its earlier ones produced, so running it
    /// against nothing manufactures a second, less honest failure for the same item.
    @Test
    func theRestOfAFailedItemIsSkippedRatherThanAttempted() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["a", "b", "c"] {
            try write(name, to: root.appendingPathComponent("\(name).pdf"))
        }
        let invoker = RecordingShortcutInvoker(failingOnInputContaining: "b.pdf")
        let opener = RecordingBrowserOpener()
        let executor = makeExecutor(root: root, shortcutInvoker: invoker, browserOpener: opener)

        // Two workflows per item, so each item is two units and the second one is skippable.
        let plan = AgentPlan(
            summary: "Summarise each of these, then open the notes page.",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "run",
                    operation: .invokeShortcut,
                    description: "Run the Shortcut on this file.",
                    shortcutName: "Summarise"
                ),
                AgentStep(
                    id: "url",
                    operation: .openURL,
                    description: "Open the page.",
                    targetURL: "https://example.com/page"
                )
            ],
            itemJob: PlanItemJob(
                source: .folder,
                folderPath: root.path,
                itemKind: .files,
                fileExtensions: ["pdf"],
                itemField: .shortcutInput
            )
        )
        let prepared = try executor.prepare(plan: plan)
        let result = try await executor.execute(plan: prepared.plan) { _, _ in }

        // Three items were tried; the middle one's second unit was not.
        #expect(invoker.inputs.count == 3)
        #expect(opener.opened.count == 2)
        #expect(result.itemJobFailures.map(\.itemIndex) == [1])
        // The control: with nothing failing, all three items open their page.
        let cleanOpener = RecordingBrowserOpener()
        let cleanExecutor = makeExecutor(root: root, browserOpener: cleanOpener)
        let cleanPrepared = try cleanExecutor.prepare(plan: plan)
        _ = try await cleanExecutor.execute(plan: cleanPrepared.plan) { _, _ in }
        #expect(cleanOpener.opened.count == 3)
    }

    /// **The chain's carried artifact does not cross an item boundary.** A mutant removing the reset
    /// survived the suite at `369cbc3` (R4), and the reachable case took some finding, so it is
    /// written down: an item whose work *succeeds while writing nothing*, followed in the same item
    /// by a step that opens "whatever the previous unit produced".
    ///
    /// A folder whose documents have all been converted already is exactly that — every record is
    /// skipped, the unit succeeds, and its previews name no write. Without the reset, that item's
    /// bare open reaches back and opens the **previous** item's PDF, and the run reports success.
    @Test
    func aJobsCarriedArtifactDoesNotLeakFromOneItemIntoTheNext() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let alpha = root.appendingPathComponent("alpha")
        let beta = root.appendingPathComponent("beta")
        try FileManager.default.createDirectory(at: alpha, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: beta, withIntermediateDirectories: true)
        try write("doc", to: alpha.appendingPathComponent("report.docx"))
        try write("doc", to: beta.appendingPathComponent("memo.docx"))
        // beta's conversion is already done, so its unit succeeds and writes nothing.
        try write("pdf", to: beta.appendingPathComponent("memo.pdf"))

        let fileOpener = RecordingFileOpener()
        let executor = makeExecutor(root: root, fileOpener: fileOpener)
        let plan = AgentPlan(
            summary: "Convert the documents in each of these folders and open the result.",
            requiresConfirmation: true,
            steps: [
                AgentStep(id: "scan", operation: .scanDocx, description: "Find the documents."),
                AgentStep(id: "convert", operation: .convertDocxToPDF, description: "Convert them."),
                AgentStep(id: "open", operation: .openGeneratedArtifact, description: "Open the result.")
            ],
            itemJob: PlanItemJob(
                source: .folder,
                folderPath: root.path,
                itemKind: .folders,
                itemField: .inputPath
            )
        )
        let prepared = try executor.prepare(plan: plan)
        let result = try await executor.execute(plan: prepared.plan) { _, _ in }

        // alpha's own PDF, once. Without the reset this list holds it twice — the second time as
        // beta's "result", which beta never produced.
        #expect(fileOpener.opened == [alpha.appendingPathComponent("report.pdf").path])
        // And beta is reported as an item that could not be done, rather than silently handed
        // somebody else's file.
        #expect(result.itemJobFailures.map(\.itemIndex) == [1])
        #expect(result.summary.contains("1 of 2 folders"))
    }

    /// **A step that takes the previous unit's output gets the item when it *leads* the template, and
    /// not otherwise.** Both directions in one test, because each was wrong on its own: exempting no
    /// consuming step made "convert the documents in each of these folders and open the result" refuse
    /// a folder outright, and exempting every one of them broke "reveal each of these", where the item
    /// is the first thing that happens.
    @Test
    func aStepThatTakesThePreviousUnitsOutputGetsTheItemOnlyWhenItLeadsTheTemplate() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("one", to: root.appendingPathComponent("a.pdf"))
        try write("two", to: root.appendingPathComponent("b.pdf"))
        let executor = makeExecutor(root: root)

        // Leading: the item is what it reveals.
        let leading = try executor.prepare(
            plan: AgentPlan(
                summary: "Reveal each of these.",
                requiresConfirmation: false,
                steps: [AgentStep(id: "reveal", operation: .revealInFinder, description: "Reveal it.")],
                itemJob: PlanItemJob(
                    source: .folder,
                    folderPath: root.path,
                    itemKind: .files,
                    fileExtensions: ["pdf"],
                    itemField: .inputPath
                )
            )
        )
        #expect(leading.plan.steps.map(\.inputPath) == [
            root.appendingPathComponent("a.pdf").path,
            root.appendingPathComponent("b.pdf").path
        ])

        // Not leading: it takes what the step before it produced, so it must keep both path fields
        // blank — that blankness is what `ChainedArtifactCarry.consumesPreviousArtifact` reads.
        let trailing = try executor.prepare(
            plan: AgentPlan(
                summary: "Write a note for each of these and open it.",
                requiresConfirmation: false,
                steps: [
                    AgentStep(
                        id: "draft",
                        operation: .createLocalDraft,
                        description: "Write a note.",
                        draftTitle: "Note",
                        draftContent: "Body."
                    ),
                    AgentStep(id: "open", operation: .openGeneratedArtifact, description: "Open it.")
                ],
                itemJob: PlanItemJob(
                    source: .folder,
                    folderPath: root.path,
                    itemKind: .files,
                    fileExtensions: ["pdf"],
                    itemField: .inputPath
                )
            )
        )
        let openSteps = trailing.plan.steps.filter { $0.operation == .openGeneratedArtifact }
        #expect(openSteps.count == 2)
        #expect(openSteps.allSatisfy { $0.inputPath == nil })
        #expect(openSteps.allSatisfy { ChainedArtifactCarry.consumesPreviousArtifact($0) })
        // The control beside it: the step that is *not* a consumer did get the item.
        let draftSteps = trailing.plan.steps.filter { $0.operation == .createLocalDraft }
        #expect(draftSteps.compactMap(\.inputPath).count == 2)
    }

    // MARK: - Remembering its place

    /// The whole point of the ticket, on the real path: a job interrupted partway records which
    /// items are done, and what is left re-runs only the items that are not.
    @Test
    func aJobRemembersWhichItemsAreDoneAndResumesAtTheNextOne() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["a", "b", "c"] {
            try write(name, to: root.appendingPathComponent("\(name).pdf"))
        }
        let firstInvoker = RecordingShortcutInvoker()
        let executor = makeExecutor(root: root, shortcutInvoker: firstInvoker)
        let prepared = try executor.prepare(plan: shortcutJob(over: root))

        var reported: [CompletedRunUnit] = []
        _ = try await executor.execute(
            plan: prepared.plan,
            onUnitCompleted: { reported.append($0) }
        ) { _, _ in }

        let record = ResumableTask(
            command: "Summarise each of these",
            plan: prepared.plan,
            completedStepIDs: reported.flatMap(\.stepIDs),
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        // Two of three: the last unit of a chain is deliberately never reported (SONNY-210), which is
        // exactly the state a record left by an interruption is in.
        let progress = try #require(record.itemJobProgress)
        #expect(progress.itemCount == 3)
        #expect(progress.completedItemIndexes == [0, 1])
        #expect(progress.failedCount == 0)

        // And what is left really runs on its own, over the third item and nothing else.
        let resumeInvoker = RecordingShortcutInvoker()
        let resumingExecutor = makeExecutor(root: root, shortcutInvoker: resumeInvoker)
        let resumed = try resumingExecutor.prepare(plan: record.remainingPlan())
        _ = try await resumingExecutor.execute(plan: resumed.plan) { _, _ in }
        #expect(resumeInvoker.inputs.map { ($0 as NSString).lastPathComponent } == ["c.pdf"])
    }

    /// Progress is derived, so a failed item is not a completed one — and the control beside it is a
    /// record with the same completed steps and no failures.
    @Test
    func aFailedItemIsNeitherCompletedNorForgotten() throws {
        let plan = expandedJobPlan(items: ["/tmp/a.pdf", "/tmp/b.pdf", "/tmp/c.pdf"])
        let failure = ItemJobFailure(
            itemIndex: 1,
            item: "/tmp/b.pdf",
            message: "Word would not open it.",
            failedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let failed = ResumableTask(
            command: "Summarise each of these",
            plan: plan,
            completedStepIDs: ["run#1"],
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            itemJobFailures: [failure]
        )
        let progress = try #require(failed.itemJobProgress)
        #expect(progress.completedItemIndexes == [0])
        #expect(progress.failures == [failure])
        #expect(progress.settledCount == 2)

        let control = ResumableTask(
            command: "Summarise each of these",
            plan: plan,
            completedStepIDs: ["run#1"],
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let controlProgress = try #require(control.itemJobProgress)
        #expect(controlProgress.failures.isEmpty)
        #expect(controlProgress.settledCount == 1)
    }

    /// An item is done only when **every** step of it is done, because a unit may hold several of
    /// them and half an item is not an item.
    @Test
    func anItemIsDoneOnlyWhenEveryStepOfItIsDone() throws {
        let plan = expandedTwoStepJobPlan(items: ["/tmp/alpha", "/tmp/beta"])
        let halfway = ItemJobProgress.of(
            plan: plan,
            completedStepIDs: ["scan#1"],
            failures: []
        )
        #expect(halfway?.completedItemIndexes == [])
        let whole = ItemJobProgress.of(
            plan: plan,
            completedStepIDs: ["scan#1", "convert#1"],
            failures: []
        )
        #expect(whole?.completedItemIndexes == [0])
    }

    /// A record that is not a job has no job progress, rather than a zero that reads like an empty
    /// job.
    @Test
    func aRecordThatIsNotAJobReportsNoJobProgress() {
        let record = ResumableTask(
            command: "Open a page",
            plan: AgentPlan(
                summary: "Open a page.",
                requiresConfirmation: false,
                steps: [AgentStep(id: "url", operation: .openURL, description: "Open.", targetURL: "https://example.com")]
            ),
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        #expect(record.itemJobProgress == nil)
    }

    // MARK: - The store

    /// The failures survive the encrypted round trip, and a record written before this field existed
    /// still decodes.
    @Test
    func theStoreKeepsAJobsFailuresAndReadsOlderRecordsWithoutThem() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ResumableTaskStore(fileURL: root.appendingPathComponent("resumable-tasks.json"))
        let failure = ItemJobFailure(
            itemIndex: 1,
            item: "/tmp/b.pdf",
            message: "Word would not open it.",
            failedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let record = ResumableTask(
            id: "job-1",
            command: "Summarise each of these",
            plan: expandedJobPlan(items: ["/tmp/a.pdf", "/tmp/b.pdf"]),
            completedStepIDs: ["run#1"],
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            itemJobFailures: [failure]
        )
        try store.save(record, now: Date(timeIntervalSince1970: 1_700_000_000))

        let loaded = try #require(try store.loadAll(now: Date(timeIntervalSince1970: 1_700_000_000)).first)
        #expect(loaded.itemJobFailures == [failure])
        #expect(loaded.itemJobProgress?.failedCount == 1)

        // A record from before SONNY-235 carries no such key at all.
        let legacy = """
        {
          "id": "old-1",
          "command": "Open a page",
          "plan": {"summary": "Open.", "requiresConfirmation": false, "steps": []},
          "completedStepIDs": [],
          "startedAt": "2023-11-14T22:13:20Z",
          "updatedAt": "2023-11-14T22:13:20Z",
          "stopReason": "interrupted"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ResumableTask.self, from: Data(legacy.utf8))
        #expect(decoded.itemJobFailures.isEmpty)
    }

    /// A job of the largest size this allows still fits the resumable store's plan budget, so the
    /// biggest job Sonny will accept is still one it can offer to carry on with.
    ///
    /// **This is the test that set `PlanItemJob.maxItems`.** At a hundred items the same shape
    /// encodes to 69717 bytes against a 65536-byte budget — measured, which is how the cap came to be
    /// fifty rather than a round number picked first.
    @Test
    func aJobOfTheLargestPermittedSizeStillFitsTheResumableStoresPlanBudget() throws {
        // Deliberately long, realistic paths — the budget is spent on them, not on the step shape.
        let items = (1...PlanItemJob.maxItems).map { index in
            "/Users/somebody/Library/Mobile Documents/com~apple~CloudDocs/Work/Client Reports 2026/Quarterly Review \(index).docx"
        }
        let plan = expandedTwoStepJobPlan(items: items)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(plan)

        // Printed as well as asserted, so the margin is readable rather than only the verdict.
        #expect(
            encoded.count <= ResumableTaskStore.maxEncodedPlanBytes,
            "A \(PlanItemJob.maxItems)-item job encodes to \(encoded.count) bytes, over the \(ResumableTaskStore.maxEncodedPlanBytes)-byte budget, so the largest job Sonny accepts could not be resumed."
        )
    }

    // MARK: - What a planner may say

    /// **A planner may declare a job and may not name its items.** The forty paths a job acts on are
    /// read from the machine, never asserted by a model — the same rule the two app pins and the
    /// Finder-read fact follow.
    @Test
    func aPlannerMayDeclareAJobAndMayNotNameItsItems() throws {
        let declared = """
        {
          "summary": "Summarise each of these.",
          "requiresConfirmation": true,
          "itemJob": {
            "source": "folder",
            "folderPath": "~/Documents/Reports",
            "itemKind": "files",
            "fileExtensions": ["pdf"],
            "itemField": "shortcutInput"
          },
          "steps": [
            {"id": "run", "operation": "invoke_shortcut", "description": "Run it.", "shortcutName": "Summarise"}
          ]
        }
        """
        let plan = try AgentPlanDecoder.decodeStrict(from: Data(declared.utf8))
        #expect(plan.itemJob?.source == .folder)
        #expect(plan.itemJob?.items.isEmpty == true)

        let named = declared.replacingOccurrences(
            of: "\"itemField\": \"shortcutInput\"",
            with: "\"itemField\": \"shortcutInput\", \"items\": [\"/etc/passwd\"]"
        )
        #expect(throws: AgentPlanDecodingError.unexpectedItemJobKey("items")) {
            _ = try AgentPlanDecoder.decodeStrict(from: Data(named.utf8))
        }

        // `null` in place of the whole object is not an error either — a plan that carries no job.
        let nullJob = declared.replacingOccurrences(
            of: #""itemJob": {"#,
            with: #""itemJob": null, "ignored": {"#
        )
        #expect(throws: AgentPlanDecodingError.unexpectedTopLevelKey("ignored")) {
            _ = try AgentPlanDecoder.decodeStrict(from: Data(nullJob.utf8))
        }
    }

    /// **How the wire says "this is not a job", and the control that makes it mean something.** The
    /// schema requires `itemJob` on every response and cannot make the object itself nullable — see
    /// `AgentPlanSchema.itemJobSchema` — so an ordinary command comes back with every field inside it
    /// null. That has to decode to exactly the plan the same response without the key decodes to,
    /// or every ordinary command would become a one-item job.
    @Test
    func anItemJobWhoseSourceIsNullDecodesToTheSamePlanAsNoItemJobAtAll() throws {
        let withNulls = """
        {
          "summary": "Open a page.",
          "requiresConfirmation": false,
          "itemJob": {
            "source": null,
            "folderPath": null,
            "itemKind": null,
            "fileExtensions": null,
            "itemField": null
          },
          "steps": [
            {"id": "url", "operation": "open_url", "description": "Open it.", "targetURL": "https://example.com"}
          ]
        }
        """
        let without = """
        {
          "summary": "Open a page.",
          "requiresConfirmation": false,
          "steps": [
            {"id": "url", "operation": "open_url", "description": "Open it.", "targetURL": "https://example.com"}
          ]
        }
        """
        let a = try AgentPlanDecoder.decodeStrict(from: Data(withNulls.utf8))
        let b = try AgentPlanDecoder.decodeStrict(from: Data(without.utf8))
        #expect(a.itemJob == nil)
        #expect(a == b)

        // **And a job that is declared but malformed is refused rather than quietly becoming an
        // ordinary plan.** This is the direction the signal exists to protect: catching a
        // `DecodingError` in `AgentPlan.init(from:)` instead of the one signal would swallow this and
        // run the template once, over nothing.
        let sourceWithoutField = withNulls.replacingOccurrences(
            of: #""source": null"#,
            with: #""source": "folder", "folderPath": "~/Documents""#
        )
        #expect(throws: (any Error).self) {
            _ = try AgentPlanDecoder.decodeStrict(from: Data(sourceWithoutField.utf8))
        }
    }

    // MARK: - Declarations that cannot be run

    @Test
    func aJobWithNoItemsSaysSoRatherThanRunningNothing() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("not a pdf", to: root.appendingPathComponent("notes.txt"))
        let executor = makeExecutor(root: root)

        #expect(throws: (any Error).self) {
            _ = try executor.prepare(plan: shortcutJob(over: root))
        }
        // The control: the same folder with one matching file prepares fine, so the refusal is about
        // the filter and not about the folder.
        try write("one", to: root.appendingPathComponent("a.pdf"))
        _ = try executor.prepare(plan: shortcutJob(over: root))
    }

    @Test
    func aJobOverMoreItemsThanSonnyWillTakeIsRefusedByCount() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 1...(PlanItemJob.maxItems + 1) {
            try write("x", to: root.appendingPathComponent("file-\(index).pdf"))
        }
        let executor = makeExecutor(root: root)

        #expect(throws: PlanItemJobError.tooManyItems(count: PlanItemJob.maxItems + 1, limit: PlanItemJob.maxItems)) {
            _ = try executor.prepare(plan: shortcutJob(over: root))
        }
    }

    @Test
    func aFolderJobThatFiltersByFileTypeIsRefusedRatherThanIgnored() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("alpha"), withIntermediateDirectories: true)
        let executor = makeExecutor(root: root)

        var plan = docxJob(over: root)
        plan.itemJob?.fileExtensions = ["docx"]
        #expect(throws: PlanItemJobError.fileExtensionsOnFolderItems) {
            _ = try executor.prepare(plan: plan)
        }
    }

    // MARK: - Fixtures

    private func shortcutJob(over folder: URL) -> AgentPlan {
        AgentPlan(
            summary: "Summarise each of these.",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "run",
                    operation: .invokeShortcut,
                    description: "Run the Shortcut on this file.",
                    shortcutName: "Summarise"
                )
            ],
            itemJob: PlanItemJob(
                source: .folder,
                folderPath: folder.path,
                itemKind: .files,
                fileExtensions: ["pdf"],
                itemField: .shortcutInput
            )
        )
    }

    private func docxJob(over folder: URL) -> AgentPlan {
        AgentPlan(
            summary: "Convert the Word documents in each of these folders.",
            requiresConfirmation: true,
            steps: [
                AgentStep(id: "scan", operation: .scanDocx, description: "Find the documents."),
                AgentStep(id: "convert", operation: .convertDocxToPDF, description: "Convert them.")
            ],
            itemJob: PlanItemJob(
                source: .folder,
                folderPath: folder.path,
                itemKind: .folders,
                itemField: .inputPath
            )
        )
    }

    /// An already-expanded one-step-per-item job, for the assertions that are about a record rather
    /// than about a run.
    private func expandedJobPlan(items: [String]) -> AgentPlan {
        PlanItemJobResolver.expanding(
            AgentPlan(
                summary: "Summarise each of these.",
                requiresConfirmation: true,
                steps: [
                    AgentStep(
                        id: "run",
                        operation: .invokeShortcut,
                        description: "Run the Shortcut on this file.",
                        shortcutName: "Summarise"
                    )
                ]
            ),
            over: PlanItemJob(
                source: .folder,
                folderPath: "/tmp",
                itemKind: .files,
                fileExtensions: ["pdf"],
                itemField: .shortcutInput,
                items: items
            )
        )
    }

    private func expandedTwoStepJobPlan(items: [String]) -> AgentPlan {
        PlanItemJobResolver.expanding(
            AgentPlan(
                summary: "Convert the Word documents in each of these folders.",
                requiresConfirmation: true,
                steps: [
                    AgentStep(id: "scan", operation: .scanDocx, description: "Find the documents."),
                    AgentStep(id: "convert", operation: .convertDocxToPDF, description: "Convert them.")
                ]
            ),
            over: PlanItemJob(
                source: .folder,
                folderPath: "/tmp",
                itemKind: .folders,
                itemField: .inputPath,
                items: items
            )
        )
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonny-item-job-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ contents: String, to url: URL) throws {
        try Data(contents.utf8).write(to: url, options: .atomic)
    }

    private func makeExecutor(
        root: URL,
        shortcutInvoker: any ShortcutInvoking = RecordingShortcutInvoker(),
        browserOpener: any BrowserOpening = RecordingBrowserOpener(),
        // Injected rather than defaulted: the shipping `AutoDocumentConverter` needs Microsoft Word,
        // so a test leaning on the default would be measuring whether Word is installed on the
        // machine — which is how the first version of `aFolderThatCannotBePreviewedIsDropped…`
        // reported all three folders as failures and looked briefly like the fix not working.
        documentConverter: any DocumentConverting = WritingDocumentConverter(),
        fileOpener: any FileOpening = RecordingFileOpener()
    ) -> AgentActionExecutor {
        AgentActionExecutor(
            whitelist: PathWhitelist(roots: [root]),
            documentConverter: documentConverter,
            browserOpener: browserOpener,
            fileOpener: fileOpener,
            permissionReadinessService: .deterministic(),
            routineStore: RoutineStore(fileURL: root.appendingPathComponent("routines.json")),
            workspaceStore: WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json")),
            clipboardHistoryStore: ClipboardHistoryStore(fileURL: root.appendingPathComponent("clipboard.json")),
            snippetStore: SnippetStore(fileURL: root.appendingPathComponent("snippets.json")),
            recentArtifactStore: RecentArtifactStore(fileURL: root.appendingPathComponent("artifacts.json")),
            shortcutCatalog: OneShortcutCatalog(),
            shortcutInvoker: shortcutInvoker,
            shortcutRunHistoryStore: ShortcutRunHistoryStore(
                fileURL: root.appendingPathComponent("shortcuts-history.json")
            )
        )
    }
}

/// Writes a real file at each destination, so a job over folders exercises the conversion path
/// rather than the absence of Word.
private struct WritingDocumentConverter: DocumentConverting {
    var isAvailable: Bool { true }
    var modeName: String { "Writing fake converter" }
    var usesMockNaming: Bool { false }

    func convert(_ records: [DocxRecord], log: @escaping (String) -> Void) async throws -> [DocxRecord] {
        var converted: [DocxRecord] = []
        for record in records where !record.skippedBecausePDFExists {
            try Data("fake pdf".utf8).write(to: record.destinationURL, options: .atomic)
            converted.append(record)
        }
        return converted
    }
}

private struct OneShortcutCatalog: ShortcutCatalogProviding {
    func shortcutNames() throws -> [String] { ["Summarise"] }
}

/// Records what it was asked to run, and can be told to fail — or to cancel — on one item.
///
/// Failing and cancelling are two different fakes on purpose: the whole of the cancellation rule is
/// that the second one must not be treated like the first.
private final class RecordingShortcutInvoker: ShortcutInvoking, @unchecked Sendable {
    private(set) var inputs: [String] = []
    private let failingSubstring: String?
    private let cancellingSubstring: String?

    init(failingOnInputContaining failing: String? = nil, cancellingOnInputContaining cancelling: String? = nil) {
        self.failingSubstring = failing
        self.cancellingSubstring = cancelling
    }

    func invokeShortcut(name: String, input: String?) async throws -> ProcessResult {
        inputs.append(input ?? "")
        if let cancellingSubstring, input?.contains(cancellingSubstring) == true {
            throw CancellationError()
        }
        if let failingSubstring, input?.contains(failingSubstring) == true {
            throw ShortcutsBridgeError.invocationFailed(name, 1, "the Shortcut reported an error")
        }
        return ProcessResult(terminationStatus: 0, output: "")
    }
}

@MainActor
private final class RecordingFileOpener: FileOpening {
    private(set) var opened: [String] = []

    func openFile(_ url: URL) async throws {
        opened.append(url.path)
    }
}

@MainActor
private final class RecordingBrowserOpener: BrowserOpening {
    private(set) var opened: [String] = []

    func open(_ url: URL, using browser: MacApp?) async throws {
        opened.append(url.absoluteString)
    }
}
