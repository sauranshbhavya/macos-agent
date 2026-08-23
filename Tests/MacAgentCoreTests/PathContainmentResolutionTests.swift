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
    /// Reads the home directory and writes nothing. Skipped where its precondition does not hold —
    /// no `~/Desktop`, or a case-sensitive home volume — because there is no defect to see there.
    @Test
    func theLowercaseSpellingOfARealFolderResolvesToItForAFileThatDoesNotExistYet() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let desktop = home.appendingPathComponent("Desktop", isDirectory: true)
        let lowercased = home.appendingPathComponent("desktop", isDirectory: true)
        guard FileManager.default.fileExists(atPath: desktop.path),
              FileManager.default.fileExists(atPath: lowercased.path) else {
            return
        }

        let folder = PathWhitelist.canonicalURL(lowercased.path)
        let file = PathWhitelist.canonicalURL(lowercased.appendingPathComponent("note.md").path)

        #expect(folder.path == desktop.path)
        #expect(file.path == desktop.appendingPathComponent("note.md").path)
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

    /// A symlink that points at itself is the one shape resolution cannot answer for: the OS refuses
    /// to follow it, and re-reading it forever is not an option, so the resolver gives up and leaves
    /// the link in the path. That is what keeps `validateOutputPath`'s parent check alive rather than
    /// leaving it as a guard nothing can reach — it is now the refusal for links resolution could not
    /// follow, not a second opinion about containment.
    @Test
    func aSymlinkLoopIsRefusedByTheSymlinkCheckThatResolutionCannotAnswerFor() throws {
        let tree = try SymlinkTree()
        defer { tree.tearDown() }
        let loop = tree.root.appendingPathComponent("loop")
        try FileManager.default.createSymbolicLink(atPath: loop.path, withDestinationPath: "loop")

        let attempt = tree.attemptOutput(at: loop.appendingPathComponent("note.md").path)

        #expect(attempt.landedAt == nil)
        #expect(tree.isSymbolicLinkRejected(attempt.error), "expected a symlink refusal, got \(attempt.errorText)")
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
        var attempt = OutputAttempt()
        do {
            let url = try whitelist.validateOutputPath(rawPath)
            attempt.accepted = url
            try Data("bytes".utf8).write(to: url, options: atomically ? [.atomic] : [])
            attempt.landedAt = Self.physicalPath(of: url)
        } catch {
            attempt.error = error
        }
        return attempt
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
