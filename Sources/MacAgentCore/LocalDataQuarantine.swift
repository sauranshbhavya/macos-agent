import Foundation

/// What happened when a set of unreadable store files was moved aside.
///
/// Same shape as `LocalDataDeletionResult` and for the same reason: the caller has to be able to
/// say how many files it actually acted on, and which ones it could not, rather than reporting a
/// success it did not have.
public struct LocalDataQuarantineResult: Equatable, Sendable {
    /// Where each file now lives, in the order the originals were given.
    public var movedFileURLs: [URL]
    /// Files that were not there to move. Not an error: a store that never wrote a file has none.
    public var missingFileCount: Int
    /// Originals that are still exactly where they were, because the move failed.
    public var failedFilePaths: [String]

    public init(
        movedFileURLs: [URL] = [],
        missingFileCount: Int = 0,
        failedFilePaths: [String] = []
    ) {
        self.movedFileURLs = movedFileURLs
        self.missingFileCount = missingFileCount
        self.failedFilePaths = failedFilePaths
    }
}

public struct LocalDataQuarantineError: Error, LocalizedError, Equatable {
    public var result: LocalDataQuarantineResult
    public var underlyingDescriptions: [String]

    public init(result: LocalDataQuarantineResult, underlyingDescriptions: [String]) {
        self.result = result
        self.underlyingDescriptions = underlyingDescriptions
    }

    public var errorDescription: String? {
        let fileNames = result.failedFilePaths
            .map { URL(fileURLWithPath: $0).lastPathComponent }
            .joined(separator: ", ")
        let detail = underlyingDescriptions.first.map { " (\($0))" } ?? ""
        return "Sonny could not set aside \(fileNames).\(detail)"
    }
}

/// Moves a local store file out of the way instead of deleting it, so a store Sonny cannot read
/// can be started over without destroying the bytes.
///
/// **Why moving rather than deleting, which is the whole point of this type** (founder decision,
/// 2026-08-23, recorded on SONNY-239 and grounded in SONNY-253). A decrypt failure does not prove a
/// file is garbage — it proves the bytes were written under a different key. That is true of a test
/// process writing them, and equally true of a user who restored from a backup, migrated Macs, or
/// had their Keychain item replaced. SONNY-253's recorded architecture has a device-bound data key
/// that a restore can reinstall, so a file that will not open today can open tomorrow. Three of the
/// stores hold things a person made by hand and cannot recreate — `routines.json`,
/// `workspaces.json` and `snippets.json`, which are three of the five `LocalStoreKind` classifies
/// `.artifact` — and destroying those on the signal "I cannot open this right now" would delete work
/// they could have got back. (`approved-apps.json` is the fourth `.artifact` and is deliberately not
/// in that list: a lost grant costs one answered prompt, not a thing somebody built. The count read
/// "two" and omitted snippets until PR #110's review.)
///
/// **One mechanism rather than one per store**, which is SONNY-239's fourth question answered: this
/// operates on a store's file URL and knows nothing about what is in it, so no store type changes
/// and every store inherits it. A store that cannot be decoded cannot be read, rewritten *or*
/// cleared through its own doors — every one of them loads first — so a recovery built inside a
/// store would be a recovery that cannot run.
///
/// **This is not `Delete Local Data`'s behaviour and must not become it.** Settings is the one place
/// the user asks for destruction: its whole wipe, `LocalDataDeletionService.deleteAllLocalData()`,
/// deletes what this leaves behind so a privacy wipe stays true, and since SONNY-266 its Data page
/// also counts and sizes what this has set aside and removes exactly that, through
/// `deleteSetAsideFilesOnly()`. Nothing else prunes, caps or ages these files out, by founder decision
/// (2026-08-24): deleting them is precisely what this type exists to avoid. Command Center's per-row
/// Delete calls `deleteStoreFilesOnly()` instead and leaves set-aside files alone — **for one round
/// of this branch it called the wipe's door**, so an ordinary press on a row that had since recovered
/// destroyed the file an earlier press promised to keep, which is this paragraph being false in the
/// code beneath it (PR #110 review, F2).
public struct LocalDataQuarantine: @unchecked Sendable {
    /// What a set-aside file's name gains, between the original name and the stamp.
    ///
    /// Public because `LocalDataDeletionService` sweeps by it: the suffix is defined once, here, and
    /// the wipe asks rather than repeating the literal. A second copy of this string is how a
    /// privacy wipe quietly stops reaching what this type leaves behind.
    public static let filenameSuffix = ".unreadable-"

    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Moves every file that is there, attempting all of them even when one fails.
    ///
    /// Stopping at the first failure would leave the remaining files in place *and* unreported,
    /// which is the same reason `LocalDataDeletionService.deleteAllLocalData` attempts every store.
    public func moveAsideAll(_ fileURLs: [URL], at date: Date = Date()) throws -> LocalDataQuarantineResult {
        var result = LocalDataQuarantineResult()
        var failureDescriptions: [String] = []

        for fileURL in fileURLs {
            guard fileManager.fileExists(atPath: fileURL.path) else {
                result.missingFileCount += 1
                continue
            }

            do {
                result.movedFileURLs.append(try moveAside(fileURL, at: date))
            } catch {
                result.failedFilePaths.append(fileURL.path)
                failureDescriptions.append(error.localizedDescription)
            }
        }

        guard result.failedFilePaths.isEmpty else {
            throw LocalDataQuarantineError(result: result, underlyingDescriptions: failureDescriptions)
        }
        return result
    }

    /// Moves one file aside and returns where it went.
    ///
    /// The name keeps the original in full — `output-locations.json` becomes
    /// `output-locations.json.unreadable-20260823T184211Z` — so which store a set-aside file came
    /// from is readable off the name alone, by a person in the Finder and by the wipe's own sweep.
    public func moveAside(_ fileURL: URL, at date: Date = Date()) throws -> URL {
        let destination = availableDestination(for: fileURL, at: date)
        try fileManager.moveItem(at: fileURL, to: destination)
        return destination
    }

    /// Every file already set aside from `fileURL`, in the directory `fileURL` lives in.
    ///
    /// Returns an empty array when the directory cannot be listed, which is the same answer as
    /// "nothing has been set aside" on purpose: this feeds a delete, and a listing failure must not
    /// become an exception that stops a wipe from removing the files it *can* see. It also feeds
    /// the count Settings' Data page shows (SONNY-266), where the same answer is the honest one — a
    /// directory that cannot be listed has nothing the control could remove.
    public func quarantinedSiblings(of fileURL: URL) -> [URL] {
        let directory = fileURL.deletingLastPathComponent()
        let prefix = fileURL.lastPathComponent + Self.filenameSuffix
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
            return []
        }
        return names
            .filter { $0.hasPrefix(prefix) }
            .sorted()
            .map { directory.appendingPathComponent($0) }
    }

    /// The first name in the series that is not taken.
    ///
    /// The stamp is whole seconds, so **the same store set aside twice inside one second** collides —
    /// a file that will not read, cleared, written afresh and breaking again, or simply a second
    /// press. The counter is not decoration; `twoFilesSetAsideInTheSameSecondDoNotOverwriteEachOther`
    /// is that case exactly.
    ///
    /// **The reason this comment used to give was the one case that cannot happen** (PR #110 review,
    /// F9): it said one press on a row covering several stores would collide with itself. It cannot —
    /// the base name begins with `fileURL.lastPathComponent`, and the four files under the Task
    /// history row have four different ones. Written down rather than quietly corrected because the
    /// test underneath already disagreed with the prose, and a reader trusting the prose would have
    /// concluded the counter was unreachable and deleted it.
    private func availableDestination(for fileURL: URL, at date: Date) -> URL {
        let directory = fileURL.deletingLastPathComponent()
        let base = fileURL.lastPathComponent + Self.filenameSuffix + Self.stamp(for: date)
        var candidate = directory.appendingPathComponent(base)
        var attempt = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base)-\(attempt)")
            attempt += 1
        }
        return candidate
    }

    /// `20260823T184211Z` — ISO 8601 basic format, UTC.
    ///
    /// Basic format rather than extended because the colons of `18:42:11` are legal in a macOS file
    /// name and are shown to the user as slashes in the Finder, which would make a set-aside file
    /// look like a path. Fixed locale and time zone so the name does not change shape with the
    /// user's region.
    private static func stamp(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%04d%02d%02dT%02d%02d%02dZ",
            parts.year ?? 0,
            parts.month ?? 0,
            parts.day ?? 0,
            parts.hour ?? 0,
            parts.minute ?? 0,
            parts.second ?? 0
        )
    }
}
