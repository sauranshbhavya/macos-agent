import Foundation
import MacAgentTestSupport
import Testing
@testable import MacAgentCore

/// Renaming one file or folder (SONNY-385), through the adapter body the kernel's `rename`
/// operation runs. A rename works end to end, a rename onto a name already in use fails and says
/// which file is in the way, and a rename is not a move. That a rename is `destructive`, and so
/// asks first, is held in `KernelCapabilityTests`.
@Suite
@MainActor
struct RenameTests {
    // MARK: - One rename, on the real dispatch path

    /// The whole point of the ticket: a plan the planner can emit renames the file.
    ///
    /// Driven through `AgentActionExecutor.execute`, which is the path a real run takes, rather than
    /// through the adapter directly — the dispatch is a `switch` a new operation can be left out of,
    /// and an adapter tested in isolation says nothing about whether anything calls it.
    @Test
    func aRenameGivesTheFileItsNewNameInTheSameFolder() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("scan1.pdf")
        try write("bytes", to: source)
        let executor = makeExecutor(root: root)

        let result = try await executor.execute(
            plan: renamePlan(source: source, to: "invoice-march.pdf"),
            log: { _, _ in }
        )

        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["invoice-march.pdf"])
        // The bytes travelled with the name — a rename that wrote a new empty file and deleted the
        // old one would satisfy the listing above.
        #expect(
            try String(contentsOf: root.appendingPathComponent("invoice-march.pdf"), encoding: .utf8) == "bytes"
        )
        #expect(result.summary == "Renamed scan1.pdf to invoice-march.pdf in \(root.path).")
        #expect(result.previews.map(\.title) == ["Rename"])
        #expect(result.previews.first?.writes == [root.appendingPathComponent("invoice-march.pdf").path])
    }

    /// A folder renames exactly as a file does, contents and all. Named separately because the
    /// ticket's sentence is "a file **or folder**", and `moveItem` treating the two alike is a
    /// property of Foundation rather than of this adapter.
    @Test
    func aFolderRenamesWithEverythingInsideIt() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Scans", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try write("inner", to: source.appendingPathComponent("a.pdf"))
        let executor = makeExecutor(root: root)

        _ = try await executor.execute(plan: renamePlan(source: source, to: "Archive"), log: { _, _ in })

        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["Archive"])
        #expect(
            try String(contentsOf: root.appendingPathComponent("Archive/a.pdf"), encoding: .utf8) == "inner"
        )
    }

    /// The preview names both halves and writes nothing — a dry run has to stay a dry run.
    @Test
    func previewingARenameNamesBothNamesAndMovesNothing() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("scan1.pdf")
        try write("bytes", to: source)
        let executor = makeExecutor(root: root)

        let previews = try executor.preview(plan: renamePlan(source: source, to: "invoice-march.pdf"))

        #expect(previews.map(\.title) == ["Rename"])
        #expect(previews.first?.details == ["Rename \(source.path)", "to invoice-march.pdf"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["scan1.pdf"])
    }

    // MARK: - The collision, which is the decision this ticket had to make

    /// **A rename onto a name already in use fails, and the message names the file that is in the
    /// way.**
    ///
    /// The alternative — overwriting — is unrecoverable through the product and destroys a file the
    /// user never named in the command. The decision is Sonny's rather than Foundation's, which is
    /// what the control at the end of this test is for: the occupied file still holds its own bytes
    /// afterwards, so the refusal is a refusal and not a move that happened to fail late.
    @Test
    func aRenameOntoATakenNameFailsAndNamesTheFileAlreadyThere() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("scan1.pdf")
        let occupied = root.appendingPathComponent("invoice-march.pdf")
        try write("source bytes", to: source)
        try write("bytes that must survive", to: occupied)
        let executor = makeExecutor(root: root)

        await #expect(
            throws: AgentExecutionError.invalidPlan(
                "There is already something called invoice-march.pdf in \(root.path). Sonny will not replace it — pick a different name."
            )
        ) {
            _ = try await executor.execute(
                plan: renamePlan(source: source, to: "invoice-march.pdf"),
                log: { _, _ in }
            )
        }

        // Nothing moved and nothing was replaced.
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == ["invoice-march.pdf", "scan1.pdf"])
        #expect(try String(contentsOf: occupied, encoding: .utf8) == "bytes that must survive")
        #expect(try String(contentsOf: source, encoding: .utf8) == "source bytes")
    }

    /// The collision is refused at **`prepare`**, not only at execution — so a user is never asked to
    /// approve a rename that cannot happen, and the approval prompt never describes a replacement
    /// Sonny would refuse to perform.
    ///
    /// The control is the same folder with the occupied name removed, where `prepare` succeeds.
    @Test
    func aCollidingRenameIsRefusedBeforeTheUserIsAskedToApproveIt() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("scan1.pdf")
        let occupied = root.appendingPathComponent("invoice-march.pdf")
        try write("source bytes", to: source)
        try write("occupied", to: occupied)
        let executor = makeExecutor(root: root)

        #expect(throws: AgentExecutionError.self) {
            _ = try executor.prepare(plan: renamePlan(source: source, to: "invoice-march.pdf"))
        }

        try FileManager.default.removeItem(at: occupied)
        let prepared = try executor.prepare(plan: renamePlan(source: source, to: "invoice-march.pdf"))
        #expect(prepared.previews.map(\.title) == ["Rename"])
    }

    /// **A rename that only changes letter case is not a collision**, and on an APFS volume it looks
    /// exactly like one: `fileExists` answers true for `README.md` while only `readme.md` is there.
    ///
    /// Refusing it would refuse a rename people genuinely ask for, over a file that is the item
    /// itself. The identity check is what tells the two apart, and the assertion is on the resulting
    /// name rather than merely on not throwing — a guard that let the call through without the move
    /// working would pass a no-throw test.
    ///
    /// Measured before it was written, at this branch's head: on this Mac's temporary directory
    /// `fileExists` at the case-changed path answers `true`, `fileResourceIdentifier` answers equal
    /// for the two URLs, and `moveItem` then performs the case change. On a case-*sensitive* volume
    /// the destination simply does not exist and the same rename takes the ordinary path — so this
    /// test asserts the same outcome either way.
    @Test
    func aRenameThatOnlyChangesCaseIsNotTreatedAsACollision() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("readme.md")
        try write("notes", to: source)
        let executor = makeExecutor(root: root)

        _ = try await executor.execute(plan: renamePlan(source: source, to: "README.md"), log: { _, _ in })

        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["README.md"])
        #expect(try String(contentsOf: root.appendingPathComponent("README.md"), encoding: .utf8) == "notes")
    }

    /// Renaming something to the name it already has is refused rather than performed, because
    /// `moveItem` onto itself is not a no-op — it throws, with a message about a file already
    /// existing that would read as the collision refusal above and mean something else entirely.
    @Test
    func renamingSomethingToTheNameItAlreadyHasIsRefusedOnItsOwnTerms() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("scan1.pdf")
        try write("bytes", to: source)
        let executor = makeExecutor(root: root)

        #expect(throws: AgentExecutionError.invalidPlan("scan1.pdf is already called that.")) {
            _ = try executor.preview(plan: renamePlan(source: source, to: "scan1.pdf"))
        }
    }

    // MARK: - A rename is not a move

    /// **A new name carrying a path separator is refused**, even when the path it composes is
    /// squarely inside the whitelist — which is exactly why `validateInsideWhitelist` cannot be what
    /// stops it. Sonny has no move operation; one arriving through the rename field would be a
    /// capability nobody decided to build, and the destination folder would never have appeared in
    /// the approval the user read.
    ///
    /// The control is the same rename with the separator removed, which succeeds — so the refusal is
    /// about the separator and not about the name.
    @Test
    func aNewNameThatIsAPathIsRefusedEvenWhenItStaysInsideTheWhitelist() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let elsewhere = root.appendingPathComponent("Elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("scan1.pdf")
        try write("bytes", to: source)
        let executor = makeExecutor(root: root)

        for name in ["Elsewhere/invoice.pdf", "../invoice.pdf", "/tmp/invoice.pdf"] {
            #expect(
                throws: AgentExecutionError.invalidPlan(
                    "Sonny renames a file where it is — \"\(name)\" is a path, not a name. Say what to call it, and it stays in the same folder."
                ),
                "\(name) should be refused as a path"
            ) {
                _ = try executor.preview(plan: renamePlan(source: source, to: name))
            }
        }

        // The control: the same leaf name with no separator is fine.
        #expect(try executor.preview(plan: renamePlan(source: source, to: "invoice.pdf")).count == 1)
        // And nothing was created anywhere while the three were being refused.
        #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
    }

    /// `.` and `..` compose to something that is not a sibling at all, and are refused by name.
    @Test
    func theTwoDirectoryNamesAreRefusedAsNewNames() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("scan1.pdf")
        try write("bytes", to: source)
        let executor = makeExecutor(root: root)

        for name in [".", ".."] {
            #expect(
                throws: AgentExecutionError.invalidPlan("\"\(name)\" is not a name Sonny can give a file."),
                "\(name) should be refused"
            ) {
                _ = try executor.preview(plan: renamePlan(source: source, to: name))
            }
        }
    }

    /// **The destination's whitelist check, which is the only thing stopping a rename from moving a
    /// whitelist root out of the whitelist** (PR #200, F1).
    ///
    /// A whitelist root is inside its own whitelist — `containsPath` answers true when the candidate
    /// *is* the root — so a rename step may legitimately name one as its `inputPath`. Its parent
    /// folder is then outside every root, and the composed destination is outside with it. The
    /// `validateOutputFile` call in `renameSpec` is what refuses that, and it is called for its
    /// refusal alone with its canonical return value deliberately discarded, which is exactly what
    /// makes it look removable. Deleting it survived the whole suite before this test existed, and
    /// what it would allow is "rename my Documents folder to Docs" composing `~/Docs`, finding
    /// nothing there, passing the collision check and the already-named check, and reaching
    /// `moveItem` — which moves the user's whole Documents folder outside the boundary.
    ///
    /// **Two controls, because the refusal on its own does not say which check produced it.** The
    /// first is the ordinary in-root rename, which previews. The second is the *source* half: the
    /// same root passes `validateInsideWhitelist`, so this is not a step that fails before the
    /// destination is ever composed.
    @Test
    func renamingTheWhitelistRootItselfIsRefusedBecauseTheDestinationWouldLeaveTheWhitelist() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("bytes", to: root.appendingPathComponent("scan1.pdf"))
        let whitelist = PathWhitelist(roots: [root])
        let executor = makeExecutor(root: root)

        // Control one: the root really is inside its own whitelist, so the source half accepts it and
        // the refusal below can only be coming from the destination.
        #expect(try whitelist.validateInsideWhitelist(root.path).path == root.path)

        #expect(throws: PathValidationError.self) {
            _ = try executor.preview(plan: renamePlan(source: root, to: "Renamed"))
        }

        // Control two: an ordinary rename inside the root previews, so the refusal is about leaving
        // the whitelist rather than about renaming at all.
        #expect(try executor.preview(plan: renamePlan(source: root.appendingPathComponent("scan1.pdf"), to: "invoice.pdf")).count == 1)
        // And nothing moved while all that was being refused.
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["scan1.pdf"])
    }

    /// **A hard link is what the case half of the same-file exemption actually stops** (PR #200, F3).
    ///
    /// Two names for one inode report **equal** `fileResourceIdentifier`, so the identity half alone
    /// would exempt a rename of one onto the other and hand the user Foundation's wording instead of
    /// Sonny's. Their paths are not equal modulo case, so the case half refuses it — which is the
    /// whole reason that half is required, and a reason that appeared nowhere in the code or the
    /// record until this test.
    ///
    /// **The two facts are asserted rather than assumed**, because the outcome alone would pass for
    /// the wrong reason: if identity happened to differ, the refusal would arrive from the identity
    /// check and this test would say nothing about the case half at all.
    @Test
    func aRenameOntoAHardLinkOfTheSameFileIsStillRefused() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("a.txt")
        let hardLink = root.appendingPathComponent("b.txt")
        try write("shared bytes", to: source)
        try FileManager.default.linkItem(at: source, to: hardLink)
        let executor = makeExecutor(root: root)

        // The premise: one inode, two names, equal identity — so identity alone would exempt this.
        let sourceIdentity = try #require(
            try source.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
        )
        let linkIdentity = try #require(
            try hardLink.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
        )
        #expect(sourceIdentity.isEqual(linkIdentity))
        // And the case half's own question answers no, which is what refuses it.
        #expect(source.path.compare(hardLink.path, options: .caseInsensitive) != .orderedSame)

        #expect(
            throws: AgentExecutionError.invalidPlan(
                "There is already something called b.txt in \(root.path). Sonny will not replace it — pick a different name."
            )
        ) {
            _ = try executor.preview(plan: renamePlan(source: source, to: "b.txt"))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == ["a.txt", "b.txt"])
    }

    /// **A dangling symbolic link occupies the destination, and `fileExists` cannot see it**
    /// (PR #200, F4).
    ///
    /// `refuseCollision` probes with `attributesOfItem` rather than `fileExists` precisely because
    /// the latter follows the link and reports a destination that is free. `moveItem` refuses either
    /// way, so what the probe buys is Sonny's message instead of Foundation's — which is the whole
    /// property that function's doc comment claims, and it was unasserted.
    ///
    /// The two probe answers are asserted directly, so the test fails on the *reason* and not only
    /// on the refusal.
    @Test
    func aDanglingSymbolicLinkAtTheDestinationIsAnOccupiedDestination() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("scan1.pdf")
        try write("bytes", to: source)
        let dangling = root.appendingPathComponent("invoice-march.pdf")
        try FileManager.default.createSymbolicLink(
            at: dangling,
            withDestinationURL: root.appendingPathComponent("nothing-here.pdf")
        )
        let executor = makeExecutor(root: root)

        // The premise, and the reason the probe is not `fileExists`.
        #expect(FileManager.default.fileExists(atPath: dangling.path) == false)
        #expect((try? FileManager.default.attributesOfItem(atPath: dangling.path)) != nil)

        #expect(
            throws: AgentExecutionError.invalidPlan(
                "There is already something called invoice-march.pdf in \(root.path). Sonny will not replace it — pick a different name."
            )
        ) {
            _ = try executor.preview(plan: renamePlan(source: source, to: "invoice-march.pdf"))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == ["invoice-march.pdf", "scan1.pdf"])
    }

    /// A rename outside the whitelist is refused by the whitelist, which is the door that already
    /// owns that question. Here so that a future change to `renameSpec` cannot quietly stop asking
    /// it — the containment check is the one thing between a rename and the whole filesystem.
    @Test
    func aRenameOfSomethingOutsideTheWhitelistIsRefused() throws {
        let root = try makeDirectory()
        let outside = try makeDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let source = outside.appendingPathComponent("scan1.pdf")
        try write("bytes", to: source)
        let executor = makeExecutor(root: root)

        #expect(throws: PathValidationError.self) {
            _ = try executor.preview(plan: renamePlan(source: source, to: "invoice.pdf"))
        }
        // The control: the same file inside the whitelist previews.
        let inside = root.appendingPathComponent("scan1.pdf")
        try write("bytes", to: inside)
        #expect(try executor.preview(plan: renamePlan(source: inside, to: "invoice.pdf")).count == 1)
    }

    /// A rename with no new name, and a rename with no path, each fail with their own sentence
    /// rather than with whatever the first `nil` unwrap happens to produce.
    @Test
    func aRenameMissingEitherHalfSaysWhichHalfIsMissing() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("scan1.pdf")
        try write("bytes", to: source)
        let executor = makeExecutor(root: root)

        #expect(throws: AgentExecutionError.invalidPlan("rename needs newName: what to call the file or folder.")) {
            _ = try executor.preview(
                plan: AgentPlan(
                    summary: "Rename it.",
                    requiresConfirmation: true,
                    steps: [
                        AgentStep(id: "rename", operation: .rename, description: "Rename it.", inputPath: source.path)
                    ]
                )
            )
        }

        #expect(throws: AgentExecutionError.invalidPlan("rename needs inputPath: the file or folder to rename.")) {
            _ = try executor.preview(
                plan: AgentPlan(
                    summary: "Rename it.",
                    requiresConfirmation: true,
                    steps: [
                        AgentStep(id: "rename", operation: .rename, description: "Rename it.", newName: "invoice.pdf")
                    ]
                )
            )
        }
    }

    /// Renaming something that is not there fails at execution with the path in the message, and —
    /// the half that matters — **previews and assesses without throwing**, because the risk engine
    /// has to be able to describe a rename before the run starts.
    @Test
    func renamingSomethingThatIsNotThereFailsAtExecutionAndNotAtAssessment() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("scan1.pdf")
        let executor = makeExecutor(root: root)

        let assessment = try executor.assessRisk(plan: renamePlan(source: missing, to: "invoice.pdf"))
        #expect(assessment.effectiveTier == .tier3)

        await #expect(throws: PathValidationError.notFound(missing.path)) {
            _ = try await executor.execute(plan: renamePlan(source: missing, to: "invoice.pdf"), log: { _, _ in })
        }
    }

    // MARK: - What the boundary is told a rename touches

    // MARK: - Fixtures

    private func renamePlan(source: URL, to newName: String) -> AgentPlan {
        AgentPlan(
            summary: "Rename it.",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "rename",
                    operation: .rename,
                    description: "Rename the file.",
                    inputPath: source.path,
                    newName: newName
                )
            ]
        )
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonny-rename-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ contents: String, to url: URL) throws {
        try Data(contents.utf8).write(to: url, options: .atomic)
    }

    private func makeExecutor(root: URL) -> PlanHarness {
        PlanHarness(context: CapabilityTestContext.make(installed: [], whitelist: PathWhitelist(roots: [root])))
    }
}
