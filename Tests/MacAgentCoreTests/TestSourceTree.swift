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
    static let targets = ["MacAgentCoreTests", "MacAgentTests", "MacAgentTestSupport"]

    /// `Tests/`, from this file's own location.
    static var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
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
        let directory = root.appendingPathComponent(target)
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            throw TreeError.unreadableTarget(target)
        }
        let prefix = directory.path + "/"
        var files: [SourceFile] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let relative = url.path.hasPrefix(prefix) ? String(url.path.dropFirst(prefix.count)) : url.lastPathComponent
            files.append(SourceFile(relativePath: "\(target)/\(relative)", url: url))
        }
        return files.sorted { $0.relativePath < $1.relativePath }
    }

    static func read(_ file: SourceFile) throws -> String {
        try String(contentsOf: file.url, encoding: .utf8)
    }

    /// Lines that are not comment-prefixed, keeping their original 1-based numbers.
    ///
    /// Comment-*prefixed* rather than every line *containing* `//`: the narrower `grep -v "//"` this
    /// repo was bitten by during row C drops a real construction that carries a trailing note.
    static func codeLines(of source: String) -> [(number: Int, text: String)] {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .map { (number: $0.offset + 1, text: String($0.element)) }
            .filter { !$0.text.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
    }
}
