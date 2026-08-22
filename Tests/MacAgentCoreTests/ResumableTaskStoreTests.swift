import Foundation
import Testing
@testable import MacAgentCore

/// The twelfth store's own behaviour (row 13, SONNY-210): what it keeps, what it refuses, and when
/// it forgets.
///
/// The registration half — the wipe, the classification, the Memory row — is asserted where those
/// live (`LocalStorageSecurityTests`, `MemorySettingsTests`), because a store proving its own
/// membership is a store that can only prove it about itself.
@MainActor
struct ResumableTaskStoreTests {
    // MARK: - The shared pattern

    @Test
    func aRecordRoundTripsEncryptedWithNothingReadableOnDisk() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)

        try store.save(sample(command: "Zip my three largest files"), now: .fixture)

        let loaded = try store.loadAll(now: .fixture)
        #expect(loaded.count == 1)
        // `#require` rather than a subscript, here and below: an `#expect` on a count records its
        // issue and carries on, so indexing an empty array crashes the process — which under a
        // mutation battery reads as an aborted run rather than as a killed mutant.
        let record = try #require(loaded.first)
        #expect(record.command == "Zip my three largest files")
        #expect(record.plan.steps.map(\.id) == ["calc", "url"])
        try expectEncryptedFile(store.fileURL, hiding: "Zip my three largest files")
    }

    /// The legacy-plaintext door every store on this pattern has: an existing plaintext file decodes,
    /// and the next successful load rewrites it encrypted.
    @Test
    func aPlaintextFileDecodesAndIsRewrittenEncrypted() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("resumable-tasks.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([sample(command: "legacy unfinished task")]).write(to: url, options: .atomic)

        // Plaintext going in — the premise, guarded rather than assumed.
        let before = try Data(contentsOf: url)
        #expect(!before.starts(with: LocalStorageEncryption.fileHeader))

        let store = ResumableTaskStore(fileURL: url, encryption: testEncryption())
        #expect(try store.loadAll(now: .fixture).map(\.command) == ["legacy unfinished task"])
        try expectEncryptedFile(url, hiding: "legacy unfinished task")
    }

    // MARK: - The lifecycle

    /// The founder's third condition, and its control.
    ///
    /// Both halves are here on purpose: "a record older than the idle period is invisible" is
    /// equally true of a store that returns nothing at all, so the record one second *inside* the
    /// period has to come back in the same test.
    @Test
    func aRecordGoesIdleAfterTheIdlePeriodAndOneInsideItDoesNot() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root, idleExpiry: 60)

        var justInside = sample(command: "still wanted")
        justInside.id = "inside"
        justInside.updatedAt = Date(timeInterval: -59, since: .fixture)
        var wellPast = sample(command: "long abandoned")
        wellPast.id = "past"
        wellPast.updatedAt = Date(timeInterval: -61, since: .fixture)

        // Written at each record's own instant, so `save`'s own reload does not discard the one it
        // is writing before the assertion gets to see it.
        try store.save(justInside, now: justInside.updatedAt)
        try store.save(wellPast, now: wellPast.updatedAt)

        #expect(try store.loadAll(now: .fixture).map(\.id) == ["inside"])
    }

    /// The number itself, pinned where changing it is a deliberate edit rather than a side effect.
    /// Fourteen days is the implementer's proposal recorded on SONNY-210, and the reasoning lives on
    /// the store.
    @Test
    func theShippedIdlePeriodIsFourteenDays() {
        #expect(ResumableTaskStore.defaultIdleExpiry == 14 * 24 * 60 * 60)
        #expect(ResumableTaskStore().idleExpiry == ResumableTaskStore.defaultIdleExpiry)
    }

    /// The safety rail, not the lifecycle. Oldest activity is what goes.
    @Test
    func theCapDropsTheLeastRecentlyActiveRecord() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root, maxTasks: 2)

        for (offset, name) in [(-300.0, "oldest"), (-200.0, "middle"), (-100.0, "newest")] {
            var task = sample(command: name)
            task.id = name
            task.updatedAt = Date(timeInterval: offset, since: .fixture)
            try store.save(task, now: .fixture)
        }

        #expect(try store.loadAll(now: .fixture).map(\.id) == ["newest", "middle"])
    }

    @Test
    func savingTheSameIdReplacesItRatherThanAddingASecond() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)

        var task = sample(command: "Zip my files")
        try store.save(task, now: .fixture)
        task.completedStepIDs = ["calc"]
        task.stopReason = .failed
        try store.save(task, now: .fixture)

        let loaded = try store.loadAll(now: .fixture)
        #expect(loaded.count == 1)
        let record = try #require(loaded.first)
        #expect(record.completedStepIDs == ["calc"])
        #expect(record.stopReason == .failed)
    }

    /// Deleting something already gone must not rewrite the file. This is the hot path: every run
    /// that finishes cleanly settles a record that a suppressed or memory-disabled run never wrote.
    @Test
    func deletingAnAbsentRecordDoesNotRewriteTheFile() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        try store.save(sample(command: "Zip my files"), now: .fixture)

        let before = try Data(contentsOf: store.fileURL)
        try store.delete(id: "no-such-record", now: .fixture)
        #expect(try Data(contentsOf: store.fileURL) == before)

        // And the control: deleting one that *is* there really does rewrite it. Without it the
        // assertion above is equally true of a `delete` that never writes at all — which is exactly
        // what the first version of this test measured, because the default clock put the fixture's
        // record past the idle period and made both halves no-ops.
        try store.delete(id: sample(command: "Zip my files").id, now: .fixture)
        #expect(try Data(contentsOf: store.fileURL) != before)
        #expect(try store.loadAll(now: .fixture).isEmpty)
    }

    @Test
    func deletingFromAStoreThatWasNeverWrittenIsASilentNoOp() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)

        try store.delete(id: "anything", now: .fixture)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
        #expect(try store.loadAll(now: .fixture).isEmpty)
    }

    @Test
    func loadingReturnsTheMostRecentlyActiveFirst() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)

        for (offset, name) in [(-100.0, "older"), (-10.0, "newer")] {
            var task = sample(command: name)
            task.id = name
            task.updatedAt = Date(timeInterval: offset, since: .fixture)
            try store.save(task, now: .fixture)
        }

        #expect(try store.loadAll(now: .fixture).map(\.id) == ["newer", "older"])
    }

    // MARK: - What a resume actually runs

    @Test
    func theRemainingPlanIsThePlanMinusTheStepsThatFinished() {
        var task = sample(command: "Zip my files")
        task.completedStepIDs = ["calc"]

        #expect(task.remainingSteps.map(\.id) == ["url"])
        #expect(task.remainingPlan().steps.map(\.id) == ["url"])
        // The summary is the task the user asked for and is kept verbatim — the offer names it and
        // the resumed run's history row carries it.
        #expect(task.remainingPlan().summary == task.plan.summary)
        #expect(task.remainingPlan().requiresConfirmation == task.plan.requiresConfirmation)
        #expect(task.isResumable)
    }

    /// A record whose plan is entirely accounted for offers nothing. Unreachable from a settled run
    /// — one that got through its last unit completed and was deleted — and reachable from a file,
    /// which is where this comes back from.
    @Test
    func aRecordWithNothingLeftIsNotResumable() {
        var task = sample(command: "Zip my files")
        task.completedStepIDs = ["calc", "url"]

        #expect(task.remainingSteps.isEmpty)
        #expect(!task.isResumable)
    }

    /// An id naming no step subtracts nothing and must not be kept, in either direction. Kept, it
    /// would make the record read as further along than it is.
    @Test
    func completedIdsThatNameNoStepAreDroppedOnConstructionAndOnDecode() throws {
        let built = ResumableTask(
            command: "Zip my files",
            plan: samplePlan,
            completedStepIDs: ["calc", "not-a-step"],
            startedAt: .fixture,
            updatedAt: .fixture
        )
        #expect(built.completedStepIDs == ["calc"])

        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("resumable-tasks.json")
        // Written as plaintext so the decode path is exercised over bytes this test controls, rather
        // than over bytes the initializer above has already cleaned.
        let hostile = """
        [{"id":"x","command":"Zip my files","plan":{"summary":"s","requiresConfirmation":false,\
        "steps":[{"id":"calc","operation":"calculate_utility","description":"d"}]},\
        "completedStepIDs":["calc","not-a-step"],"startedAt":"2023-11-14T22:13:20Z",\
        "updatedAt":"2023-11-14T22:13:20Z","stopReason":"interrupted"}]
        """
        try Data(hostile.utf8).write(to: url, options: .atomic)

        let store = ResumableTaskStore(fileURL: url, encryption: testEncryption())
        #expect(try store.loadAll(now: .fixture).map(\.completedStepIDs) == [["calc"]])
    }

    /// The command is display text, so it is trimmed — and trimmed on the way back in too, for the
    /// reason `StoredTaskPlanDetail` gives: a rule the decode path skips holds in one direction only.
    @Test
    func anOverlongCommandIsCappedOnBothDoors() throws {
        let long = String(repeating: "a", count: ResumableTask.maxCommandCharacters + 50)
        let built = ResumableTask(command: long, plan: samplePlan, startedAt: .fixture, updatedAt: .fixture)
        #expect(built.command.count == ResumableTask.maxCommandCharacters)
        #expect(built.command.hasSuffix("\u{2026}"))

        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        try store.save(built, now: .fixture)
        #expect(try store.loadAll(now: .fixture).map(\.command.count) == [ResumableTask.maxCommandCharacters])
    }

    /// **The one cap that refuses rather than trims, and the reason it must.** Every other store here
    /// caps by truncating text that is read back to be shown; this plan is read back to be *executed*,
    /// so a trimmed plan would run a different task from the one the user started.
    @Test
    func anOversizedPlanIsRefusedAndNothingIsWritten() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)

        let huge = AgentPlan(
            summary: "Draft something enormous",
            requiresConfirmation: false,
            steps: [
                AgentStep(
                    id: "draft",
                    operation: .createLocalDraft,
                    description: "Draft.",
                    draftTitle: "Notes",
                    draftContent: String(repeating: "x", count: ResumableTaskStore.maxEncodedPlanBytes + 1)
                )
            ]
        )
        let task = ResumableTask(command: "Draft it", plan: huge, startedAt: .fixture, updatedAt: .fixture)

        #expect(throws: ResumableTaskStoreError.self) {
            try store.save(task, now: .fixture)
        }
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))

        // The control: the same plan under the limit is kept whole, so the refusal is about size and
        // not about `create_local_draft`.
        let fits = AgentPlan(
            summary: "Draft something ordinary",
            requiresConfirmation: false,
            steps: [
                AgentStep(
                    id: "draft",
                    operation: .createLocalDraft,
                    description: "Draft.",
                    draftTitle: "Notes",
                    draftContent: String(repeating: "x", count: 1_000)
                )
            ]
        )
        try store.save(
            ResumableTask(command: "Draft it", plan: fits, startedAt: .fixture, updatedAt: .fixture),
            now: .fixture
        )
        #expect(try store.loadAll(now: .fixture).first?.plan.steps.first?.draftContent?.count == 1_000)
    }

    // MARK: - Constructed the way production constructs one

    /// Nothing in `Sources/` narrows the idle period or the cap — both are injectable so a test can
    /// reach them without waiting a fortnight or writing twenty-one records, exactly as
    /// `TaskPlanDetailStore.maxDetails` is, and a production path that passed either would be
    /// changing the founder's lifecycle by a parameter.
    ///
    /// A source scan rather than a runtime assertion, because there is no object to interrogate: the
    /// thing being asserted is the absence of an argument at a call site.
    @Test
    func noProductionPathPassesAnIdleExpiryOrCapToTheResumableStore() throws {
        var constructionSites = 0
        var offenders: [String] = []

        for file in try shippedSwiftFiles() {
            let lines = TestSourceTree.codeLines(of: try String(contentsOf: file, encoding: .utf8))
            for (index, line) in lines.enumerated() where line.text.contains("ResumableTaskStore(") {
                constructionSites += 1
                // The construction and the few lines under it, because an argument list can be
                // written across several. Six is comfortably more than the longest construction in
                // this repository and short enough not to reach a neighbouring one.
                let window = lines[index..<min(index + 6, lines.count)].map(\.text).joined(separator: "\n")
                if window.contains("idleExpiry:") || window.contains("maxTasks:") {
                    offenders.append("\(file.lastPathComponent):\(line.number)")
                }
            }
        }

        #expect(offenders.isEmpty, "these pass a narrowed lifecycle to the shipped store: \(offenders)")
        // And the scan really reached the construction sites, so an empty `offenders` is a finding
        // rather than a search that matched nothing: the store's own wipe entry, the classification's
        // URL resolver, and the view model's default parameter.
        #expect(constructionSites >= 3, "expected the wipe list, the classification and the view model")
    }

    /// Every Swift file in the two shipped targets. Its own walker rather than
    /// `TestSourceTree.swiftFiles(in:)`, which resolves against `Tests/` and takes a test target.
    private func shippedSwiftFiles() throws -> [URL] {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
        var files: [URL] = []
        for target in ["MacAgentCore", "MacAgent"] {
            let directory = sources.appendingPathComponent(target)
            guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
                Issue.record("Could not read \(directory.path)")
                continue
            }
            for case let url as URL in walker where url.pathExtension == "swift" {
                files.append(url)
            }
        }
        #expect(files.count > 100, "the walk found \(files.count) files, which is not the shipped tree")
        return files.sorted { $0.path < $1.path }
    }

    // MARK: - Fixtures

    private var samplePlan: AgentPlan {
        AgentPlan(
            summary: "Work out a number, then open a page.",
            requiresConfirmation: false,
            steps: [
                AgentStep(id: "calc", operation: .calculateUtility, description: "Add them up.", searchQuery: "2 + 2"),
                AgentStep(
                    id: "url",
                    operation: .openURL,
                    description: "Open the page.",
                    targetURL: "https://example.com/page"
                )
            ]
        )
    }

    private func sample(command: String) -> ResumableTask {
        ResumableTask(
            id: "sample",
            command: command,
            plan: samplePlan,
            startedAt: .fixture,
            updatedAt: .fixture
        )
    }

    private func makeStore(
        root: URL,
        idleExpiry: TimeInterval = ResumableTaskStore.defaultIdleExpiry,
        maxTasks: Int = ResumableTaskStore.defaultMaxTasks
    ) -> ResumableTaskStore {
        ResumableTaskStore(
            fileURL: root.appendingPathComponent("resumable-tasks.json"),
            encryption: testEncryption(),
            idleExpiry: idleExpiry,
            maxTasks: maxTasks
        )
    }
}

private extension Date {
    static let fixture = Date(timeIntervalSince1970: 1_700_000_000)
}
