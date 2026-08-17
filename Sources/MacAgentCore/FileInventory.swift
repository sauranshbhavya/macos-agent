import Foundation

/// How two output destinations are compared when deciding whether they would be **the same file**.
///
/// Case-folded, because the default macOS volume is case-insensitive APFS: `Report.pdf` and
/// `report.pdf` are two distinct Swift strings and one file on disk. Comparing raw paths let two
/// documents each claim a destination that looked free and was not, which then aborted the conversion
/// at the converter — the exact pre-fix production failure — instead of renaming, and said nothing in
/// the summary because neither record was flagged as renamed (SONNY-28, PR #41 review F1).
///
/// **What this does and does not catch, stated as a bound rather than as an approximation.**
/// - *Caught:* simple case differences, which is the reachable everyday collision.
/// - *Caught already, by `String` itself, not by anything here:* canonically-equivalent spellings.
///   Swift's `String` equality and hashing are canonical-equivalence-based, so a name written NFC and
///   one written NFD are the **same** `Set<String>` element before this function is called. An earlier
///   version ran `precomposedStringWithCanonicalMapping` here and a comment credited it with handling
///   that case; it was a no-op for the comparison it served, and it is gone rather than kept as
///   belt-and-braces, because a call that reads like the mechanism and is not is worse than no call.
/// - *Caught since SONNY-79:* pairs whose full case folding **expands** — `Straße.pdf` against
///   `STRASSE.pdf`, and ligature pairs such as `ﬁ`/`fi`. `lowercased()` left `ß` alone while mapping
///   `SS` to `ss`, so these were one file on disk and two keys here; the batch then aborted partway
///   with nothing in the summary explaining why. The fold below closes that, and the table on
///   `folded` records what was measured against the volume itself.
///
/// The full reasoning, the measurement and the two folds that were tried and rejected live on
/// `DestinationKey.folded` rather than being repeated here.
enum DestinationKey {
    /// Folds a destination path the way the filesystem does.
    ///
    /// **`.caseInsensitive` alone, and `locale: nil` — both halves were measured rather than
    /// reasoned about** (SONNY-79). The previous `lowercased()` under-folded: it leaves `ß` as `ß`
    /// while mapping `SS` to `ss`, so `Straße.pdf` and `STRASSE.pdf` were two keys here and one file
    /// on disk. Measured on APFS at `06297f1`, comparing each candidate fold against what the volume
    /// itself answers by writing one name and asking `fileExists` for the other:
    ///
    /// | pair | filesystem | `lowercased()` | `.caseInsensitive` |
    /// |---|---|---|---|
    /// | `Straße` / `STRASSE` | same | **differs** | same |
    /// | `ﬁle` / `file` | same | **differs** | same |
    /// | `ﬀ` / `ff` | same | **differs** | same |
    /// | `Report` / `report` | same | same | same |
    /// | `café` / `CAFÉ` | same | same | same |
    /// | `café` / `cafe` | differs | differs | differs |
    /// | NFC `café` / NFD `café` | same | same | same |
    /// | `İstanbul` / `istanbul` | differs | differs | differs |
    /// | `ırmak` / `IRMAK` | differs | differs | differs |
    /// | `ΟΔΟΣ` / `οδός` | differs | differs | differs |
    /// | `Ｒeport` / `Report` | differs | differs | differs |
    /// | Kelvin sign `K` / `k` | same | same | same |
    ///
    /// Twelve classes, agreement on all twelve.
    ///
    /// **Two tempting additions were measured and rejected, and that is the point of recording the
    /// table.** Adding `.diacriticInsensitive` folds `café.pdf` and `cafe.pdf` together, which the
    /// filesystem does *not* — it would rename a document that never needed renaming. Passing
    /// `locale: .current` instead of `nil` folds `İstanbul` and `istanbul` together under a Turkish
    /// locale, which the filesystem also does not — so this would misbehave only for Turkish users,
    /// which is exactly the kind of bug that ships. Both appear in this repo's *search* fold
    /// (`RecentArtifactStore`), correctly: a user typing "cafe" to find "café" wants diacritic
    /// insensitivity, and search is locale-shaped. **That recipe answers a different question and
    /// borrowing it here would have been wrong in two directions at once.**
    ///
    /// **What is still not claimed.** This is agreement with the volumes measured, not a reproduction
    /// of any filesystem's folding table. A volume whose folding differs from Foundation's
    /// `.caseInsensitive` fold is not ruled out, and the failure mode there is unchanged from before:
    /// the batch aborts at the converter rather than overwriting, because both shipped converters
    /// refuse an occupied destination. Nothing is destroyed either way.
    ///
    /// **Folded unconditionally rather than probed per volume.** On a case-sensitive volume the only
    /// cost is a rename that was not strictly required, which the summary announces either way;
    /// getting it wrong in the other direction loses the fix entirely on the volume nearly every user
    /// has.
    ///
    /// Used by `FileInventory.docxFiles` and by `AgentActionExecutor`'s within-plan output-path
    /// disambiguation. The two keep separate *policies* — the docx side must also avoid names that
    /// exist on disk, the executor side must never consult disk or it would suppress the tier-3
    /// "output already exists" escalation — but they must agree on what "the same destination" means,
    /// and this is that agreement. Note that folding is a pure string operation: the executor side
    /// still touches no disk.
    static func folded(_ path: String) -> String {
        path.folding(options: [.caseInsensitive], locale: nil)
    }
}

public struct FileRecord: Equatable, Sendable {
    public var url: URL
    public var byteCount: Int64

    public init(url: URL, byteCount: Int64) {
        self.url = url
        self.byteCount = byteCount
    }

    public var displaySize: String {
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }
}

public struct DocxRecord: Equatable, Sendable {
    public var sourceURL: URL
    public var destinationURL: URL
    public var skippedBecausePDFExists: Bool
    public var isMockDestination: Bool
    /// Whether `destinationURL` carries a `-2`, `-3`, … suffix because an earlier document in the
    /// same scan already claimed the name this document's basename produces. Reported to the user
    /// in the preview and the run summary — a file appearing under a name they did not ask for is
    /// something they have to be told, even though nothing was lost.
    public var renamedToAvoidCollision: Bool

    public init(
        sourceURL: URL,
        destinationURL: URL,
        skippedBecausePDFExists: Bool,
        isMockDestination: Bool,
        renamedToAvoidCollision: Bool = false
    ) {
        self.sourceURL = sourceURL
        self.destinationURL = destinationURL
        self.skippedBecausePDFExists = skippedBecausePDFExists
        self.isMockDestination = isMockDestination
        self.renamedToAvoidCollision = renamedToAvoidCollision
    }
}

public struct FileInventory {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func largestFiles(in folder: URL, count: Int) throws -> [FileRecord] {
        try regularFiles(in: folder)
            .sorted { first, second in
                if first.byteCount == second.byteCount {
                    return first.url.path < second.url.path
                }
                return first.byteCount > second.byteCount
            }
            .prefix(max(count, 0))
            .map { $0 }
    }

    /// Every convertible `.docx` under `folder`, paired with the PDF each one would produce.
    ///
    /// **No two records of one scan ever share a destination**, comparing them the way the filesystem
    /// does — see `DestinationKey`. A destination is derived from the document's
    /// basename, and `regularFiles(in:)` recurses, so `SubA/report.docx` and `SubB/report.docx` both
    /// name `report.pdf` — and with an explicit flat `outputFolder` they land in the same directory.
    /// `SubA/Report.docx` and `SubB/report.docx` do too, on the case-insensitive volume nearly every
    /// user has, which a raw string comparison missed (PR #41 review F1).
    ///
    /// The guarantee is per *scan*, and that qualifier is load-bearing: two `[scan_docx, convert]`
    /// units in one chain scan separately, so the second re-scans after the first has written and its
    /// record is skipped rather than renamed. That is SONNY-76, filed, not fixed here.
    /// `skippedBecausePDFExists` cannot save them: it is evaluated once, here, before anything is
    /// written, so against a fresh output folder both records answer `false` and both convert. The
    /// second one then destroyed the first under `MockDocumentConverter` (an `.atomic` write, which
    /// clobbers) and aborted the whole batch mid-run under `MicrosoftWordDocumentConverter` (a
    /// `moveItem`, which throws), leaving every later document unprocessed. SONNY-28.
    ///
    /// Fixed where the collision is manufactured rather than in each converter: a basename another
    /// document in this same scan has already claimed gets a `-2`, `-3`, … suffix until it is free.
    ///
    /// **Free means neither claimed nor already on disk.** Suffixing onto an existing file would
    /// turn one silent overwrite into another, and the on-disk check is also what keeps this from
    /// interfering with the skip rule: a document whose *preferred* destination already exists is
    /// still skipped, exactly as before, and never renames. Only a collision with another document
    /// of the same run renames, and only ever onto a name nothing occupies.
    public func docxFiles(in folder: URL, outputFolder: URL? = nil, mockDestinations: Bool = false) throws -> [DocxRecord] {
        let sources = try regularFiles(in: folder)
            .filter { record in
                record.url.pathExtension.lowercased() == "docx" &&
                !record.url.lastPathComponent.hasPrefix("~$")
            }
            .sorted { $0.url.path < $1.url.path }

        var claimedDestinations: Set<String> = []
        var records: [DocxRecord] = []
        for source in sources {
            let basename = source.url.deletingPathExtension().lastPathComponent
            let destinationFolder = outputFolder ?? source.url.deletingLastPathComponent()
            let preferred = destinationFolder.appendingPathComponent(
                Self.pdfName(stem: basename, mockDestinations: mockDestinations)
            )

            if fileManager.fileExists(atPath: preferred.path) {
                records.append(
                    DocxRecord(
                        sourceURL: source.url,
                        destinationURL: preferred,
                        skippedBecausePDFExists: true,
                        isMockDestination: mockDestinations
                    )
                )
                continue
            }

            var destination = preferred
            let renamed = claimedDestinations.contains(DestinationKey.folded(preferred.path))
            if renamed {
                var suffix = 2
                while true {
                    let candidate = destinationFolder.appendingPathComponent(
                        Self.pdfName(stem: "\(basename)-\(suffix)", mockDestinations: mockDestinations)
                    )
                    if !claimedDestinations.contains(DestinationKey.folded(candidate.path)),
                       !fileManager.fileExists(atPath: candidate.path) {
                        destination = candidate
                        break
                    }
                    suffix += 1
                }
            }

            claimedDestinations.insert(DestinationKey.folded(destination.path))
            records.append(
                DocxRecord(
                    sourceURL: source.url,
                    destinationURL: destination,
                    skippedBecausePDFExists: false,
                    isMockDestination: mockDestinations,
                    renamedToAvoidCollision: renamed
                )
            )
        }
        return records
    }

    private static func pdfName(stem: String, mockDestinations: Bool) -> String {
        mockDestinations ? "\(stem).mock.pdf" : "\(stem).pdf"
    }

    private func regularFiles(in folder: URL) throws -> [FileRecord] {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .totalFileAllocatedSizeKey
        ]

        guard let enumerator = fileManager.enumerator(
            at: folder,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            return []
        }

        var records: [FileRecord] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true {
                continue
            }
            guard values.isRegularFile == true else {
                continue
            }

            let size = Int64(values.fileSize ?? values.totalFileAllocatedSize ?? 0)
            records.append(FileRecord(url: url, byteCount: size))
        }
        return records
    }
}

public extension URL {
    func pathRelative(to baseURL: URL) -> String {
        let base = baseURL.standardizedFileURL.path
        let full = standardizedFileURL.path
        if full == base {
            return lastPathComponent
        }
        if full.hasPrefix(base + "/") {
            return String(full.dropFirst(base.count + 1))
        }
        return full
    }
}
