import Foundation

public struct LocalDataDeletionResult: Equatable, Sendable {
    public var deletedFileCount: Int
    public var missingFileCount: Int
    /// Paths that still hold data because deletion failed, newest failure last.
    public var failedFilePaths: [String]

    public init(
        deletedFileCount: Int,
        missingFileCount: Int,
        failedFilePaths: [String] = []
    ) {
        self.deletedFileCount = deletedFileCount
        self.missingFileCount = missingFileCount
        self.failedFilePaths = failedFilePaths
    }
}

public struct LocalDataDeletionError: Error, LocalizedError, Equatable {
    public var result: LocalDataDeletionResult
    public var underlyingDescriptions: [String]

    public init(result: LocalDataDeletionResult, underlyingDescriptions: [String]) {
        self.result = result
        self.underlyingDescriptions = underlyingDescriptions
    }

    public var errorDescription: String? {
        let fileNames = result.failedFilePaths
            .map { URL(fileURLWithPath: $0).lastPathComponent }
            .joined(separator: ", ")
        let deleted = "Deleted \(result.deletedFileCount) local data file\(result.deletedFileCount == 1 ? "" : "s")"
        let remaining = "\(result.failedFilePaths.count) could not be deleted and still hold data: \(fileNames)"
        let detail = underlyingDescriptions.first.map { " (\($0))" } ?? ""
        return "\(deleted), but \(remaining).\(detail)"
    }
}

/// The words Settings uses to say what the whole wipe takes (SONNY-233).
///
/// **One sentence, derived from the population, read by both surfaces that state it.** Settings' Data
/// page carries a detail line under "Delete Sonny local data" and the confirmation dialog carries a
/// message; both enumerate what goes, and both were written by hand. At the head this ticket was
/// picked up the detail line named ten of the thirteen stores the wipe deleted then and the dialog
/// named nine — the dialog being the last thing a user reads before an irreversible press. Neither was
/// noticed going stale, because nothing tied the words to
/// `LocalDataDeletionService.defaultStoreFileURLs()`: a store landed, its file went into the wipe,
/// and the sentence stayed as it was. SONNY-233 was filed against the detail line alone; the dialog
/// was found by sweeping for the claim rather than for the line number the ticket gave.
///
/// **It names no count, deliberately.** "Everything Sonny keeps on this Mac" or a figure would both
/// be shorter, and both would say less than the list does about the one thing a person reading a
/// destructive control wants to know — whether their own thing is in it. A figure would also go
/// stale exactly the way the list did, while reading as current.
///
/// **It names every store rather than every Memory row**, which would have been four phrases
/// shorter — nine against thirteen, `MemoryCategory` having nine cases
/// (`awk '/^public enum MemoryCategory/,/^    public var id: String/' Sources/MacAgentCore/MemorySettings.swift | grep -cE '^    case '`
/// → 9). The Memory page folds the vision journal, plan details and Shortcut history under Task
/// history, so a row-derived sentence would stop saying "records of what Sonny did on screen" — the
/// most sensitive store in the product, and the one a wipe's description least deserves to drop.
/// (**Three and ten** stood here and in the changelog entry until PR #155's review recounted them,
/// which is this branch's own subject arriving in the prose written to explain it: nine categories
/// give nine phrases, and the ten came from adding the uncategorised store back — contradicting the
/// very next sentence, which says the row-derived form under-promises by one.)
///
/// **The order is `LocalStore.allCases`'** rather than a second list that can disagree with it. That
/// puts the screen records first, which is right for a destructive-action disclosure rather than
/// merely accepted: it is the item a person is likeliest to be checking for.
public enum LocalDataDeletionCopy {
    /// Every store the wipe reaches, named, as one list phrase — "a, b, and c".
    ///
    /// Read by both call sites, so the two cannot describe the same button differently. Each frames
    /// it in its own sentence, which is the only thing they do separately.
    public static var everythingItTakes: String {
        list(LocalStore.allCases.map(\.deletionCopyName))
    }

    /// Oxford-comma join. Written out rather than `joined(separator:)` because the last separator
    /// differs, and handling one and two items is what stops a future single-store list reading
    /// "and unfinished tasks" on its own.
    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0:
            return ""
        case 1:
            return items[0]
        case 2:
            return "\(items[0]) and \(items[1])"
        default:
            return items.dropLast().joined(separator: ", ") + ", and " + items[items.count - 1]
        }
    }
}

/// How many files are set aside across a service's stores, and how many bytes they hold.
///
/// What Settings' Data page states — the count and the size, and nothing about why the files exist
/// (SONNY-266, founder decision 2026-08-24; the standing no-explanatory-copy rule is why the second
/// half is a negative). `isEmpty` is that row's gate: a line reading "0 files" would be a surface
/// for a state most users never reach.
public struct SetAsideFilesSummary: Equatable, Sendable {
    public var fileCount: Int
    /// Logical size, summed — the figure Finder shows first and the unit SONNY-266's own measurement
    /// of `clipboard-history.json` (1 011 740 bytes at its cap) is in. Not the allocated size.
    public var byteCount: Int64

    public init(fileCount: Int, byteCount: Int64) {
        self.fileCount = fileCount
        self.byteCount = byteCount
    }

    public static let none = SetAsideFilesSummary(fileCount: 0, byteCount: 0)

    public var isEmpty: Bool {
        fileCount == 0
    }
}

public struct LocalDataDeletionService: @unchecked Sendable {
    private let fileManager: FileManager
    private let fileURLs: [URL]
    private let quarantine: LocalDataQuarantine

    /// **`fileURLs` is required, and this is the type where that matters most** (SONNY-350, PR #162
    /// review F5).
    ///
    /// It used to be `[URL]? = nil`, falling back to `defaultStoreFileURLs(fileManager:)` — so
    /// `LocalDataDeletionService()` compiled and silently resolved the founder's real thirteen
    /// files, on the one type in this repository whose whole job is to *remove* them. That is the
    /// same shape SONNY-350 took off the thirteen store initializers and off the four store
    /// vendors, arrived at through the same method: remove the default and see which call sites
    /// were relying on it. This one is the fifth level and the worst of them, which the suite's own
    /// `otherRequiredParameters` doc had already said in as many words — "its default is the real
    /// file list and the service *deletes*".
    ///
    /// It was never a live defect: the only silent site in the tree was the shipping factory, and
    /// every test already named `fileURLs:`. What it was is a door standing open on the destructive
    /// type, held shut by nothing but every author so far having happened to walk past it.
    ///
    /// The real list is still reachable — `LocalDataDeletionService(fileURLs: defaultStoreFileURLs())`,
    /// which is what `AgentViewModel.atItsRealStoreLocations()` now writes. In words, like every
    /// other real location this ticket touched.
    public init(fileManager: FileManager = .default, fileURLs: [URL]) {
        self.fileManager = fileManager
        self.fileURLs = fileURLs
        self.quarantine = LocalDataQuarantine(fileManager: fileManager)
    }

    /// **Settings' whole wipe: every store file, and every file set aside from one.**
    ///
    /// Attempts every store even when one fails. Stopping at the first error would leave the
    /// remaining files — real user data this action promised to erase — silently untouched and
    /// unreported, which is the opposite of what a privacy wipe must do.
    ///
    /// **The set-aside files go too, and that is load-bearing rather than tidy** (SONNY-239).
    /// `LocalDataQuarantine` renames an unreadable file instead of unlinking it, so a store the user
    /// cleared from the Memory page leaves its bytes on disk under a suffixed name. Those bytes are
    /// the user's — folder paths, commands, routines — and a wipe that deleted only the exact
    /// thirteen names would leave them behind while reporting that everything was erased. Sonny
    /// cannot read them, which is not the same as their holding nothing.
    ///
    /// **Two doors reach the set-aside files — this one and `deleteSetAsideFilesOnly()` — and
    /// `deleteStoreFilesOnly()` is what makes that an enforceable statement rather than an
    /// aspiration** (PR #110 review, F2). Command Center's per-row Delete used to call *this* method,
    /// so an ordinary press on a readable row destroyed a file an earlier press had promised to keep
    /// — measured against the real types: set one aside, rewrite the store, press Delete, and the
    /// result was `deletedFileCount == 2` with the kept file gone. (This paragraph said "the one
    /// door that sweeps" until SONNY-266 added the second; both live on Settings, which is still the
    /// one place the user asks for destruction.)
    public func deleteAllLocalData() throws -> LocalDataDeletionResult {
        try delete(reaching: .storeFilesAndSetAsideFiles)
    }

    /// **Command Center's per-row Delete: the store files themselves, and nothing set aside from
    /// them.**
    ///
    /// The founder's decision of 2026-08-23 is that Sonny never destroys a file it cannot read,
    /// because a decrypt failure proves only that the bytes were written under a different key and
    /// SONNY-253's key migration can hand that key back. A per-row Delete is scoped to "forget this
    /// kind of memory", and a set-aside file is not part of that kind's memory — the row does not
    /// count it, the sheet does not list it, and the confirmation the user accepted when it was set
    /// aside said in so many words that Sonny keeps it.
    ///
    /// **The asymmetry with `deleteAllLocalData` is deliberate and is the smaller of two broken
    /// promises.** Leaving it means "Delete routines" leaves unreadable routine bytes on disk, which
    /// is real — but it is *disclosed* (the user was told the file is kept) and *recoverable*
    /// (Settings' Data page counts and sizes those files and removes exactly them through
    /// `deleteSetAsideFilesOnly()`, and its whole wipe takes them too — both controls the product
    /// already frames as destructive). Sweeping it here would destroy data the product promised to
    /// keep, undisclosed and with no undo. Disclosed-and-recoverable beats silent-and-final.
    ///
    /// **Re-asked once the files became visible, and the answer stayed no** (SONNY-266's founder
    /// comment of 2026-08-23 put the question on that ticket; its decision of 2026-08-24 gave the
    /// files a surface and left this door alone). Visibility is what makes leaving them honest: the
    /// user can now see how many there are, how much space they hold, and remove them from the line
    /// that says so — which is a better answer than a per-row Delete silently taking them.
    public func deleteStoreFilesOnly() throws -> LocalDataDeletionResult {
        try delete(reaching: .storeFilesOnly)
    }

    /// **Settings' narrower control: every file set aside from one of these stores, and none of the
    /// store files themselves** (SONNY-266, founder decision 2026-08-24).
    ///
    /// The second caller of `quarantinedSiblings(of:)` that removes anything. The user is shown how
    /// many files there are and how much space they hold, and this is what the control beside that
    /// line does — the whole wipe's loop with the store files left out, rather than a third deletion
    /// routine, so the attempt-every-file-and-report-what-survived behaviour comes for free and the
    /// sweep's suffix match is written once.
    ///
    /// **This is destruction, asked for.** A set-aside file exists because a decrypt failure proves
    /// only that the bytes were written under a different key, and SONNY-253's key migration may
    /// hand that key back. Nothing prunes, caps or ages these files out — the founder's decision is
    /// that deleting them is precisely what the design exists to avoid — so the only thing that
    /// removes one is a control the user pressed: this, or the whole wipe.
    ///
    /// Named beside `deleteStoreFilesOnly()` rather than after the view model's control, which was
    /// its first name, so that `everyDeletionDoorIsCalledOnceFromTheMethodThatOwnsIt` can tell the
    /// service's three doors from the controls that call them by name alone (PR #117 review, F5).
    public func deleteSetAsideFilesOnly() throws -> LocalDataDeletionResult {
        try delete(reaching: .setAsideFilesOnly)
    }

    /// Every file set aside from one of these stores, in a stable order — exactly what
    /// `deleteSetAsideFilesOnly()` would remove.
    ///
    /// One listing, read by the summary and walked by the delete, so the number the user is shown
    /// and the files the press takes cannot come from different populations.
    public func setAsideFiles() -> [URL] {
        unique(fileURLs).flatMap { quarantine.quarantinedSiblings(of: $0) }
    }

    /// How many files are set aside and how many bytes they hold — the line Settings' Data page shows.
    ///
    /// The count is the listing's. The bytes are summed over the files whose size could be read: a
    /// file whose attributes cannot be read is still there and the delete will still attempt it, so
    /// it counts, and it contributes nothing to the size rather than failing the whole summary.
    public func setAsideFilesSummary() -> SetAsideFilesSummary {
        let files = setAsideFiles()
        let byteCount = files.reduce(Int64(0)) { total, fileURL in
            let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return total + Int64(size)
        }
        return SetAsideFilesSummary(fileCount: files.count, byteCount: byteCount)
    }

    /// Which of a store's files a delete reaches. Three doors, one loop — the difference between
    /// them is the whole of what each public method promises, so it is a named value rather than two
    /// booleans a caller could cross.
    private enum Reach {
        /// The store file and every file set aside from it — Settings' whole wipe.
        case storeFilesAndSetAsideFiles
        /// The store file alone — Command Center's per-row Delete.
        case storeFilesOnly
        /// The set-aside files alone — Settings' narrower control (SONNY-266).
        case setAsideFilesOnly

        var includesStoreFiles: Bool {
            self != .setAsideFilesOnly
        }

        var includesSetAsideFiles: Bool {
            self != .storeFilesOnly
        }
    }

    private func delete(reaching reach: Reach) throws -> LocalDataDeletionResult {
        var deletedFileCount = 0
        var missingFileCount = 0
        var failedFilePaths: [String] = []
        var failureDescriptions: [String] = []

        for fileURL in unique(fileURLs) {
            // Before the existence check below, not inside it: a store whose own file was already
            // moved aside has nothing at its own path and everything at the suffixed one, which is
            // precisely the state this sweep exists for.
            if reach.includesSetAsideFiles {
                for setAside in quarantine.quarantinedSiblings(of: fileURL) {
                    do {
                        try fileManager.removeItem(at: setAside)
                        deletedFileCount += 1
                    } catch {
                        failedFilePaths.append(setAside.path)
                        failureDescriptions.append(error.localizedDescription)
                    }
                }
            }

            // The narrower control stops here: the store file is the user's live memory, and this
            // door never touches it. `missingFileCount` stays at zero for that door — nothing it was
            // asked for was absent.
            guard reach.includesStoreFiles else {
                continue
            }

            guard fileManager.fileExists(atPath: fileURL.path) else {
                missingFileCount += 1
                continue
            }

            do {
                try fileManager.removeItem(at: fileURL)
                deletedFileCount += 1
            } catch {
                failedFilePaths.append(fileURL.path)
                failureDescriptions.append(error.localizedDescription)
            }
        }

        let result = LocalDataDeletionResult(
            deletedFileCount: deletedFileCount,
            missingFileCount: missingFileCount,
            failedFilePaths: failedFilePaths
        )

        guard failedFilePaths.isEmpty else {
            throw LocalDataDeletionError(result: result, underlyingDescriptions: failureDescriptions)
        }
        return result
    }

    /// The wipe over **every** local store, correct by construction (PR #162 review N1/W2).
    ///
    /// `fileURLs` became required so that `LocalDataDeletionService()` could not silently resolve
    /// the real thirteen files. That closed a silent reach and opened a quieter one: the shipping
    /// factory then had to *assemble* the argument by hand, at the one site no behavioural test can
    /// reach, and `theRealStoreFactoryHandsTheWipeTheRealFileList` could only check that
    /// `defaultStoreFileURLs` was *named* somewhere in that call. A presence check catches wholesale
    /// replacement — `fileURLs: []` dies — and cannot see a list derived wrongly from the right
    /// function. `Array(defaultStoreFileURLs().dropFirst())` passed the entire suite while the wipe
    /// left `vision-sessions.json` on disk and the confirmation dialog went on naming it: the store
    /// this file's own comment calls the loudest possible failure of a privacy wipe.
    ///
    /// So the argument is not assembled any more. This is `realFileURL`'s pattern one level up —
    /// the reach stays in words, and there is nothing left at the call site to get wrong. A
    /// fourteenth store joins it without anyone editing the factory, because
    /// `theWipeReachesEveryLocalStore` pins `defaultStoreFileURLs()` against `LocalStore.allCases`
    /// by value.
    ///
    /// **This does not weaken the door that was closed.** `LocalDataDeletionService()` still does
    /// not compile; a caller wanting the real thirteen has to write this member's name, and
    /// `noStoreVendorDefaultsAStoreParameter` still refuses a default on `fileURLs`.
    public static func acrossEveryLocalStore(fileManager: FileManager = .default) -> LocalDataDeletionService {
        LocalDataDeletionService(
            fileManager: fileManager,
            fileURLs: defaultStoreFileURLs(fileManager: fileManager)
        )
    }

    public static func defaultStoreFileURLs(fileManager: FileManager = .default) -> [URL] {
        [
            // Row I's action journal. A wipe that left a record of every click Sonny made inside the
            // user's apps would be the loudest possible failure of a privacy wipe.
            VisionSessionJournalStore.realFileURL(fileManager: fileManager),
            RoutineStore.realFileURL(fileManager: fileManager),
            WorkspaceStore.realFileURL(fileManager: fileManager),
            ClipboardHistoryStore.realFileURL(fileManager: fileManager),
            ClipboardHistorySettingsStore.realFileURL(fileManager: fileManager),
            SnippetStore.realFileURL(fileManager: fileManager),
            RecentArtifactStore.realFileURL(fileManager: fileManager),
            ShortcutRunHistoryStore.realFileURL(fileManager: fileManager),
            TaskHistoryStore.realFileURL(fileManager: fileManager),
            // Row E's plan details. Deleted with the same wipe as the rows they hang off — a wipe
            // that left the plan of every task Sonny ran would be the same failure as leaving the
            // rows themselves.
            TaskPlanDetailStore.realFileURL(fileManager: fileManager),
            // Row J's per-app grants. A durable record of which apps the user let Sonny drive is
            // theirs to erase along with everything else — and leaving it behind would also leave
            // the wipe's own promise half-true.
            ApprovedAppStore.realFileURL(fileManager: fileManager),
            // Row 13's common output locations (SONNY-209). A short list of folder paths, which
            // sounds harmless and is not: where somebody's work goes is a map of what they work on,
            // and folder names are theirs. Erased with the rest for the same reason as everything
            // above it.
            OutputLocationStore.realFileURL(fileManager: fileManager),
            // Row 13's unfinished runs (SONNY-210). It holds a whole plan — the steps, the paths
            // they name, the draft text they carry — for a task the user started and did not
            // finish, which is as much of their content as any row in task history and is left
            // behind by a wipe that forgot it.
            ResumableTaskStore.realFileURL(fileManager: fileManager)
        ]
    }

    private func unique(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        var result: [URL] = []
        for url in urls {
            let key = url.standardizedFileURL.path
            if seen.insert(key).inserted {
                result.append(url)
            }
        }
        return result
    }
}
