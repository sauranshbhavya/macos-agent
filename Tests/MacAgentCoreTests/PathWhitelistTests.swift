import Foundation
import Testing
@testable import MacAgentCore

@Suite
struct PathWhitelistTests {
    @Test
    func allowsDirectoryInsideRoot() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let child = root.appendingPathComponent("Project", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)

        let whitelist = PathWhitelist(roots: [root])
        let validated = try whitelist.validateExistingDirectory(child.path)

        #expect(validated.path == child.standardizedFileURL.path)
    }

    @Test
    func rejectsPathOutsideRoot() throws {
        let root = try makeDirectory()
        let outside = try makeDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let whitelist = PathWhitelist(roots: [root])

        do {
            _ = try whitelist.validateExistingDirectory(outside.path)
            Issue.record("Expected outside whitelist error")
        } catch PathValidationError.outsideWhitelist {
        } catch {
            Issue.record("Expected outside whitelist error, got \(error)")
        }
    }

    @Test
    func rejectsSymlinkResolvingOutsideRoot() throws {
        let root = try makeDirectory()
        let outside = try makeDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let link = root.appendingPathComponent("outside-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        let whitelist = PathWhitelist(roots: [root])

        do {
            _ = try whitelist.validateExistingDirectory(link.path)
            Issue.record("Expected outside whitelist error")
        } catch PathValidationError.outsideWhitelist {
        } catch {
            Issue.record("Expected outside whitelist error, got \(error)")
        }
    }

    /// `canonicalURL` + `contains` are exposed so a narrower boundary — a workspace's restriction
    /// scope — reuses this whitelist's path arithmetic instead of running a second one.
    ///
    /// The assertion that carries the weight is the **expected outcome** for each shape, not the
    /// agreement between the two entry points: `validateInsideWhitelist` calls `canonicalURL` and
    /// `contains` itself, so an agreement-only test would be `f(x) == f(x)` and would pass just as
    /// happily if both were wrong together. The agreement check is kept as a second, weaker
    /// assertion — it is what catches a future change that stops routing one path through the
    /// shared helpers.
    @Test
    func theExposedContainmentDecidesEveryPathShapeAndValidateInsideWhitelistAgrees() throws {
        let root = try makeDirectory()
        let outside = try makeDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let inside = root.appendingPathComponent("Client", isDirectory: true)
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        let sibling = root.appendingPathComponent("ClientAlpha", isDirectory: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let link = inside.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        let whitelist = PathWhitelist(roots: [inside])
        let cases: [(path: String, isInside: Bool, why: String)] = [
            (inside.path, true, "the root itself"),
            (inside.appendingPathComponent("notes.md").path, true, "a file directly inside"),
            (inside.appendingPathComponent("nested/deep/notes.md").path, true, "a file nested below"),
            (inside.path + "/", true, "the root with a trailing slash"),
            (sibling.appendingPathComponent("notes.md").path, false, "a sibling folder sharing a prefix"),
            (inside.appendingPathComponent("../ClientAlpha/notes.md").path, false, "parent traversal out"),
            (link.path, false, "a symlink resolving outside"),
            (outside.path, false, "an unrelated folder"),
            (root.path, false, "the parent of the root")
        ]

        for testCase in cases {
            let contained = PathWhitelist.contains(
                root: PathWhitelist.canonicalURL(inside.path),
                candidate: PathWhitelist.canonicalURL(testCase.path)
            )
            #expect(contained == testCase.isInside, "wrong verdict for \(testCase.why): \(testCase.path)")

            let validated = (try? whitelist.validateInsideWhitelist(testCase.path)) != nil
            #expect(validated == contained, "entry points disagreed about \(testCase.why)")
        }
    }

    @Test
    func containmentRejectsASiblingFolderSharingAPrefix() {
        let root = URL(fileURLWithPath: "/tmp/scope/Client", isDirectory: true)

        #expect(
            PathWhitelist.contains(root: root, candidate: URL(fileURLWithPath: "/tmp/scope/Client/x.txt"))
        )
        #expect(PathWhitelist.contains(root: root, candidate: root))
        #expect(
            PathWhitelist.contains(root: root, candidate: URL(fileURLWithPath: "/tmp/scope/ClientAlpha/x.txt")) == false
        )
    }

    @Test
    func validatesOutputParentAndRejectsMissingParent() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let whitelist = PathWhitelist(roots: [root])
        let output = root.appendingPathComponent("nested/out.zip")

        do {
            _ = try whitelist.validateOutputPath(output.path)
            Issue.record("Expected parent missing error")
        } catch PathValidationError.parentMissing {
        } catch {
            Issue.record("Expected parent missing error, got \(error)")
        }
    }
}

func makeDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("MacAgentTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
