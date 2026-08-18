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
    /// `com.apple.Terminal` and `com.googlecode.iterm2` are the two the founder named. Most of the
    /// rest are the other terminal emulators in common use on macOS, included because the ratified
    /// rule is categorical — "terminals are never controllable" — and a list of two does not
    /// implement that on a Mac with Warp or Ghostty installed. The founder's own wording
    /// ("extensible") is what this list is; adding an entry is a one-line change with no other
    /// moving part.
    ///
    /// **Termius is here on the rule rather than on the word "terminal"** (founder decision
    /// 2026-08-17, SONNY-102). The rule's ground is spec §7.4: a terminal is arbitrary shell
    /// execution with the user's full rights. An SSH session meets that test on the *far* machine,
    /// and a dedicated SSH client is not an emulator in the sense the rest of this list was built
    /// around. The decision aligns the list with the rule rather than widening the rule. It was not
    /// hypothetical: Launch Services reports Termius as the default `ssh://` handler on the
    /// founder's Mac, ahead of Terminal and iTerm, so it is what opens when anything asks for an SSH
    /// connection — and it was controllable.
    ///
    /// **"The founder's Mac" is the only machine in any of this**, and it is also what older notes
    /// here called "the development machine". Earlier text spoke of the two as if they were
    /// separate; they never were (PR #68 review).
    ///
    /// **`com.termius-dmg.mac` is correct as written. Do not "fix" the `-dmg`.** It is a packaging
    /// artefact carried in the real identifier, and it is exactly the character a plausible guess
    /// would have dropped: `com.termius.mac` is what typing this from memory produces. It was read
    /// from Launch Services on the founder's Mac rather than recalled, which is the only reason it
    /// is right.
    ///
    /// **Evidence, split by how each identifier was *obtained*.** Provenance only. It is not a
    /// claim about which of these apps is installed anywhere — that is a separate axis, recorded
    /// below, and running the two together is what put two false sentences in this comment once
    /// already (PR #68 review, F1 and F2).
    ///
    /// - **Read from the bundle's own `Info.plist` (1):** `com.apple.terminal`, off
    ///   `/System/Applications/Utilities/Terminal.app/Contents/Info.plist` at `25fb29c`.
    /// - **Established from Launch Services' handler registry, 2026-08-17 (1):**
    ///   `com.termius-dmg.mac`. A different provenance from the line above — the answer came from
    ///   `NSWorkspace.urlsForApplications(toOpen:)` rather than from reading a bundle, and that
    ///   distinction is load-bearing: Termius is LS's registered default `ssh://` handler while
    ///   declaring *no* such scheme in its own `CFBundleURLTypes`, so a plist scan — the more
    ///   obvious method — found Terminal and iTerm and missed the one app the question was about.
    /// - **From each project's published bundle configuration, no bundle inspected (9):** iTerm2,
    ///   Warp, Ghostty, kitty, Alacritty, WezTerm, Hyper, Tabby, Terminus.
    ///
    /// The split is recorded rather than averaged into "these are the terminal identifiers" because
    /// the three claims have different strengths and a reader deciding whether to trust an entry
    /// deserves to know which kind it is. A wrong identifier fails *open* — it protects nothing
    /// rather than banning something wrongly — which is why the entries are listed rather than
    /// pattern-matched, and why a correction is cheap. `theEvidenceSplitMatchesTheList` fails if
    /// this list changes without this record changing with it.
    ///
    /// **The other axis: three of the eleven can be corroborated against Launch Services on the
    /// founder's Mac, and eight cannot.** Re-measured on 2026-08-18 by asking LS for each of the
    /// eleven in turn — a fact about that Mac on that date rather than about any commit. Three
    /// resolve: `com.apple.terminal` at `/System/Applications/Utilities/Terminal.app` (LS spells it
    /// `com.apple.Terminal`, capital T), `com.googlecode.iterm2` at `~/Applications/iTerm.app`, and
    /// `com.termius-dmg.mac` at `/Applications/Termius.app`. The other eight are not installed, so
    /// LS can neither confirm nor deny them — not evidence they are wrong, recorded so nobody reads
    /// "checked against Launch Services" as covering the whole list.
    ///
    /// **`com.googlecode.iterm2` is in the published-configuration group *and* corroborated here,
    /// and that is not a contradiction.** Provenance is how an identifier was first obtained;
    /// corroboration is whether this Mac agrees now. An entry can be one, both or neither.
    ///
    /// ## What this list cannot do — two gaps, both real, said plainly rather than discovered later
    ///
    /// **1. A terminal nobody listed is controllable.** This is a *name*-based deny list, and a
    /// name-based deny list is never complete: a terminal emulator released tomorrow, or shipped
    /// today under an identifier no one here thought of, is not on it and Sonny will control it. The
    /// categorical rule the founder ratified — "terminals are never controllable" — is therefore
    /// enforced by an enumeration that cannot in principle be exhaustive, and that gap does not
    /// close by adding entries; it only narrows. Nothing about this is a defect in the list. It is
    /// what a deny list *is*, stated so nobody later reads a passing test suite as proof of the
    /// categorical claim. **Filed as its own ticket (SONNY-102) rather than left implied** — the
    /// alternatives to enumeration (a heuristic on bundle metadata, an allow-list inversion, an
    /// AX-tree signal) are real design work with real costs, and they are not row I's.
    ///
    /// **Adding Termius did not cover the SSH-client category**, and that limit is deliberate.
    /// Royal TSX, Shuttle, Core Shell, Prompt, Blink, SecureCRT, ZOC, PuTTY and SSH Config Editor
    /// are not installed on the founder's Mac, so no identifier for any of them can be
    /// established from there — and none was invented. **A guessed identifier is worse than an
    /// absent one**: it matches nothing while looking like coverage. This list grows as apps are
    /// encountered, with the app in hand, never by inference.
    ///
    /// **2. A shell inside an app that is not a terminal is controllable.** VS Code's integrated
    /// terminal, a JetBrains run console, a notebook cell. Nothing in an app's bundle identity
    /// distinguishes "has a shell inside it" from "does not", so no static list reaches that case at
    /// all — this one does not even narrow with more entries.
    ///
    /// Row I's in-loop model-side recognition is where both risks are actually addressed, as defense
    /// in depth. It is not claimed here as a guarantee, and it must never become the load-bearing
    /// check: a static comparison cannot be talked out of its answer by anything on screen, and that
    /// is the whole reason this list is what the ban rests on.
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
        "org.eugeny.terminus",         // Terminus (Tabby's former identity)
        "com.termius-dmg.mac"          // Termius (SSH client) — the -dmg is real, see above
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
