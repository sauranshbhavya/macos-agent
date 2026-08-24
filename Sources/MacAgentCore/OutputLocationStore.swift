import Foundation

/// One folder the user's outputs have landed in, with how often and how recently (SONNY-209).
///
/// **Keyed by the folder, not by an identifier of its own**, the same shape `ApprovedApp` uses for a
/// bundle identifier: a folder already has a natural identity, and a record with a generated `id`
/// would need the id-backfill migration `LocalStorageMigrationLog.recordDeferredIDBackfill` exists
/// for. Two records for one folder is the failure this avoids — the whole point of the store is that
/// the same destination accumulates weight rather than appearing twice with one use each.
public struct OutputLocation: Codable, Equatable, Identifiable, Sendable {
    /// The folder, as `PathWhitelist.canonicalURL` resolves it: tilde expanded, `..` collapsed,
    /// symlinks followed.
    ///
    /// Canonical rather than as-written, so that two paths naming one folder are one record. The
    /// same arithmetic every capability's whitelist check already uses, which is what keeps "the
    /// folder Sonny may write to" and "the folder Sonny remembers writing to" from being two
    /// different strings for one place.
    public var path: String

    /// How many *runs* have written here — never how many files. A batch that converts thirty
    /// documents into one folder is one use of that folder, because the question this store answers
    /// is where the user's work goes, not how big a job was. `OutputLocationStore.recordOutputs`
    /// folds a run's paths to distinct folders before counting, which is where that holds.
    public var useCount: Int

    /// Kept even though nothing ranks on it: it is what makes a row legible when someone asks why a
    /// folder is being suggested — "twelve times since March" is an answer, "twelve times" is not.
    public var firstUsedAt: Date

    /// The recency half of the ranking, and the whole of the eviction rule.
    public var lastUsedAt: Date

    public var id: String { path }

    public init(
        path: String,
        useCount: Int = 1,
        firstUsedAt: Date,
        lastUsedAt: Date
    ) {
        self.path = path
        self.useCount = useCount
        self.firstUsedAt = firstUsedAt
        self.lastUsedAt = lastUsedAt
    }

    /// The folder's own name — "Reports" for `/Users/x/Documents/Reports`.
    ///
    /// Falls back to the whole path for a root directory, whose last component is empty or `/`, so a
    /// row can never render with a blank title.
    public var name: String {
        let component = URL(fileURLWithPath: path).lastPathComponent
        guard !component.isEmpty, component != "/" else {
            return path
        }
        return component
    }

    /// `~/Documents/Reports` rather than `/Users/someone/Documents/Reports`. What the rest of the
    /// app shows a person, and shorter in the one place it has to fit on a row.
    public var displayPath: String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    /// Recency-decayed frequency: the use count halved once per `halfLife` elapsed since the last
    /// write here.
    ///
    /// **Frequency alone would pin last quarter's project folder at the top forever, and recency
    /// alone would let a one-off export outrank the folder everything really goes in.** The decay is
    /// what lets a folder fall out of favour without being deleted, which is the honest behaviour for
    /// a suggestion: nothing is forgotten, it just stops being the first answer.
    ///
    /// A future `lastUsedAt` — a clock that moved backwards — scores as if it were now rather than
    /// producing a decay above 1, so a bad timestamp cannot inflate a location past every other one.
    func score(now: Date, halfLife: TimeInterval = OutputLocationStore.recencyHalfLife) -> Double {
        let elapsed = max(0, now.timeIntervalSince(lastUsedAt))
        guard halfLife > 0 else {
            return Double(useCount)
        }
        return Double(useCount) * pow(0.5, elapsed / halfLife)
    }
}

/// Where the user's outputs actually land, so Sonny can offer a destination instead of guessing
/// one (SONNY-209, §6.10's "common output locations").
///
/// The twelfth local store, on the shared `LocalStorageEncryption` pattern exactly: a defaulted
/// `encryption: LocalStorageEncryption = .shared`, AES-GCM under the `SONNYENC1` header, and the
/// transparent legacy-plaintext migration every other store performs on its first successful load.
///
/// ## What counts as an output location
///
/// A folder is recorded when this run wrote a file into it **and that folder is inside the path
/// whitelist**. The whitelist is the load-bearing half, and it is doing real work rather than
/// belt-and-braces validation. Eight capability adapters produce `ActionPreview.writes` (at
/// `7255551`, `git grep -l "writes:" Sources/MacAgentCore | grep CapabilityAdapter | wc -l` prints
/// 8) and they split evenly into two populations:
///
/// - **Four write the user's outputs**: `CreateLocalDraftCapabilityAdapter`,
///   `DocxConversionCapabilityAdapter`, `LargestFilesZipCapabilityAdapter`,
///   `WebResearchMarkdownCapabilityAdapter`. Every one of them resolves its destination through
///   `PathWhitelist`, so it lands inside the whitelist by construction.
/// - **Four write Sonny's own bookkeeping files**: `CreateWorkspaceCapabilityAdapter`,
///   `EditWorkspaceCapabilityAdapter`, `SaveRoutineCapabilityAdapter`,
///   `SnippetSaveCapabilityAdapter`, each naming its store's JSON under
///   `ClipboardHistoryStore.defaultDirectory` — Application Support, which is not a whitelist root
///   and never can be.
///
/// So one rule separates them, and it stays right when a ninth adapter arrives: a destination Sonny
/// is not allowed to write to is not a destination worth suggesting. The alternative — an allowlist
/// of plan operations, which is how `RecentArtifactStore` decides the same question — is a list that
/// a new capability falls outside of silently, and it is plan-shaped rather than path-shaped, so a
/// plan that both drafts a file *and* saves a routine hands it both paths.
///
/// ## What it deliberately does not see
///
/// A capability that writes a file without reporting it in `ActionPreview.writes` is invisible here.
/// `InvokeShortcutCapabilityAdapter` is the live example, and it is a *stronger* blind spot than an
/// unpublished write: **Sonny never resolves a destination for a Shortcut at all.** That adapter sets
/// no `outputPath` — `git grep -n "outputPath" -- Sources/MacAgentCore/InvokeShortcutCapabilityAdapter.swift`
/// prints nothing at `b74984d` — publishes no `writes`, and its `ShortcutSpec` holds a name and an
/// input and nothing else. A Shortcut that writes a file writes it wherever the Shortcut itself
/// decides, and Sonny never learns the path.
///
/// **So the remedy is not what an earlier version of this paragraph said** (PR #101 review, F5). It
/// claimed the adapter "resolves an `outputPath` but publishes no `writes`", which made the fix look
/// like a change to that adapter's preview contract. There is no resolved path to publish: making a
/// Shortcut's output visible means making the adapter resolve a destination first, which is a
/// materially larger change carrying its own whitelist and approval questions. A reader who took the
/// old sentence at face value would scope that work wrongly, which is the half that costs someone
/// later.
///
/// A run that throws before `execute` returns records nothing, even if it had already written a
/// file. That is the conservative direction and it matches `RecentArtifactStore`, whose bookkeeping
/// hangs off the same returned result.
public struct OutputLocationStore: @unchecked Sendable {
    /// How many folders are kept. Generous, because each record is four small fields and the value
    /// of the store is that a folder used in March is still known in September.
    public static let maxItems = 50

    /// How long a location's weight takes to halve. Thirty days: long enough that a weekly habit
    /// keeps its place, short enough that a finished project stops being the first suggestion within
    /// a couple of months.
    public static let recencyHalfLife: TimeInterval = 30 * 24 * 60 * 60

    public let fileURL: URL
    private let fileManager: FileManager
    private let encryption: LocalStorageEncryption
    private let whitelist: PathWhitelist

    public init(
        fileURL: URL? = nil,
        fileManager: FileManager = .default,
        encryption: LocalStorageEncryption = .shared,
        whitelist: PathWhitelist = PathWhitelist()
    ) {
        self.fileManager = fileManager
        self.encryption = encryption
        self.whitelist = whitelist
        if let fileURL {
            self.fileURL = fileURL
        } else {
            self.fileURL = ClipboardHistoryStore.defaultDirectory(fileManager: fileManager)
                .appendingPathComponent("output-locations.json")
        }
    }

    /// Records the folders one finished run wrote into, one use each.
    ///
    /// The single door the product uses, called from `AgentRunner` once per executed run — the same
    /// seam and the same moment as `RecentArtifactStore.recordGeneratedArtifacts`.
    @discardableResult
    public func recordOutputs(from result: AgentRunResult, recordedAt: Date = Date()) throws -> [OutputLocation] {
        try recordOutputs(atPaths: result.previews.flatMap(\.writes), recordedAt: recordedAt)
    }

    /// Records the folder of each written file, **at most one use per folder per call**.
    ///
    /// The fold to distinct folders happens here rather than at the caller, so the "a run is one
    /// use" rule stated on `OutputLocation.useCount` has one home. Returns the locations as they now
    /// stand, in the order their folders were first seen; an empty array means nothing was
    /// recordable, which is the ordinary answer for a run that wrote no files.
    @discardableResult
    public func recordOutputs(atPaths rawPaths: [String], recordedAt: Date = Date()) throws -> [OutputLocation] {
        let folders = distinctRecordableFolders(in: rawPaths)
        guard !folders.isEmpty else {
            return []
        }

        var locations = try loadKeyed()
        var recorded: [OutputLocation] = []
        for folder in folders {
            let key = Self.storageKey(for: folder)
            let updated = bumped(locations[key], folder: folder, at: recordedAt)
            locations[key] = updated
            recorded.append(updated)
        }
        try write(evictingLeastRecentlyUsed(locations))
        return recorded
    }

    /// The destinations Sonny would offer, best first.
    ///
    /// The ranking is `OutputLocation.score` — recency-decayed frequency — not the eviction order,
    /// and the two differ on purpose. See `evictingLeastRecentlyUsed` for why.
    public func suggestedDestinations(limit: Int = 5, now: Date = Date()) throws -> [OutputLocation] {
        Array(try loadAll(now: now).prefix(max(0, limit)))
    }

    /// Every remembered location, in the order `suggestedDestinations` would offer them.
    ///
    /// Ranked rather than arbitrary so the Memory section's list reads in the same order Sonny would
    /// actually suggest — a list whose top row is not the answer Sonny would give is a surface
    /// disagreeing with the behaviour it describes.
    ///
    /// **Does not touch the disk to check that a folder still exists.** A removable volume that is
    /// unplugged today is plugged in tomorrow, and a load that pruned it would erase a real habit for
    /// the duration of a disconnection. Existence is checked once, at record time, where the folder
    /// has just been written to and the answer is certain.
    public func loadAll(now: Date = Date()) throws -> [OutputLocation] {
        ranked(Array(try loadKeyed().values), now: now)
    }

    /// Forgets one location. Nothing on disk is touched — this store only ever held a note about
    /// where files went, exactly as `RecentArtifactStore` only ever held a note about a file.
    ///
    /// A path that is not stored is a no-op rather than an error, matching every other per-entry
    /// delete the Memory section drives.
    public func forget(path: String) throws {
        var locations = try loadKeyed()
        guard locations.removeValue(forKey: Self.storageKey(for: path)) != nil else {
            return
        }
        try write(locations)
    }

    /// One folder's stored record, or `nil`. The read half of the identity rule: callers ask by any
    /// spelling of the path and never have to know how the key is derived.
    public func location(for path: String) throws -> OutputLocation? {
        try loadKeyed()[Self.storageKey(for: path)]
    }

    /// The one place a folder becomes a key: canonicalised the way every whitelist check in the app
    /// canonicalises, then folded the way every destination comparison in the app folds.
    ///
    /// **Both halves, in one function, used by all three doors.** Recording resolves its folder
    /// through `PathWhitelist.validateExistingDirectory`, which hands back a canonical URL, so the
    /// record door would look correct with the fold alone — and `forget` and `location` would then
    /// silently miss, because a caller holding `/tmp/x` and a store keyed on `/private/tmp/x` never
    /// meet. One derivation is what stops the read doors and the write door disagreeing, which is
    /// `RunClaims`' own rule about its two doors applied to three.
    private static func storageKey(for path: String) -> String {
        DestinationKey.folded(PathWhitelist.canonicalURL(path).path)
    }

    private func loadKeyed() throws -> [String: OutputLocation] {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return [:]
        }
        let data = try Data(contentsOf: fileURL)
        let decoded = try encryption.decode(
            [String: OutputLocation].self,
            from: data,
            decoder: .outputLocationISO8601
        )
        return decoded.migratingLegacyPlaintext(store: "output locations", write: write)
    }

    private func bumped(_ existing: OutputLocation?, folder: String, at date: Date) -> OutputLocation {
        guard let existing else {
            return OutputLocation(path: folder, useCount: 1, firstUsedAt: date, lastUsedAt: date)
        }
        return OutputLocation(
            path: folder,
            useCount: existing.useCount + 1,
            // `min`/`max` rather than plain assignment, so a run whose clock disagrees with an
            // earlier one widens the window instead of inverting it. A record whose first use is
            // later than its last is a record no reader can make sense of.
            firstUsedAt: min(existing.firstUsedAt, date),
            lastUsedAt: max(existing.lastUsedAt, date)
        )
    }

    /// Which folders in `rawPaths` are worth remembering, deduplicated by the same fold the store
    /// keys on, in first-seen order.
    private func distinctRecordableFolders(in rawPaths: [String]) -> [String] {
        var seen: Set<String> = []
        var folders: [String] = []
        for rawPath in rawPaths {
            guard let folder = recordableFolder(forFileAt: rawPath),
                  seen.insert(Self.storageKey(for: folder)).inserted else {
                continue
            }
            folders.append(folder)
        }
        return folders
    }

    /// The folder a written file lives in, when that folder is one Sonny is allowed to write to.
    ///
    /// `try?` is right here and is not the swallowed-error pattern the store conventions forbid:
    /// every throw `validateExistingDirectory` can produce — outside the whitelist, missing, not a
    /// directory, a symlink — is a *classification* answer meaning "this is not an output location",
    /// not a failure to report. A store's own file failing to read is the other thing entirely, and
    /// that one propagates out of `loadAll`.
    private func recordableFolder(forFileAt rawPath: String) -> String? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        let folder = PathWhitelist.canonicalURL(trimmed).deletingLastPathComponent()
        guard let validated = try? whitelist.validateExistingDirectory(folder.path) else {
            return nil
        }
        return validated.path
    }

    /// Keeps the `maxItems` most recently used locations.
    ///
    /// **Least-recently-used, deliberately *not* lowest-scoring**, and the difference is the one
    /// decision in this file that could reasonably have gone the other way. Evicting by score reads
    /// as the tidier rule — keep what you would suggest — and it has a failure mode that is much
    /// worse than the one it avoids: a full store of heavy hitters gives every brand-new folder a
    /// score of 1.0, below theirs, so a person who starts a new project watches Sonny keep offering
    /// last quarter's folders and never learn the new one. Recency cannot fail that way. What it
    /// costs instead is that a folder used constantly for a year and then left alone eventually
    /// falls off the end, which is a suggestion getting worse slowly rather than a store that stops
    /// learning.
    ///
    /// Ranking still uses the score. The two questions are different: what to keep, and what to
    /// offer first.
    private func evictingLeastRecentlyUsed(_ locations: [String: OutputLocation]) -> [String: OutputLocation] {
        guard locations.count > Self.maxItems else {
            return locations
        }
        let kept = locations
            .sorted { left, right in
                if left.value.lastUsedAt != right.value.lastUsedAt {
                    return left.value.lastUsedAt > right.value.lastUsedAt
                }
                return left.key < right.key
            }
            .prefix(Self.maxItems)
        return Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }

    /// Best suggestion first, with ties broken so the order is total: a dictionary's values arrive
    /// in no defined order, and a list that reshuffles between two loads of identical data would be
    /// a surface that looks alive when nothing changed.
    private func ranked(_ locations: [OutputLocation], now: Date) -> [OutputLocation] {
        locations.sorted { left, right in
            let leftScore = left.score(now: now)
            let rightScore = right.score(now: now)
            if leftScore != rightScore {
                return leftScore > rightScore
            }
            if left.lastUsedAt != right.lastUsedAt {
                return left.lastUsedAt > right.lastUsedAt
            }
            return left.path < right.path
        }
    }

    private func write(_ locations: [String: OutputLocation]) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encryption.encode(locations, encoder: .outputLocationPrettySorted)
        try data.write(to: fileURL, options: .atomic)
    }
}

private extension JSONEncoder {
    static var outputLocationPrettySorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var outputLocationISO8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
