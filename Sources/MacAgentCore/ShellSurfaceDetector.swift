import Foundation

// MARK: - Signals

/// One class of evidence that the text recognized on a captured window came off a shell.
///
/// **Classes, not occurrences.** ``ShellSurfaceVerdict/showsShell`` counts how many of these fired,
/// never how many times any one of them did, which is what makes the founder's condition — *two
/// independent signs, not one* (2026-08-16) — mean what it says. Two lines matching the same pattern
/// are one piece of evidence seen twice; a prompt line beside a shell's own error message are two.
///
/// **Every signal is specific to the thing it claims to detect, and that is a correctness property
/// rather than a matter of taste** (PR #57 review, F1). The first version of this enum was not: its
/// prompt signal accepted `▶` and `»` — a disclosure triangle and a breadcrumb separator, neither of
/// which is a prompt in any shell — and its command signal fired on any line beginning with a
/// punctuation mark followed by a word like `go`, `make`, `open` or `head`. Between them, a
/// documentation page reading "Getting Started / ▶ Advanced options / $ brew install sonny" refused,
/// and fifteen of sixteen quoted-reply lines in an email thread fired the second signal. A signal
/// that fires on "Getting Started" is not evidence of a shell, and no threshold can repair one.
///
/// **Every signal is one-directional.** Nothing here subtracts. `.claude/rules/`'s standing rule for
/// screen-derived signals is that they may add scrutiny and never remove it, and a check that could
/// be talked *down* by something rendered would hand the attacker the off switch — the exact reason
/// the static deny list stays the load-bearing refusal and this one is layered after it. The one
/// place a pattern declines to fire on text it otherwise matches — a shebang, under
/// ``shellInterpreterInvocation`` — is a statement about what that text *is* (a file's first line,
/// not a command being run), not a suppressor that cancels evidence found elsewhere.
public enum ShellSurfaceSignal: String, CaseIterable, Equatable, Sendable {
    /// A shell prompt: `user@host:~/dev$`, `user@host dir %`, `[user@host dir]$`, `bash-5.2$`, an
    /// oh-my-zsh `➜`, a PowerShell `PS C:\…>`.
    ///
    /// **Structure, not a sigil.** The address-shaped part alone is nowhere near enough — "Hi team,
    /// alice@example.com says the build is 50% faster" carries an address and a `%` and is not a
    /// prompt. What is required is a prompt's *shape*: an identity, then a path (either after a
    /// colon or as its own whitespace-delimited token), then a terminating sigil **separated from
    /// that path by whitespace, or glued only to a closing bracket**. In prose the sigil is glued to
    /// a digit — which is exactly what "priya@acme.io 82% open" is, and what a prompt never is
    /// (PR #57 N1).
    ///
    /// **A minimal prompt counts only when it repeats and ends at a waiting prompt** (PR #57 N2).
    /// Plenty of shells print nothing but `$ ` or `% `, and the deny list cannot help there because
    /// this check exists for shells running *inside* something else. A single `$ npm install` is a
    /// documentation page and must stay invisible; a `$ `/`% ` line occurring at least
    /// ``ShellSurfaceDetector/minimumMinimalPromptLines`` times **whose last occurrence is bare** is
    /// a scrollback ending at a prompt waiting for input — a shape prose does not produce and a live
    /// terminal almost always does.
    case interactivePrompt = "interactive_prompt"

    /// A command that a shell has actually been asked to run: a recognised command name in the
    /// remainder of a prompt line, a `./script` execution at one, or a notebook `!command` escape.
    ///
    /// **Position is what makes this specific, and it is the whole fix for the documentation-page
    /// case.** A bare `$` at the start of a line is how a docs page, a README and a chat message all
    /// show a reader what to type; it is not a prompt and no longer counts as one. This fires only
    /// where something is being typed *at* a real prompt, or through a notebook's explicit shell
    /// escape. So `$ npm install -g sonny` on a documentation page yields **nothing at all**, while
    /// `sauransh@Mac macos-agent % ls` — an idle terminal panel where the last command succeeded —
    /// yields this and ``interactivePrompt``, which is two.
    ///
    /// **Why this is a second class and not the prompt counted twice.** A prompt is the shell
    /// rendering its own identity; this is a command having been run. Either occurs without the
    /// other: a freshly-opened or cleared panel shows a prompt with nothing typed at it, and a
    /// notebook `!pip install` fires this with no prompt anywhere. That independence is the
    /// difference between this and the `promptScrollback` signal deleted before the first commit,
    /// which was the *same* predicate counted a second time.
    ///
    /// **The independence is partial on the prompt path, and that is stated rather than implied**
    /// (PR #57 N1). Where this fires from a prompt line it is computed *from* the prompt ranges, so
    /// a prompt-pattern misfire can produce both signals off one line with no second opinion. That
    /// derivation is inherent to the case it exists for — a command typed at a prompt is on the
    /// prompt's own line, which is what makes an idle terminal panel refuse — so it cannot be fixed
    /// by requiring different lines. What was done instead is to shrink the shared failure mode
    /// until it is hard to reach: the sigil may no longer be glued to a digit, and the command must
    /// be the **first** token after the prompt rather than any of the ~90 names appearing anywhere
    /// in the remainder. The residual is recorded on the ticket with the string that still reaches
    /// it.
    case commandRunInAShell = "command_run_in_a_shell"

    /// The shape of a directory listing: a permission string with a link count, or a `total <n>`
    /// header. Output, so it exists only because a command already ran.
    case commandOutputListing = "command_output_listing"

    /// A shell's own diagnostic — `zsh: command not found: …`, `-bash: …`, ssh's
    /// `Permission denied (publickey)`. Emitted by the execution layer itself, never typed by a user
    /// and never rendered by an app describing one.
    case shellDiagnostic = "shell_diagnostic"

    /// Session chrome: `Last login:`, `[Process completed]`, `Process finished with exit code`, a
    /// bare `logout`, `Connection to … closed`. A shell session beginning or ending.
    case sessionBanner = "session_banner"

    /// An interpreter being named as the thing that will run something — `/bin/bash script.sh`,
    /// `/usr/bin/env zsh`, `bash -c`, or a notebook's `%%bash` cell magic.
    ///
    /// A shebang is **not** this, and is excluded: `#!/bin/bash` at the top of a file open in an
    /// editor is the file saying how it *would* be run, not a shell running. `%%bash` is: it selects
    /// the interpreter a notebook cell will be handed to, which is the same fact `/bin/bash foo.sh`
    /// states, and it is a different fact from the `!ls` escape that ``commandRunInAShell`` reads.
    case shellInterpreterInvocation = "shell_interpreter_invocation"
}

// MARK: - Verdict

/// What ``ShellSurfaceDetector`` concluded about one document of recognized text.
///
/// **The only producer is ``ShellSurfaceDetector``.** `init` is `fileprivate` and this file has one
/// call site for it, so no other file in either target can mint a verdict — a "no shell" answer
/// cannot be fabricated by a call site that forgot to ask, forwarded a stale answer, or was handed
/// one by a decoder. That is the same structural shape ``ScreenControlVerdict`` uses for the
/// question next to this one, and the reason it is used here too: both decide whether a program is
/// allowed to move the user's cursor inside a window.
///
/// Deliberately **not** `Codable`, for the reason `ScreenControlVerdict` is not: a verdict is an
/// answer computed now, about the window in front of Sonny now, and a decodable one could arrive
/// from a stored plan or a hostile payload carrying an empty signal list.
///
/// **It carries signal names and nothing else, and that is enforced rather than observed.** The
/// single stored property is a list drawn from a six-case enum with no associated values, so a
/// verdict crossing a type boundary carries no screen content with it — which is what lets the raw
/// recognized text stay inside ``LocalRedactionService``. Adding *any* field of a text-bearing type
/// here would silently reopen that route, so
/// `theVerdictHoldsNothingButSignalsAndThatIsCheckedNotAssumed` reads this declaration and fails on
/// one, and `twoDifferentScreensWithTheSameSignalsProduceEqualVerdicts` fails on it behaviourally.
public struct ShellSurfaceVerdict: Equatable, Sendable {
    /// Which classes of evidence fired, in ``ShellSurfaceSignal/allCases`` order and each at most
    /// once.
    public let signals: [ShellSurfaceSignal]

    /// Whether this document showed a shell.
    ///
    /// Defined off ``signals`` rather than stored beside it, so the two can never disagree — the
    /// same reason `ScreenControlVerdict.isEligible` is computed from its refusal.
    public var showsShell: Bool {
        signals.count >= ShellSurfaceDetector.signalThreshold
    }

    fileprivate init(signals: [ShellSurfaceSignal]) {
        self.signals = signals
    }
}

// MARK: - Detector

/// Pattern-based detection of a shell rendered on screen, over text a recognizer already produced.
///
/// **What this is for.** `ScreenControlPolicy.terminalBundleIdentifiers` refuses the terminal apps
/// it names and refuses them first, at three doors and again every iteration. It cannot reach a
/// terminal nobody listed, and it cannot reach a shell running *inside* an app that is not a
/// terminal — VS Code's integrated terminal, a JetBrains run console, a notebook cell — because
/// nothing in a bundle identifier distinguishes "has a shell inside it". That second gap does not
/// narrow with more list entries at all. This reads what is actually rendered, so it reaches both
/// (SONNY-102's approach, chosen by the founder 2026-08-16; designed in
/// `docs/sonny-row-j-plan.md` §4).
///
/// **It is never the primary refusal, and the ordering is not a design choice.** A static bundle
/// comparison cannot be talked out of its answer by anything rendered; this reads exactly the
/// surface an attacker controls. So the list refuses first and is not trimmed by one entry because
/// this exists. **This narrows SONNY-102's gap in all three modes and does not close it** — a shell
/// that is not rendered is not seen.
///
/// **One document, not line by line.** The joined recognized text is matched as a single string,
/// with `(?m)` line anchors where a signal is genuinely line-shaped. That is
/// ``SecretTextDetector``'s shape and it is there for PR #49's F1: scanning each line in isolation
/// let a multi-line private-key block match only its `BEGIN` line while the body shipped unpainted.
/// Anchoring inside one document keeps every cross-line pattern available; splitting the document
/// first would not.
///
/// Regex literals are built inside the functions rather than held as stored `static let`s because
/// `Regex` is not `Sendable`, which is the same reason ``SecretTextDetector`` declares its patterns
/// as locals.
struct ShellSurfaceDetector {
    /// How many **distinct** ``ShellSurfaceSignal`` classes a document needs before Sonny refuses to
    /// act in the window it came from.
    ///
    /// **Two, by founder decision (2026-08-16), recorded as a value rather than as prose** so the
    /// boundary is executable. `theBoundaryIsTwoDistinctSignalsFromBothSides` asserts it from each
    /// side: one sign proceeds, two refuse.
    ///
    /// **This is not the tuning surface** (PR #57 review adjudication, 2026-08-17). When the check
    /// both over-refused ordinary pages and under-refused an idle terminal panel, the two looked
    /// like opposite pressures on this number and were not: they were one defect, in signals that
    /// were not specific to what they claimed to detect. Lowering this to one would trade a false
    /// negative for a worse false positive — it is what keeps a single `$` on a documentation page
    /// from stopping real work. Raising it would abandon the embedded-shell case this check exists
    /// for. Tune the signals.
    static let signalThreshold = 2

    /// How many `$ `/`% ` line-starts a document needs before they are read as a scrollback rather
    /// than as a documentation example — see ``minimalPromptRanges(in:)``. Two, because one is what
    /// a docs page shows and two is already more than prose produces by accident; the trailing
    /// bare-prompt requirement is what carries the rest of the weight.
    static let minimumMinimalPromptLines = 2

    /// The commands whose appearance **at a prompt** counts as
    /// ``ShellSurfaceSignal/commandRunInAShell``.
    ///
    /// **Read only in a position where a shell would execute what follows** — the remainder of a
    /// prompt line, or after a notebook `!`. That is what makes ordinary English in this list
    /// harmless: `go`, `make`, `open`, `find`, `head` and `exit` begin ordinary sentences, and an
    /// earlier version of this detector consulted the list on any line starting with a punctuation
    /// mark, which is why fifteen of sixteen quoted email replies fired the signal (PR #57 F1). The
    /// words are kept rather than pruned, because after `%` or `$` on a real prompt line they are
    /// exactly what they look like, and dropping them would blind the check to `% make release` and
    /// `% go test ./...`.
    ///
    /// It is meant to be appended to. Adding an entry can only raise this one signal from absent to
    /// present; it can never on its own produce a refusal, because of ``signalThreshold``.
    static let shellCommandNames: Set<String> = [
        "ls", "ll", "cd", "pwd", "cat", "less", "tail", "head", "grep", "rg", "sed", "awk",
        "chmod", "chown", "mkdir", "rm", "mv", "cp", "touch", "ln", "echo", "printf",
        "export", "source", "sudo", "ssh", "scp", "rsync", "curl", "wget", "tar", "zip", "unzip",
        "git", "npm", "npx", "yarn", "pnpm", "brew", "pip", "pip3", "python", "python3",
        "node", "deno", "bun", "swift", "swiftc", "make", "cargo", "rustc", "go",
        "docker", "kubectl", "systemctl", "ps", "kill", "killall", "top", "htop", "df", "du",
        "find", "which", "whoami", "man", "vim", "vi", "nano", "emacs", "open", "defaults",
        "launchctl", "xcodebuild", "pod", "bundle", "rails", "java", "javac", "gradle", "mvn",
        "apt", "apt-get", "yum", "dnf", "env", "unset", "history", "clear", "exit"
    ]

    /// The one entry point. Every signal is evaluated; the verdict names the ones that fired.
    ///
    /// **What it costs, and what was deliberately not done about it.** A call is single-digit
    /// milliseconds on a full terminal window, printed on every test run by
    /// `theShellCheckCostsMicrosecondsOnARepresentativeDocument`. Almost all of it is Swift `Regex`
    /// *compilation*, not matching: measured here, evaluating a regex literal costs roughly 200 µs
    /// of compilation against roughly 90 µs of matching, and the pattern's shape barely moves either
    /// number. Two ways to remove it were considered and rejected:
    ///
    /// - **Caching the compiled patterns in `nonisolated(unsafe) static let`s.** `Regex` is not
    ///   `Sendable` because it lazily builds a lowered program inside itself, so a shared instance is
    ///   a real data race on first use from two threads, and the suite runs tests in parallel. A
    ///   documented race in the file that decides whether Sonny may drive a window is not a trade
    ///   worth 3 ms.
    /// - **Cheap substring prefilters in front of the expensive patterns** (`text.contains("@")`
    ///   before the prompt regex, and so on). A prefilter is a second, weaker copy of a pattern's
    ///   necessary condition, and when the two drift the signal stops firing *silently* — a
    ///   fail-open bug in a check whose whole job is to fail closed.
    ///
    /// So the cost stands, and it is small where it lands: this runs once per capture beside an OCR
    /// pass that costs hundreds of milliseconds, inside a loop that already sleeps 800 ms between
    /// iterations. Signals that are fixed strings do use `String.contains`, which is not a prefilter
    /// — there the literal *is* the whole check, so there is nothing for it to drift from.
    static func verdict(for recognizedText: String) -> ShellSurfaceVerdict {
        // **Folded before anything is matched** (SONNY-277). Every pattern below is exact over
        // ASCII, and the recognizer that produces this text substitutes look-alikes from other
        // scripts for Latin letters — SONNY-260 measured four of them in one reading. A look-alike
        // inside `sudo` or inside a prompt's host name is a signal that does not fire, and the
        // refusal needs two, so one lost signal can be the difference between refusing to act inside
        // a shell and acting. `SecretTextDetector` folds two calls above this one in
        // `LocalRedactionService.redactCapture` for the same reason; this closes the asymmetry.
        //
        // **Here rather than at the two call sites**, so that the property belongs to the detector
        // and a third caller cannot arrive without it. Nothing maps back: a verdict carries signal
        // names and no ranges, which is what makes this cheaper than the secret detector's fold.
        //
        // **What it is worth, stated rather than implied by its arrival.** Measured over the seven
        // realistic capture sizes SONNY-260 pinned, the recognizer substituted *no* foldable scalar
        // at any of them — so this is bought as a boundary property, not as a fix for a failure
        // anybody has seen at a realistic size. Its measured cost is likewise zero: every fixture
        // in `ShellSurfaceDetectorTests.corpus` produces the same verdict folded and unfolded. The
        // figures and the control that fires are on SONNY-277.
        //
        // **The count is deliberately not spelled here** (PR #209 review, F7). It was written as 38,
        // which was the corpus the measurement really ran over and a true statement about the past
        // written in the present tense; the corpus grew twice in one branch. A fixture lands most
        // rounds, so a number in this sentence expires while reading as current — the count belongs
        // in `theCorpusCoversBothDirections`, where the suite complains when it moves.
        let text = LatinConfusables.fold(recognizedText).text

        // Computed once and shared: two signals read it, and it is the most expensive thing here.
        let prompts = promptRanges(in: text)

        var found: Set<ShellSurfaceSignal> = []
        if !prompts.isEmpty { found.insert(.interactivePrompt) }
        if hasCommandRunInAShell(text, prompts: prompts) { found.insert(.commandRunInAShell) }
        if hasCommandOutputListing(text) { found.insert(.commandOutputListing) }
        if hasShellDiagnostic(text) { found.insert(.shellDiagnostic) }
        if hasSessionBanner(text) { found.insert(.sessionBanner) }
        if hasShellInterpreterInvocation(text) { found.insert(.shellInterpreterInvocation) }
        // Sorted by declaration order so a verdict's signal list is stable to compare and to read.
        return ShellSurfaceVerdict(signals: ShellSurfaceSignal.allCases.filter { found.contains($0) })
    }

    // MARK: - Prompts

    /// Every shell prompt in the document, each range ending **at the prompt's terminating sigil** —
    /// so the text after it on the same line is what was typed at that prompt.
    ///
    /// Returned rather than reduced to a `Bool` because ``ShellSurfaceSignal/commandRunInAShell``
    /// needs the position, not just the presence. Computing it once also keeps the five patterns
    /// from being evaluated twice.
    private static func promptRanges(in text: String) -> [Range<String.Index>] {
        // `user@host:path$` — the colon form. The path is a run of non-space characters, so the
        // sigil has to sit inside that run: `deploy@staging: Permission denied` does not match,
        // because a space follows the colon.
        // `(?m)` is load-bearing on both address forms, and not for an anchor: without it the `$` in
        // the trailing lookahead means end of *input*, so a prompt sitting on its own line in the
        // middle of a scrollback — a user who pressed Return at an empty prompt — matched only when
        // it happened to be the document's last line.
        let colonForm = /(?m)[A-Za-z0-9._-]+@[A-Za-z0-9._-]+:[^\s]{0,80}[$%#](?=[ \t]|$)/
        // `user@host ~ %`, `user@host dir %`, `[user@host dir]$` — the spaced form. The path token is
        // pinned to immediately follow the host, which is what keeps ordinary prose out: in
        // "alice@example.com says the build is 50% faster" the only token that can occupy the path
        // slot is `says`, and no sigil follows it. In prose a `%` is glued to a digit; in a prompt it
        // is a token of its own.
        // Two variants rather than one with `[ \t]*`, because the difference is the whole guard: a
        // prompt separates its path from its sigil with whitespace (`user@host dir % `), or closes a
        // bracket against it (`[user@host dir]$ `). Prose glues the sigil to a digit — "priya@acme.io
        // 82% open" — and neither variant admits that (PR #57 N1).
        let spacedForm = /(?m)[A-Za-z0-9._-]+@[A-Za-z0-9._-]+[ \t]+[~\/A-Za-z0-9._-]{1,60}[ \t]+[$%#](?=[ \t]|$)/
        let bracketedForm = /(?m)[A-Za-z0-9._-]+@[A-Za-z0-9._-]+[ \t]+[~\/A-Za-z0-9._-]{1,60}\][$%#](?=[ \t]|$)/
        // A shell with no prompt customisation at all: `bash-5.2$`, `sh-3.2#`.
        let bareShell = /(?m)^[ \t]{0,8}-?(?:bash|zsh|sh|ksh|csh|tcsh|dash|fish)-[0-9][0-9.]*[$#](?=[ \t]|$)/
        // oh-my-zsh's arrow, and **only** that glyph. `▶` is the macOS/Xcode/GitHub/Notion disclosure
        // triangle and the universal play symbol, `»` is a breadcrumb separator and a European
        // quotation mark, and `❯` is a common chevron bullet — all three were accepted here once and
        // each refused ordinary pages on its own (PR #57 F1). Consequence, stated rather than
        // discovered: a starship prompt, whose default glyph is `❯`, is not recognised as a prompt.
        // The arrow prompt swallows oh-my-zsh's own decorations — the directory, the `git:(branch)`
        // segment, the ✗/✓ status — so that, as with every other pattern here, the range ends where
        // the *command* begins. That is what lets ``hasCommandRunInAShell`` read the first token
        // rather than scanning a whole line for any command name (PR #57 N1).
        let arrowPrompt = /(?m)^[ \t]{0,8}\u{279C}[ \t]+[A-Za-z0-9._~\/-]+(?:[ \t]+git:\([^)\n]{0,40}\))?(?:[ \t]+[\u{2717}\u{2713}])?[ \t]*/
        let powerShell = /(?m)^[ \t]{0,8}PS [A-Za-z]:\\[^\n]{0,120}>(?=[ \t]|$)/

        var ranges: [Range<String.Index>] = []
        for match in text.matches(of: colonForm) { ranges.append(match.range) }
        for match in text.matches(of: spacedForm) { ranges.append(match.range) }
        for match in text.matches(of: bracketedForm) { ranges.append(match.range) }
        for match in text.matches(of: bareShell) { ranges.append(match.range) }
        for match in text.matches(of: arrowPrompt) { ranges.append(match.range) }
        for match in text.matches(of: powerShell) { ranges.append(match.range) }
        ranges.append(contentsOf: minimalPromptRanges(in: text))
        ranges.append(contentsOf: sectionSignPromptRanges(in: text))
        return ranges
    }

    /// Address-form prompts whose terminating sigil is `\u{00A7}` rather than `$`, `%` or `#` — anchored
    /// to the start of a line, and counted only when at least ``minimumMinimalPromptLines`` of them
    /// share one `identity@host`.
    ///
    /// **Why the section sign is here at all** (SONNY-277). The measuring round rendered a terminal
    /// panel at the seven realistic capture sizes SONNY-260 pinned and read it with the shipped
    /// recognizer: at the three smallest font sizes — 12 pt and 13 pt — Vision reads a prompt's `%`
    /// as U+00A7 SECTION SIGN, and the verdict collapsed from two signals to **none**, on a panel
    /// with `sudo rm -rf .build` typed at it. A whole refusal lost to one glyph, at three sizes out
    /// of seven. `sectionSignPanel` in the test corpus is that recognizer output verbatim. It is the
    /// same defect the fold in ``verdict(for:)`` covers, arriving through a character no letter fold
    /// can reach: `LatinConfusables` requires source and target to both be letters, and `\u{00A7}` to
    /// `%` is symbol to symbol.
    ///
    /// **Why two conditions rather than a count, and why a count was the wrong instrument** (PR #209
    /// review, F1). The other three sigils are safe in prose for a reason this one does not inherit,
    /// stated on ``promptRanges``' spaced form: in prose a `%` is glued to a digit, while a prompt
    /// makes it a token of its own. A section mark in a document is written the way a prompt writes
    /// its sigil — space, sigil, space — so the spaced address form matches real sentences. The first
    /// version of this answered that with a repetition floor alone, and two such lines is a document
    /// rather than a contrivance: the review's *"Report incidents to security@acme.example under
    /// `\u{00A7}` 7.2"* policy page was refused, while the same page with the mark spelled out was
    /// served. A threshold cannot repair a signal that is not specific, which is PR #57's F1 note on
    /// this same file.
    ///
    /// **The two conditions were measured against each other over 13 documents and neither dominates**
    /// (the table is on SONNY-277). Requiring a shared `identity@host` — the narrowing the review
    /// proposed — kills its own three documents and leaves three others: the same prose sentence
    /// repeated with *one* address, which is how a contract names one party twice, and a terminal
    /// session quoted in an email reply, which shares an identity by construction. Anchoring to a
    /// line start kills all of those, because prose puts an address mid-sentence and a quoted
    /// transcript puts `>` first — and misses a contact table whose lines each *begin* with an
    /// address. Together they answer 12 of the 13 correctly, against 6 for the shipped floor alone.
    ///
    /// **The one they get wrong is a gap, not a false stop, and that ordering is the founder's**
    /// (2026-08-17, recorded on ``minimalPromptRanges``): an ssh hop whose two prompts carry two
    /// identities and whose sigils are both misread contributes nothing here. That is exactly where
    /// `main` leaves it — `main` has no section-sign form at all — so this declines to fix that shape
    /// rather than regressing it. The alternative, dropping the identity condition, would refuse the
    /// contact table, and a stop is unappealable while a gap is partly covered by the deny list.
    ///
    /// **What the floor does not buy, corrected here because this comment claimed otherwise**
    /// (PR #209 review, F2). It used to argue the floor costs nothing because "one misread sigil among
    /// four leaves three ordinary `%` prompts that match without any of this". That is true of
    /// ``ShellSurfaceSignal/interactivePrompt`` and false of ``ShellSurfaceSignal/commandRunInAShell``,
    /// which ``hasCommandRunInAShell(_:prompts:)`` computes from the prompt range **on the command's
    /// own line** — so losing the one prompt that carries the command loses the second signal however
    /// many other prompts match, and the refusal needs two. A panel is therefore not rescued by its
    /// neighbours; what the floor really costs is any panel with fewer than two misread prompts
    /// sharing an identity, single-prompt panels included.
    ///
    /// **The margin is one at the smallest size measured** (PR #209 review, F3). The recognizer
    /// emitted 2, 3 and 4 section signs at the three failing sizes, so all three clear a floor of 2 —
    /// and `1280x800 @ 12pt` clears it by **nothing**. That size is load-bearing for
    /// `aRealTerminalPanelIsRefusedAtEveryRealisticCaptureSize`, and `CLAUDE.md`'s SONNY-260 gotcha is
    /// that this recognizer jitters at the character level and is not monotonic in size, so one fewer
    /// `\u{00A7}` there turns the product behaviour back into the defect and that test red, with no
    /// assertion naming the cause. It is written down rather than tuned away: raising the floor helps
    /// nothing and lowering it to 1 is what the whole first half of this comment refuses.
    ///
    /// No trailing-bare-prompt requirement, unlike ``minimalPromptRanges``: that rule exists to tell
    /// a comment block from a scrollback where the sigil is the *only* evidence, and here the
    /// address and path in front of it have already done that work.
    private static func sectionSignPromptRanges(in text: String) -> [Range<String.Index>] {
        let colonForm = /(?m)^[ \t]*[A-Za-z0-9._-]+@[A-Za-z0-9._-]+:[^\s]{0,80}\u{00A7}(?=[ \t]|$)/
        let spacedForm = /(?m)^[ \t]*[A-Za-z0-9._-]+@[A-Za-z0-9._-]+[ \t]+[~\/A-Za-z0-9._-]{1,60}[ \t]+\u{00A7}(?=[ \t]|$)/
        let bracketedForm = /(?m)^[ \t]*[A-Za-z0-9._-]+@[A-Za-z0-9._-]+[ \t]+[~\/A-Za-z0-9._-]{1,60}\]\u{00A7}(?=[ \t]|$)/

        var hits: [Range<String.Index>] = []
        for match in text.matches(of: colonForm) { hits.append(match.range) }
        for match in text.matches(of: spacedForm) { hits.append(match.range) }
        for match in text.matches(of: bracketedForm) { hits.append(match.range) }

        // Grouped rather than "all hits share one identity": a scrollback that ssh's away keeps the
        // prompts it had, and the group that repeats is still a scrollback. A group below the floor
        // contributes nothing rather than dragging the qualifying ones down with it.
        var byIdentity: [Substring: [Range<String.Index>]] = [:]
        for hit in hits {
            byIdentity[identityAtHost(of: text[hit]), default: []].append(hit)
        }
        return byIdentity.values.filter { $0.count >= minimumMinimalPromptLines }.flatMap { $0 }
    }

    /// The `identity@host` a prompt match opens with — leading whitespace dropped, then everything up
    /// to the end of the host token.
    ///
    /// Read off the match rather than re-matched: all three forms above begin with the same
    /// `[A-Za-z0-9._-]+@[A-Za-z0-9._-]+`, so the prefix is already there and a second pattern would be
    /// a copy to drift from — the reason ``verdict(for:)`` gives for refusing prefilters.
    private static func identityAtHost(of match: Substring) -> Substring {
        let body = match.drop(while: { $0 == " " || $0 == "\t" })
        guard let at = body.firstIndex(of: "@") else { return body }
        var end = body.index(after: at)
        while end < body.endIndex, body[end].isLetter || body[end].isNumber
            || body[end] == "." || body[end] == "_" || body[end] == "-" {
            end = body.index(after: end)
        }
        return body[body.startIndex..<end]
    }

    /// Prompts that are nothing but a sigil — `$ `, `% ` — which are only prompts when they repeat
    /// and the last of them is waiting for input.
    ///
    /// **Why repetition, and why the trailing bare one** (PR #57 N2). A lone `$ npm install` is what
    /// every documentation page, README and changelog uses to show a reader what to type, so a
    /// single occurrence has to stay invisible. Several occurrences *plus a final bare sigil* is a
    /// scrollback that ends where the cursor sits — a shape a comment block does not have. Both
    /// halves are load-bearing and were measured: without repetition the docs page refuses; without
    /// the trailing bare prompt, a LaTeX or config comment block (`% cache settings` / `%` /
    /// `% clear on restart`) refuses.
    ///
    /// **`#` and `❯` are deliberately not here.** `#` is Markdown's heading marker and the comment
    /// marker of most config formats; a root prompt arrives as `root@host:/#` through the colon form
    /// anyway. `❯` is a chevron bullet — the measured cost of admitting it is that a bullet list
    /// ending in an empty bullet refuses, which is the F1 class this branch already paid for once.
    ///
    /// **Excluding `❯` is a founder decision of 2026-08-17, and the cost it accepts is this: a
    /// developer running starship inside a VS Code panel is not caught by this check.** That is the
    /// case the whole feature exists for, since the static deny list already refuses terminal
    /// *applications* and an embedded shell is the entire remaining subject. The reasoning, recorded
    /// on SONNY-139 so it is not re-litigated: a false stop is worse than a gap, because a stop is
    /// unappealable and the product is not allowed to explain why it happened, while the gap is
    /// partly covered by the deny list. Naming the prompt themes (`starship`, `pure`) rather than
    /// what it costs a person is the shape of record this branch already had to correct once.
    private static func minimalPromptRanges(in text: String) -> [Range<String.Index>] {
        let minimal = /(?m)^[ \t]{0,8}[$%](?=[ \t]|$)/
        let hits = text.matches(of: minimal).map(\.range)
        guard hits.count >= minimumMinimalPromptLines, let last = hits.last else {
            return []
        }
        let lineEnd = text[last.upperBound...].firstIndex(of: "\n") ?? text.endIndex
        let waiting = text[last.upperBound..<lineEnd].allSatisfy { $0 == " " || $0 == "\t" }
        return waiting ? hits : []
    }

    // MARK: - Per-signal detection

    private static func hasCommandRunInAShell(_ text: String, prompts: [Range<String.Index>]) -> Bool {
        for prompt in prompts {
            let lineEnd = text[prompt.upperBound...].firstIndex(of: "\n") ?? text.endIndex
            if beginsWithACommand(text[prompt.upperBound..<lineEnd]) {
                return true
            }
        }
        // A notebook's `!command` escape, which hands one line to a shell with no prompt rendered
        // anywhere. This is why the signal is not simply "a prompt with something after it".
        let notebookEscape = /(?m)^[ \t]{0,8}(?:In \[\d+\]:[ \t]*)?!([A-Za-z][A-Za-z0-9._-]*|\.{1,2}\/[^\s]+)/
        return text.matches(of: notebookEscape).contains { isCommand(String($0.output.1)) }
    }

    /// Whether what was typed at a prompt **starts with** a command.
    ///
    /// **First token, not any token** (PR #57 N1). Scanning the whole remainder meant one ordinary
    /// English word anywhere on a line the prompt pattern had misread was enough — which is how
    /// "billing@acme.io Total $ 400 please open the invoice" refused, on `open`. A shell puts the
    /// command immediately after the prompt, so requiring that costs nothing real and removes a
    /// large share of the surface the prompt pattern shares with this one.
    private static func beginsWithACommand(_ remainder: Substring) -> Bool {
        let first = remainder
            .split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "." || $0 == "/" || $0 == "-" || $0 == "_") })
            .first
        return first.map { isCommand(String($0)) } ?? false
    }

    private static func isCommand(_ token: String) -> Bool {
        token.hasPrefix("./") || token.hasPrefix("../") || shellCommandNames.contains(token)
    }

    private static func hasCommandOutputListing(_ text: String) -> Bool {
        // `drwxr-xr-x  12 …` / `-rw-r--r--@  1 …`: a type character, nine permission characters, an
        // optional extended-attribute or ACL marker, then the link count. Requiring the count is
        // what keeps this off a word that happens to be ten characters long.
        let permissions = /(?m)^[ \t]{0,8}[-dlbcps][-rwxSsTt]{9}[@+.]?[ \t]+\d+[ \t]/
        // `ls -l`'s block-count header, alone on its line.
        let total = /(?m)^[ \t]{0,8}total[ \t]+\d+[ \t]*$/
        return text.firstMatch(of: permissions) != nil || text.firstMatch(of: total) != nil
    }

    private static func hasShellDiagnostic(_ text: String) -> Bool {
        // A signal that is a fixed string is written as one. `String.contains` is around twelve
        // times cheaper than the simplest possible regex literal here, because a regex literal is
        // *compiled* every time it is evaluated and these are all built per call — see the cost note
        // on ``verdict(for:)``. It also reads as what it is.
        if text.contains("command not found") {
            return true
        }
        // ssh's exact refusal, which is how a failing `scp`/`ssh` in a run console reads.
        if text.contains("Permission denied (publickey)") {
            return true
        }
        // A shell naming itself at the head of its own error line — `zsh: no such file or
        // directory: …`, `-bash: …`. Anchored to the line start so a sentence mentioning zsh does
        // not match; this one needs the anchor, so it stays a regex.
        let shellPrefixed = /(?m)^[ \t]{0,8}-?(?:zsh|bash|sh|ksh|csh|tcsh|dash|fish):[ \t]/
        return text.firstMatch(of: shellPrefixed) != nil
    }

    private static func hasSessionBanner(_ text: String) -> Bool {
        if text.contains("Last login:")
            || text.contains("[Process completed]")
            || text.contains("Process finished with exit code") {
            return true
        }
        let logout = /(?m)^[ \t]{0,8}logout[ \t]*$/
        let connectionClosed = /Connection to [^\n]{1,80} closed/
        return text.firstMatch(of: logout) != nil || text.firstMatch(of: connectionClosed) != nil
    }

    private static func hasShellInterpreterInvocation(_ text: String) -> Bool {
        let interpreterPath = /(?:\/usr\/bin\/env[ \t]+|\/bin\/|\/usr\/bin\/|\/usr\/local\/bin\/|\/opt\/homebrew\/bin\/)(?:bash|zsh|sh|ksh|csh|tcsh|dash|fish)\b/
        // A shebang is excluded, and it is the difference between a `.sh` file open in an editor and
        // a shell actually running — the sharpest false positive in the corpus.
        let invoked = text.matches(of: interpreterPath).contains { !isShebang(at: $0.range.lowerBound, in: text) }
        let dashC = /\b(?:bash|zsh|sh|ksh|fish)[ \t]+-[a-z]*c[ \t]/
        // `%%bash` selects the interpreter a notebook cell is handed to, which is the same fact
        // `/bin/bash deploy.sh` states. It sits here rather than beside the `!ls` escape because
        // choosing an interpreter and running a command are two different facts, and a notebook that
        // does both should not have them counted as one.
        let cellMagic = /(?m)^[ \t]{0,8}(?:In \[\d+\]:[ \t]*)?%%(?:bash|sh|zsh)\b/
        return invoked
            || text.firstMatch(of: dashC) != nil
            || text.firstMatch(of: cellMagic) != nil
    }

    // MARK: - Helpers

    /// Whether an interpreter path at `start` is the target of a `#!` shebang.
    ///
    /// Stand-in for regex lookbehind, which this toolchain's `Regex` engine does not support — the
    /// same gap ``SecretTextDetector/precededByDigitOrHyphen(_:in:)`` works around. Whitespace
    /// between the `!` and the path is skipped, because `#! /bin/sh` is legal and is still a shebang.
    private static func isShebang(at start: String.Index, in text: String) -> Bool {
        var index = start
        while index > text.startIndex {
            let previous = text.index(before: index)
            let character = text[previous]
            if character == " " || character == "\t" {
                index = previous
                continue
            }
            guard character == "!", previous > text.startIndex else {
                return false
            }
            return text[text.index(before: previous)] == "#"
        }
        return false
    }
}
