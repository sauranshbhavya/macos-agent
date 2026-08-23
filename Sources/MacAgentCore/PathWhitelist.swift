import Foundation

public enum PathValidationError: Error, Equatable, LocalizedError {
    case pathIsEmpty
    case outsideWhitelist(String, [String])
    case notFound(String)
    case notDirectory(String)
    case symbolicLinkRejected(String)
    case parentMissing(String)

    public var errorDescription: String? {
        switch self {
        case .pathIsEmpty:
            return "The path is empty."
        case .outsideWhitelist(let path, let roots):
            // "Outside the writable whitelist" named an implementation detail the person reading it
            // has no way to know about, and then listed the roots — one of which, in SONNY-242's
            // report, was the folder they had plainly asked for. The resolution fix is what makes
            // the path in this sentence the one they meant; this half is only the sentence saying
            // it plainly. Path first, because the workspace detail sheet renders this after
            // "Not in effect — " and needs the subject at the front.
            return "\(path) is not one of the folders Sonny can use: \(roots.joined(separator: ", "))."
        case .notFound(let path):
            return "\(path) does not exist."
        case .notDirectory(let path):
            return "\(path) is not a directory."
        case .symbolicLinkRejected(let path):
            return "\(path) is a symbolic link Sonny could not follow."
        case .parentMissing(let path):
            return "The parent folder for \(path) does not exist."
        }
    }
}

public struct PathWhitelist: Sendable {
    public let roots: [URL]

    public init(roots: [URL]? = nil) {
        if let roots {
            self.roots = roots.map(Self.normalizedURL)
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            self.roots = [
                home.appendingPathComponent("Desktop", isDirectory: true),
                home.appendingPathComponent("Documents", isDirectory: true)
            ].map(Self.normalizedURL)
        }
    }

    public var displayRoots: [String] {
        roots.map(\.path)
    }

    public func validateExistingDirectory(_ rawPath: String) throws -> URL {
        let url = try validateInsideWhitelist(rawPath)
        // Before existence, because a link the resolver could not follow is reported by
        // `fileExists` as absent and the honest answer is not "no such folder". See
        // `symbolicLinkRejected`'s note on `validateOutputPath` for why this is the only shape
        // that reaches either check now.
        if Self.isSymbolicLink(url) {
            throw PathValidationError.symbolicLinkRejected(url.path)
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PathValidationError.notFound(url.path)
        }

        let values = try url.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else {
            throw PathValidationError.notDirectory(url.path)
        }
        return url
    }

    public func validateOutputPath(_ rawPath: String) throws -> URL {
        let url = try validateInsideWhitelist(rawPath)
        let parent = url.deletingLastPathComponent()
        // **What this check is for changed with SONNY-249, and it is worth saying which rule it now
        // carries.** It used to be the mechanism that kept a write from leaving the whitelist, and
        // it was a bad one: it sees the immediate parent only, so a symlink one level up was caught
        // and two levels up was not — `<root>/link/sub/new.md` was accepted and the bytes landed in
        // `<outside>/sub/new.md`. Containment is that mechanism now, because `canonicalURL`
        // resolves the path before comparing it, and a link is judged by where it leads.
        //
        // What is left here is the one shape resolution cannot answer for: a link it could not
        // follow — a loop, or a chain longer than the kernel itself will follow. That path was
        // compared *without* following the link, so the containment verdict above says nothing
        // about it, and refusing is the only safe reading. It runs before the existence guard
        // because `fileExists` follows links, so a loop reads as absent and would otherwise be
        // reported as a missing parent, which is not what is wrong with it.
        if Self.isSymbolicLink(parent) {
            throw PathValidationError.symbolicLinkRejected(parent.path)
        }
        guard FileManager.default.fileExists(atPath: parent.path) else {
            throw PathValidationError.parentMissing(parent.path)
        }

        let values = try parent.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else {
            throw PathValidationError.notDirectory(parent.path)
        }
        return url
    }

    public func validateInsideWhitelist(_ rawPath: String) throws -> URL {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw PathValidationError.pathIsEmpty
        }

        let resolved = Self.canonicalURL(trimmed)
        let allowed = roots.contains { root in
            // `canonicalURL` on both sides rather than `resolvingSymlinksInPath` on this one: for a
            // root that exists the two are the same call, and for one that does not — a whitelist
            // pointed at a folder the user has not created yet — only the first resolves anything,
            // and a root resolved differently from the candidates compared against it is a boundary
            // that answers nothing correctly.
            Self.contains(root: Self.canonicalURL(root.path), candidate: resolved)
        }

        guard allowed else {
            throw PathValidationError.outsideWhitelist(resolved.path, displayRoots)
        }
        return resolved
    }

    public func defaultOutputFile(name: String, extension ext: String, in rawFolder: String? = nil) throws -> URL {
        let folder: URL
        if let rawFolder, !rawFolder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            folder = try validateExistingDirectory(rawFolder)
        } else {
            folder = roots[0]
        }
        return folder.appendingPathComponent("\(name).\(ext)")
    }

    /// Resolves a user-supplied output path, falling back to a generated default file.
    /// If `rawPath` names an existing directory, `defaultName`/`ext` are appended inside it.
    ///
    /// **The existence probe asks about the path this type would resolve, not about a different
    /// one** (SONNY-242). It used to expand only the tilde, so a *relative* folder name was tested
    /// against the process's working directory while every other line in this file resolved it
    /// against the home directory. `Desktop` therefore answered "no such directory" from an app
    /// whose working directory is `/`, fell through to `validateOutputPath`, and named
    /// `~/Desktop` — the folder itself — as the file to write. The write then fails, because
    /// `Data.write(to:)` on a directory throws (measured: "The file ... couldn't be saved in the
    /// folder ..."), so the draft the person asked for is simply lost. The two answers also
    /// disagreed by *where the process happened to be* — a suite run from a home directory and one
    /// run from a checkout would take different branches. `canonicalURL` is the same expansion
    /// `validateInsideWhitelist` performs on the very next line, which is what makes the probe and
    /// the validation one question rather than two.
    public func resolveOutputPath(
        rawPath: String?,
        defaultName: String,
        extension ext: String,
        fileManager: FileManager
    ) throws -> URL {
        if let rawPath, !rawPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let expanded = Self.canonicalURL(rawPath).path
            if fileManager.fileExists(atPath: expanded) {
                let url = try validateInsideWhitelist(rawPath)
                let values = try url.resourceValues(forKeys: [.isDirectoryKey])
                if values.isDirectory == true {
                    return url.appendingPathComponent("\(defaultName).\(ext)")
                }
                return try validateOutputPath(rawPath)
            }
            return try validateOutputPath(rawPath)
        }

        return try defaultOutputFile(name: defaultName, extension: ext)
    }

    /// The canonical form every containment check in this type compares: tilde and
    /// relative-to-home expansion, standardization (which is what collapses `..`), then symlink and
    /// on-disk-spelling resolution of **the longest prefix of the path that exists**.
    ///
    /// Public, together with `contains(root:candidate:)`, so a *narrower* boundary — a workspace's
    /// restriction scope — can be evaluated with this whitelist's own path arithmetic instead of a
    /// second one. Two path comparisons that disagree about `..` or a symlink is a security bug, not
    /// a style one. Nothing here widens the whitelist: a path this resolves is still subject to
    /// `validateInsideWhitelist` before any capability touches it.
    ///
    /// **Why the longest existing prefix and not the whole path** (SONNY-249). This used to end in
    /// a bare `resolvingSymlinksInPath()`, which resolves nothing at all for a path that is not on
    /// disk — and nearly every path Sonny is asked to *write* is not on disk yet, so that was the
    /// common case, not the edge. It made the boundary answer two different questions wrongly, and
    /// both are now covered by tests in `PathContainmentResolutionTests`:
    ///
    /// - A write escaped. `validateOutputPath` looked at the immediate parent for a symlink, so one
    ///   level up was caught and two were not: `<root>/link/sub/new.md` was accepted as being
    ///   inside, and the bytes landed in `<outside>/sub/new.md`. The boundary said inside and the
    ///   file went outside.
    /// - A folder the filesystem considers the same folder was refused. On a case-insensitive
    ///   volume `resolvingSymlinksInPath()` adopts the on-disk spelling, but again only for a path
    ///   that exists — so `desktop` became `Desktop` and was accepted while `desktop/note.md` did
    ///   not and was refused. The same sentence worked or failed depending on whether it named a
    ///   file.
    ///
    /// Resolving the prefix that is really there answers both, because it is the OS's own answer:
    /// it follows the intermediate link, and it adopts the real spelling of every component that
    /// exists. The components that do not exist are appended as written, which is the only honest
    /// thing to do with them — nothing on disk has an opinion about a file nobody has created. On a
    /// case-*sensitive* volume the differently-cased prefix does not exist, so it correctly resolves
    /// nothing.
    ///
    /// **The returned URL is the one callers write through**, which is what makes this a boundary
    /// rather than a description: every capability writes to the URL a `validate...` method handed
    /// back, never to the string the plan named. So the path that was checked and the path the bytes
    /// go to are the same path.
    ///
    /// **Two limits, stated rather than left to be found.** A component created between this
    /// resolution and the write is not seen — the check is a check, and closing that would mean
    /// opening every output file without following links, at every write site. And a link this
    /// cannot follow (a loop, or a chain longer than the budget below) stays in the returned path;
    /// `validateOutputPath` and `validateExistingDirectory` refuse those rather than pretending the
    /// comparison meant something.
    public static func canonicalURL(_ rawPath: String) -> URL {
        resolvingExistingPrefix(
            normalizedURL(expandPath(rawPath.trimmingCharacters(in: .whitespacesAndNewlines)))
        )
    }

    /// How many symbolic links one resolution will follow before giving up, which is the number the
    /// kernel itself stops at — `getconf SYMLOOP_MAX` prints 32 on macOS 15 (Darwin 25.5.0), and
    /// the constant is not exposed to Swift, so it is written here rather than read.
    ///
    /// Matching it is the point rather than a coincidence. The links this counts are a subset of
    /// the links a lookup of the same path has to traverse, so a chain long enough to exhaust this
    /// budget is a chain `open` refuses with `ELOOP` — nothing can be written through a path this
    /// resolver gave up on.
    private static let maximumSymbolicLinkHops = 32

    /// The result of one resolution pass: either the final answer, or a path rewritten through a
    /// symbolic link that has to be resolved again from the top.
    private enum ResolutionPass {
        case resolved(URL)
        case followedLink(URL)
    }

    private static func resolvingExistingPrefix(_ url: URL) -> URL {
        var current = url
        // One extra pass beyond the hop budget, so a chain of exactly `maximumSymbolicLinkHops`
        // links still gets the pass that turns its destination into an answer.
        for _ in 0...maximumSymbolicLinkHops {
            switch resolutionPass(current) {
            case .resolved(let resolved):
                return resolved
            case .followedLink(let rewritten):
                current = rewritten
            }
        }
        return current
    }

    private static func resolutionPass(_ url: URL) -> ResolutionPass {
        let fileManager = FileManager.default
        var unwritten: [String] = []
        var existing = url
        // Upwards, so the ordinary case — a path that is entirely there — costs one `stat` rather
        // than one per component. The walk ends at the filesystem root: `pathComponents` for `/` is
        // a single element, which bounds this by the length of the path rather than by `/` existing.
        while !fileManager.fileExists(atPath: existing.path), existing.pathComponents.count > 1 {
            unwritten.append(existing.lastPathComponent)
            existing = existing.deletingLastPathComponent()
        }

        let components = Array(unwritten.reversed())
        var resolved = existing.resolvingSymlinksInPath()
        for (index, component) in components.enumerated() {
            resolved.appendPathComponent(component)
            guard let destination = symbolicLinkDestination(of: resolved) else {
                continue
            }
            // A link whose own target does not exist. `fileExists` reported it absent, so the walk
            // above stepped straight past it, and `resolvingSymlinksInPath()` leaves it alone
            // (measured) — it is the one link shape nothing else here would have followed, and
            // `/usr/bin/zip` writing to `outputURL.path` follows it happily.
            var rewritten = destination
            for remaining in components.dropFirst(index + 1) {
                rewritten.appendPathComponent(remaining)
            }
            return .followedLink(rewritten.standardizedFileURL)
        }
        return .resolved(resolved.standardizedFileURL)
    }

    /// Where a symbolic link points, or `nil` for anything that is not one. A relative destination
    /// is resolved against the link's own folder, the way the kernel resolves it.
    private static func symbolicLinkDestination(of url: URL) -> URL? {
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else {
            return nil
        }
        if destination.hasPrefix("/") {
            return URL(fileURLWithPath: destination)
        }
        return URL(fileURLWithPath: destination, relativeTo: url.deletingLastPathComponent()).absoluteURL
    }

    /// Whether the item at `url` is itself a symbolic link, asked without following it — so a link
    /// pointing nowhere, or at itself, answers `true` where `fileExists` answers `false`.
    private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }

    /// Containment as this whitelist defines it: equal, or a path component below. Deliberately a
    /// `root + "/"` prefix test rather than a bare prefix — `/Documents/ClientAlpha` must not count
    /// as inside `/Documents/Client`.
    ///
    /// Both sides are expected to be `canonicalURL` output already; passing a raw path here compares
    /// unresolved text and is a mistake.
    public static func contains(root: URL, candidate: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let candidatePath = candidate.standardizedFileURL.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    private static func expandPath(_ rawPath: String) -> URL {
        let expanded = (rawPath as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded)
        }

        if expanded.hasPrefix("Desktop/") || expanded == "Desktop" {
            return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(expanded)
        }

        if expanded.hasPrefix("Documents/") || expanded == "Documents" {
            return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(expanded)
        }

        return URL(fileURLWithPath: expanded, relativeTo: FileManager.default.homeDirectoryForCurrentUser).absoluteURL
    }

    private static func normalizedURL(_ url: URL) -> URL {
        url.standardizedFileURL
    }
}

public enum Timestamp {
    public static func fileSafe(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}
