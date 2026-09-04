import Foundation
import Testing
@testable import MacAgentCore

/// What `PathWhitelist` answers for a path that does not exist yet — which is nearly every path
/// Sonny is asked to *write* (SONNY-249).
///
/// Every test here that claims a write stayed inside the boundary proves it with bytes: it writes
/// to the URL the whitelist handed back and then asks `realpath(3)` where those bytes actually
/// are. Nothing in this suite decides where a file landed by re-running the arithmetic under test —
/// a containment test that compares two strings produced by the same function it is testing passes
/// just as happily when that function is wrong.
@Suite
struct PathContainmentResolutionTests {
    // MARK: - Half one: a write below a symlink

    /// The ticket's own reproduction, at the level of bytes.
    ///
    /// `validateOutputPath` looks at the immediate parent for `isSymbolicLink`, so a symlink one
    /// level up is caught and two levels up is not: the parent is then a real directory that merely
    /// happens to be reached through the link. Before the fix the whitelist accepted
    /// `<root>/link/sub/new.md`, and the bytes written to the URL it handed back landed in
    /// `<outside>/sub/new.md` — the boundary said inside and the file went outside.
    @Test
    func aWriteTwoLevelsBelowASymlinkIsRefusedRatherThanLandingOutsideTheRoot() throws {
        let tree = try SymlinkTree()
        defer { tree.tearDown() }
        try FileManager.default.createDirectory(
            at: tree.outside.appendingPathComponent("sub", isDirectory: true),
            withIntermediateDirectories: true
        )

        let attempt = tree.attemptOutput(at: tree.link.appendingPathComponent("sub/new.md").path)

        #expect(attempt.landedAt == nil, "bytes reached \(attempt.landedAt ?? "") through an accepted path")
        #expect(tree.isOutsideWhitelist(attempt.error), "expected a containment refusal, got \(attempt.errorText)")
    }

    /// The same escape one level shallower. It was already refused, by the parent's `isSymbolicLink`
    /// check rather than by containment; now containment refuses it first, so both depths fail for
    /// the same reason instead of two mechanisms splitting one rule between them.
    @Test
    func aWriteOneLevelBelowASymlinkIsRefusedByContainmentRatherThanByTheParentCheck() throws {
        let tree = try SymlinkTree()
        defer { tree.tearDown() }

        let attempt = tree.attemptOutput(at: tree.link.appendingPathComponent("new.md").path)

        #expect(attempt.landedAt == nil)
        #expect(tree.isOutsideWhitelist(attempt.error), "expected a containment refusal, got \(attempt.errorText)")
    }

    /// A symlink whose target does not exist yet is the shape neither mechanism saw: `fileExists`
    /// says no (it follows the link to a target that is not there), so nothing resolved it, and the
    /// parent — the real root — is not a link, so the parent check passed it. The accepted URL was a
    /// symlink pointing out of the boundary.
    ///
    /// Written here without `.atomic`, deliberately, because that is what the writer on the other
    /// side of this path does: `ProcessZipArchiver` hands `outputURL.path` to `/usr/bin/zip`, which
    /// opens it and follows the link. Foundation's atomic write happens to replace the link instead
    /// of following it, so an atomic-only test would have reported this hole as closed.
    @Test
    func aSymlinkLeafPointingOutsideIsRefusedRatherThanCreatingItsTargetOutThere() throws {
        let tree = try SymlinkTree()
        defer { tree.tearDown() }
        let dangling = tree.root.appendingPathComponent("report.zip")
        try FileManager.default.createSymbolicLink(
            at: dangling,
            withDestinationURL: tree.outside.appendingPathComponent("report.zip")
        )

        let attempt = tree.attemptOutput(at: dangling.path, atomically: false)

        #expect(attempt.landedAt == nil, "bytes reached \(attempt.landedAt ?? "") through an accepted path")
        #expect(tree.isOutsideWhitelist(attempt.error), "expected a containment refusal, got \(attempt.errorText)")
    }

    /// The other direction of the same resolution, and the class of path this fix newly *accepts*: a
    /// link that stays inside the boundary is followed, and the bytes land at its target. Before the
    /// fix this was refused at depth one — `symbolicLinkRejected` on a link that could not have let
    /// anything out.
    @Test
    func aSymlinkStayingInsideTheRootIsFollowedAndTheBytesLandAtItsTarget() throws {
        let tree = try SymlinkTree()
        defer { tree.tearDown() }
        let real = tree.root.appendingPathComponent("Reports", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let shortcut = tree.root.appendingPathComponent("shortcut")
        try FileManager.default.createSymbolicLink(at: shortcut, withDestinationURL: real)

        let attempt = tree.attemptOutput(at: shortcut.appendingPathComponent("note.md").path)

        #expect(attempt.errorText == "none")
        #expect(attempt.landedAt == SymlinkTree.physicalPath(of: real.appendingPathComponent("note.md")))
        #expect(attempt.accepted?.path == real.appendingPathComponent("note.md").path)
    }

    /// What the refusal says when resolution is the reason for it.
    ///
    /// The fix creates a sentence that could not happen before: the path being refused is not the
    /// path the person typed. Naming only the resolved one sends them somewhere they have never
    /// heard of; naming only the typed one refuses a folder they can see listed as allowed two
    /// clauses later, which is the shape SONNY-242 had just finished removing from this sentence.
    /// So both, and only when both are needed — an ordinary refusal is unchanged.
    @Test
    func theRefusalNamesWhatWasAskedForAndWhereItLedWhenALinkIsWhyItWasRefused() throws {
        let tree = try SymlinkTree()
        defer { tree.tearDown() }
        try FileManager.default.createDirectory(
            at: tree.outside.appendingPathComponent("sub", isDirectory: true),
            withIntermediateDirectories: true
        )
        let asked = tree.link.appendingPathComponent("sub/new.md").path
        let leadsTo = tree.outside.appendingPathComponent("sub/new.md").path

        let throughTheLink = tree.attemptOutput(at: asked)
        let plainlyOutside = tree.attemptOutput(at: tree.outside.appendingPathComponent("other.md").path)

        let refusal = try #require((throughTheLink.error as? PathValidationError)?.errorDescription)
        #expect(refusal.contains(asked))
        #expect(refusal.contains(leadsTo))

        let ordinary = try #require((plainlyOutside.error as? PathValidationError)?.errorDescription)
        #expect(ordinary.hasPrefix(tree.outside.appendingPathComponent("other.md").path))
        #expect(ordinary.contains("leads to") == false)
    }

    // MARK: - Half two: a folder whose case was typed differently

    /// "save it to my desktop" worked and "save it to my desktop as note.md" did not, because the
    /// folder's case was corrected only when the whole path existed. The fix resolves the longest
    /// prefix that does exist, so the folder is corrected and the not-yet-written leaf keeps the
    /// case it was given.
    ///
    /// Volume-aware rather than volume-dependent: on a case-*sensitive* volume the differently-cased
    /// folder genuinely is not the same folder, nothing exists at that prefix, and the refusal is the
    /// correct answer. The precondition is measured on the volume the test is running on, so the
    /// assertion is about the code either way.
    @Test
    func aNotYetWrittenFileUnderADifferentlyCasedFolderResolvesToTheFolderThatExists() throws {
        let tree = try SymlinkTree()
        defer { tree.tearDown() }
        let real = tree.root.appendingPathComponent("Reports", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let shouted = tree.root.appendingPathComponent("REPORTS", isDirectory: true)
        let volumeIsCaseInsensitive = FileManager.default.fileExists(atPath: shouted.path)

        let attempt = tree.attemptOutput(at: shouted.appendingPathComponent("note.md").path)

        if volumeIsCaseInsensitive {
            #expect(attempt.errorText == "none")
            #expect(attempt.accepted?.path == real.appendingPathComponent("note.md").path)
            #expect(attempt.landedAt == SymlinkTree.physicalPath(of: real.appendingPathComponent("note.md")))
        } else {
            #expect(attempt.landedAt == nil)
            #expect(tree.isParentMissing(attempt.error), "expected a missing-parent refusal, got \(attempt.errorText)")
        }
    }

    /// The ticket's half two as reported, against the real home directory: `desktop` resolved to
    /// `Desktop` and was accepted, `desktop/note.md` did not and was refused, so the same phrasing
    /// worked or failed depending on whether it named a file.
    ///
    /// Reads the home directory and writes nothing. Volume-aware rather than skipped: where
    /// `~/desktop` is not the same directory as `~/Desktop` the correct answer is that the case is
    /// left alone, and that is asserted too. A test that returns silently when its precondition
    /// fails is a vacuous pass that reads exactly like a real one (PR #111's review).
    @Test
    func theLowercaseSpellingOfARealFolderResolvesToItForAFileThatDoesNotExistYet() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let desktop = home.appendingPathComponent("Desktop", isDirectory: true)
        let lowercased = home.appendingPathComponent("desktop", isDirectory: true)
        guard FileManager.default.fileExists(atPath: desktop.path) else {
            // No Desktop at all is the one thing this cannot say anything about.
            return
        }
        let homeVolumeIsCaseInsensitive = FileManager.default.fileExists(atPath: lowercased.path)

        let folder = PathWhitelist.canonicalURL(lowercased.path)
        let file = PathWhitelist.canonicalURL(lowercased.appendingPathComponent("note.md").path)

        if homeVolumeIsCaseInsensitive {
            #expect(folder.path == desktop.path)
            #expect(file.path == desktop.appendingPathComponent("note.md").path)
        } else {
            #expect(folder.path == lowercased.path)
            #expect(file.path == lowercased.appendingPathComponent("note.md").path)
        }
    }

    // MARK: - A chain of links, and where resolution gives up

    /// **The regression PR #111's review found, at the length it found it.**
    ///
    /// The first version of this fix followed at most one link per pass, ran a fixed number of
    /// passes, and on running out returned the path it had *reached* — the original with 33 hops
    /// taken out of it. `validateInsideWhitelist` then judged that, and the kernel's own
    /// `SYMLOOP_MAX` budget started again from the shortened path, so it had plenty left to finish
    /// the walk. Chains of 34 to 63 links read as inside and the bytes landed outside. At
    /// `94afca1` — before any of this — those same chains were refused by the kernel with `ELOOP`,
    /// so the branch that closed the one-link escape opened a longer one.
    ///
    /// A longer budget does not fix it; every finite number has the same cliff. What fixes it is
    /// that a resolution which did not converge is never reported as inside anything.
    @Test
    func aChainLongerThanTheResolverWillFollowIsRefusedRatherThanPartlyResolved() throws {
        let tree = try SymlinkTree()
        defer { tree.tearDown() }

        for length in [34, 40, 63] {
            // A target of its own per length. Sharing one made each length depend on whether an
            // earlier one had escaped and created it: with the target present, a long-enough tail
            // of the chain becomes resolvable in a single `resolvingSymlinksInPath` and the answer
            // changes. Measured while checking this test against the head it was written for.
            let target = tree.outside.appendingPathComponent("pwned-\(length).txt")
            let head = try tree.chain(length: length, endingAt: target)

            let attempt = tree.attemptOutput(at: head.path, atomically: false)

            #expect(
                attempt.landedAt == nil,
                "a chain of \(length) links put bytes at \(attempt.landedAt ?? "") through an accepted path"
            )
            #expect(
                tree.isSymbolicLinkRejected(attempt.error),
                "a chain of \(length) links: expected a symlink refusal, got \(attempt.errorText)"
            )
            #expect(FileManager.default.fileExists(atPath: target.path) == false)
        }
    }

    /// The hop budget pinned on both sides, which is what nothing did before — the constant the
    /// escape above lived in was held by no test, so the battery that mutated everything around it
    /// came back clean.
    ///
    /// Both chains end at the same place *inside* the root, so length is the only difference
    /// between them: 32 links resolve and the bytes land at the target, 33 are refused. Neutering
    /// the budget breaks the first; shortening it by one breaks it too; removing the refusal on
    /// exhaustion breaks the second.
    @Test
    func aChainTheResolverCanFollowResolvesAndOneLinkLongerIsRefused() throws {
        let tree = try SymlinkTree()
        defer { tree.tearDown() }
        let real = tree.root.appendingPathComponent("Reports", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let target = real.appendingPathComponent("note.md")

        let follows = try tree.chain(length: 32, endingAt: target)
        let followsAttempt = tree.attemptOutput(at: follows.path)

        #expect(followsAttempt.errorText == "none")
        #expect(followsAttempt.accepted?.path == target.path)
        #expect(followsAttempt.landedAt == SymlinkTree.physicalPath(of: target))

        try FileManager.default.removeItem(at: target)
        let refuses = try tree.chain(length: 33, endingAt: target)
        let refusesAttempt = tree.attemptOutput(at: refuses.path)

        #expect(refusesAttempt.landedAt == nil)
        #expect(
            tree.isSymbolicLinkRejected(refusesAttempt.error),
            "expected a symlink refusal, got \(refusesAttempt.errorText)"
        )
    }

    /// A refusal names a link the person can find, which is the head of the chain and not the point
    /// the resolver gave up at (PR #111's review, F6).
    ///
    /// Asking for `<root>/l1` used to be refused with "`<root>/l33` is a symbolic link Sonny could
    /// not follow" — a path they never typed and cannot act on. That is the same failure this file
    /// reasons about carefully one case away, for `outsideWhitelist`: naming only the far end shows
    /// somebody somewhere they have never heard of. The first link followed is always a component of
    /// the path as asked for.
    @Test
    func aRefusalNamesTheFirstLinkItCouldNotFollowRatherThanWhereItGaveUp() throws {
        let tree = try SymlinkTree()
        defer { tree.tearDown() }
        let head = try tree.chain(length: 33, endingAt: tree.outside.appendingPathComponent("pwned.txt"))

        let attempt = tree.attemptOutput(at: head.path, atomically: false)

        #expect(attempt.landedAt == nil)
        guard let validation = attempt.error as? PathValidationError,
              case .symbolicLinkRejected(let named) = validation else {
            Issue.record("expected a symlink refusal, got \(attempt.errorText)")
            return
        }
        #expect(named == head.path)
        #expect(named.hasSuffix("/l33") == false)
        #expect(validation.errorDescription?.contains(head.path) == true)
    }

    /// The rule carried by the type rather than by two callers remembering it: the one comparison
    /// every boundary in the app goes through refuses a path whose resolution did not converge, so
    /// a future caller cannot reintroduce the escape by forgetting to ask.
    @Test
    func containmentRefusesACandidateWhoseResolutionDidNotConverge() throws {
        let tree = try SymlinkTree()
        defer { tree.tearDown() }
        let loop = tree.root.appendingPathComponent("loop")
        try FileManager.default.createSymbolicLink(atPath: loop.path, withDestinationPath: "loop")

        let candidate = PathWhitelist.canonical(loop.appendingPathComponent("note.md").path)

        #expect(candidate.isResolved == false)
        #expect(candidate.unfollowableLink?.path == loop.path)
        // The text alone would say inside — the path still starts with the root.
        #expect(candidate.url.path.hasPrefix(tree.root.path + "/"))
        #expect(PathWhitelist.contains(root: tree.root, candidate: candidate) == false)
    }

    // MARK: - Where resolution stops

    /// A path with no existing ancestor below `/`: the walk ends at the filesystem root, which always
    /// exists, so there is always an ancestor to resolve and the answer is the path as written.
    /// Nothing on disk claimed it, and containment refuses it.
    @Test
    func aPathWhoseOnlyExistingAncestorIsTheFilesystemRootResolvesToItselfAndIsRefused() throws {
        let tree = try SymlinkTree()
        defer { tree.tearDown() }
        let nowhere = "/no-such-root-\(UUID().uuidString)/deep/note.md"

        #expect(PathWhitelist.canonicalURL(nowhere).path == nowhere)

        let attempt = tree.attemptOutput(at: nowhere)
        #expect(attempt.landedAt == nil)
        #expect(tree.isOutsideWhitelist(attempt.error), "expected a containment refusal, got \(attempt.errorText)")
    }

    /// A symlink that points at itself never converges, so it is refused by the same rule that
    /// refuses a chain past the budget — one rule, not a special case.
    ///
    /// **Both depths, because the first version of this fix only got the first one right.** It
    /// refused depth one with an `isSymbolicLink` check on the immediate parent, and at depth two
    /// the parent is `<root>/loop/sub`, which is not itself a link, so the answer fell back to
    /// "the parent folder does not exist" — true in a useless way, and contradicting what the
    /// branch's own changelog claimed (the review's F2). Refusing non-convergence answers both.
    @Test
    func aSymlinkLoopIsRefusedAtEveryDepthBecauseItsResolutionNeverConverges() throws {
        let tree = try SymlinkTree()
        defer { tree.tearDown() }
        let loop = tree.root.appendingPathComponent("loop")
        try FileManager.default.createSymbolicLink(atPath: loop.path, withDestinationPath: "loop")

        for depth in ["note.md", "sub/note.md", "one/two/three/note.md"] {
            let attempt = tree.attemptOutput(at: loop.appendingPathComponent(depth).path)

            #expect(attempt.landedAt == nil)
            #expect(
                tree.isSymbolicLinkRejected(attempt.error),
                "at \(depth): expected a symlink refusal, got \(attempt.errorText)"
            )
        }
    }

    /// The same unfollowable link named as a *folder*, which is the other door into the whitelist —
    /// `validateExistingDirectory` is what every read-side capability calls, and it now refuses for
    /// the same reason the write door does rather than through a check of its own. It reports the
    /// link rather than "no such folder", which is what `fileExists` would have said about it: a
    /// link pointing at itself is a different problem from a folder that is not there, and the
    /// person reading the refusal is the one who has to tell them apart.
    @Test
    func aSymlinkLoopNamedAsAFolderIsRefusedAsALinkRatherThanAsAMissingFolder() throws {
        let tree = try SymlinkTree()
        defer { tree.tearDown() }
        let loop = tree.root.appendingPathComponent("loop")
        try FileManager.default.createSymbolicLink(atPath: loop.path, withDestinationPath: "loop")

        var thrown: Error?
        do {
            _ = try tree.whitelist.validateExistingDirectory(loop.path)
        } catch {
            thrown = error
        }

        #expect(tree.isSymbolicLinkRejected(thrown), "expected a symlink refusal, got \(String(describing: thrown))")
    }

    /// Both sides of the comparison go through one arithmetic, which only shows when a whitelist
    /// root is a path that does not exist yet: the candidates are resolved and a root resolved by a
    /// different rule would be compared against a spelling nothing produces.
    ///
    /// The one test here that does not write bytes, deliberately — the property is that two
    /// spellings of one root agree, and a root nobody has created is a root nothing can be written
    /// into. What it pins is that removing `canonicalURL` from the root side is a change with a
    /// consequence, rather than a tidy-up nothing notices.
    @Test
    func aWhitelistRootThatDoesNotExistYetIsResolvedTheSameWayTheCandidatesAre() throws {
        let base = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let real = base.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = base.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        // Named through the link, and its last component has never been created.
        let whitelist = PathWhitelist(roots: [link.appendingPathComponent("Scope", isDirectory: true)])
        let candidate = real.appendingPathComponent("Scope/notes.md").path

        let validated = try whitelist.validateInsideWhitelist(candidate)

        #expect(validated.path == candidate)
    }

    /// The boundary is checked when it is asked, and the bytes are written afterwards. A component
    /// created in between is not seen — pinned here rather than left for someone to discover, because
    /// it is the residual this fix does not close and cannot close from a path string: only opening
    /// the file without following links, at every write site, would.
    ///
    /// It costs an attacker local code execution inside `~/Desktop` or `~/Documents` and a race with
    /// the run in progress, which is a different threat from the one this ticket fixes — there, no
    /// race was needed, and a link planted at any time held the door open until someone noticed.
    @Test
    func containmentIsDecidedWhenTheBoundaryIsAskedAndNotWhenTheBytesAreWritten() throws {
        let tree = try SymlinkTree()
        defer { tree.tearDown() }
        let planted = tree.root.appendingPathComponent("later.md")

        let accepted = try tree.whitelist.validateOutputPath(planted.path)
        #expect(accepted.path == planted.path)

        try FileManager.default.createSymbolicLink(
            at: planted,
            withDestinationURL: tree.outside.appendingPathComponent("later.md")
        )
        try Data("bytes".utf8).write(to: accepted)

        #expect(
            SymlinkTree.physicalPath(of: accepted)
                == SymlinkTree.physicalPath(of: tree.outside.appendingPathComponent("later.md"))
        )
    }

    // MARK: - A leaf appended to a folder that was already validated

    /// SONNY-264, at the level of bytes, for the first of the two sites inside `PathWhitelist`.
    ///
    /// `defaultOutputFile` validates the *folder* and then appends the generated filename, so before
    /// the fix the leaf never met a `validate...` method. A dangling symbolic link planted at that
    /// name is the shape nothing upstream catches — `fileExists` follows it to a target that is not
    /// there and reports the path absent, so no resolution ever ran on it — and the URL handed back
    /// was a link pointing out of the boundary.
    ///
    /// Written without `.atomic`, deliberately, for the same reason
    /// `aSymlinkLeafPointingOutsideIsRefusedRatherThanCreatingItsTargetOutThere` is: the writer on
    /// the far side of a generated zip name is `/usr/bin/zip`, which opens the path and follows the
    /// link. An atomic-only write replaces the link instead and would report this hole as closed.
    @Test
    func aGeneratedDefaultFilenameThatIsALinkOutOfTheRootIsRefusedRatherThanWrittenThrough() throws {
        let tree = try SymlinkTree()
        defer { tree.tearDown() }
        let target = tree.outside.appendingPathComponent("note.md")
        try FileManager.default.createSymbolicLink(
            at: tree.root.appendingPathComponent("note.md"),
            withDestinationURL: target
        )

        let attempt = tree.attemptWrite(atomically: false) {
            try tree.whitelist.defaultOutputFile(name: "note", extension: "md")
        }

        #expect(attempt.landedAt == nil, "bytes reached \(attempt.landedAt ?? "") through an accepted path")
        #expect(tree.isOutsideWhitelist(attempt.error), "expected a containment refusal, got \(attempt.errorText)")
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    /// The other direction, and the reason the fix is a validation rather than a refusal of links: a
    /// generated leaf that is a link *staying inside* the root is followed, and the bytes land at its
    /// target. This is what `validateOutputPath` has always done for a user-named path; the generated
    /// one now behaves identically instead of being a second, unexamined rule.
    @Test
    func aGeneratedDefaultFilenameThatIsALinkStayingInsideIsFollowedToItsTarget() throws {
        let tree = try SymlinkTree()
        defer { tree.tearDown() }
        let real = tree.root.appendingPathComponent("Archive", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let target = real.appendingPathComponent("note.md")
        try FileManager.default.createSymbolicLink(
            at: tree.root.appendingPathComponent("note.md"),
            withDestinationURL: target
        )

        let attempt = tree.attemptWrite(atomically: false) {
            try tree.whitelist.defaultOutputFile(name: "note", extension: "md")
        }

        #expect(attempt.errorText == "none")
        #expect(attempt.accepted?.path == real.appendingPathComponent("note.md").path)
        #expect(attempt.landedAt == SymlinkTree.physicalPath(of: target))
    }

    /// The second site inside `PathWhitelist`: `resolveOutputPath` given a path that is an existing
    /// *directory* appends the generated name inside it, which is the same composition by a different
    /// door. `CreateLocalDraftCapabilityAdapter` and `WebResearchMarkdownCapabilityAdapter` both
    /// reach it whenever a plan names a folder rather than a file.
    @Test
    func theDirectoryBranchOfResolveOutputPathValidatesTheLeafItAppends() throws {
        let tree = try SymlinkTree()
        defer { tree.tearDown() }
        let target = tree.outside.appendingPathComponent("draft.md")
        try FileManager.default.createSymbolicLink(
            at: tree.root.appendingPathComponent("draft.md"),
            withDestinationURL: target
        )

        let attempt = tree.attemptWrite(atomically: false) {
            try tree.whitelist.resolveOutputPath(
                rawPath: tree.root.path,
                defaultName: "draft",
                extension: "md",
                fileManager: .default
            )
        }

        #expect(attempt.landedAt == nil, "bytes reached \(attempt.landedAt ?? "") through an accepted path")
        #expect(tree.isOutsideWhitelist(attempt.error), "expected a containment refusal, got \(attempt.errorText)")
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    /// The ordinary case through that same branch, so the refusal above is not paid for by breaking
    /// every draft written into a folder. Asserted on the composed path and on where the bytes went,
    /// because a returned URL that is never written through proves nothing about the write.
    @Test
    func theDirectoryBranchStillComposesTheGeneratedNameInsideTheFolder() throws {
        let tree = try SymlinkTree()
        defer { tree.tearDown() }

        let attempt = tree.attemptWrite(atomically: false) {
            try tree.whitelist.resolveOutputPath(
                rawPath: tree.root.path,
                defaultName: "draft",
                extension: "md",
                fileManager: .default
            )
        }

        #expect(attempt.errorText == "none")
        #expect(attempt.accepted?.lastPathComponent == "draft.md")
        #expect(attempt.landedAt == SymlinkTree.physicalPath(of: tree.root.appendingPathComponent("draft.md")))
    }

    /// **The door's other half, which a reviewer's mutation battery found held by nothing**
    /// (PR #157's review, F5, mutant V4). `validateOutputFile(named:in:)` routes through
    /// `validateOutputPath` rather than `validateInsideWhitelist`, and swapping the two leaves
    /// containment perfectly intact while dropping the parent checks — the whole suite stayed green.
    ///
    /// Those checks are a decision SONNY-264 recorded and nothing pinned: `defaultOutputFile`'s
    /// no-folder branch now refuses a whitelist root that does not exist, where before it handed back
    /// a URL and the write failed later with `Data.write(to:)`'s own message naming a folder rather
    /// than the missing one. Both refusals are asserted, because the two are different sentences a
    /// user reads — a folder that is not there, and a "folder" that is a file.
    @Test
    func theDoorRefusesAFolderThatIsMissingOrIsNotAFolderRatherThanComposingIntoIt() throws {
        let tree = try SymlinkTree()
        defer { tree.tearDown() }
        let missing = tree.root.appendingPathComponent("NotCreatedYet", isDirectory: true)
        let file = tree.root.appendingPathComponent("a-file.txt")
        try Data("bytes".utf8).write(to: file)

        let intoMissing = tree.attemptWrite { try tree.whitelist.validateOutputFile(named: "note.md", in: missing) }
        let intoFile = tree.attemptWrite { try tree.whitelist.validateOutputFile(named: "note.md", in: file) }

        #expect(intoMissing.landedAt == nil, "bytes reached \(intoMissing.landedAt ?? "")")
        #expect(tree.isParentMissing(intoMissing.error), "expected parentMissing, got \(intoMissing.errorText)")
        #expect(intoFile.landedAt == nil, "bytes reached \(intoFile.landedAt ?? "")")
        #expect(tree.isNotDirectory(intoFile.error), "expected notDirectory, got \(intoFile.errorText)")
    }

    /// The same decision at the caller SONNY-264's closing comment names: a whitelist whose only root
    /// does not exist refuses the generated default outright, instead of handing back a URL whose
    /// write fails later with a message naming the wrong thing.
    @Test
    func aGeneratedDefaultIsRefusedWhenTheWhitelistRootDoesNotExist() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacAgentTests-\(UUID().uuidString)", isDirectory: true)
        let whitelist = PathWhitelist(roots: [root])

        var caught: Error?
        do {
            _ = try whitelist.defaultOutputFile(name: "draft", extension: "md")
        } catch {
            caught = error
        }

        guard let validation = caught as? PathValidationError, case .parentMissing = validation else {
            Issue.record("expected parentMissing, got \(String(describing: caught))")
            return
        }
    }

    /// A leaf that is not a link at all still has to reach the containment check, because
    /// `appendingPathComponent` will happily compose `..` out of the folder. Nothing generates such a
    /// name today — every caller passes a slug or a timestamp — so this pins the property rather than
    /// a reachable defect, and it is the one assertion here that would still fail if
    /// `validateOutputFile` were reduced to a plain `appendingPathComponent`.
    @Test
    func aGeneratedLeafThatClimbsOutOfTheFolderIsRefusedByContainment() throws {
        let tree = try SymlinkTree()
        defer { tree.tearDown() }

        let attempt = tree.attemptWrite(atomically: false) {
            try tree.whitelist.validateOutputFile(named: "../escaped.md", in: tree.root)
        }

        #expect(attempt.landedAt == nil, "bytes reached \(attempt.landedAt ?? "") through an accepted path")
        #expect(tree.isOutsideWhitelist(attempt.error), "expected a containment refusal, got \(attempt.errorText)")
    }
}

// MARK: - Fixture

/// A whitelist root, an unrelated folder outside it, and a symlink from one to the other.
private struct SymlinkTree {
    let root: URL
    let outside: URL
    let link: URL
    let whitelist: PathWhitelist

    init() throws {
        root = try makeDirectory()
        outside = try makeDirectory()
        link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        whitelist = PathWhitelist(roots: [root])
    }

    /// What one output path did: what the whitelist answered, and — when it accepted — where the
    /// bytes written to the URL it handed back physically ended up.
    struct OutputAttempt {
        var accepted: URL?
        var landedAt: String?
        var error: Error?

        var errorText: String {
            guard let error else {
                return "none"
            }
            return String(describing: error)
        }
    }

    /// `atomically` models the two kinds of writer this repository actually has on the far side of a
    /// validated path: Foundation's atomic write, which replaces a symlink at the leaf, and an
    /// ordinary `open` — `/usr/bin/zip`, an app told to save somewhere — which follows it.
    func attemptOutput(at rawPath: String, atomically: Bool = true) -> OutputAttempt {
        attemptWrite(atomically: atomically) { try whitelist.validateOutputPath(rawPath) }
    }

    /// The same proof for a URL the whitelist **composes** rather than one it is handed — the
    /// generated-leaf sites SONNY-264 closed. Split out of `attemptOutput` rather than copied, so
    /// every test here decides where the bytes went by the same two lines.
    func attemptWrite(atomically: Bool = true, producing url: () throws -> URL) -> OutputAttempt {
        var attempt = OutputAttempt()
        do {
            let target = try url()
            attempt.accepted = target
            try Data("bytes".utf8).write(to: target, options: atomically ? [.atomic] : [])
            attempt.landedAt = Self.physicalPath(of: target)
        } catch {
            attempt.error = error
        }
        return attempt
    }

    /// A chain of `length` symbolic links inside the root, `l1 -> l2 -> … -> lN -> target`, with
    /// `target` not existing — which is the ordinary shape of an output path, and the shape a shell
    /// loop produces in a second. Built from the far end back so each link names one that is
    /// already there. Returns the head, `l1`.
    func chain(length: Int, endingAt target: URL) throws -> URL {
        let fileManager = FileManager.default
        var destination = target
        for index in stride(from: length, through: 1, by: -1) {
            let link = root.appendingPathComponent("l\(index)")
            try? fileManager.removeItem(at: link)
            try fileManager.createSymbolicLink(at: link, withDestinationURL: destination)
            destination = link
        }
        return root.appendingPathComponent("l1")
    }

    /// Where a file really is, asked of the OS. `realpath` rather than any Foundation URL method,
    /// so the answer cannot come from the same resolution these tests exist to check.
    static func physicalPath(of url: URL) -> String? {
        guard let resolved = realpath(url.path, nil) else {
            return nil
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    func isOutsideWhitelist(_ error: Error?) -> Bool {
        guard let validation = error as? PathValidationError, case .outsideWhitelist = validation else {
            return false
        }
        return true
    }

    func isParentMissing(_ error: Error?) -> Bool {
        guard let validation = error as? PathValidationError, case .parentMissing = validation else {
            return false
        }
        return true
    }

    func isNotDirectory(_ error: Error?) -> Bool {
        guard let validation = error as? PathValidationError, case .notDirectory = validation else {
            return false
        }
        return true
    }

    func isSymbolicLinkRejected(_ error: Error?) -> Bool {
        guard let validation = error as? PathValidationError, case .symbolicLinkRejected = validation else {
            return false
        }
        return true
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: outside)
    }
}
