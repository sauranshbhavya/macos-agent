import Foundation

/// The test tree as the compiler sees it, shared by the two source-scan suites (SONNY-123, PR #72 C4).
///
/// **Why recursive.** `FileManager.contentsOfDirectory` lists one directory; a SwiftPM target's
/// `path:` is compiled recursively. Both scan suites enumerated one level deep, so a file at
/// `Tests/MacAgentCoreTests/Anything/Live.swift` was compiled into the target and invisible to every
/// pin — measured by the cycle-2 review, which built exactly that file with a live readiness service
/// in it and watched all nine pins pass. No subdirectory exists under either target today, so the
/// hole was latent rather than live; it is closed here rather than recorded because the fix is one
/// enumerator.
///
/// **Why paths are target-qualified.** Both suites exempted their own file by basename, which would
/// also have skipped a same-named file in the *other* target. `relativePath` carries the target, so
/// an exemption names one file rather than a name.
///
/// One copy, in the core target, because both suites that use it live there. The permission stub and
/// the privilege trait were twinned once and are not any more — they live in `MacAgentTestSupport`,
/// which both test targets depend on (SONNY-172).
enum TestSourceTree {
    /// **Every directory SwiftPM compiles a test file from, which is what makes the scans complete.**
    ///
    /// `MacAgentTestSupport` is here for a specific reason rather than for symmetry: SONNY-172 moved
    /// `DeterministicPermissions.swift` and `UnprivilegedProcess.swift` into it, and the file whose
    /// entire job is being the deterministic alternative to a live permission checker would
    /// otherwise sit outside `LivePermissionCheckerScanTests`' reach. A scan that stops covering the
    /// files a refactor moved is the silent hole this repository keeps paying for; a target added to
    /// `Package.swift` and not added here is exactly that.
    ///
    /// `LivePermissionCheckerScanTests` pins this list against `Package.swift`'s own test targets, so
    /// nothing that is not a SwiftPM test target may be added to it.
    static let targets = ["MacAgentCoreTests", "MacAgentTests", "MacAgentTestSupport"]

    /// `Tests/`, from this file's own location.
    static var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    /// The repository root, which is `Tests/`'s parent. Derived from this file's own path rather than
    /// from the working directory, for the reason `root` is: a test process's working directory is
    /// SwiftPM's to choose.
    static var repositoryRoot: URL {
        root.deletingLastPathComponent()
    }

    struct SourceFile {
        /// Target-qualified and slash-separated, e.g. `MacAgentCoreTests/DeterministicPermissions.swift`.
        let relativePath: String
        let url: URL
    }

    enum TreeError: Error {
        case unreadableTarget(String)
    }

    /// Every `.swift` file compiled into `target`, at any depth, in a stable order.
    static func swiftFiles(in target: String) throws -> [SourceFile] {
        try files(in: root.appendingPathComponent(target), withExtension: "swift", labelledBy: target)
    }

    /// Every `.swift` file compiled into a `Sources/` target, at any depth, in a stable order.
    ///
    /// The `Tests/`-side twin of ``swiftFiles(in:)``, added by SONNY-395 because a new sweep over
    /// `Sources/MacAgentCore` had hand-rolled `contentsOfDirectory` and inherited the exact hole
    /// this type's header describes — one level deep against a `path:` SwiftPM compiles
    /// recursively. Same walker, so a `Sources/` scan cannot drift from a `Tests/` one.
    static func sourceFiles(in target: String) throws -> [SourceFile] {
        try files(
            in: repositoryRoot.appendingPathComponent("Sources").appendingPathComponent(target),
            withExtension: "swift",
            labelledBy: target
        )
    }

    private static func files(
        in directory: URL,
        withExtension pathExtension: String,
        labelledBy label: String
    ) throws -> [SourceFile] {
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            throw TreeError.unreadableTarget(label)
        }
        let prefix = directory.path + "/"
        var files: [SourceFile] = []
        for case let url as URL in walker where url.pathExtension == pathExtension {
            let relative = url.path.hasPrefix(prefix) ? String(url.path.dropFirst(prefix.count)) : url.lastPathComponent
            files.append(SourceFile(relativePath: "\(label)/\(relative)", url: url))
        }
        return files.sorted { $0.relativePath < $1.relativePath }
    }

    static func read(_ file: SourceFile) throws -> String {
        try String(contentsOf: file.url, encoding: .utf8)
    }

    /// How a comment opens in a Swift source line. `///` and `//!` both start with `//`.
    static let swiftCommentPrefixes = ["//"]

    /// Lines that are not comment-prefixed, keeping their original 1-based numbers.
    ///
    /// Comment-*prefixed* rather than every line *containing* `//`: the narrower `grep -v "//"` this
    /// repo was bitten by during row C drops a real construction that carries a trailing note. The
    /// same limit applies in the other direction and always has: a comment that *trails* code on the
    /// same line is not dropped.
    static func codeLines(
        of source: String,
        droppingLinesStartingWith prefixes: [String] = TestSourceTree.swiftCommentPrefixes
    ) -> [(number: Int, text: String)] {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .map { (number: $0.offset + 1, text: String($0.element)) }
            .filter { line in
                let trimmed = line.text.trimmingCharacters(in: .whitespaces)
                return !prefixes.contains { trimmed.hasPrefix($0) }
            }
    }
}
