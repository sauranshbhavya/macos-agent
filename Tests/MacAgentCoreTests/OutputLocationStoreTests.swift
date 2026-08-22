import Foundation
import Testing
@testable import MacAgentCore

/// `OutputLocationStore`'s own rules (SONNY-209): what counts as an output location, how a folder
/// accumulates weight, which folder is offered first, and what falls off the end.
///
/// The *wiring* — whether anything ever calls this, and whether the memory switches are consulted
/// when it does — is pinned in `MemoryCommandCenterTests` through the real dispatch doors. A store
/// that behaves correctly proves nothing about whether a run reaches it, which is the split the
/// Memory tests already draw.
@Suite
struct OutputLocationStoreTests {
    // MARK: - What counts as an output location

    @Test
    func recordsTheFolderAFileWasWrittenIntoRatherThanTheFileItself() throws {
        let fixture = try OutputLocationFixture()
        defer { fixture.cleanUp() }
        let reports = try fixture.makeOutputFolder("Reports")

        let recorded = try fixture.store.recordOutputs(
            atPaths: [reports.appendingPathComponent("q3.md").path],
            recordedAt: .fixture
        )

        #expect(recorded.map(\.path) == [reports.path])
        #expect(recorded.first?.name == "Reports")
        #expect(recorded.first?.useCount == 1)
        #expect(recorded.first?.firstUsedAt == .fixture)
        #expect(recorded.first?.lastUsedAt == .fixture)
        // The file is not what is stored, which is the whole distinction from `RecentArtifactStore`.
        #expect(try fixture.store.loadAll(now: .fixture).map(\.path) == [reports.path])
    }

    /// **The rule that keeps Sonny's own bookkeeping out of the list.** Four of the eight adapters
    /// that publish `ActionPreview.writes` write a store's JSON under Application Support, which is
    /// never a whitelist root — so the whitelist is what tells "the user's output landed here" apart
    /// from "Sonny saved its own file". Modelled here with a directory beside the whitelist rather
    /// than with the real Application Support path, so the assertion is about the rule and not about
    /// the developer's own Mac.
    @Test
    func aWriteOutsideTheWhitelistIsNotAnOutputLocation() throws {
        let fixture = try OutputLocationFixture()
        defer { fixture.cleanUp() }
        let sonnysOwnDirectory = fixture.root.appendingPathComponent("Application Support", isDirectory: true)
        try FileManager.default.createDirectory(at: sonnysOwnDirectory, withIntermediateDirectories: true)

        let recorded = try fixture.store.recordOutputs(
            atPaths: [sonnysOwnDirectory.appendingPathComponent("routines.json").path],
            recordedAt: .fixture
        )

        #expect(recorded.isEmpty)
        #expect(try fixture.store.loadAll(now: .fixture).isEmpty)
    }

    /// The control for the test above: the same call shape, one path inside the whitelist and one
    /// outside, so a store that recorded *nothing* would fail here rather than look correct.
    @Test
    func aRunThatWritesBothAnOutputAndAStoreFileRecordsOnlyTheOutput() throws {
        let fixture = try OutputLocationFixture()
        defer { fixture.cleanUp() }
        let reports = try fixture.makeOutputFolder("Reports")
        let sonnysOwnDirectory = fixture.root.appendingPathComponent("Application Support", isDirectory: true)
        try FileManager.default.createDirectory(at: sonnysOwnDirectory, withIntermediateDirectories: true)

        let recorded = try fixture.store.recordOutputs(
            atPaths: [
                reports.appendingPathComponent("q3.md").path,
                sonnysOwnDirectory.appendingPathComponent("routines.json").path
            ],
            recordedAt: .fixture
        )

        #expect(recorded.map(\.path) == [reports.path])
    }

    @Test
    func aWriteIntoAFolderThatDoesNotExistIsNotRecorded() throws {
        let fixture = try OutputLocationFixture()
        defer { fixture.cleanUp() }
        let missing = fixture.outputsRoot.appendingPathComponent("Nowhere", isDirectory: true)

        let recorded = try fixture.store.recordOutputs(
            atPaths: [missing.appendingPathComponent("q3.md").path],
            recordedAt: .fixture
        )

        #expect(recorded.isEmpty)
    }

    @Test
    func anEmptyOrWhitespaceOnlyPathIsNotRecorded() throws {
        let fixture = try OutputLocationFixture()
        defer { fixture.cleanUp() }

        #expect(try fixture.store.recordOutputs(atPaths: ["", "   ", "\n"], recordedAt: .fixture).isEmpty)
        #expect(try fixture.store.loadAll(now: .fixture).isEmpty)
    }

    // MARK: - How weight accumulates

    @Test
    func asecondRunIntoTheSameFolderBumpsItsCountAndWidensItsWindow() throws {
        let fixture = try OutputLocationFixture()
        defer { fixture.cleanUp() }
        let reports = try fixture.makeOutputFolder("Reports")
        let later = Date(timeInterval: 86_400, since: .fixture)

        try fixture.store.recordOutputs(
            atPaths: [reports.appendingPathComponent("q3.md").path],
            recordedAt: .fixture
        )
        try fixture.store.recordOutputs(
            atPaths: [reports.appendingPathComponent("q4.md").path],
            recordedAt: later
        )

        let stored = try #require(try fixture.store.location(for: reports.path))
        #expect(stored.useCount == 2)
        #expect(stored.firstUsedAt == .fixture)
        #expect(stored.lastUsedAt == later)
        // One folder, one record — two would mean the same destination competing with itself.
        #expect(try fixture.store.loadAll(now: later).count == 1)
    }

    /// **A run is one use, however many files it wrote.** A batch converting thirty documents into
    /// one folder would otherwise give that folder thirty times the weight of a folder someone
    /// deliberately chose thirty separate times.
    @Test
    func oneRunWritingSeveralFilesIntoOneFolderCountsAsASingleUse() throws {
        let fixture = try OutputLocationFixture()
        defer { fixture.cleanUp() }
        let reports = try fixture.makeOutputFolder("Reports")

        let recorded = try fixture.store.recordOutputs(
            atPaths: (1...5).map { reports.appendingPathComponent("doc-\($0).pdf").path },
            recordedAt: .fixture
        )

        #expect(recorded.count == 1)
        #expect(try fixture.store.location(for: reports.path)?.useCount == 1)
    }

    /// A record arriving with an older timestamp than one already stored widens the window instead
    /// of inverting it — a clock that moved backwards must not produce a record whose first use is
    /// later than its last.
    @Test
    func anOutOfOrderRecordWidensTheWindowRatherThanInvertingIt() throws {
        let fixture = try OutputLocationFixture()
        defer { fixture.cleanUp() }
        let reports = try fixture.makeOutputFolder("Reports")
        let earlier = Date(timeInterval: -86_400, since: .fixture)

        try fixture.store.recordOutputs(atPaths: [reports.appendingPathComponent("a.md").path], recordedAt: .fixture)
        try fixture.store.recordOutputs(atPaths: [reports.appendingPathComponent("b.md").path], recordedAt: earlier)

        let stored = try #require(try fixture.store.location(for: reports.path))
        #expect(stored.firstUsedAt == earlier)
        #expect(stored.lastUsedAt == .fixture)
        #expect(stored.firstUsedAt <= stored.lastUsedAt)
    }

    /// Two spellings of one folder are one record.
    ///
    /// Exercised with a `..` traversal rather than with a case difference, deliberately: whether
    /// `REPORTS` and `Reports` are even two spellings of one directory depends on the volume, and a
    /// test whose meaning changes with the developer's filesystem is not a test. `..` collapses
    /// identically everywhere, and it goes through the same `PathWhitelist.canonicalURL` half of the
    /// key that resolves a symlinked temporary directory in production. The case half of the key —
    /// `DestinationKey.folded` — is pinned by `theDeleteDoorFoldsCaseTheSameWayTheRecordDoorDoes`
    /// below, which deletes the folder first so that canonicalisation cannot answer for the fold.
    /// (That pointer named the right test and the test did not hold it, until PR #101's review, F2.)
    @Test
    func twoSpellingsOfOneFolderAreOneRecord() throws {
        let fixture = try OutputLocationFixture()
        defer { fixture.cleanUp() }
        let reports = try fixture.makeOutputFolder("Reports")
        let roundabout = fixture.outputsRoot
            .appendingPathComponent("Reports", isDirectory: true)
            .appendingPathComponent("..", isDirectory: true)
            .appendingPathComponent("Reports", isDirectory: true)

        try fixture.store.recordOutputs(atPaths: [reports.appendingPathComponent("a.md").path], recordedAt: .fixture)
        try fixture.store.recordOutputs(atPaths: [roundabout.appendingPathComponent("b.md").path], recordedAt: .fixture)

        #expect(try fixture.store.loadAll(now: .fixture).map(\.path) == [reports.path])
        #expect(try fixture.store.location(for: roundabout.path)?.useCount == 2)
    }

    // MARK: - Which folder is offered first

    /// Recency-decayed frequency, computed by hand rather than by re-running the implementation's
    /// own arithmetic: at a thirty-day half-life, a folder used twice a year ago is worth
    /// `2 x 0.5^(365/30)` — about 0.00028 — and loses to one used once yesterday, worth about 0.977.
    @Test
    func aFolderUsedOnceYesterdayOutranksOneUsedTwiceAYearAgo() throws {
        let fixture = try OutputLocationFixture()
        defer { fixture.cleanUp() }
        let now = Date.fixture
        let archive = try fixture.makeOutputFolder("Archive")
        let current = try fixture.makeOutputFolder("Current")

        let aYearAgo = Date(timeInterval: -365 * 86_400, since: now)
        try fixture.store.recordOutputs(atPaths: [archive.appendingPathComponent("a.md").path], recordedAt: aYearAgo)
        try fixture.store.recordOutputs(atPaths: [archive.appendingPathComponent("b.md").path], recordedAt: aYearAgo)
        try fixture.store.recordOutputs(
            atPaths: [current.appendingPathComponent("c.md").path],
            recordedAt: Date(timeInterval: -86_400, since: now)
        )

        #expect(try fixture.store.loadAll(now: now).map(\.name) == ["Current", "Archive"])
        // And the frequency half is not merely ignored: with both used at the same moment, the one
        // used more often wins — the assertion that fails if the score collapsed to pure recency.
        let sameDay = try fixture.makeOutputFolder("SameDay")
        try fixture.store.recordOutputs(
            atPaths: [sameDay.appendingPathComponent("d.md").path],
            recordedAt: Date(timeInterval: -86_400, since: now)
        )
        try fixture.store.recordOutputs(
            atPaths: [sameDay.appendingPathComponent("e.md").path],
            recordedAt: Date(timeInterval: -86_400, since: now)
        )
        #expect(try fixture.store.loadAll(now: now).map(\.name) == ["SameDay", "Current", "Archive"])
    }

    @Test
    func suggestionsAreTheRankedListCutToTheAskedForLength() throws {
        let fixture = try OutputLocationFixture()
        defer { fixture.cleanUp() }
        let now = Date.fixture
        for (index, name) in ["A", "B", "C"].enumerated() {
            let folder = try fixture.makeOutputFolder(name)
            try fixture.store.recordOutputs(
                atPaths: [folder.appendingPathComponent("f.md").path],
                recordedAt: Date(timeInterval: -Double(index) * 86_400, since: now)
            )
        }

        #expect(try fixture.store.suggestedDestinations(limit: 2, now: now).map(\.name) == ["A", "B"])
        #expect(try fixture.store.suggestedDestinations(limit: 0, now: now).isEmpty)
        // A negative limit is clamped rather than trapping on `prefix`.
        #expect(try fixture.store.suggestedDestinations(limit: -3, now: now).isEmpty)
    }

    /// Ties are broken deterministically, because a dictionary's values arrive in no defined order
    /// and a list that reshuffled between two identical loads would look alive when nothing changed.
    @Test
    func twoLocationsWithIdenticalWeightKeepAStableOrder() throws {
        let fixture = try OutputLocationFixture()
        defer { fixture.cleanUp() }
        let now = Date.fixture
        for name in ["Bravo", "Alpha", "Charlie"] {
            let folder = try fixture.makeOutputFolder(name)
            try fixture.store.recordOutputs(atPaths: [folder.appendingPathComponent("f.md").path], recordedAt: now)
        }

        let first = try fixture.store.loadAll(now: now).map(\.name)
        let second = try fixture.store.loadAll(now: now).map(\.name)
        #expect(first == second)
        #expect(first == ["Alpha", "Bravo", "Charlie"])
    }

    // MARK: - What falls off the end

    /// **Eviction is least-recently-used, and this is the property that choice was made for**: a
    /// brand-new folder always gets in. Under score-based eviction a full store of heavy hitters
    /// would give every new folder a score of 1.0, below theirs, so a person starting a new project
    /// would watch Sonny keep offering last quarter's folders and never learn the new one.
    @Test
    func aFullStoreStillAdmitsABrandNewFolderAndDropsTheStalestOne() throws {
        let fixture = try OutputLocationFixture()
        defer { fixture.cleanUp() }
        let now = Date.fixture

        // `maxItems` heavy hitters, each used far more than once and each older than the next.
        for index in 0..<OutputLocationStore.maxItems {
            let folder = try fixture.makeOutputFolder("Heavy-\(index)")
            for use in 0..<3 {
                try fixture.store.recordOutputs(
                    atPaths: [folder.appendingPathComponent("f-\(use).md").path],
                    recordedAt: Date(timeInterval: -Double(index + 1) * 86_400, since: now)
                )
            }
        }
        #expect(try fixture.store.loadAll(now: now).count == OutputLocationStore.maxItems)

        let newcomer = try fixture.makeOutputFolder("Newcomer")
        try fixture.store.recordOutputs(
            atPaths: [newcomer.appendingPathComponent("f.md").path],
            recordedAt: now
        )

        let stored = try fixture.store.loadAll(now: now)
        #expect(stored.count == OutputLocationStore.maxItems)
        #expect(stored.contains { $0.name == "Newcomer" })
        // The stalest went, not the least-used: every heavy hitter has three uses to the newcomer's
        // one, so a lowest-score rule would have dropped the newcomer instead.
        #expect(!stored.contains { $0.name == "Heavy-\(OutputLocationStore.maxItems - 1)" })
        #expect(stored.contains { $0.name == "Heavy-0" })
    }

    // MARK: - Forgetting

    @Test
    func forgettingOneLocationLeavesTheRestAndTheFoldersThemselves() throws {
        let fixture = try OutputLocationFixture()
        defer { fixture.cleanUp() }
        let reports = try fixture.makeOutputFolder("Reports")
        let invoices = try fixture.makeOutputFolder("Invoices")
        try fixture.store.recordOutputs(atPaths: [reports.appendingPathComponent("a.md").path], recordedAt: .fixture)
        try fixture.store.recordOutputs(atPaths: [invoices.appendingPathComponent("b.md").path], recordedAt: .fixture)

        try fixture.store.forget(path: reports.path)

        #expect(try fixture.store.loadAll(now: .fixture).map(\.name) == ["Invoices"])
        #expect(FileManager.default.fileExists(atPath: reports.path))
    }

    @Test
    func forgettingAPathThatIsNotStoredIsANoOp() throws {
        let fixture = try OutputLocationFixture()
        defer { fixture.cleanUp() }
        let reports = try fixture.makeOutputFolder("Reports")
        try fixture.store.recordOutputs(atPaths: [reports.appendingPathComponent("a.md").path], recordedAt: .fixture)

        try fixture.store.forget(path: fixture.outputsRoot.appendingPathComponent("Elsewhere").path)

        #expect(try fixture.store.loadAll(now: .fixture).count == 1)
    }

    /// The delete and read doors fold case the same way the record door does, so a person removing a
    /// row rendered from one spelling really removes the record stored under the other.
    ///
    /// **The folder is deleted first, and that is the whole of what makes this test its own
    /// subject** (PR #101 review, F2). The previous version recorded into `Outputs/Reports` and
    /// forgot `Outputs/REPORTS` with the folder still on disk, and it passed with
    /// `DestinationKey.folded` removed from `storageKey` outright — its doc said "no filesystem is
    /// involved on this path", which was backwards on both halves. `PathWhitelist.canonicalURL` ends
    /// in `resolvingSymlinksInPath()`, and **Foundation's** version of that — unlike POSIX
    /// `realpath`, which does not — returns the on-disk casing for a path whose components all exist.
    /// Measured at `b74984d` by creating `Outputs/Reports` and canonicalising `Outputs/REPORTS`: it
    /// came back `.../Outputs/Reports` while the directory was there, and `.../Outputs/REPORTS` once
    /// it was deleted. So with the folder present the filesystem answers the question before the fold
    /// is ever consulted, and the test was watching the volume rather than the code it named.
    ///
    /// Deleting the folder takes the filesystem out of the comparison, which is also the ordinary
    /// moment somebody opens the Memory page to forget a note: the folder is gone, and the note about
    /// it is what is left. Only the case fold can match the two spellings then — asserted below as a
    /// precondition rather than assumed, so this cannot quietly go vacuous again.
    ///
    /// **Volume-independent in the direction that matters.** The precondition asserted is the
    /// *post*-deletion one, which holds on a case-sensitive volume too, where `REPORTS` never existed
    /// to be normalised. The pre-deletion behaviour is recorded above as prose, not asserted, because
    /// that one really is a fact about the volume.
    @Test
    func theDeleteDoorFoldsCaseTheSameWayTheRecordDoorDoes() throws {
        let fixture = try OutputLocationFixture()
        defer { fixture.cleanUp() }
        let reports = try fixture.makeOutputFolder("Reports")
        try fixture.store.recordOutputs(atPaths: [reports.appendingPathComponent("a.md").path], recordedAt: .fixture)

        try FileManager.default.removeItem(at: reports)
        let shouted = fixture.outputsRoot.appendingPathComponent("REPORTS", isDirectory: true).path
        #expect(
            PathWhitelist.canonicalURL(shouted).path != reports.path,
            "Precondition: with the folder gone, canonicalisation must leave the casing alone, so the case fold is the only thing that can match these two spellings. If this fails, the assertions below prove nothing about DestinationKey.folded."
        )

        // The read door first: it is the one a row is rendered from.
        #expect(try fixture.store.location(for: shouted)?.name == "Reports")

        try fixture.store.forget(path: shouted)

        #expect(try fixture.store.loadAll(now: .fixture).isEmpty)
    }

    // MARK: - The run-shaped door

    /// `recordOutputs(from:)` reads `ActionPreview.writes` — what each executed unit really produced
    /// — and nothing else. Built from a result that carries one output write and one store write, so
    /// the assertion covers the split rather than only the happy path.
    @Test
    func recordingFromARunResultReadsItsPreviewWrites() throws {
        let fixture = try OutputLocationFixture()
        defer { fixture.cleanUp() }
        let reports = try fixture.makeOutputFolder("Reports")
        let sonnysOwnDirectory = fixture.root.appendingPathComponent("Application Support", isDirectory: true)
        try FileManager.default.createDirectory(at: sonnysOwnDirectory, withIntermediateDirectories: true)

        let result = AgentRunResult(
            plan: AgentPlan(summary: "Draft and save.", requiresConfirmation: false, steps: []),
            previews: [
                ActionPreview(title: "Create local draft", writes: [reports.appendingPathComponent("q3.md").path]),
                ActionPreview(title: "Save routine", writes: [sonnysOwnDirectory.appendingPathComponent("routines.json").path])
            ],
            summary: "Done."
        )

        let recorded = try fixture.store.recordOutputs(from: result, recordedAt: .fixture)

        #expect(recorded.map(\.path) == [reports.path])
    }

    @Test
    func aRunThatWroteNothingRecordsNothingAndLeavesNoFile() throws {
        let fixture = try OutputLocationFixture()
        defer { fixture.cleanUp() }
        let result = AgentRunResult(
            plan: AgentPlan(summary: "Calculate.", requiresConfirmation: false, steps: []),
            previews: [ActionPreview(title: "Calculate", details: ["2"])],
            summary: "2."
        )

        #expect(try fixture.store.recordOutputs(from: result, recordedAt: .fixture).isEmpty)
        // No file at all, rather than an empty encrypted one — a store that wrote on every run would
        // create `output-locations.json` for a user who has never produced an output.
        #expect(!FileManager.default.fileExists(atPath: fixture.store.fileURL.path))
    }

    // MARK: - Display

    @Test
    func aLocationRendersItsFolderNameAndATildeAbbreviatedPath() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let location = OutputLocation(
            path: "\(home)/Documents/Reports",
            useCount: 3,
            firstUsedAt: .fixture,
            lastUsedAt: .fixture
        )

        #expect(location.name == "Reports")
        #expect(location.displayPath == "~/Documents/Reports")
        // The identity a row is keyed by is the folder itself, not a generated id.
        #expect(location.id == location.path)
    }

    /// A root directory's last path component is empty, so `name` falls back to the whole path
    /// rather than rendering a row with a blank title.
    @Test
    func aRootDirectoryStillHasAName() {
        let location = OutputLocation(path: "/", useCount: 1, firstUsedAt: .fixture, lastUsedAt: .fixture)

        #expect(location.name == "/")
    }
}

/// A whitelist root that is **not** the directory the store's own file lives in, mirroring
/// production: Sonny's stores live under Application Support and the user's outputs never do. A
/// fixture that put both in one directory could not tell "recorded the user's folder" apart from
/// "recorded Sonny's own".
private struct OutputLocationFixture {
    let root: URL
    let outputsRoot: URL
    let store: OutputLocationStore

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OutputLocationStoreTests-\(UUID().uuidString)", isDirectory: true)
        outputsRoot = root.appendingPathComponent("Outputs", isDirectory: true)
        try FileManager.default.createDirectory(at: outputsRoot, withIntermediateDirectories: true)
        store = OutputLocationStore(
            fileURL: root.appendingPathComponent("output-locations.json"),
            encryption: testEncryption(),
            whitelist: PathWhitelist(roots: [outputsRoot])
        )
    }

    func makeOutputFolder(_ name: String) throws -> URL {
        let folder = outputsRoot.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // `PathWhitelist.canonicalURL` resolves symlinks, and the temporary directory is one on
        // macOS (`/var` -> `/private/var`), so the store records the resolved path. Returning the
        // resolved form is what lets a test compare paths rather than compare two spellings.
        return PathWhitelist.canonicalURL(folder.path)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}

private extension Date {
    static let fixture = Date(timeIntervalSince1970: 1_700_000_000)
}
