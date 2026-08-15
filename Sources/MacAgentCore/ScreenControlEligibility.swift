import Foundation

/// Why Sonny refused to control an app. One case today; an enum rather than a `Bool` because a
/// second refusal ground would otherwise arrive as a second, parallel check somewhere else, and the
/// whole point of this file is that there is exactly one.
public enum ScreenControlRefusal: String, CaseIterable, Equatable, Sendable {
    /// The target is a terminal emulator.
    ///
    /// **Authority, not accuracy** (spec §7.4, founder-ratified as E6/C3 2026-08-12 and kept
    /// verbatim through the 2026-08-14 supersession that deleted per-app consent around it). A
    /// terminal is arbitrary shell execution: anything Sonny types into one runs with the user's
    /// full authority, outside every capability tier, every path whitelist and every workspace
    /// scope this engine has. That is true of a perfectly accurate vision model, so no amount of
    /// model quality ever converts this into a question worth asking a human — which is why it is
    /// a refusal and never a prompt.
    case terminal

    /// The sentence the user reads, and the same sentence the engine records as the refusal's
    /// reason. One string, because a refusal the log describes differently from the panel is a
    /// refusal nobody can audit.
    public var userFacingReason: String {
        switch self {
        case .terminal:
            return "Sonny never controls a terminal — anything typed into one runs with your full "
                + "account authority, outside every permission Sonny has. This is not something you "
                + "can allow."
        }
    }
}

/// Whether Sonny may control one specific app by synthesizing input events into it.
///
/// **The only producer is ``ScreenControlPolicy``.** `init` is `fileprivate` and this file has
/// exactly one call site for it, so no other file in either target can mint a verdict — an
/// "eligible" answer cannot be fabricated by a call site that forgot to ask, forwarded a stale
/// answer, or was handed one by a decoder. That is the same structural shape `PreparedPlanSource`
/// uses for origin (stamped by the engine after decoding, unreachable from planner output), applied
/// to the one question that decides whether a program is allowed to move the user's cursor.
///
/// Deliberately **not** `Codable`. A verdict is an answer computed now, about the app in front of
/// Sonny now; a decodable one could arrive from a stored plan, a routine, or a hostile planner
/// payload carrying `isEligible: true` for a terminal. Row I's pinned fields are resolver-only for
/// the same reason (SONNY-58 discipline) — this type simply has no decode path to exclude.
public struct ScreenControlVerdict: Equatable, Sendable {
    /// The bundle identifier this verdict was computed for, **as given** — trimmed, but with its own
    /// casing intact.
    ///
    /// **Not the normalized form, and that was a real bug for one commit.** Normalization exists for
    /// the deny-list comparison and lives inside it; storing the lowercased result here made the
    /// verdict's identifier unusable for the thing callers actually do with it, which is talk to
    /// macOS. `NSRunningApplication`, `SCShareableContent` and `NSWorkspace` all key on the bundle's
    /// own spelling, so a session pointed at `com.apple.safari` found no window, activated nothing,
    /// and failed on its first iteration with "no on-screen window was found". Anything comparing
    /// this against another identifier normalizes *both sides* — see
    /// `VisionSessionContainment.checkIterationStart`.
    public let bundleIdentifier: String
    public let displayName: String
    /// `nil` exactly when Sonny may control this app. There is no third state: ``isEligible`` is
    /// defined off this one field rather than stored beside it, so the two can never disagree.
    public let refusal: ScreenControlRefusal?

    public var isEligible: Bool {
        refusal == nil
    }

    fileprivate init(bundleIdentifier: String, displayName: String, refusal: ScreenControlRefusal?) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.refusal = refusal
    }
}

/// The one rule that decides which apps Sonny may control.
///
/// **What this replaced, and why the replacement is smaller.** SONNY-91 was contracted as a
/// per-app *consent store*: a durable grant per app, minted by the first vision approval, revocable
/// in Settings. The founder superseded that on 2026-08-14 — Sonny may control any installed app
/// without asking, in Normal and Power alike, and Safe mode's "ask before every action" is the only
/// thing that still prompts. So there is no grant to store, no revocation to observe and no consent
/// field on `ApprovalContext`. What survives is the half that was never about consent at all: the
/// terminal ban, which no user was ever going to be offered a choice about.
///
/// **The list is the tested guarantee.** Model-side "this looks like a shell" recognition is
/// defense in depth that row I's loop may add, and it is never what this check rests on: a static
/// bundle-identifier comparison cannot be talked out of its answer by anything on screen.
public enum ScreenControlPolicy {
    /// Terminal emulators, by bundle identifier, lowercased.
    ///
    /// `com.apple.Terminal` and `com.googlecode.iterm2` are the two the founder named. The rest are
    /// the other terminal emulators in common use on macOS, included because the ratified rule is
    /// categorical — "terminals are never controllable" — and a list of two does not implement that
    /// on a Mac with Warp or Ghostty installed. The founder's own wording ("extensible") is what
    /// this list is; adding an entry is a one-line change with no other moving part.
    ///
    /// **Evidence, stated honestly.** `com.apple.Terminal` was read off
    /// `/System/Applications/Utilities/Terminal.app/Contents/Info.plist` on the development machine
    /// at `25fb29c`; it is the only one of these installed there. Every other identifier comes from
    /// its project's published bundle configuration, not from a bundle inspected on this machine. A
    /// wrong identifier here fails *open* — it protects nothing — which is exactly why the entries
    /// are listed rather than pattern-matched, and why a correction is cheap.
    ///
    /// **What this list cannot do, said plainly rather than discovered later.** It bans terminal
    /// *applications*. It does not and cannot ban a shell embedded inside an app that is not one —
    /// VS Code's integrated terminal, a JetBrains run console, a notebook cell. Nothing in an app's
    /// bundle identity distinguishes "has a shell inside it" from "does not", so no static list
    /// reaches that case; row I's in-loop model-side recognition is where that risk is addressed,
    /// as defense in depth, and it is not claimed here as a guarantee.
    public static let terminalBundleIdentifiers: Set<String> = [
        "com.apple.terminal",          // Terminal (macOS)
        "com.googlecode.iterm2",       // iTerm2
        "dev.warp.warp-stable",        // Warp
        "com.mitchellh.ghostty",       // Ghostty
        "net.kovidgoyal.kitty",        // kitty
        "org.alacritty",               // Alacritty
        "com.github.wez.wezterm",      // WezTerm
        "co.zeit.hyper",               // Hyper
        "org.tabby",                   // Tabby
        "org.eugeny.terminus"          // Terminus (Tabby's former identity)
    ]

    /// The verdict for an app the resolver has already identified.
    ///
    /// Takes an ``InstalledApp`` rather than a name so that the identity being judged is Launch
    /// Services' answer — the same single-sourcing rule `WorkspaceScope`'s `bundle:` keys exist for
    /// (SONNY-58). A running process's self-reported name is never an input here, and neither is a
    /// display name: an app that calls itself "Terminal" while carrying some other bundle
    /// identifier is a different app, and controlling arbitrary apps is precisely what the founder
    /// authorized.
    public static func verdict(for app: InstalledApp) -> ScreenControlVerdict {
        verdict(bundleIdentifier: app.bundleIdentifier, displayName: app.displayName)
    }

    /// The verdict for a bundle identifier pinned earlier in the run.
    ///
    /// The second door, for the per-iteration re-check inside a live session: the target was pinned
    /// at resolve, and the loop re-asks rather than trusting that the answer it got once still
    /// holds. Both doors funnel here, so there is one comparison and one normalization, not two
    /// that drift.
    public static func verdict(bundleIdentifier: String, displayName: String) -> ScreenControlVerdict {
        let trimmed = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        return ScreenControlVerdict(
            bundleIdentifier: trimmed,
            displayName: displayName,
            refusal: terminalBundleIdentifiers.contains(normalize(bundleIdentifier)) ? .terminal : nil
        )
    }

    /// Trim, then lowercase.
    ///
    /// Bundle identifiers reaching the second door are strings carried through a run rather than
    /// values just read from Launch Services, so the comparison tolerates the shapes a carried
    /// string picks up: surrounding whitespace, and the case-insensitive matching Launch Services
    /// itself does (`com.apple.Terminal` and `com.apple.terminal` name one app).
    /// `String.lowercased()` is locale-independent in Swift — deliberately not
    /// `NSString.lowercased(with:)`, whose Turkish `I` would fold to `ı` and miss.
    ///
    /// **A Unicode precomposition step was written here and then removed, deliberately.** The worry
    /// was a decomposed spelling (`e` + U+0301 rather than `é`) slipping past set membership. It
    /// cannot: Swift's `String` compares and *hashes* by canonical equivalence, so the two spellings
    /// are one key in a `Set<String>` despite differing in byte length — measured, not assumed
    /// (13 vs 14 UTF-8 bytes, `==` true, `hashValue` equal, `Set.contains` true). Adding
    /// `precomposedStringWithCanonicalMapping` would have been a line that looks load-bearing,
    /// changes no answer, and quietly teaches the next reader that Swift needs help here. Recorded
    /// rather than silently omitted, so that reader does not add it back.
    static func normalize(_ bundleIdentifier: String) -> String {
        bundleIdentifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
