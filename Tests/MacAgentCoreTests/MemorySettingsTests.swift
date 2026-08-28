import Foundation
import Testing
@testable import MacAgentCore

/// The memory model itself (SONNY-208): which store belongs to which of Command Center's Memory
/// rows, what each switch withholds, and the entry points the section needs to remove one thing
/// rather than everything.
///
/// The wiring these values drive — a real dispatch refusing to save a routine, a run leaving no
/// history row — is pinned in `MemoryCommandCenterTests` in the app target, because a value type
/// answering correctly proves nothing about whether anybody asks it.
@Suite
struct MemorySettingsTests {
    // MARK: - The mapping

    /// **The exhaustiveness guard, in the direction the compiler cannot check.** `memoryCategory`'s
    /// switch has no `default`, so a fourteenth `LocalStore` fails to compile until someone answers for
    /// it — but "answers" includes answering `nil`, and a store excluded by accident is invisible in
    /// the surface built to show the user everything Sonny remembers. This asserts the union
    /// explicitly, so an exclusion has to be a decision recorded in a test rather than a shrug.
    @Test
    func everyLocalStoreIsPlacedUnderExactlyOneMemoryCategoryOrDeliberatelyExcluded() {
        // The only store the Memory section does not show, and the reason is on the case: this file
        // *is* the clipboard switch, so listing it would offer to delete a preference.
        let deliberatelyExcluded: Set<LocalStore> = [.clipboardHistorySettings]

        let placed = Set(LocalStore.allCases.filter { $0.memoryCategory != nil })
        #expect(placed.union(deliberatelyExcluded) == Set(LocalStore.allCases))
        #expect(placed.isDisjoint(with: deliberatelyExcluded))

        // Each placed store appears under exactly one row — `stores` filters `allCases`, so a
        // duplicate could only come from the mapping answering twice, which it cannot; asserting
        // the total is what makes that structural rather than assumed.
        let coveredByRows = MemoryCategory.allCases.flatMap(\.stores)
        #expect(Set(coveredByRows) == placed)
        #expect(coveredByRows.count == placed.count, "a store was counted under two rows")
    }

    /// The grouping the Memory section renders rests on this: each row's stores share one
    /// `LocalStoreKind`, so a row can be filed under "saved by you" or "recorded as Sonny works"
    /// without the page inventing a taxonomy of its own. It is a fact about the mapping rather than
    /// something the types guarantee, so it is asserted rather than assumed.
    @Test
    func everyMemoryRowsStoresShareOneKindSoTheRowCanBeGroupedByIt() {
        for category in MemoryCategory.allCases {
            let kinds = Set(category.stores.map(\.kind))
            #expect(kinds.count == 1, "\(category.title) spans \(kinds.count) store kinds")
            #expect(kinds.first == category.storeKind)
            // `.notWrittenByTasks` is unreachable here — its one store is the clipboard switch,
            // which no row covers. A row that reached it would be a row offering to stop recording
            // something no task records.
            #expect(category.storeKind != .notWrittenByTasks, "\(category.title)")
        }

        // Both groups are non-empty, which is what makes the two-section rendering honest rather
        // than one section and an empty header.
        #expect(MemoryCategory.allCases.contains { $0.storeKind == .artifact })
        #expect(MemoryCategory.allCases.contains { $0.storeKind == .trace })
    }

    @Test
    func everyMemoryRowCoversAtLeastOneStore() {
        for category in MemoryCategory.allCases {
            #expect(!category.stores.isEmpty, "\(category.title) shows no store at all")
        }
    }

    /// **Every row's count names what it counts** (SONNY-243).
    ///
    /// The founder read `1 saved` on the Output locations row beside `2 times` in its sheet and
    /// reported the pair as a bug. Both numbers were right; "saved" named no unit, so nothing said
    /// that one counted folders and the other counted one folder's uses. The repair is a noun on
    /// every row, and this is the population check on it — a tenth category cannot arrive without
    /// one, and cannot arrive with a plural that was never written.
    @Test
    func everyMemoryRowsCountNamesTheThingItCounts() {
        for category in MemoryCategory.allCases {
            let one = category.countedEntries(1)
            let two = category.countedEntries(2)
            let none = category.countedEntries(0)

            #expect(one == "1 \(category.singularNoun)", "\(category.title)")
            #expect(two == "2 \(category.pluralNoun)", "\(category.title)")
            // Zero takes the plural, which is the form the empty row renders.
            #expect(none == "0 \(category.pluralNoun)", "\(category.title)")

            // A noun, not a bare number and not the unitless word this replaced.
            #expect(!category.singularNoun.isEmpty, "\(category.title) counts nothing in particular")
            #expect(category.singularNoun == category.singularNoun.lowercased(), "\(category.title)")
            #expect(category.pluralNoun == category.pluralNoun.lowercased(), "\(category.title)")
            for noun in [category.singularNoun, category.pluralNoun] {
                #expect(!noun.contains("saved"), "\(category.title) still infers its unit")
            }

            // A copied singular is the mistake this catches: nine nouns written by hand, and the
            // one that reads "2 copied item" is invisible to a test that only checks presence.
            #expect(category.singularNoun != category.pluralNoun, "\(category.title) is not pluralised")
        }
    }

    /// The two nouns the row and its sheet each need, pinned by value.
    ///
    /// `outputLocations` is the row the founder reported and `resumableTasks` is the one the ticket
    /// asked to check beside it. Both are spelled out here rather than left to the population check
    /// above, which cannot tell a right noun from a plausible one.
    @Test
    func theRowsTheFounderComparedNameFoldersAndUnfinishedTasks() {
        #expect(MemoryCategory.outputLocations.countedEntries(1) == "1 folder")
        #expect(MemoryCategory.outputLocations.countedEntries(3) == "3 folders")
        // Not "1 task": task history's rows are tasks too, the two rows sit on one page, and the
        // stores are disjoint — so a bare noun here invites adding the two counts together.
        #expect(MemoryCategory.resumableTasks.countedEntries(1) == "1 unfinished task")
        #expect(MemoryCategory.taskHistory.countedEntries(184) == "184 tasks")
        #expect(MemoryCategory.clipboardHistory.countedEntries(12) == "12 copied items")
    }

    /// Task history is the one row that speaks for more than one file, and the three it carries are
    /// named rather than counted: a reader wondering where screen records go should find the answer
    /// in an assertion, not in a number.
    @Test
    func taskHistoryCarriesThePlanDetailsScreenRecordsAndShortcutHistoryHangingOffIt() {
        #expect(
            Set(MemoryCategory.taskHistory.stores) == [
                .visionSessionJournal,
                .shortcutRunHistory,
                .taskHistory,
                .taskPlanDetails
            ]
        )
    }

    /// Row 13's output locations is its own row over its own single store, and it is a *record* of
    /// what happened rather than something the user asked Sonny to save (SONNY-209).
    ///
    /// Named rather than left to the population tests above, because the decision that could have
    /// gone the other way is folding it into `recentArtifacts` — the two are neighbours, both
    /// `.trace`, and one notes the file where the other notes the folder. `MemoryCategory
    /// .outputLocations`' own doc carries the argument; this is the assertion that fails if somebody
    /// merges them.
    @Test
    func outputLocationsIsItsOwnRecordedRowOverItsOwnStore() {
        #expect(MemoryCategory.outputLocations.stores == [.outputLocations])
        #expect(MemoryCategory.outputLocations.storeKind == .trace)
        #expect(LocalStore.outputLocations.memoryCategory == .outputLocations)
        #expect(MemoryCategory.recentArtifacts.stores == [.recentArtifacts])
    }

    /// Each of the two switches withholds its own store and leaves the other's alone — the assertion
    /// that fails if the two neighbouring rows were ever wired to one flag.
    @Test
    func theOutputLocationsSwitchAndTheRecentArtifactsSwitchAreIndependent() {
        let outputsOff = MemoryRecordingSettings(categoriesDisabledByUser: [.outputLocations])
        #expect(!outputsOff.allowsRecording(to: .outputLocations))
        #expect(outputsOff.allowsRecording(to: .recentArtifacts))

        let artifactsOff = MemoryRecordingSettings(categoriesDisabledByUser: [.recentArtifacts])
        #expect(!artifactsOff.allowsRecording(to: .recentArtifacts))
        #expect(artifactsOff.allowsRecording(to: .outputLocations))
    }

    // MARK: - What each switch withholds

    @Test
    func theMasterSwitchOffWithholdsEveryCategory() {
        let settings = MemoryRecordingSettings(isEnabledByUser: false)

        #expect(!settings.isRecording)
        for category in MemoryCategory.allCases {
            #expect(!settings.allowsRecording(in: category), "\(category.title) still records")
        }
        for store in LocalStore.allCases where store.memoryCategory != nil {
            #expect(!settings.allowsRecording(to: store))
        }
    }

    @Test
    func aPerTypeSwitchWithholdsItsOwnStoresAndNothingElse() {
        let settings = MemoryRecordingSettings(categoriesDisabledByUser: [.taskHistory])

        #expect(settings.isRecording)
        #expect(!settings.allowsRecording(in: .taskHistory))
        #expect(!settings.allowsRecording(to: .taskHistory))
        #expect(!settings.allowsRecording(to: .taskPlanDetails))
        #expect(!settings.allowsRecording(to: .visionSessionJournal))
        #expect(!settings.allowsRecording(to: .shortcutRunHistory))

        // Every other row is untouched — the half that would fail if a per-type switch were wired to
        // the master one by mistake.
        for category in MemoryCategory.allCases where category != .taskHistory {
            #expect(settings.allowsRecording(in: category), "\(category.title) stopped recording too")
        }
        #expect(settings.allowsRecording(to: .routines))
        #expect(settings.allowsRecording(to: .snippets))
    }

    /// The clipboard switch's own file is never withheld, however much memory is switched off — a
    /// memory switch that could stop the user recording their *preference* about memory would be a
    /// switch that can turn itself off and not back on.
    @Test
    func theClipboardSwitchesOwnFileIsNeverWithheldByAnyMemorySwitch() {
        #expect(LocalStore.clipboardHistorySettings.memoryCategory == nil)

        let everythingOff = MemoryRecordingSettings(
            isEnabledByUser: false,
            categoriesDisabledByUser: Set(MemoryCategory.allCases),
            policy: MemoryEnterprisePolicy(isManaged: true, disablesMemory: true)
        )
        #expect(everythingOff.allowsRecording(to: .clipboardHistorySettings))
    }

    // MARK: - The enterprise hook

    /// **Present and inert**, both halves asserted: the shipping provider says nothing, and the type
    /// that row 19 will supply already composes correctly.
    @Test
    func theShippingPolicyProviderRestrictsNothing() {
        #expect(UnmanagedMemoryPolicyProvider().currentPolicy() == .unmanaged)
        #expect(!MemoryEnterprisePolicy.unmanaged.isManaged)
        #expect(!MemoryEnterprisePolicy.unmanaged.disablesMemory)
        #expect(MemoryRecordingSettings.recordEverything.isRecording)
        #expect(!MemoryRecordingSettings.recordEverything.isDisabledByPolicy)
    }

    @Test
    func anAdministratorsPolicyOverridesTheUsersSwitchInOneDirectionOnly() {
        let userOnPolicyOff = MemoryRecordingSettings(
            isEnabledByUser: true,
            policy: MemoryEnterprisePolicy(isManaged: true, disablesMemory: true)
        )
        #expect(userOnPolicyOff.isDisabledByPolicy)
        #expect(!userOnPolicyOff.isRecording)
        #expect(!userOnPolicyOff.allowsRecording(in: .routines))

        // The other direction: a policy that permits memory does not switch it on for a user who
        // turned it off, and a managed machine whose policy allows memory is still distinguishable
        // from an unmanaged one.
        let userOffPolicyPermits = MemoryRecordingSettings(
            isEnabledByUser: false,
            policy: MemoryEnterprisePolicy(isManaged: true, disablesMemory: false)
        )
        #expect(!userOffPolicyPermits.isRecording)
        #expect(!userOffPolicyPermits.isDisabledByPolicy)
        #expect(userOffPolicyPermits.policy.isManaged)
    }

    @Test
    func aRefusedSaveNamesTheTypeItRefused() {
        #expect(
            MemoryDisabledError(category: .routines).errorDescription
                == "Routines memory is off, so nothing was saved. Turn it on in Memory."
        )
        #expect(
            MemoryDisabledError(category: .snippets).errorDescription
                == "Snippets memory is off, so nothing was saved. Turn it on in Memory."
        )
    }

    // MARK: - The per-entry delete entry points

    @Test
    func deletingOneSnippetLeavesTheRest() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SnippetStore(
            fileURL: root.appendingPathComponent("snippets.json"),
            encryption: testEncryption()
        )
        try store.save(StoredSnippet(trigger: ";sig", expansion: "signature", updatedAt: .memoryFixture))
        try store.save(StoredSnippet(trigger: ";addr", expansion: "address", updatedAt: .memoryFixture))

        try store.delete(trigger: " ;sig ")

        #expect(Set(try store.loadAll().keys) == [";addr"])
        // A trigger nothing holds is a no-op — the user's intent is already true.
        try store.delete(trigger: ";sig")
        #expect(Set(try store.loadAll().keys) == [";addr"])
    }

    @Test
    func deletingOneRecentArtifactLeavesTheRestAndTheFileItself() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let kept = root.appendingPathComponent("kept.txt")
        let forgotten = root.appendingPathComponent("forgotten.txt")
        try "kept".write(to: kept, atomically: true, encoding: .utf8)
        try "forgotten".write(to: forgotten, atomically: true, encoding: .utf8)
        let store = RecentArtifactStore(
            fileURL: root.appendingPathComponent("recent-artifacts.json"),
            encryption: testEncryption()
        )
        try store.record(path: kept.path, recordedAt: .memoryFixture)
        let removed = try #require(try store.record(path: forgotten.path, recordedAt: .memoryFixture))

        try store.delete(id: removed.id, now: .memoryFixture)

        #expect(try store.loadAll(now: .memoryFixture).map(\.path) == [kept.path])
        // The store only ever held a note about the file, and forgetting the note must not touch it.
        #expect(FileManager.default.fileExists(atPath: forgotten.path))

        try store.delete(id: UUID(), now: .memoryFixture)
        #expect(try store.loadAll(now: .memoryFixture).count == 1)
    }

    @Test
    func deletingOneClipboardItemLeavesTheRest() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ClipboardHistoryStore(
            fileURL: root.appendingPathComponent("clipboard-history.json"),
            encryption: testEncryption()
        )
        let older = try store.record("older", copiedAt: .memoryFixture)
        try store.record("newer", copiedAt: .memoryFixture.addingTimeInterval(60))

        try store.delete(id: older.id, now: .memoryFixture.addingTimeInterval(60))

        #expect(try store.loadAll(now: .memoryFixture.addingTimeInterval(60)).map(\.text) == ["newer"])
        try store.delete(id: UUID(), now: .memoryFixture.addingTimeInterval(60))
        #expect(try store.loadAll(now: .memoryFixture.addingTimeInterval(60)).count == 1)
    }

    @Test
    func forgettingOneAllowedAppLeavesTheRestAndMatchesTheWayTheGateReadsIt() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ApprovedAppStore(
            fileURL: root.appendingPathComponent("approved-apps.json"),
            encryption: testEncryption()
        )
        try store.approve(bundleIdentifier: "com.apple.Safari", displayName: "Safari", approvedAt: .memoryFixture)
        try store.approve(bundleIdentifier: "com.apple.Notes", displayName: "Notes", approvedAt: .memoryFixture)

        // Case-and-whitespace tolerant, because `matches(bundleIdentifier:)` is what the gate reads a
        // grant with — an app the gate can match must be an app the user can forget.
        try store.forget(bundleIdentifier: "  COM.APPLE.SAFARI  ")

        #expect(try store.loadAll().map(\.bundleIdentifier) == ["com.apple.Notes"])
        try store.forget(bundleIdentifier: "com.apple.Safari")
        #expect(try store.loadAll().count == 1)
        try store.forget(bundleIdentifier: "   ")
        #expect(try store.loadAll().count == 1)
    }

    /// Every one of the four deletes goes through its store's own encrypted write path, so the file
    /// left behind is still encrypted. A delete that rewrote plaintext would be a privacy control
    /// that leaks what it was asked to remove.
    @Test
    func aPerEntryDeleteLeavesTheStoreStillEncrypted() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = "Kept \(UUID().uuidString)"
        let store = SnippetStore(
            fileURL: root.appendingPathComponent("snippets.json"),
            encryption: testEncryption()
        )
        try store.save(StoredSnippet(trigger: ";keep", expansion: marker, updatedAt: .memoryFixture))
        try store.save(StoredSnippet(trigger: ";drop", expansion: "dropped", updatedAt: .memoryFixture))

        try store.delete(trigger: ";drop")

        try expectEncryptedFile(store.fileURL, hiding: marker)
    }
}

/// The same instant the other store suites pin to (1_700_000_000); their copies are file-private.
private extension Date {
    static let memoryFixture = Date(timeIntervalSince1970: 1_700_000_000)
}
