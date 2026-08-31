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

    /// **An item that produces nothing is reported, not handed the previous item's file.**
    ///
    /// **What this does and does not claim, because the difference was measured.** It pins the
    /// outcome — one file opened, the item that produced nothing named as a failure — and it does
    /// **not** pin the cross-item carry reset in `executeChain`, which a mutant deleted at `6976659`
    /// with the whole suite still green (R4). Two mechanisms stand between these items and the wrong
    /// file, and the one that actually holds here is the carry's own re-seeding from a unit's last
    /// suggestion: the conversion unit returns one naming the folder it worked in, so this item's
    /// carry is replaced by its own folder before its opening step ever runs. The reset is defensive
    /// and `executeChain` says so at the line itself.
    ///
    /// A test that claimed to hold the reset would be worse than no test, so it does not: it holds
    /// what a user would notice, which is that a folder whose documents were all converted already
    /// is reported rather than silently handed the previous folder's PDF.
    @Test
    func anItemThatProducesNothingIsReportedRatherThanHandedThePreviousItemsFile() async throws {
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

        // alpha's own PDF, once, and beta's nothing.
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
        let folders = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: folders) }
        for name in ["alpha", "beta"] {
            let folder = folders.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try write("doc", to: folder.appendingPathComponent("report.docx"))
        }
        let folderExecutor = makeExecutor(root: folders)
        let trailing = try folderExecutor.prepare(
            plan: AgentPlan(
                summary: "Convert the documents in each of these folders and open the result.",
                requiresConfirmation: false,
                steps: [
                    AgentStep(id: "scan", operation: .scanDocx, description: "Find them."),
                    AgentStep(id: "convert", operation: .convertDocxToPDF, description: "Convert them."),
                    AgentStep(id: "open", operation: .openGeneratedArtifact, description: "Open it.")
                ],
                itemJob: PlanItemJob(
                    source: .folder,
                    folderPath: folders.path,
                    itemKind: .folders,
                    itemField: .inputPath
                )
            )
        )
        let openSteps = trailing.plan.steps.filter { $0.operation == .openGeneratedArtifact }
        #expect(openSteps.count == 2)
        #expect(openSteps.allSatisfy { $0.inputPath == nil })
        #expect(openSteps.allSatisfy { ChainedArtifactCarry.consumesPreviousArtifact($0) })
        // The control beside it: the steps that are *not* trailing consumers did get the item.
        let scanSteps = trailing.plan.steps.filter { $0.operation == .scanDocx }
        #expect(scanSteps.compactMap(\.inputPath).count == 2)
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

    // MARK: - A resumed job is still a job (PR #185, F1)

    /// **The ticket's headline property, on the app's own Continue path.** `remainingPlan()` rebuilt
    /// the plan from three fields and let `itemJob` default to `nil`, so a remainder kept every step's
    /// `itemIndex` and stopped being a job — every rule that makes a job a job was present on the
    /// first attempt and absent on the second, silently.
    @Test
    func aResumedJobIsStillAJob() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["a", "b", "c"] {
            try write(name, to: root.appendingPathComponent("\(name).pdf"))
        }
        let executor = makeExecutor(root: root)
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
        let remainder = record.remainingPlan()

        // It is a job, its declaration is intact, and it keeps the whole item list so a failure's
        // index still means what it meant.
        let job = try #require(remainder.itemJob)
        #expect(job.items.count == 3)
        #expect(job.itemField == .shortcutInput)
        #expect(remainder.steps.map(\.id) == ["run#3"])

        // **And the count is the remainder's own, which is the trap in the obvious fix**: carrying
        // the declaration without scoping the count reports "all 3" after doing one.
        let progress = try #require(ItemJobProgress.of(plan: remainder, completedStepIDs: [], failures: []))
        #expect(progress.itemCount == 1)
        #expect(progress.completedCount == 0)

        let resumeInvoker = RecordingShortcutInvoker()
        let resuming = makeExecutor(root: root, shortcutInvoker: resumeInvoker)
        let resumed = try resuming.prepare(plan: remainder)
        let result = try await resuming.execute(plan: resumed.plan) { _, _ in }
        #expect(resumeInvoker.inputs.map { ($0 as NSString).lastPathComponent } == ["c.pdf"])
        #expect(result.summary == "Worked through all 1 files.")
    }

    /// The three job rules that were silently absent on a resume, each asserted through the real
    /// `prepare`/`execute` rather than by inspecting the plan.
    @Test
    func aResumedJobKeepsSkipAndContinueAndItsPreviewDrop() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["a", "b", "c", "d"] {
            try write(name, to: root.appendingPathComponent("\(name).pdf"))
        }
        let executor = makeExecutor(root: root)
        let prepared = try executor.prepare(plan: shortcutJob(over: root))
        // Pretend the first item finished and the run stopped there.
        let record = ResumableTask(
            command: "Summarise each of these",
            plan: prepared.plan,
            completedStepIDs: ["run#1"],
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        // Skip-and-continue survives the resume: `c.pdf` fails and `d.pdf` still runs.
        let invoker = RecordingShortcutInvoker(failingOnInputContaining: "c.pdf")
        let resuming = makeExecutor(root: root, shortcutInvoker: invoker)
        let resumed = try resuming.prepare(plan: record.remainingPlan())
        let result = try await resuming.execute(plan: resumed.plan) { _, _ in }

        #expect(invoker.inputs.map { ($0 as NSString).lastPathComponent } == ["b.pdf", "c.pdf", "d.pdf"])
        #expect(result.itemJobFailures.map(\.itemIndex) == [2])
        // Counted over the three the remainder covers, not the four the job began with.
        #expect(result.summary.contains("2 of 3 files"))
    }

    /// A remainder whose own items include one that cannot be previewed drops it and runs the rest —
    /// the defect `82ee28d` fixed for the first attempt, which came back on the second.
    @Test
    func aResumedJobDropsAnUnpreviewableItemRatherThanDyingAtTheDoor() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["alpha", "beta", "gamma"] {
            let folder = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if name != "beta" {
                try write("doc", to: folder.appendingPathComponent("report.docx"))
            }
        }
        let executor = makeExecutor(root: root)
        // `beta` is dropped at the first prepare, so the plan holds alpha and gamma.
        let prepared = try executor.prepare(plan: docxJob(over: root))
        #expect(prepared.plan.itemJob?.unavailableItems.map(\.itemIndex) == [1])

        // Now empty `gamma` too, so the *remainder* has one item that cannot be previewed.
        try FileManager.default.removeItem(at: root.appendingPathComponent("gamma/report.docx"))
        let record = ResumableTask(
            command: "Convert each of these",
            plan: prepared.plan,
            completedStepIDs: ["scan#1", "convert#1"],
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        // Before F1's fix this threw `noMatchingFiles` and prepared nothing at all.
        let resuming = makeExecutor(root: root)
        #expect(throws: PlanItemJobError.self) {
            _ = try resuming.prepare(plan: record.remainingPlan())
        }
        // …and that is the *right* refusal here, because gamma was the remainder's only item. The
        // control is the same remainder with gamma still convertible, which prepares and runs.
        try write("doc", to: root.appendingPathComponent("gamma/report.docx"))
        let healthy = try resuming.prepare(plan: record.remainingPlan())
        #expect(healthy.plan.steps.map(\.itemIndex) == [2, 2])
        let result = try await resuming.execute(plan: healthy.plan) { _, _ in }
        // One folder, and beta is not re-reported: the earlier attempt's unavailable items do not
        // travel into the remainder, for the same reason its failures do not.
        #expect(healthy.plan.itemJob?.unavailableItems.isEmpty == true)
        #expect(result.summary == "Worked through all 1 folders.")
    }

    /// **A resume's carried artifact never crosses an item boundary**, because the resume door bakes
    /// it onto the remainder's leading step before `executeChain` runs and no in-loop reset can take
    /// a value back out of the plan (PR #185, F2(b)).
    @Test
    func aResumesCarriedArtifactIsWithheldWhenItWouldCrossAnItemBoundary() throws {
        let plan = expandedTwoStepJobPlan(items: ["/tmp/alpha", "/tmp/beta"])
        let crossing = ResumableTask(
            command: "Convert each of these",
            plan: plan,
            // Item 0's unit finished; the remainder starts item 1.
            completedStepIDs: ["scan#1", "convert#1"],
            chainedArtifactPath: "/tmp/alpha/report.pdf",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        #expect(crossing.chainedArtifactPath == "/tmp/alpha/report.pdf")
        #expect(crossing.chainedArtifactPathForRemainder == nil)

        // The control, and the case the carry exists for: the remainder continues the *same* item.
        let sameItem = ResumableTask(
            command: "Convert each of these",
            plan: plan,
            completedStepIDs: ["scan#1"],
            chainedArtifactPath: "/tmp/alpha/report.pdf",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        #expect(sameItem.chainedArtifactPathForRemainder == "/tmp/alpha/report.pdf")

        // And a plan that is not a job is untouched by the rule.
        let ordinary = ResumableTask(
            command: "Open a page",
            plan: AgentPlan(
                summary: "Open.",
                requiresConfirmation: false,
                steps: [AgentStep(id: "url", operation: .openURL, description: "Open.", targetURL: "https://example.com")]
            ),
            chainedArtifactPath: "/tmp/whatever.md",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        #expect(ordinary.chainedArtifactPathForRemainder == "/tmp/whatever.md")
    }

    // MARK: - The declared field has to be one the template reads (PR #185, F2)

    /// **The silent wrong result this refusal exists for.** A `[invoke_shortcut]` template declaring
    /// `itemField: .inputPath` ran the Shortcut once per item with no input at all, recorded zero
    /// failures, and reported "Worked through all 3 files" — a job that touched none of its items and
    /// called itself a complete success.
    @Test
    func aJobWhoseTemplateReadsTheDeclaredFieldNowhereIsRefused() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["a", "b", "c"] {
            try write(name, to: root.appendingPathComponent("\(name).pdf"))
        }
        let invoker = RecordingShortcutInvoker()
        let executor = makeExecutor(root: root, shortcutInvoker: invoker)

        var mismatched = shortcutJob(over: root)
        mismatched.itemJob?.itemField = .inputPath
        #expect(throws: PlanItemJobError.self) {
            _ = try executor.prepare(plan: mismatched)
        }
        // Nothing ran, which is the half that matters: the old behaviour invoked three times.
        #expect(invoker.inputs.isEmpty)

        // The control: the same template with the field the Shortcut actually reads prepares and runs.
        let correct = try executor.prepare(plan: shortcutJob(over: root))
        #expect(correct.plan.steps.count == 3)
    }

    /// The item is written only into steps that read the declared field, so a step that reads neither
    /// is left exactly as the planner wrote it.
    @Test
    func theItemIsWrittenOnlyIntoStepsThatReadTheDeclaredField() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("one", to: root.appendingPathComponent("a.pdf"))
        try write("two", to: root.appendingPathComponent("b.pdf"))
        let executor = makeExecutor(root: root)

        let prepared = try executor.prepare(
            plan: AgentPlan(
                summary: "Summarise each of these, then open the notes page.",
                requiresConfirmation: true,
                steps: [
                    AgentStep(id: "run", operation: .invokeShortcut, description: "Run it.", shortcutName: "Summarise"),
                    AgentStep(id: "url", operation: .openURL, description: "Open.", targetURL: "https://example.com/page")
                ],
                itemJob: PlanItemJob(
                    source: .folder,
                    folderPath: root.path,
                    itemKind: .files,
                    fileExtensions: ["pdf"],
                    itemField: .shortcutInput
                )
            )
        )
        let shortcutSteps = prepared.plan.steps.filter { $0.operation == .invokeShortcut }
        let urlSteps = prepared.plan.steps.filter { $0.operation == .openURL }
        #expect(shortcutSteps.compactMap(\.shortcutInput).count == 2)
        // `open_url` reads neither field: it keeps its own target and gains nothing.
        #expect(urlSteps.allSatisfy { $0.shortcutInput == nil && $0.inputPath == nil })
        #expect(urlSteps.allSatisfy { $0.targetURL == "https://example.com/page" })
    }

    /// **A template whose only field-reading step is a trailing consumer is refused**, and this is the
    /// case that makes the refusal ask `writesTheItem` rather than `itemFieldsRead` alone (PR #185,
    /// F2; a mutant reading the looser question survived at `08db3aa` until this test existed).
    ///
    /// `[create_local_draft, open_generated_artifact]` declaring `.inputPath` has a step that *reads*
    /// the field — `open_generated_artifact` reads `outputPath ?? inputPath` — and that step is
    /// precisely the one the expansion skips, so the item would reach nothing and every item would be
    /// reported done.
    @Test
    func aTemplateWhoseOnlyFieldReadingStepIsATrailingConsumerIsRefused() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("one", to: root.appendingPathComponent("a.pdf"))
        let executor = makeExecutor(root: root)

        let job = PlanItemJob(
            source: .folder,
            folderPath: root.path,
            itemKind: .files,
            fileExtensions: ["pdf"],
            itemField: .inputPath
        )
        let draftThenOpen = [
            AgentStep(
                id: "draft",
                operation: .createLocalDraft,
                description: "Write a note.",
                draftTitle: "Note",
                draftContent: "Body."
            ),
            AgentStep(id: "open", operation: .openGeneratedArtifact, description: "Open it.")
        ]
        // The premise, asserted rather than assumed: the trailing step really does read the field, so
        // the looser question would have said yes.
        #expect(draftThenOpen[1].operation.itemFieldsRead.contains(.inputPath))
        #expect(!draftThenOpen[0].operation.itemFieldsRead.contains(.inputPath))

        #expect(throws: PlanItemJobError.self) {
            _ = try executor.prepare(
                plan: AgentPlan(
                    summary: "Write a note for each of these and open it.",
                    requiresConfirmation: false,
                    steps: draftThenOpen,
                    itemJob: job
                )
            )
        }

        // The control: put a step in front that does read the field, and the same trailing consumer
        // is fine — the refusal is about the item reaching nothing, not about consumers.
        let folders = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: folders) }
        let alpha = folders.appendingPathComponent("alpha")
        try FileManager.default.createDirectory(at: alpha, withIntermediateDirectories: true)
        try write("doc", to: alpha.appendingPathComponent("report.docx"))
        let folderExecutor = makeExecutor(root: folders)
        _ = try folderExecutor.prepare(
            plan: AgentPlan(
                summary: "Convert the documents in each of these folders and open the result.",
                requiresConfirmation: false,
                steps: [
                    AgentStep(id: "scan", operation: .scanDocx, description: "Find them."),
                    AgentStep(id: "convert", operation: .convertDocxToPDF, description: "Convert them."),
                    AgentStep(id: "open", operation: .openGeneratedArtifact, description: "Open it.")
                ],
                itemJob: PlanItemJob(
                    source: .folder,
                    folderPath: folders.path,
                    itemKind: .folders,
                    itemField: .inputPath
                )
            )
        )
    }

    /// The narrower half of the same hole: a *leading* consuming step handed a field it does not read
    /// would keep both path fields blank and stay a live consumer of an artifact from outside its own
    /// item. It is not written into, and the whole declaration is refused when nothing else reads the
    /// field either.
    @Test
    func aLeadingConsumingStepIsNotHandedAFieldItDoesNotRead() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("one", to: root.appendingPathComponent("a.pdf"))
        try write("two", to: root.appendingPathComponent("b.pdf"))
        let executor = makeExecutor(root: root)

        // The expansion leaves the reveal alone: it does not read `shortcutInput`, so it is not
        // handed one and does not become a step carrying a value nothing will read.
        let expanded = PlanItemJobResolver.expanding(
            AgentPlan(
                summary: "Reveal each of these, then run the Shortcut on it.",
                requiresConfirmation: true,
                steps: [
                    AgentStep(id: "reveal", operation: .revealInFinder, description: "Reveal it."),
                    AgentStep(id: "run", operation: .invokeShortcut, description: "Run it.", shortcutName: "Summarise")
                ]
            ),
            over: PlanItemJob(
                source: .folder,
                folderPath: root.path,
                itemKind: .files,
                fileExtensions: ["pdf"],
                itemField: .shortcutInput,
                items: [root.appendingPathComponent("a.pdf").path, root.appendingPathComponent("b.pdf").path]
            )
        )
        let revealSteps = expanded.steps.filter { $0.operation == .revealInFinder }
        #expect(revealSteps.count == 2)
        #expect(revealSteps.allSatisfy { $0.shortcutInput == nil })
        #expect(revealSteps.allSatisfy { $0.inputPath == nil })
        // So every item's leading reveal has nothing to reveal, and `prepare` says so at the door
        // rather than after the run — every item is unavailable.
        #expect(throws: PlanItemJobError.self) {
            _ = try executor.prepare(
                plan: AgentPlan(
                    summary: "Reveal each of these, then run the Shortcut on it.",
                    requiresConfirmation: true,
                    steps: expanded.steps.prefix(2).map { step in
                        var template = step
                        template.id = String(step.id.prefix(while: { $0 != "#" }))
                        template.itemIndex = nil
                        template.shortcutInput = nil
                        return template
                    },
                    itemJob: PlanItemJob(
                        source: .folder,
                        folderPath: root.path,
                        itemKind: .files,
                        fileExtensions: ["pdf"],
                        itemField: .shortcutInput
                    )
                )
            )
        }
        // The control, and the direction the leading-step exemption is for: with the field the reveal
        // *does* read, it gets the item and stops being a consumer.
        let reading = try executor.prepare(
            plan: AgentPlan(
                summary: "Reveal each of these.",
                requiresConfirmation: true,
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
        #expect(reading.plan.steps.allSatisfy { $0.inputPath != nil })
        #expect(reading.plan.steps.allSatisfy { !ChainedArtifactCarry.consumesPreviousArtifact($0) })
    }

    /// The backstop on the table: every operation the table says reads a field is one whose adapter
    /// really names that field, and every operation it says reads none names neither.
    ///
    /// A source scan rather than a value list, because the thing that goes stale is the *agreement*
    /// between the table and the adapters, and only the adapters can say what they read.
    @Test
    func theItemFieldTableMatchesWhatTheAdaptersActuallyRead() throws {
        let adapterSource = try adapterSourceByOperation()
        for operation in AgentOperation.allCases {
            guard let source = adapterSource[operation] else {
                // No adapter owns it (`.clarify`, `.unsupported`), so it can read nothing.
                #expect(operation.itemFieldsRead.isEmpty, "\(operation.rawValue) has no adapter yet claims a field")
                continue
            }
            for field in PlanItemField.allCases {
                let named = source.contains(".\(field.rawValue)")
                #expect(
                    operation.itemFieldsRead.contains(field) == named,
                    "AgentOperation.itemFieldsRead disagrees with the adapter for \(operation.rawValue) on \(field.rawValue)"
                )
            }
        }
    }

    // MARK: - The whitelist guards on a job's items (PR #185, F3)

    /// A symbolic link is not an item, so a link inside the folder pointing outside the whitelist
    /// never becomes one of the fifty paths a single approval covers.
    @Test
    func aSymbolicLinkInTheFolderIsNotAnItem() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: outside) }
        let target = outside.appendingPathComponent("secret.pdf")
        try write("outside", to: target)
        try write("inside", to: root.appendingPathComponent("a.pdf"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link.pdf"),
            withDestinationURL: target
        )

        let executor = makeExecutor(root: root)
        let prepared = try executor.prepare(plan: shortcutJob(over: root))

        #expect(prepared.plan.itemJob?.items == [root.appendingPathComponent("a.pdf").path])
        #expect(prepared.plan.itemJob?.items.contains(target.path) == false)
    }

    /// **An item from the Finder selection that sits outside the whitelist is refused.**
    ///
    /// **What this does and does not hold, measured rather than assumed.** It pins the outcome — such
    /// an item never becomes one of the paths a single approval covers — and it does **not** hold
    /// `resolveItems`' own closing `validateInsideWhitelist` pass: a mutant deleting that line
    /// survived the whole suite at `08db3aa`. The refusal here comes from
    /// `FinderSelectionResolver.whitelistedSelection`, which validates every URL it returns before
    /// this resolver sees it. `PlanItemJobResolver`'s own line says at the code that it is defensive
    /// and which guards reach first.
    @Test
    func anItemOutsideTheWhitelistIsRefusedByItsOwnValidation() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: outside) }
        try write("outside", to: outside.appendingPathComponent("secret.pdf"))

        // The Finder selection is the source that can hand back a path from anywhere, so it is where
        // the per-item check is reachable without bypassing the link filter.
        let job = PlanItemJob(
            source: .finderSelection,
            itemKind: .files,
            fileExtensions: ["pdf"],
            itemField: .shortcutInput
        )
        #expect(throws: (any Error).self) {
            _ = try PlanItemJobResolver.resolveItems(
                for: job,
                whitelist: PathWhitelist(roots: [root]),
                finderContextReader: FixedFinderSelection([outside.appendingPathComponent("secret.pdf")]),
                fileManager: .default
            )
        }
        // The control: the same reader handing back a path inside the whitelist resolves fine.
        try write("inside", to: root.appendingPathComponent("a.pdf"))
        let items = try PlanItemJobResolver.resolveItems(
            for: job,
            whitelist: PathWhitelist(roots: [root]),
            finderContextReader: FixedFinderSelection([root.appendingPathComponent("a.pdf")]),
            fileManager: .default
        )
        #expect(items == [root.appendingPathComponent("a.pdf").path])
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

    /// Each operation's owning adapter source, read from the tree rather than listed here.
    private func adapterSourceByOperation() throws -> [AgentOperation: String] {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/MacAgentCore")
        var byOperation: [AgentOperation: String] = [:]
        for adapter in CapabilityRegistry.default.adapters {
            let name = adapter.metadata.id
            _ = name
            let file = directory.appendingPathComponent("\(String(describing: type(of: adapter))).swift")
            guard let source = try? String(contentsOf: file, encoding: .utf8) else {
                continue
            }
            for operation in adapter.metadata.operations {
                byOperation[operation] = source
            }
        }
        return byOperation
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

/// Hands back a fixed selection, so the Finder-selection source is reachable without Apple Events.
private struct FixedFinderSelection: FinderContextReading {
    let urls: [URL]

    init(_ urls: [URL]) {
        self.urls = urls
    }

    func selectedItems() throws -> [URL] { urls }
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
