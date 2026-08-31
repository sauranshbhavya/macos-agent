import Foundation

/// One app the user has allowed Sonny to control, and when they allowed it.
///
/// **The bundle identifier is the key, and it is Launch Services' answer** — never a running
/// process's self-reported name. Same single-sourcing rule `WorkspaceScope`'s `bundle:` keys exist
/// for (SONNY-58): an app that merely calls itself "Chrome" must not inherit the real Chrome's
/// standing, and a durable grant is exactly the wrong place to start trusting a name.
///
/// `displayName` is carried for the revocation surface to render — a user revoking a grant reads
/// "Notes", not `com.apple.Notes` — and is never what the grant is matched on.
public struct ApprovedApp: Codable, Equatable, Sendable {
    /// **Stored as given** — trimmed, with its own casing intact.
    ///
    /// Row I paid for the other choice: `ScreenControlVerdict` first stored a *lowercased* bundle
    /// identifier, and the loop hands that identifier to ScreenCaptureKit and
    /// `NSRunningApplication`, both of which key on the bundle's own spelling. Every session found
    /// no window and died on its first iteration. Case-folding belongs in the comparison, which is
    /// ``matches(bundleIdentifier:)``, and nowhere else.
    public var bundleIdentifier: String
    public var displayName: String
    public var approvedAt: Date

    public init(bundleIdentifier: String, displayName: String, approvedAt: Date = Date()) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.approvedAt = approvedAt
    }

    /// Whether this grant covers `bundleIdentifier`, folding **both sides** through
    /// ``ScreenControlPolicy/normalize(_:)``.
    ///
    /// The rule is borrowed rather than restated: Launch Services matches identifiers
    /// case-insensitively (`com.apple.Terminal` and `com.apple.terminal` name one app), and a
    /// string carried through a run picks up surrounding whitespace. A second normalizer written
    /// here would be a second rule to keep in step with the deny list's, and the two drifting is
    /// how a grant starts covering something the refusal does not.
    public func matches(bundleIdentifier candidate: String) -> Bool {
        ScreenControlPolicy.normalize(bundleIdentifier) == ScreenControlPolicy.normalize(candidate)
    }
}

/// The apps the user has allowed Sonny to control, encrypted on disk — the eleventh local store.
///
/// **Tenth when this was written, eleventh when it landed.** Row E's `TaskPlanDetailStore` merged
/// first and took the count to ten, so this branch rebased onto it. SONNY-140's ticket text, its
/// commit title and `docs/sonny-row-j-plan.md` §2.4 all say "the tenth store" and are left as the
/// dated records they are; the arithmetic that has to be right is the wipe's, and that is asserted
/// rather than described — `theWipeReachesEveryLocalStore`.
///
/// **The shared pattern, not a variant** (`CLAUDE.md`): a defaulted `encryption:` parameter,
/// AES-GCM behind the `SONNYENC1\n` header, and transparent legacy-plaintext migration on the
/// first successful load. The ten stores before it work this way and this one has no reason to
/// differ.
///
/// **A stored grant never outranks a refusal, and that is belt and braces rather than the load
/// bearing part.** The terminal deny list refuses at three doors above this store, and the runtime
/// screen check refuses above it too — so a grant simply never gets consulted for a terminal. What
/// this store adds is that it will not *hold* one: a durable grant outlives the session that minted
/// it, and an entry for an app that lands on the deny list later must not be able to look like
/// permission to anyone reading the file. ``approve(bundleIdentifier:displayName:approvedAt:)``
/// asks ``ScreenControlPolicy/verdict(bundleIdentifier:displayName:)`` — the production comparison
/// itself, so the refusal tracks the list rather than re-reading it.
///
/// **Deliberately uncapped, unlike the trace stores.** `RecentArtifactStore` and its siblings evict
/// on count and age because they accumulate without limit and nobody asked for their contents. A
/// grant is the opposite on both counts: the user asked for it by hand, it is bounded in practice
/// by the number of apps a person installs, and evicting one would revoke consent silently. That is
/// the same thing the founder refused when they declined to auto-clear the user's list on a mode
/// switch — *auto-clearing destroys user data on a toggle, which the consequence rule says should
/// ask first* (2026-08-16). Removal is the user's, through the revocation surface.
public struct ApprovedAppStore: @unchecked Sendable {
    public let fileURL: URL
    private let fileManager: FileManager
    private let encryption: LocalStorageEncryption

    public init(
        fileURL: URL,
        fileManager: FileManager = .default,
        encryption: LocalStorageEncryption = .shared
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.encryption = encryption
    }

    /// Where the shipping app keeps this store.
    ///
    /// The rule that makes this a named call rather than an initializer default is on
    /// `ClipboardHistoryStore.defaultDirectory` (SONNY-350).
    public static func realFileURL(fileManager: FileManager = .default) -> URL {
        ClipboardHistoryStore.defaultDirectory(fileManager: fileManager)
            .appendingPathComponent("approved-apps.json")
    }

    /// Every grant, most recently approved first.
    ///
    /// Ordering is stable rather than merely sorted: `approvedAt` first, and the identifier as the
    /// tiebreak, so two grants minted inside the same second do not swap places between reads.
    public func loadAll() throws -> [ApprovedApp] {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return []
        }
        let data = try Data(contentsOf: fileURL)
        let decoded = try encryption.decode(
            [ApprovedApp].self,
            from: data,
            decoder: .approvedAppISO8601
        )
        let apps = decoded.migratingLegacyPlaintext(store: "approved apps", write: write)
        return sorted(apps)
    }

    /// Records the user's decision to let Sonny control this app.
    ///
    /// - Returns: the grant now held for this app — the freshly written one, or the existing one
    ///   when there already was one — and `nil` when nothing was stored, which happens exactly
    ///   twice: a blank identifier, and an app the terminal deny list refuses.
    ///
    /// **Re-approving does not restart the clock.** An app already granted is returned as it
    /// stands and no write happens: `approvedAt` records when the user actually decided, and
    /// rewriting it on a second pass through would turn a fact into a timestamp of the last time
    /// anything happened to touch the file.
    @discardableResult
    public func approve(
        bundleIdentifier rawBundleIdentifier: String,
        displayName rawDisplayName: String,
        approvedAt: Date = Date()
    ) throws -> ApprovedApp? {
        let bundleIdentifier = rawBundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundleIdentifier.isEmpty else {
            return nil
        }
        // The production comparison, not a second reading of `terminalBundleIdentifiers`. A grant
        // this store will not hold is one nobody can later mistake for permission.
        guard ScreenControlPolicy.verdict(
            bundleIdentifier: bundleIdentifier,
            displayName: rawDisplayName
        ).isEligible else {
            return nil
        }

        var apps = try loadAll()
        if let existing = apps.first(where: { $0.matches(bundleIdentifier: bundleIdentifier) }) {
            return existing
        }

        let approved = ApprovedApp(
            bundleIdentifier: bundleIdentifier,
            displayName: rawDisplayName.trimmingCharacters(in: .whitespacesAndNewlines),
            approvedAt: approvedAt
        )
        apps.append(approved)
        try write(sorted(apps))
        return approved
    }

    /// Revokes one grant — "Removal is the user's, through the revocation surface", which is
    /// Command Center's Memory section (SONNY-208).
    ///
    /// The type doc above says this store is deliberately uncapped because evicting a grant would
    /// revoke consent silently. This is the loud counterpart, and the only removal path short of
    /// deleting the whole file: the user asks, by name, for one app to be forgotten. Sonny then asks
    /// about that app again the next time it needs it, which is the correct consequence rather than
    /// a regression.
    ///
    /// Matching goes through `ApprovedApp.matches(bundleIdentifier:)`, the same comparison the gate
    /// reads a grant with, so an app that can be matched can be forgotten. An identifier nothing
    /// holds is a no-op, not an error.
    public func forget(bundleIdentifier rawBundleIdentifier: String) throws {
        let bundleIdentifier = rawBundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundleIdentifier.isEmpty else {
            return
        }
        let apps = try loadAll()
        let remaining = apps.filter { !$0.matches(bundleIdentifier: bundleIdentifier) }
        guard remaining.count != apps.count else {
            return
        }
        try write(sorted(remaining))
    }

    /// Revokes every grant at once — Settings' Remove All (SONNY-144).
    ///
    /// **One write, not one per app.** The alternative, looping ``forget(bundleIdentifier:)``, is a
    /// load-and-write per grant and is not atomic: a failure halfway through leaves the user looking
    /// at a list they asked to empty, half emptied, with no way to tell which half went. This writes
    /// the empty list once, so the press either happens or does not.
    ///
    /// **It takes what the revocation surface does not render, and that is deliberate.** ``loadAll()``
    /// shows everything; the *view* filters, dropping any grant the terminal deny list refuses, so a
    /// stored entry the list hides has no row and therefore no per-row Remove. This is the one
    /// control that reaches it — the user asked for the file to hold nothing, and it then holds
    /// nothing. (That claim was false as first shipped: the control was gated on the rendered list
    /// being non-empty, so with *every* stored grant ineligible it was not on screen either and
    /// nothing short of Settings' whole-app wipe reached the file. It is gated on this store's own
    /// count now — PR #175 review, F1.)
    ///
    /// A store with nothing in it is a no-op rather than a write, so pressing Remove All on an empty
    /// list does not mint a file for a user who never granted anything.
    ///
    /// **A file that will not read is reported, never overwritten.** The load is inside this call
    /// rather than beside it, so an undecryptable store throws here and the press fails with a
    /// message instead of writing an empty list over bytes that may still be recoverable — the same
    /// reasoning `LocalDataQuarantine` sets aside an unreadable file under: a decrypt failure proves
    /// only that the bytes were written under a different key, and a key migration can hand that key
    /// back. The user's route through an unreadable store is the Memory row's Delete, which keeps
    /// the file; this control is not a second, quieter door onto destroying it.
    public func forgetAll() throws {
        guard !(try loadAll()).isEmpty else {
            return
        }
        try write([])
    }

    private func sorted(_ apps: [ApprovedApp]) -> [ApprovedApp] {
        apps.sorted {
            if $0.approvedAt != $1.approvedAt {
                return $0.approvedAt > $1.approvedAt
            }
            return $0.bundleIdentifier < $1.bundleIdentifier
        }
    }

    private func write(_ apps: [ApprovedApp]) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encryption.encode(apps, encoder: .approvedAppPrettySorted)
        try data.write(to: fileURL, options: .atomic)
    }
}

private extension JSONEncoder {
    static var approvedAppPrettySorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var approvedAppISO8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
