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
            return "\(path) is outside the writable whitelist: \(roots.joined(separator: ", "))."
        case .notFound(let path):
            return "\(path) does not exist."
        case .notDirectory(let path):
            return "\(path) is not a directory."
        case .symbolicLinkRejected(let path):
            return "\(path) is a symbolic link. Symlink traversal is disabled."
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
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PathValidationError.notFound(url.path)
        }

        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        if values.isSymbolicLink == true {
            throw PathValidationError.symbolicLinkRejected(url.path)
        }
        guard values.isDirectory == true else {
            throw PathValidationError.notDirectory(url.path)
        }
        return url
    }

    public func validateOutputPath(_ rawPath: String) throws -> URL {
        let url = try validateInsideWhitelist(rawPath)
        let parent = url.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: parent.path) else {
            throw PathValidationError.parentMissing(parent.path)
        }

        let values = try parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        if values.isSymbolicLink == true {
            throw PathValidationError.symbolicLinkRejected(parent.path)
        }
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
            Self.contains(root: root.resolvingSymlinksInPath(), candidate: resolved)
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
    public func resolveOutputPath(
        rawPath: String?,
        defaultName: String,
        extension ext: String,
        fileManager: FileManager
    ) throws -> URL {
        if let rawPath, !rawPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let expanded = (rawPath as NSString).expandingTildeInPath
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
    /// relative-to-home expansion, standardization (which is what collapses `..`), then symlink
    /// resolution.
    ///
    /// Public, together with `contains(root:candidate:)`, so a *narrower* boundary — a workspace's
    /// restriction scope — can be evaluated with this whitelist's own path arithmetic instead of a
    /// second one. Two path comparisons that disagree about `..` or a symlink is a security bug, not
    /// a style one. Nothing here widens the whitelist: a path this resolves is still subject to
    /// `validateInsideWhitelist` before any capability touches it.
    public static func canonicalURL(_ rawPath: String) -> URL {
        normalizedURL(expandPath(rawPath.trimmingCharacters(in: .whitespacesAndNewlines)))
            .resolvingSymlinksInPath()
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
