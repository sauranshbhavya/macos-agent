import Foundation
import MacAgentTestSupport
import Testing
@testable import MacAgentCore

/// SONNY-242. The words a person puts in front of a name that are never part of the name, and how
/// `PathWhitelist` resolves and refuses an output path.
@Suite
@MainActor
struct SpokenPathTests {
    // MARK: - The list, and the phrases people actually use

    /// The separator between an article and the name it precedes is any whitespace, not a literal
    /// U+0020 (PR #106 review, F5). Dictation and pasted rich text produce non-breaking spaces, and
    /// the difference is invisible on screen.
    @Test
    func aNonBreakingSpaceSeparatesAnArticleJustAsAPlainOneDoes() {
        #expect(SpokenName.withoutLeadingArticle("my\u{00A0}Safari") == "Safari")
    }

    /// The name reading strips once, because `InstantCommandResolver` matches the original
    /// candidate alongside the stripped one and would otherwise lose `The Archive` as a routine name.
    @Test
    func theNameReadingStripsOnce() {
        #expect(SpokenName.withoutLeadingArticle("my The Archive") == "The Archive")
        #expect(SpokenName.withoutLeadingArticle("The Archive") == "Archive")
    }

    @Test
    func everyLeadingArticleComesOffAName() {
        for article in SpokenName.leadingArticles {
            #expect(SpokenName.withoutLeadingArticle("\(article) Safari") == "Safari")
        }
    }

    // MARK: - The existence probe

    /// Records what `resolveOutputPath` asks the filesystem about.
    ///
    /// The probe is the whole of the second defect, so this pins the question rather than a
    /// downstream consequence of it — and it needs no real folder to do that, which is what lets
    /// this test say something exact about a relative path without reading the developer's home.
    private final class ProbeRecordingFileManager: FileManager, @unchecked Sendable {
        var probedPaths: [String] = []

        override func fileExists(atPath path: String) -> Bool {
            probedPaths.append(path)
            return super.fileExists(atPath: path)
        }
    }

    /// `resolveOutputPath` used to probe `(rawPath as NSString).expandingTildeInPath`, which leaves
    /// a relative name relative — so it asked the process's *working directory* a question every
    /// other line in that file asks the home directory. A bare `Desktop` therefore answered "no such
    /// directory" from an app whose working directory is `/`, fell through, and named `~/Desktop` —
    /// the folder itself — as the file to write.
    @Test
    func theExistenceProbeAsksAboutThePathThisTypeWouldResolve() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpokenPathTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let whitelist = PathWhitelist(roots: [root])
        let recorder = ProbeRecordingFileManager()
        let home = FileManager.default.homeDirectoryForCurrentUser

        // Throws, because a temp-rooted whitelist contains no home path — the probe has already
        // happened by then, and the probe is what is under test.
        _ = try? whitelist.resolveOutputPath(
            rawPath: "Desktop",
            defaultName: "draft",
            extension: "md",
            fileManager: recorder
        )

        #expect(recorder.probedPaths == [
            home.appendingPathComponent("Desktop", isDirectory: true).resolvingSymlinksInPath().path
        ])
        #expect(!recorder.probedPaths.contains("Desktop"))
    }

    /// The branch the probe exists to reach, on a folder that really is inside the whitelist: an
    /// existing directory takes the generated name *inside* it rather than becoming the file.
    @Test
    func anExistingDirectoryTakesTheGeneratedNameInsideIt() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpokenPathTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let resolved = try PathWhitelist(roots: [root]).resolveOutputPath(
            rawPath: root.path,
            defaultName: "draft",
            extension: "md",
            fileManager: .default
        )

        #expect(resolved.deletingLastPathComponent().path == root.resolvingSymlinksInPath().path)
        #expect(resolved.lastPathComponent == "draft.md")
    }

    // MARK: - The refusal copy

    /// "Outside the writable whitelist" named an implementation detail the reader has no way to know
    /// about. The sentence has to survive the workspace detail sheet rendering it after
    /// "Not in effect — ", which is why the path stays at the front.
    @Test
    func theRefusalCopyIsPlainAndLeadsWithThePath() {
        // `asked: nil` is the ordinary refusal — the person named a folder Sonny cannot use, and
        // nothing resolved the path out from under them. SONNY-249's second sentence, for a path a
        // symbolic link led out of, is pinned in `PathContainmentResolutionTests`.
        let error = PathValidationError.outsideWhitelist(
            path: "/Users/someone/Downloads",
            asked: nil,
            roots: ["/Users/someone/Desktop", "/Users/someone/Documents"]
        )
        #expect(
            error.errorDescription
                == "/Users/someone/Downloads is not one of the folders Sonny can use: /Users/someone/Desktop, /Users/someone/Documents."
        )
    }
}
