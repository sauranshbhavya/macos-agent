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
    /// scope — reuses this whitelist's path arithmetic instead of running a second one. This pins
    /// that they *are* the same arithmetic: for every shape that matters, the pair agrees with
    /// `validateInsideWhitelist` about what is inside the root.
    @Test
    func theExposedContainmentAgreesWithValidateInsideWhitelistOnEveryShape() throws {
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
        let candidates = [
            inside.path,
            inside.appendingPathComponent("notes.md").path,
            inside.appendingPathComponent("nested/deep/notes.md").path,
            sibling.appendingPathComponent("notes.md").path,
            inside.appendingPathComponent("../ClientAlpha/notes.md").path,
            link.appendingPathComponent("notes.md").path,
            outside.path,
            root.path
        ]

        for candidate in candidates {
            let validated = (try? whitelist.validateInsideWhitelist(candidate)) != nil
            let contained = PathWhitelist.contains(
                root: PathWhitelist.canonicalURL(inside.path),
                candidate: PathWhitelist.canonicalURL(candidate)
            )
            #expect(validated == contained, "disagreed about \(candidate)")
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
