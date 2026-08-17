import Foundation

// MARK: - Signals

/// One class of evidence that the text recognized on a captured window came off a shell.
///
/// **Classes, not occurrences.** ``ShellSurfaceVerdict/showsShell`` counts how many of these fired,
/// never how many times any one of them did, which is what makes the founder's condition — *two
/// independent signs, not one* (2026-08-16) — mean what it says. Two lines matching the same pattern
/// are one piece of evidence seen twice; a prompt line beside a shell's own error message are two.
///
/// **Every signal is one-directional.** Nothing here subtracts. `.claude/rules/`'s standing rule for
/// screen-derived signals is that they may add scrutiny and never remove it, and a check that could
/// be talked *down* by something rendered would hand the attacker the off switch — the exact reason
/// the static deny list stays the load-bearing refusal and this one is layered after it. The one
/// place a pattern declines to fire on text it otherwise matches — a shebang, under
/// ``shellInterpreterInvocation`` — is a statement about what that text *is* (a file's first line,
/// not a command being run), not a suppressor that cancels evidence found elsewhere.
public enum ShellSurfaceSignal: String, CaseIterable, Equatable, Sendable {
    /// A shell prompt: `user@host:~/dev$`, `user@host dir %`, `bash-5.2$`, an oh-my-zsh arrow, a
    /// PowerShell `PS C:\…>`. The strongest single sign, and still only one of two needed.
    case interactivePrompt = "interactive_prompt"

    /// A command shown after a bare prompt sigil — `$ npm install`, `% ls`, `!pip install`,
    /// `%%bash`.
    ///
    /// **Deliberately the weak one.** This is the shape documentation pages, README files and chat
    /// messages use to show a reader what to type, and it is the exact case the founder named: *a
    /// single `$` on a documentation page must not stop Sonny driving Chrome*. It is in the set
    /// because it is real evidence beside a second sign, and the threshold is two because on its own
    /// it is not.
    case shellCommandEcho = "shell_command_echo"

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

    /// An interpreter being invoked by path — `/bin/bash script.sh`, `/usr/bin/env zsh`, `bash -c`.
    /// A shebang is **not** this, and is excluded: `#!/bin/bash` at the top of a file open in an
    /// editor is the file saying how it would be run, not a shell running.
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
/// It carries the signal *names* and never the text they were found in — a closed vocabulary of six
/// strings, so a verdict crossing a type boundary carries no screen content with it. That is what
/// lets the raw recognized text stay inside ``LocalRedactionService``.
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
/// **What this is for.** `ScreenControlPolicy.terminalBundleIdentifiers` refuses ten named terminal
/// apps and refuses them first, at three doors and again every iteration. It cannot reach a terminal
/// nobody listed, and it cannot reach a shell running *inside* an app that is not a terminal — VS
/// Code's integrated terminal, a JetBrains run console, a notebook cell — because nothing in a
/// bundle identifier distinguishes "has a shell inside it". That second gap does not narrow with
/// more list entries at all. This reads what is actually rendered, so it reaches both (SONNY-102's
/// approach, chosen by the founder 2026-08-16; designed in `docs/sonny-row-j-plan.md` §4).
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
    static let signalThreshold = 2

    /// The commands whose appearance after a bare prompt sigil counts as
    /// ``ShellSurfaceSignal/shellCommandEcho``.
    ///
    /// **A vocabulary rather than "any word", and that is the whole reason quoted email survives.**
    /// A pattern that accepted `[$%>!]` followed by anything would fire on every quoted reply line
    /// in a mail thread (`> can you run the deploy script tonight?`) and on the first line of any
    /// blockquote. Requiring a real command name makes the signal mean "a command line is being
    /// shown" instead of "a line starts with a punctuation mark".
    ///
    /// This is a *weak-signal* vocabulary and is meant to be appended to. Adding an entry can only
    /// raise this one signal from absent to present; it can never on its own produce a refusal,
    /// because of ``signalThreshold``.
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
    static func verdict(for text: String) -> ShellSurfaceVerdict {
        var found: Set<ShellSurfaceSignal> = []
        if hasInteractivePrompt(text) { found.insert(.interactivePrompt) }
        if hasShellCommandEcho(text) { found.insert(.shellCommandEcho) }
        if hasCommandOutputListing(text) { found.insert(.commandOutputListing) }
        if hasShellDiagnostic(text) { found.insert(.shellDiagnostic) }
        if hasSessionBanner(text) { found.insert(.sessionBanner) }
        if hasShellInterpreterInvocation(text) { found.insert(.shellInterpreterInvocation) }
        // Sorted by declaration order so a verdict's signal list is stable to compare and to read.
        return ShellSurfaceVerdict(signals: ShellSurfaceSignal.allCases.filter { found.contains($0) })
    }

    // MARK: - Per-signal detection

    private static func hasInteractivePrompt(_ text: String) -> Bool {
        // `user@host` somewhere on the line, then a prompt sigil later on that same line. The sigil
        // is required, and that requirement is what keeps this off `deploy@staging: Permission
        // denied` and off a shell script's own `scp "$f" "deploy@$1:$APP_DIR/"` — neither ends a
        // path segment in `$`, `%` or `#`. `>` is excluded here on purpose: it is redirection far
        // more often than it is a prompt.
        let userHost = /(?m)^[^\n]{0,160}?[A-Za-z0-9._-]+@[A-Za-z0-9._-]+[^\n]{0,100}?[$%#](?:\s|$)/
        // A shell with no prompt customisation at all: `bash-5.2$`, `sh-3.2#`.
        let bareShell = /(?m)^[^\n]{0,40}?\b-?(?:bash|zsh|sh|ksh|csh|tcsh|dash|fish)-[0-9][0-9.]*[$#](?:\s|$)/
        // The glyph prompts: oh-my-zsh's ➜, starship's ❯, and the two other common ones.
        let arrow = /(?m)^[ \t]{0,8}[\u{279C}\u{276F}\u{00BB}\u{25B6}][ \t]/
        let powerShell = /(?m)^[ \t]{0,8}PS [A-Za-z]:\\[^\n]{0,120}>(?:\s|$)/
        return text.firstMatch(of: userHost) != nil
            || text.firstMatch(of: bareShell) != nil
            || text.firstMatch(of: arrow) != nil
            || text.firstMatch(of: powerShell) != nil
    }

    private static func hasShellCommandEcho(_ text: String) -> Bool {
        // The sigil must start the line (after at most a little indentation, or a notebook's
        // `In [n]:` gutter). A `$` in the middle of a sentence — "yep, $ npm run release is fine" —
        // is prose about a command, not a command line, and does not match.
        let sigilled = /(?m)^[ \t]{0,8}(?:In \[\d+\]:[ \t]*)?[$%>!][ \t]?([A-Za-z][A-Za-z0-9._-]*|\.{1,2}\/[^\s]+)/
        let echoesACommand = text.matches(of: sigilled).contains { match in
            let token = String(match.output.1)
            return token.hasPrefix("./") || token.hasPrefix("../") || shellCommandNames.contains(token)
        }
        // Notebook cell magic that hands the whole cell to a shell.
        let cellMagic = /(?m)^[ \t]{0,8}(?:In \[\d+\]:[ \t]*)?%%(?:bash|sh|zsh)\b/
        return echoesACommand || text.firstMatch(of: cellMagic) != nil
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
        return invoked || text.firstMatch(of: dashC) != nil
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
