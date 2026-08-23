import Foundation

public enum PathValidationError: Error, Equatable, LocalizedError {
    case pathIsEmpty
    /// The path that was refused, the path the person actually asked for when resolution is the
    /// only reason it was refused, and the folders that are allowed.
    case outsideWhitelist(path: String, asked: String?, roots: [String])
    case notFound(String)
    case notDirectory(String)
    case symbolicLinkRejected(String)
    case parentMissing(String)

    public var errorDescription: String? {
        switch self {
        case .pathIsEmpty:
            return "The path is empty."
        case .outsideWhitelist(let path, let asked, let roots):
            // "Outside the writable whitelist" named an implementation detail the person reading it
            // has no way to know about, and then listed the roots — one of which, in SONNY-242's
            // report, was the folder they had plainly asked for. The resolution fix is what makes
            // the path in this sentence the one they meant; this half is only the sentence saying
            // it plainly. Path first, because the workspace detail sheet renders this after
            // "Not in effect — " and needs the subject at the front.
            //
            // Two sentences, because there are two situations (SONNY-249). Ordinarily the refused
            // path is the one the person named and saying it back is enough. When something on the
            // way is a symbolic link leading out of the whitelist, the path that was checked is not
            // the path they typed — and naming only the resolved one shows them somewhere they have
            // never heard of, while naming only the typed one refuses a folder they can plainly see
            // in the allowed list two clauses later, which is the shape SONNY-242 had just finished
            // removing from this same sentence.
            guard let asked else {
                return "\(path) is not one of the folders Sonny can use: \(roots.joined(separator: ", "))."
            }
            return "\(asked) leads to \(path), which is not one of the folders Sonny can use: "
                + "\(roots.joined(separator: ", "))."
        case .notFound(let path):
            return "\(path) does not exist."
        case .notDirectory(let path):
            return "\(path) is not a directory."
        case .symbolicLinkRejected(let path):
            return "\(path) is a symbolic link Sonny could not follow."
        // Thrown from exactly one place — `validateInsideWhitelist`, when resolution did not
        // converge. It used to be thrown from two more, as an `isSymbolicLink` check on the parent
        // and on the folder itself, and those are gone: once a non-convergent resolution is refused
        // outright, every path that reaches them is fully resolved and has no link left to find.
        case .parentMissing(let path):
            return "The parent folder for \(path) does not exist."
        }
    }
}

/// A path resolved as far as the filesystem allows, and whether that resolution finished.
///
/// **Why this is a type and not a `URL`** (SONNY-249's review, F1). Resolution can fail to converge
/// — a symbolic link that points at itself, or a chain longer than the kernel will follow — and the
/// path it has reached by then is not an answer: it is the path it started with, minus however many
/// hops it managed. Returning that as though it were resolved is what let a chain of 34 links read
/// as inside the whitelist while the bytes landed outside, because the kernel's own budget started
/// again from the shortened path and finished the walk that the un-shortened one would have been
/// refused for. The fact that decides whether a path may be compared therefore travels with the
/// path, rather than being dropped at a return statement, and `PathWhitelist.contains` will not
/// compare one that did not converge.
public struct CanonicalPath: Equatable, Sendable {
    /// The path resolution reached. A boundary answer only when `unfollowableLink` is `nil`; for
    /// anything else it is an identity — good enough to key a store by, not to compare with a root.
    public let url: URL

    /// The symbolic link resolution stopped at, when it could not finish: the last one it followed
    /// before the budget ran out, or the loop it kept arriving back at. `nil` when it converged.
    public let unfollowableLink: URL?

    public var isResolved: Bool { unfollowableLink == nil }

    public init(url: URL, unfollowableLink: URL?) {
        self.url = url
        self.unfollowableLink = unfollowableLink
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
        // No symlink check on the parent, and there used to be one (SONNY-249, and then its
        // review's F1). It was the mechanism that kept a write from leaving the whitelist, and it
        // was a bad one — it sees the immediate parent only, so a symlink one level up was caught
        // and two levels up was not. Containment is that mechanism now, and a link resolution
        // cannot follow is refused by `validateInsideWhitelist` before this line runs, so a path
        // that gets here is fully resolved and has no link for this check to find. Two mechanisms
        // splitting one rule is what the first attempt at this fix left behind; this is the one.
        let parent = url.deletingLastPathComponent()
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

        let canonical = Self.canonical(trimmed)
        // **Before containment, never after** (SONNY-249's review, F1). A resolution that did not
        // converge has not answered the question; the path it reached is the one it started with,
        // minus however many hops it managed. Comparing that against a root is what let a chain of
        // 34 links read as inside while the bytes landed outside — the whitelist handed back a path
        // 33 hops shorter, and the kernel's own budget then started again from there and finished
        // the walk. So it is refused rather than compared, and named as the link it is.
        if let unfollowable = canonical.unfollowableLink {
            throw PathValidationError.symbolicLinkRejected(unfollowable.path)
        }

        let resolved = canonical.url
        let allowed = roots.contains { root in
            // `canonical` on both sides rather than `resolvingSymlinksInPath` on this one: for a
            // root that exists the two are the same call, and for one that does not — a whitelist
            // pointed at a folder the user has not created yet — only the first resolves anything,
            // and a root resolved differently from the candidates compared against it is a boundary
            // that answers nothing correctly. A root that does not resolve cannot contain anything.
            let canonicalRoot = Self.canonical(root.path)
            guard canonicalRoot.isResolved else {
                return false
            }
            return Self.contains(root: canonicalRoot.url, candidate: canonical)
        }

        guard allowed else {
            throw PathValidationError.outsideWhitelist(
                path: resolved.path,
                asked: pathAsAskedIfResolutionIsWhatRefusedIt(trimmed),
                roots: displayRoots
            )
        }
        return resolved
    }

    /// The path as typed, but only when the whitelist would have accepted it and resolution is the
    /// whole reason it did not — which is exactly the shape SONNY-249 fixed, something on the way
    /// being a symbolic link that leads out. `nil` for every other refusal, including the ordinary
    /// one where the person simply named a folder Sonny cannot use, and including a path whose text
    /// resolution merely tidied, so the longer sentence appears when it explains something and
    /// never as noise.
    private func pathAsAskedIfResolutionIsWhatRefusedIt(_ trimmed: String) -> String? {
        // No `asTyped == resolved` early return, though the first version of this had one (the
        // review's M8). It could not fire as its own behaviour: if the two are equal then the test
        // below is the identical comparison that has just refused this path, so it is false and the
        // answer is `nil` either way. A second mechanism producing the first one's answer is what
        // this repository removed from `validatedFileLocationAdditions` for the same reason.
        let asTyped = Self.normalizedURL(Self.expandPath(trimmed))
        let wouldHaveBeenAllowed = roots.contains { root in
            let canonicalRoot = Self.canonical(root.path)
            guard canonicalRoot.isResolved else {
                return false
            }
            return Self.containsPath(root: canonicalRoot.url, candidate: asTyped)
        }
        return wouldHaveBeenAllowed ? asTyped.path : nil
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
    /// opening the output file without following links at the two writers that follow one (a leaf
    /// in front of `/usr/bin/zip`, and a directory component mid-path, which an atomic write does
    /// follow because it puts its temporary file in the destination's parent). And resolution does
    /// not always converge: a link that points at itself, or a chain longer than the budget below,
    /// leaves a path that is not an answer. **That case is refused, not returned** — see
    /// `CanonicalPath`, and the review finding that says why in as many words.
    ///
    /// **`canonicalURL` is for identity, never for a boundary.** It drops the convergence flag, so
    /// what it hands back for a non-convergent path is the original with some hops taken out of it
    /// — fine as a key for "the same folder twice", wrong as something to compare against a root.
    /// `contains(root:candidate:)` takes a `CanonicalPath` precisely so that a boundary cannot be
    /// answered from this overload by accident.
    public static func canonicalURL(_ rawPath: String) -> URL {
        canonical(rawPath).url
    }

    /// The same resolution, with the fact that decides whether its answer may be compared.
    public static func canonical(_ rawPath: String) -> CanonicalPath {
        resolvingExistingPrefix(
            normalizedURL(expandPath(rawPath.trimmingCharacters(in: .whitespacesAndNewlines)))
        )
    }

    /// How many symbolic links one resolution will follow before giving up, which is the number the
    /// kernel itself stops at — `getconf SYMLOOP_MAX` prints 32 on macOS 15 (Darwin 25.5.0), and
    /// the constant is not exposed to Swift, so it is written here rather than read.
    ///
    /// **A budget exists because resolution has to terminate, not because 32 is safe.** The first
    /// version of this comment argued that a chain long enough to exhaust the budget is a chain
    /// `open` refuses with `ELOOP`, so nothing could be written through a path the resolver gave up
    /// on. That was wrong, and measurably so: the resolver handed back the path it had *reached*,
    /// which is the original minus 33 hops, and the kernel's budget then started again from there —
    /// chains of 34 to 63 links read as inside the whitelist and the bytes landed outside, a band
    /// where `961b9c2` had been safe by accident because the kernel refused the un-shortened path.
    /// Any finite number has that cliff; what removes it is refusing a resolution that did not
    /// converge instead of reporting one, which is what `resolvingExistingPrefix` does.
    ///
    /// So the number is a termination bound with a defensible value rather than a security
    /// property: chains the kernel would traverse resolve, and everything past that is refused.
    /// `PathContainmentResolutionTests` pins both sides of it — 32 links resolve, 33 are refused —
    /// because a constant no test holds is a constant a battery cannot protect, which is exactly
    /// how this survived a green suite and a ten-mutant battery.
    private static let maximumSymbolicLinkHops = 32

    /// The result of one resolution pass: either the final answer, or a path rewritten through a
    /// symbolic link that has to be resolved again from the top, carrying the link it followed so
    /// that a resolution which runs out of budget can name the one it stopped at.
    private enum ResolutionPass {
        case resolved(URL)
        case followedLink(rewritten: URL, link: URL)
    }

    private static func resolvingExistingPrefix(_ url: URL) -> CanonicalPath {
        var current = url
        var followed = 0
        var lastLink = url
        while followed <= maximumSymbolicLinkHops {
            switch resolutionPass(current) {
            case .resolved(let resolved):
                return CanonicalPath(url: resolved, unfollowableLink: nil)
            case .followedLink(let rewritten, let link):
                current = rewritten
                lastLink = link
                followed += 1
            }
        }

        // The budget is spent and a link is still in the way. **The path reached is not returned as
        // an answer** — that is the whole of the review's F1: it is the original with `followed`
        // hops already taken out of it, and every boundary in this file would then be comparing a
        // path 33 links shorter than the one the write is going to walk.
        return CanonicalPath(url: current, unfollowableLink: lastLink)
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
            return .followedLink(rewritten: rewritten.standardizedFileURL, link: resolved)
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

    /// Containment as this whitelist defines it: equal, or a path component below. Deliberately a
    /// `root + "/"` prefix test rather than a bare prefix — `/Documents/ClientAlpha` must not count
    /// as inside `/Documents/Client`.
    ///
    /// **A candidate whose resolution did not converge is not inside anything**, and that is why
    /// this takes a `CanonicalPath` rather than a `URL`. It is the one place every boundary
    /// comparison in the app passes through — `validateInsideWhitelist` and
    /// `WorkspaceScope.verdict` — so the rule is carried by the type instead of by two callers
    /// remembering it. `validateInsideWhitelist` refuses such a path before it ever gets here, with
    /// a message that names the link; scope has no error to raise and reads it as out of scope,
    /// which prompts. Both are the fail-safe direction.
    ///
    /// The root side is a `URL` because it is not the attacker-controlled one: a root reaches here
    /// only after `validateInsideWhitelist` accepted it, which means it converged.
    public static func contains(root: URL, candidate: CanonicalPath) -> Bool {
        guard candidate.isResolved else {
            return false
        }
        return containsPath(root: root, candidate: candidate.url)
    }

    /// The text comparison alone, for the two callers inside this file that have already settled
    /// convergence for themselves.
    private static func containsPath(root: URL, candidate: URL) -> Bool {
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
