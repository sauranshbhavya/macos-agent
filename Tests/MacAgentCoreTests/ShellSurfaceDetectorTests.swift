import CoreGraphics
import Foundation
import Testing
@testable import MacAgentCore

/// SONNY-139: the screen check that refuses to control a window showing a shell.
///
/// **This is a corpus, not a one-off**, in the manner of ``VisionPromptInjectionTests`` — it is
/// meant to be appended to as real screens turn up that the detector reads wrongly in either
/// direction. Tuning happens against the fixtures, never against a recollection of what a shell
/// looks like.
///
/// **Half of it exists because the first version of this corpus could not fail** (PR #57 review,
/// F3). The negative half had no UI glyph row, no address-shaped token in prose beside a `%`, and no
/// quoted line whose first word was in the command vocabulary; the positive half had no shell in
/// which nothing had gone wrong. So it passed while the detector refused documentation pages and
/// allowed idle terminal panels. Every fixture marked *(F1)* or *(F2)* below is one that would have
/// failed against the committed detector at `9cacfc0`, and several are the reviewer's own repros
/// verbatim.
///
/// What is asserted, said plainly because it is easy to over-claim: **not** that every shell on
/// every screen is caught. A shell that is not rendered is not seen, and this check reads exactly
/// the surface an attacker controls, which is why the static name-based deny list stays the primary
/// refusal and why SONNY-102 stays open. What is asserted is that this corpus lands on the right
/// side of a threshold that is a named constant, from both directions, **with the exact signal set
/// pinned on both halves** — a must-refuse fixture that started refusing for a different reason, or
/// drifted down to exactly two, used to pass silently.
@Suite
struct ShellSurfaceDetectorTests {
    /// One screen, as the OCR pass would join it: one line per recognized line, in reading order.
    ///
    /// `signals` is the exact expected set, on both halves. The negative half is not simply "empty":
    /// a docs page legitimately reaching one sign is a different fact from one reaching none, and
    /// collapsing them would hide a drift toward the threshold.
    struct Fixture {
        let name: String
        let signals: [ShellSurfaceSignal]
        let text: String

        var refuses: Bool { signals.count >= ShellSurfaceDetector.signalThreshold }
    }

    // MARK: - Must refuse

    /// The five the ticket names, plus the two that are the ground a name list cannot reach at all,
    /// plus four *(F2)* cases where **nothing on screen has failed** — which is the ordinary state of
    /// a terminal and was the state in which the committed detector let all of them through.
    static let mustRefuse: [Fixture] = [
        // **The two section-sign panels the fix round measured and did not pin** (PR #209 cycle 2,
        // N5). Both were rows of the thirteen-document table on SONNY-277 and neither joined the
        // corpus, which left a mutant alive on the anchor's own leading-whitespace allowance: with
        // `^[ \t]*` narrowed to `^`, the indented panel goes from two section-sign prompts to zero —
        // refused to allowed — and the whole suite passed. Six lines of fixture is the fix, and the
        // reason they are first in this array is that they are the cheapest thing here to delete by
        // accident; `theCorpusCoversBothDirections` holds a floor on the marker.
        Fixture(name: "an indented terminal panel (SONNY-277 panel)", signals: [.interactivePrompt, .commandRunInAShell], text: """
            sauransh@Mac macos-agent \u{00A7} ls
            README.md Sources
            sauransh@Mac macos-agent \u{00A7}
        """),

        // The partial misread: two of the panel's four sigils came back as section signs and two as
        // ordinary `%`. This is the 12 pt shape — the size whose margin over the floor is exactly
        // zero — so it is the row that says the two halves compose rather than merely coexist.
        Fixture(name: "a panel with only two of its sigils misread (SONNY-277 panel)", signals: [.interactivePrompt, .commandRunInAShell], text: """
        PROBLEMS
        OUTPUT
        TERMINAL
        PORTS
        sauransh@Mac macos-agent \u{00A7} ls
        README.md Sources
        Tests docs
        sauransh@Mac macos-agent \u{00A7} sudo rm -rf .build
        Password:
        sauransh@Mac macos-agent % git status
        On branch main
        sauransh@Mac macos-agent %
        """),

        Fixture(name: "Terminal", signals: [.interactivePrompt, .commandRunInAShell, .sessionBanner], text: """
        Last login: Sat Aug 16 09:14:22 on ttys000
        sauransh@Mac ~ % cd Desktop/macos-agent
        sauransh@Mac macos-agent % git status
        On branch feature/terminal-screen-check
        nothing to commit, working tree clean
        sauransh@Mac macos-agent %
        """),

        Fixture(
            name: "iTerm",
            signals: [.interactivePrompt, .commandRunInAShell, .commandOutputListing, .shellDiagnostic],
            text: """
            sauransh@Mac:~/dev/macos-agent$ ls -la
            total 48
            drwxr-xr-x  12 sauransh  staff   384 16 Aug 09:12 .
            -rw-r--r--@  1 sauransh  staff  1284 15 Aug 21:03 README.md
            sauransh@Mac:~/dev/macos-agent$ ./scripts/plane
            zsh: no such file or directory: ./scripts/plane
            sauransh@Mac:~/dev/macos-agent$
            """
        ),

        // The whole VS Code window, not just its panel — which is what a window capture contains.
        // The editor half carries a shebang on purpose: the same `#!/bin/bash` that must not make an
        // editor refuse on its own does not make this one refuse either, and the panel below it does
        // the refusing.
        Fixture(
            name: "VS Code integrated terminal panel, a command failed",
            signals: [.interactivePrompt, .commandRunInAShell, .shellDiagnostic],
            text: """
            EXPLORER                    deploy.sh
            MACOS-AGENT                   1  #!/bin/bash
              Sources                     2  set -euo pipefail
            PROBLEMS   OUTPUT   TERMINAL   PORTS
            sauransh@Mac macos-agent % swift build
            Building for debugging...
            Build complete!
            sauransh@Mac macos-agent % ./scripts/deploy.sh
            zsh: permission denied: ./scripts/deploy.sh
            sauransh@Mac macos-agent %
            """
        ),

        // **(F2)** The same panel with the failure removed and nothing else changed. This is the
        // ordinary case — an editor with a terminal open and the last command having worked — and it
        // is manual-test item 2. At `9cacfc0` it reached one sign and Sonny proceeded, so whether the
        // headline gap was closed depended on whether the founder's last command happened to error.
        Fixture(
            name: "VS Code integrated terminal panel, nothing failed (F2)",
            signals: [.interactivePrompt, .commandRunInAShell],
            text: """
            EXPLORER                    deploy.sh
            MACOS-AGENT                   1  #!/bin/bash
              Sources                     2  set -euo pipefail
            PROBLEMS   OUTPUT   TERMINAL   PORTS
            sauransh@Mac macos-agent % ls
            README.md  Sources  Tests  docs
            sauransh@Mac macos-agent %
            """
        ),

        // **(F2)** A long-running process in the panel: no prompt returned, no output shaped like a
        // listing, nothing failed.
        Fixture(
            name: "VS Code integrated terminal panel, a dev server running (F2)",
            signals: [.interactivePrompt, .commandRunInAShell],
            text: """
            PROBLEMS   OUTPUT   TERMINAL   PORTS
            sauransh@Mac macos-agent % npm run dev
            VITE v5.4.2  ready in 412 ms
            Local:   http://localhost:5173/
            """
        ),

        Fixture(
            name: "JetBrains run console, the script failed",
            signals: [.shellDiagnostic, .sessionBanner, .shellInterpreterInvocation],
            text: """
            IntelliJ IDEA — macos-agent
            Run:   deploy  ×
            /bin/bash /Users/sauransh/dev/macos-agent/scripts/deploy.sh
            + echo 'Deploying to staging'
            Deploying to staging
            deploy@staging: Permission denied (publickey).
            Process finished with exit code 255
            """
        ),

        // **(F2)** The same console on a clean run. It survived at `9cacfc0` too, but on two signals
        // that have nothing to do with the command succeeding, so it is pinned here to keep that a
        // fact rather than a coincidence.
        Fixture(
            name: "JetBrains run console, the script succeeded (F2)",
            signals: [.sessionBanner, .shellInterpreterInvocation],
            text: """
            IntelliJ IDEA — macos-agent
            Run:   deploy  ×
            /bin/bash /Users/sauransh/dev/macos-agent/scripts/deploy.sh
            Deploying to staging
            Process finished with exit code 0
            """
        ),

        Fixture(
            name: "notebook cell running shell",
            signals: [.commandRunInAShell, .commandOutputListing, .shellDiagnostic, .shellInterpreterInvocation],
            text: """
            deploy-notebook.ipynb — Jupyter
            In [3]: !ls -la build
                    total 12
                    drwxr-xr-x  3 sauransh staff   96 17 Aug 09:02 .
            In [4]: %%bash
                    scp build/app.tar.gz deploy@staging:/srv/app/
                    deploy@staging: Permission denied (publickey).
            """
        ),

        // **(F2)** The same notebook with the listing flag and the failure removed.
        Fixture(
            name: "notebook cell running shell, nothing failed (F2)",
            signals: [.commandRunInAShell, .shellInterpreterInvocation],
            text: """
            deploy-notebook.ipynb — Jupyter
            In [3]: !ls build
                    app.tar.gz  manifest.json
            In [4]: %%bash
                    echo done
            """
        ),

        // The gap the deny list narrows and never closes: a terminal nobody listed. Its prompt is
        // oh-my-zsh's, which no bundle identifier would have told anyone about.
        Fixture(
            name: "an unlisted terminal running oh-my-zsh",
            signals: [.interactivePrompt, .commandRunInAShell, .sessionBanner],
            text: """
            \u{279C}  macos-agent git:(main) \u{2717} swift test
            Test run with 1223 tests in 92 suites passed
            \u{279C}  macos-agent git:(main) \u{2717} exit
            logout
            """
        ),

        Fixture(
            name: "an ssh session inside an unlisted terminal",
            signals: [.interactivePrompt, .commandRunInAShell, .sessionBanner],
            text: """
            sauransh@Mac ~ % ssh deploy@staging.example.com
            Last login: Fri Aug 15 22:10:04 2026 from 10.0.0.4
            deploy@staging:~$ uptime
            deploy@staging:~$ exit
            Connection to staging.example.com closed.
            """
        ),

        // A bracketed prompt, which is the default on most Linux distributions and has no space
        // between the closing bracket and the sigil.
        Fixture(
            name: "a bracketed Linux prompt",
            signals: [.interactivePrompt, .commandRunInAShell],
            text: """
            [sauransh@build-01 macos-agent]$ make release
            cc -O2 -o build/app src/main.c
            [sauransh@build-01 macos-agent]$
            """
        ),

        // **(N2)** The four shapes PR #57's re-check measured going from refuse to allow when the
        // prompt signal was narrowed, plus the panel case they generalise to. A shell that prints
        // nothing but `$ ` or `% ` is extremely common, and the deny list cannot help — this check
        // exists for shells running inside something else.
        Fixture(
            name: "a minimal $ prompt where a command failed (N2)",
            signals: [.interactivePrompt, .commandRunInAShell, .shellDiagnostic],
            text: """
            $ ./scripts/deploy.sh
            zsh: permission denied: ./scripts/deploy.sh
            $
            """
        ),

        Fixture(
            name: "a minimal $ prompt with ls -l output (N2)",
            signals: [.interactivePrompt, .commandRunInAShell, .commandOutputListing],
            text: """
            $ ls -l
            total 48
            drwxr-xr-x  12 sauransh  staff  384 16 Aug 09:12 .
            $
            """
        ),

        Fixture(
            name: "a bare % prompt with ls -l output (N2)",
            signals: [.interactivePrompt, .commandRunInAShell, .commandOutputListing],
            text: """
            % ls -l
            total 48
            drwxr-xr-x  12 sauransh  staff  384 16 Aug 09:12 .
            %
            """
        ),

        // The generalisation, and the one that matters most: an editor panel whose shell prints a
        // minimal prompt and where nothing has gone wrong. Before N2 this was zero signals.
        Fixture(
            name: "an editor panel with a minimal prompt, nothing failed (N2)",
            signals: [.interactivePrompt, .commandRunInAShell],
            text: """
            PROBLEMS   OUTPUT   TERMINAL   PORTS
            $ ls
            README.md  Sources  Tests  docs
            $
            """
        )
    ]

    // MARK: - Must not refuse

    /// The three the ticket names, plus eight more. Six of the eight are *(F1)* — the reviewer's own
    /// repros, each of which refused at `9cacfc0`, all now landing at zero. Over-refusing is the
    /// correct direction of error for a categorical rule and it still has a real product cost: every
    /// one of these ends the session with "Sonny stopped because that window is showing a shell …
    /// This is not something you can allow", which is a hard, unappealable stop saying something
    /// untrue about a docs page or a Slack thread.
    static let mustNotRefuse: [Fixture] = [
        Fixture(name: "a documentation page showing $ npm install", signals: [], text: """
        Getting Started — Sonny Docs
        Installation
        Install the command line tool with npm:
        $ npm install -g sonny
        Then run sonny --help to see everything it can do. If you prefer Homebrew,
        brew install sonny works too.
        Requirements: macOS 14 or later, Node 20 or later.
        """),

        // **(F1)** The reviewer's repro A, verbatim. A disclosure triangle is not a prompt.
        Fixture(name: "a documentation page with a disclosure triangle (F1)", signals: [], text: """
        Getting Started
        \u{25B6} Advanced options
        Install with:
        $ brew install sonny
        """),

        // **(F1)** The reviewer's repro B, verbatim — pure ASCII, no glyph anywhere, so it stands
        // whatever Vision does or does not transcribe. An address-shaped token, a percent sign in
        // prose, and a quoted line whose first word is in the command vocabulary.
        Fixture(name: "a chat window with an address and a quoted reply (F1)", signals: [], text: """
        Priya  10:15 AM
        bob@acme.com is at 90% context already
        > go ahead and ship it
        Sauransh  10:16 AM
        ok
        """),

        // **(F1)**
        Fixture(name: "a GitHub issue page with a collapsed section (F1)", signals: [], text: """
        Bug: install fails on macOS 15
        \u{25B6} Show 12 more comments
        Repro:
        $ npm install -g sonny
        npm warn deprecated glob@7
        """),

        // **(F1)**
        Fixture(name: "a Notion runbook with a collapsed section (F1)", signals: [], text: """
        Staging rollout runbook
        \u{25B6} Rollback steps
        To roll forward:
        $ kubectl rollout restart deploy/api
        """),

        // **(F1)** Chevron bullets are a slide-deck convention. This is also the fixture that
        // records the cost of dropping `❯` from the prompt glyphs: a starship prompt is not
        // recognised, and this page is the reason.
        Fixture(name: "a slide deck with chevron bullets (F1)", signals: [], text: """
        Roadmap FY26
        \u{276F} ship the agent
        \u{276F} land the backend
        > go deeper next quarter
        """),

        // **(F1)**
        Fixture(name: "a mail thread with an address and a percentage (F1)", signals: [], text: """
        Re: rollout — Mail
        priya@acme.io wrote: we are at 80% of the rollout
        > open the PR when you get a chance
        Thanks, will do after standup.
        """),

        // **(F1)** Two shapes that each fired the old prompt pattern on their own: an address
        // followed by a `#`, and an address on a line carrying a percentage.
        Fixture(name: "prose carrying an address, a hash and a percentage (F1)", signals: [], text: """
        Support
        ping support@example.com # if it breaks
        Hi team - alice@example.com says the build is 50% faster now.
        """),

        Fixture(name: "a chat message quoting a command", signals: [], text: """
        Sauransh   10:14 AM
        can you run `git push origin main` once CI goes green?
        Priya   10:15 AM
        sure. and after that `npm run release`? the deploy script lives at
        scripts/deploy.sh if you need to check what it does
        Sauransh   10:16 AM
        yep. $ npm run release is fine, just not before the tag lands
        """),

        // **The sharpest false positive in the set.** A `.sh` file open in an editor is not an
        // interactive shell. Line 11 is there deliberately: `deploy@$1:$APP_DIR/` is the closest
        // thing in ordinary shell source to a `user@host:path$` prompt.
        Fixture(name: "an editor displaying shell script source", signals: [], text: """
        deploy.sh — macos-agent
          1  #!/bin/bash
          2  set -euo pipefail
          3
          4  APP_DIR="/srv/app"
          5  if [ -z "${1:-}" ]; then
          6    echo "usage: deploy.sh <target>" >&2
          7    exit 1
          8  fi
          9
         10  for f in build/*.tar.gz; do
         11    scp "$f" "deploy@$1:$APP_DIR/"
         12  done
         13
         14  echo "Deployed to $1"
        """),

        Fixture(name: "a README rendered in a browser", signals: [], text: """
        macos-agent / README.md
        Building
        Run swift build, then swift test with the flags below. Plain swift test
        does not link.
        swift build
        swift test --disable-sandbox
        Contributing
        Open a pull request against main. Every commit message names its ticket.
        """),

        Fixture(name: "an email thread with quoted reply lines", signals: [], text: """
        Re: staging deploy — Mail
        From: Priya
        > can you run the deploy script tonight?
        > it needs to land before the release tag
        Yes, I will do it after the standup. The runbook is in the wiki, and the
        exit criteria are the same as last time.
        """),

        Fixture(name: "a Dockerfile open in an editor", signals: [], text: """
        Dockerfile — macos-agent
        FROM node:20-alpine
        WORKDIR /srv/app
        COPY package.json ./
        RUN npm install --omit=dev
        COPY . .
        EXPOSE 3000
        CMD ["node", "server.js"]
        """),

        // Sonny's own Settings page, which talks about terminals at length. A check that fired on
        // the product's own copy would end a session started from the window explaining the rule.
        Fixture(name: "Sonny's own Security & Access settings page", signals: [], text: """
        Security & Access
        Screen Control
        Once Screen Recording and Accessibility are granted, Sonny can control any
        app installed on this Mac — clicking, typing and scrolling in it the way
        you would. Sonny will never control Terminal, iTerm, or any other terminal app.
        Permission Readiness
        """),

        // **(N1)** The three shapes PR #57's re-check measured refusing on a single line: an address
        // column abutting a percentage column abutting a status column, which is what a support
        // desk, a CRM or an analytics table OCRs to.
        Fixture(name: "a support-desk row with an address and a percentage (N1)", signals: [], text: """
        priya@acme.io 82% open
        """),

        Fixture(name: "a support-desk table, three rows (N1)", signals: [], text: """
        qa@acme.io 91% top performer this quarter
        sales@acme.io 60% find the renewal date
        ops@acme.io 75% clear by Friday
        """),

        // Still read as a prompt *shape* — address, path token, spaced sigil — and that is the honest
        // residual: the N1 fix stops the refusal by denying the second signal, not by making the
        // prompt pattern stop misreading this line.
        Fixture(name: "an invoice line with an address and a currency sigil (N1)", signals: [.interactivePrompt], text: """
        billing@acme.io Total $ 400 please open the invoice
        """),

        // **(N2 adversarial)** These four are why the minimal-prompt rule needs *both* halves. Each
        // refused under a weaker version of it, and each is an ordinary document.
        // Comment blocks in LaTeX and in config formats start every line with `%`.
        Fixture(name: "LaTeX source with a bare % separator (N2 adversarial)", signals: [], text: """
        % Introduction section
        %
        % source: the 2025 survey
        \\section{Intro}
        We present a method.
        """),

        Fixture(name: "a config file with % comments (N2 adversarial)", signals: [], text: """
        % cache settings
        %
        % clear on restart
        max_entries = 500
        """),

        // Markdown headings are `#`, and a page that also shows one `$` example must stay silent.
        Fixture(name: "Markdown source in an editor (N2 adversarial)", signals: [], text: """
        # Getting Started

        Install it:

        $ npm install -g sonny

        # Configuration

        Edit the file.
        """),

        // Two `$` examples in one document, with no waiting prompt anywhere.
        Fixture(name: "a quick-start page with two $ examples (N2 adversarial)", signals: [], text: """
        Quick start

        $ npm install -g sonny

        Now configure it:

        $ sonny init

        That is all.
        """),

        // The measured cost of leaving `❯` out of the minimal set: a bullet list ending in an empty
        // bullet would refuse if it were in. Kept as a fixture so the trade stays visible.
        Fixture(name: "a bullet list ending in an empty chevron (N2 adversarial)", signals: [], text: """
        Agenda
        \u{276F} open the retro
        \u{276F} find owners
        \u{276F}
        """),

        // **The cost of admitting the section sign as a prompt sigil, bounded** (SONNY-277). It is
        // accepted only in the address forms, so a legal document carrying section marks — including
        // one whose last is bare, which is what `minimalPromptRanges` reads as a waiting prompt for
        // `$` and `%` — stays invisible. This fixture is what would refuse if the sigil were added to
        // the minimal set instead, and it is the reason it was not.
        Fixture(name: "a legal page of section marks ending in a bare one (SONNY-277 adversarial)", signals: [], text: """
        Terms of Service

        \u{00A7} 4.1 The service is provided as is.

        \u{00A7} 4.2 Liability is limited to fees paid.

        \u{00A7}
        """),

        // A section mark on a line that also carries an address. Not a prompt: no path token sits
        // between the address and the sigil, which is the guard PR #57 N1 put on the spaced form.
        Fixture(name: "an address and a section mark in prose (SONNY-277 adversarial)", signals: [], text: """
        Write to counsel@acme.example about \u{00A7} 12 before Friday.
        The clause priya@acme.io cited is \u{00A7} 3 and it is 82% settled.
        """),

        // **PR #209's F1 documents, and the three that defeat the narrowing it proposed** (SONNY-277).
        // Every one of these is refused by the repetition floor this branch first shipped. They are
        // marked *(SONNY-277 adversarial)* so `theCorpusCoversBothDirections` can hold a floor on
        // them; the measurement that chose the rule is on the ticket. Two of them keep one signal
        // apiece — a document may mention an ssh error or end a menu in `logout` and still not be a
        // shell — which is the threshold doing its job, and is why the expected sets are asserted
        // exactly rather than through `showsShell`.
        Fixture(name: "an incident policy naming two parties under section marks (SONNY-277 adversarial)", signals: [.shellDiagnostic], text: """
        Incident Response Policy

        Report incidents to security@acme.example under \u{00A7} 7.2 within one hour.
        Escalations go to soc@acme.example under \u{00A7} 7.3 within four hours.

        If your key is rejected the agent prints Permission denied (publickey) and you must re-enrol.
        """),

        // The same document with the mark spelled out. **This is the control that makes the fixture
        // above mean something**: the two differ only in whether they write the section sign, so a
        // rule that refuses one and serves the other is refusing the glyph rather than the shell. It
        // keeps its shell-diagnostic signal in both, which is why neither reaches two.
        Fixture(name: "the same incident policy with the mark spelled out (SONNY-277 control)", signals: [.shellDiagnostic], text: """
        Incident Response Policy

        Report incidents to security@acme.example under clause 7.2 within one hour.
        Escalations go to soc@acme.example under clause 7.3 within four hours.

        If your key is rejected the agent prints Permission denied (publickey) and you must re-enrol.
        """),

        Fixture(name: "a help page whose menu ends in logout, beside two contact lines (SONNY-277 adversarial)", signals: [.sessionBanner], text: """
        Account help

        Billing questions go to billing@acme.example under \u{00A7} 4 of the agreement.
        Access questions go to identity@acme.example under \u{00A7} 5 of the agreement.

        Menu
        profile
        settings
        logout
        """),

        // The branch's own adversarial sentence written twice, which is what the repetition floor
        // could not tell from a scrollback.
        Fixture(name: "the address-and-section-mark sentence twice, two addresses (SONNY-277 adversarial)", signals: [], text: """
        Write to counsel@acme.example about \u{00A7} 12 before Friday.
        Write to soc@acme.example about \u{00A7} 13 before Monday.
        """),

        // **The three that defeat a shared-identity rule on its own** — written by asking what the
        // review's proposed narrowing does not reach, rather than by checking it against its own
        // examples. One address repeated is the ordinary way a contract names a single party.
        Fixture(name: "the same sentence twice with one address (SONNY-277 adversarial)", signals: [], text: """
        Write to counsel@acme.example about \u{00A7} 12 before Friday.
        Write to counsel@acme.example about \u{00A7} 13 before Monday.
        """),

        Fixture(name: "one party, one section mark, three times (SONNY-277 adversarial)", signals: [], text: """
        Under the contract legal@acme.example owns \u{00A7} 1 and reviews it yearly.
        Under the contract legal@acme.example owns \u{00A7} 2 and reviews it yearly.
        Under the contract legal@acme.example owns \u{00A7} 3 and reviews it yearly.
        """),

        // A real terminal, quoted in an email. Not a live shell, and it shares its identity by
        // construction — so a shared-identity rule alone refuses it and the line anchor is what does
        // not.
        Fixture(name: "a terminal session quoted in an email reply (SONNY-277 adversarial)", signals: [], text: """
        On Tuesday priya wrote:
        > sauransh@Mac macos-agent \u{00A7} ls
        > README.md Sources
        > sauransh@Mac macos-agent \u{00A7}
        Can you try again?
        """),

        // **The one the line anchor alone gets wrong**, which is why both conditions are kept: a
        // contact table puts its addresses at the start of every line.
        Fixture(name: "a contact table whose lines start with addresses (SONNY-277 adversarial)", signals: [], text: """
        security@acme.example owns \u{00A7} 7.2 of the policy.
        soc@acme.example owns \u{00A7} 7.3 of the policy.
        """),

        // **The one document the shipped rule gets wrong, in the tree beside the ones it gets right**
        // (PR #209 cycle 2, N5). An ssh hop shows two prompts under two identities; with both sigils
        // misread, neither group reaches the floor, so the section-sign form contributes nothing and
        // the panel rests on its `Last login:` banner alone — one signal, and Sonny would act in it.
        //
        // **It sits in `mustNotRefuse` because that is what the detector does, not because it is what
        // anyone wants.** `main` has no section-sign form at all, so this is exactly where `main`
        // leaves that shape: the rule declines to fix it rather than regressing it, and the
        // alternative — dropping the shared-identity condition — refuses the contact table above.
        // The founder ordering on `minimalPromptRanges` prefers a gap to an unappealable stop.
        // A future rule that closes this moves the fixture to `mustRefuse`; until then the gap is
        // asserted rather than described, so it cannot quietly become something else.
        Fixture(name: "an ssh hop, two prompts under two identities, both sigils misread (SONNY-277 gap)", signals: [.sessionBanner], text: """
        sauransh@Mac macos-agent \u{00A7} ssh deploy@staging
        Last login: Tue Sep  2 09:14:11 2026
        deploy@staging ~ \u{00A7} ls
        releases current
        """)
    ]

    /// **The panel the recognizer actually returned** (SONNY-277). Not written by hand: this is the
    /// verbatim joined text of the 800x600 @ 13pt run in `ShellSurfaceLookAlikeFoldTests`, where
    /// Vision read every `%` sigil as U+00A7 SECTION SIGN. Against the detector at `4a3d0ef6` it
    /// produced **no signals at all** — a terminal panel with `sudo rm -rf .build` typed at it,
    /// allowed.
    static let sectionSignPanel = Fixture(
        name: "a terminal panel whose sigils the recognizer read as section signs (SONNY-277)",
        signals: [.interactivePrompt, .commandRunInAShell],
        text: """
        PROBLEMS
        OUTPUT
        TERMINAL
        PORTS
        sauransh@Mac macos-agent \u{00A7} ls
        README.md Sources
        Tests docs
        sauransh@Mac macos-agent \u{00A7} sudo rm -rf .build
        Password:
        sauransh@Mac macos-agent \u{00A7} git status
        On branch main
        sauransh@Mac macos-agent \u{00A7}
        """
    )

    static var corpus: [Fixture] { mustRefuse + mustNotRefuse + [sectionSignPanel] }

    // MARK: - The corpus, asserted

    /// **The exact signal set, both halves.** Asserting only `showsShell` let a must-refuse fixture
    /// drift to a different pair, or down to exactly two, without a failure (PR #57 F3).
    @Test(arguments: ShellSurfaceDetectorTests.corpus.map(\.name))
    func everyCorpusFixtureProducesExactlyTheSignalsItShould(name: String) throws {
        let fixture = try #require(Self.corpus.first { $0.name == name })
        let verdict = ShellSurfaceDetector.verdict(for: fixture.text)
        #expect(verdict.signals == fixture.signals, "\(fixture.name)")
        #expect(verdict.showsShell == fixture.refuses, "\(fixture.name)")
    }

    /// The editor case, asserted by name because the ticket names it, and on emptiness rather than
    /// on the verdict — "does not refuse" would also be true of a fixture sitting at exactly one
    /// sign for a reason nobody intended.
    @Test
    func aShellScriptOpenInAnEditorIsNotAnInteractiveShell() throws {
        let fixture = try #require(
            Self.mustNotRefuse.first { $0.name == "an editor displaying shell script source" }
        )
        let verdict = ShellSurfaceDetector.verdict(for: fixture.text)
        #expect(verdict.showsShell == false)
        // Zero, not one: nothing in shell *source* is evidence of a shell *running*. The shebang is
        // excluded, and `deploy@$1:$APP_DIR/` is not a prompt.
        #expect(verdict.signals.isEmpty)
    }

    /// **An idle terminal panel refuses.** The ticket's headline gap and manual-test item 2, pinned
    /// as a minimal pair so the reason is unmistakable: the same panel differs only in whether a
    /// command has been typed at the prompt.
    @Test
    func anIdleTerminalPanelRefusesWhetherOrNotAnythingFailed() {
        let nothingTyped = """
        PROBLEMS   OUTPUT   TERMINAL   PORTS
        sauransh@Mac macos-agent %
        """
        let afterALS = """
        PROBLEMS   OUTPUT   TERMINAL   PORTS
        sauransh@Mac macos-agent % ls
        README.md  Sources  Tests  docs
        sauransh@Mac macos-agent %
        """
        #expect(ShellSurfaceDetector.verdict(for: nothingTyped).signals == [.interactivePrompt])
        #expect(ShellSurfaceDetector.verdict(for: nothingTyped).showsShell == false)
        #expect(
            ShellSurfaceDetector.verdict(for: afterALS).signals == [.interactivePrompt, .commandRunInAShell]
        )
        #expect(ShellSurfaceDetector.verdict(for: afterALS).showsShell)
    }

    /// **The five commands the recorded bound was wrong about** (PR #57 F2). Each is a full shell
    /// session where nothing failed and no listing was printed, and each used to reach one sign and
    /// proceed. Pinned individually rather than as a corpus entry, because the claim they falsified
    /// is in three durable records and the correction needs something executable behind it.
    @Test(arguments: [
        "sauransh@Mac ~ % ls\nREADME.md  Sources  Tests  docs\nsauransh@Mac ~ %",
        "sauransh@Mac ~ % cd Desktop\nsauransh@Mac Desktop %",
        "sauransh@Mac p % git status\nOn branch main\nnothing to commit, working tree clean\nsauransh@Mac p %",
        "sauransh@Mac p % swift build\nBuilding for debugging...\nBuild complete!\nsauransh@Mac p %",
        "sauransh@Mac p % python3 train.py\nEpoch 1/10 loss 0.42\nsauransh@Mac p %"
    ])
    func aSucceedingCommandAtAPromptIsTwoSigns(screen: String) {
        let verdict = ShellSurfaceDetector.verdict(for: screen)
        #expect(verdict.signals == [.interactivePrompt, .commandRunInAShell], "\(screen)")
        #expect(verdict.showsShell, "\(screen)")
    }

    /// **What is still one sign, stated as a test rather than as prose.** These are the honest bounds
    /// of the two-signs rule, and they are the replacement for the claim F2 found to be false. A
    /// prompt with nothing typed at it, and a prompt carrying a command the vocabulary does not
    /// know, both proceed.
    @Test
    func aPromptAloneAndAnUnrecognisedCommandBothStayAtOneSign() {
        let bare = ShellSurfaceDetector.verdict(for: "sauransh@Mac macos-agent %")
        #expect(bare.signals == [.interactivePrompt])
        #expect(bare.showsShell == false)

        let unknownCommand = ShellSurfaceDetector.verdict(
            for: "sauransh@Mac p % mytool --deploy staging\nok\nsauransh@Mac p %"
        )
        #expect(unknownCommand.signals == [.interactivePrompt])
        #expect(unknownCommand.showsShell == false)

        // But an unrecognised command *executed by path* is still two, because `./` is a shell
        // construct rather than a name that has to be listed.
        let byPath = ShellSurfaceDetector.verdict(
            for: "sauransh@Mac p % ./mytool --deploy\nok\nsauransh@Mac p %"
        )
        #expect(byPath.signals == [.interactivePrompt, .commandRunInAShell])
        #expect(byPath.showsShell)
    }

    /// **A prompt sigil is only a prompt in a prompt's shape.** The bare-sigil line is how a docs
    /// page, a README and a chat message show a reader what to type, and it is not evidence of
    /// anything on its own.
    @Test
    func aBareSigilAtLineStartIsNotAPrompt() {
        for line in ["$ npm install -g sonny", "% ls -la", "> git push origin main", "# make release"] {
            #expect(ShellSurfaceDetector.verdict(for: line).signals.isEmpty, "\(line)")
        }
    }

    /// **The glyphs that are not prompts.** Each of these fired `interactive_prompt` on its own at
    /// `9cacfc0` and each is a UI convention rather than a shell (PR #57 F1). `➜` stays because it
    /// is oh-my-zsh's and is not used as a bullet.
    @Test
    func onlyTheOhMyZshArrowCountsAsAGlyphPrompt() {
        for notAPrompt in ["\u{25B6} Show more", "\u{00BB} Settings \u{00BB} Advanced", "\u{276F} ship the agent"] {
            #expect(ShellSurfaceDetector.verdict(for: notAPrompt).signals.isEmpty, "\(notAPrompt)")
        }
        // The arrow prompt now swallows oh-my-zsh's own decorations, so a prompt with nothing typed
        // at it is one signal rather than two — which is the honest reading: `git:(main)` is the
        // prompt telling you the branch, not a command anybody ran.
        #expect(
            ShellSurfaceDetector.verdict(for: "\u{279C}  macos-agent git:(main)").signals
                == [.interactivePrompt]
        )
        #expect(
            ShellSurfaceDetector.verdict(for: "\u{279C}  macos-agent git:(main) \u{2717} swift test").signals
                == [.interactivePrompt, .commandRunInAShell]
        )
    }

    /// **An address in prose is not a prompt**, in each of the shapes the old pattern accepted.
    @Test
    func anAddressShapedTokenInProseIsNotAPrompt() {
        let prose = [
            "Hi team - alice@example.com says the build is 50% faster now.",
            "ping support@example.com # if it breaks",
            "bob@acme.com is at 90% context already",
            "priya@acme.io wrote: we are at 80% of the rollout",
            "deploy@staging: Permission denied (publickey)."
        ]
        for line in prose {
            #expect(ShellSurfaceDetector.verdict(for: line).contains(.interactivePrompt) == false, "\(line)")
        }
        // And the shapes that genuinely are prompts still are.
        for prompt in [
            "sauransh@Mac ~ % ",
            "sauransh@Mac macos-agent % ",
            "sauransh@Mac:~/dev/macos-agent$ ",
            "deploy@staging:~$ ",
            "root@a1b2c3d4:/# ",
            "[sauransh@build-01 macos-agent]$ "
        ] {
            #expect(ShellSurfaceDetector.verdict(for: prompt).signals == [.interactivePrompt], "\(prompt)")
        }
    }

    /// **The command vocabulary is only consulted at a prompt**, which is what makes ordinary English
    /// in it harmless. Fifteen of these sixteen quoted-reply lines fired the old signal.
    @Test
    func ordinaryEnglishAfterAQuoteMarkerIsNotACommand() {
        let firstWords = [
            "go", "make", "open", "find", "top", "clear", "exit", "history",
            "man", "kill", "head", "source", "java", "touch", "less", "can"
        ]
        for word in firstWords {
            let line = "> \(word) ahead and ship it"
            #expect(ShellSurfaceDetector.verdict(for: line).signals.isEmpty, "\(line)")
        }
        // The same words after a real prompt are commands, which is why they stay in the vocabulary.
        #expect(
            ShellSurfaceDetector.verdict(for: "sauransh@Mac p % make release").signals
                == [.interactivePrompt, .commandRunInAShell]
        )
    }

    /// **A prompt that ends its own line is still a prompt, in both address forms.**
    ///
    /// Found by a surviving mutation rather than by reading (cycle-2 battery, mutation 14): dropping
    /// `(?m)` from the colon-form pattern changed nothing anywhere in the suite. The reason is that
    /// the `$` in the trailing lookahead means end of *input* without it, so every prompt the corpus
    /// contained still matched — each was either followed by a space or was the document's last
    /// line. The uncovered case is the ordinary one: a shell that has printed its prompt and is
    /// waiting, with scrollback below it. The spaced form was already covered by
    /// `theBoundaryIsTwoDistinctSignalsFromBothSides`; the colon form was not, and both are pinned
    /// here so neither can regress alone.
    @Test
    func aPromptEndingItsLineMidDocumentIsStillAPrompt() {
        let colonForm = ShellSurfaceDetector.verdict(for: """
        deploy@staging:~$
        zsh: command not found: sonny
        """)
        #expect(colonForm.signals == [.interactivePrompt, .shellDiagnostic])
        #expect(colonForm.showsShell)

        let spacedForm = ShellSurfaceDetector.verdict(for: """
        sauransh@Mac macos-agent %
        zsh: command not found: sonny
        """)
        #expect(spacedForm.signals == [.interactivePrompt, .shellDiagnostic])
        #expect(spacedForm.showsShell)
    }

    /// A shebang names an interpreter and is not one being invoked. Both halves asserted, so the
    /// exclusion cannot be deleted without a failure and cannot be widened into "any interpreter
    /// path is ignored" either.
    @Test
    func aShebangIsNotAnInterpreterInvocationButRunningOneIs() {
        #expect(ShellSurfaceDetector.verdict(for: "#!/bin/bash\nset -euo pipefail").signals == [])
        #expect(ShellSurfaceDetector.verdict(for: "#! /bin/sh\necho hi").signals == [])
        #expect(
            ShellSurfaceDetector.verdict(for: "/bin/bash /Users/s/deploy.sh").signals
                == [.shellInterpreterInvocation]
        )
        #expect(
            ShellSurfaceDetector.verdict(for: "/usr/bin/env zsh -l").signals
                == [.shellInterpreterInvocation]
        )
    }

    // MARK: - The threshold, from both sides

    /// **One sign does not refuse; two do.** The founder's condition of 2026-08-16 — two independent
    /// signs, recorded as a testable value rather than as prose — asserted as a minimal pair over
    /// one fixture, so the only difference between refusing and not is a second class of evidence.
    @Test
    func theBoundaryIsTwoDistinctSignalsFromBothSides() {
        // One sign: a shell prompt, nothing typed at it.
        let oneSign = ShellSurfaceDetector.verdict(for: "sauransh@Mac macos-agent %")
        #expect(oneSign.signals == [.interactivePrompt])
        #expect(oneSign.showsShell == false)

        // The same screen with one line added — a shell's own error message, a different class of
        // evidence entirely. Nothing else changed.
        let twoSigns = ShellSurfaceDetector.verdict(
            for: "sauransh@Mac macos-agent %\nzsh: command not found: sonny"
        )
        #expect(twoSigns.signals == [.interactivePrompt, .shellDiagnostic])
        #expect(twoSigns.showsShell)

        #expect(ShellSurfaceDetector.signalThreshold == 2)
    }

    /// **Two occurrences of one class are one sign, not two.** This is what "independent" means and
    /// it is the property a future signal must not quietly break: a signal that fires harder on more
    /// of the same evidence would let one class refuse on its own.
    @Test
    func repeatingOneClassOfEvidenceNeverReachesTheThresholdByItself() {
        let manyPromptLines = """
        sauransh@Mac ~ %
        sauransh@Mac ~ %
        sauransh@Mac ~ %
        sauransh@Mac ~ %
        sauransh@Mac ~ %
        """
        let verdict = ShellSurfaceDetector.verdict(for: manyPromptLines)
        #expect(verdict.signals == [.interactivePrompt])
        #expect(verdict.showsShell == false)

        let manyBareSigilCommands = """
        $ npm install
        $ npm run build
        $ npm test
        $ git push
        """
        let echoes = ShellSurfaceDetector.verdict(for: manyBareSigilCommands)
        #expect(echoes.signals.isEmpty)
        #expect(echoes.showsShell == false)
    }

    /// Empty and whitespace-only text produce no signals — the case a window with nothing readable
    /// in it hits. It does **not** mean "safe": a capture whose recognition *failed* never reaches
    /// this function at all, because `redactCapture` throws first. See
    /// `anUnreadableScreenEndsTheSessionRatherThanProducingANoShellVerdict`.
    @Test
    func textWithNothingInItProducesNoSignals() {
        #expect(ShellSurfaceDetector.verdict(for: "").signals.isEmpty)
        #expect(ShellSurfaceDetector.verdict(for: "   \n\n  \t ").signals.isEmpty)
    }

    // MARK: - The signals as values

    /// Every declared signal is reachable, so the enum cannot accumulate a case that nothing
    /// produces — a dead signal reads like coverage and is not.
    @Test
    func everyDeclaredSignalIsProducedByAtLeastOneInput() {
        let probes: [ShellSurfaceSignal: String] = [
            .interactivePrompt: "sauransh@Mac ~ % ",
            .commandRunInAShell: "In [3]: !ls build",
            .commandOutputListing: "total 48",
            .shellDiagnostic: "zsh: command not found: sonny",
            .sessionBanner: "Last login: Sat Aug 16 09:14:22 on ttys000",
            .shellInterpreterInvocation: "/bin/bash deploy.sh"
        ]
        #expect(Set(probes.keys) == Set(ShellSurfaceSignal.allCases))
        for signal in ShellSurfaceSignal.allCases {
            let text = probes[signal] ?? ""
            #expect(
                ShellSurfaceDetector.verdict(for: text).signals == [signal],
                "\(signal.rawValue) was not produced alone by its own probe"
            )
        }
    }

    /// The signal vocabulary is a closed set of stable strings. A verdict crosses type boundaries
    /// and reaches a log; these names are all it ever carries, and they are chosen so that no
    /// recognized screen text can travel with it.
    @Test
    func signalNamesAreStableAndCarryNoScreenText() {
        #expect(Set(ShellSurfaceSignal.allCases.map(\.rawValue)) == [
            "interactive_prompt",
            "command_run_in_a_shell",
            "command_output_listing",
            "shell_diagnostic",
            "session_banner",
            "shell_interpreter_invocation"
        ])
    }

    /// **What the check costs, printed rather than asserted into prose.**
    ///
    /// The end-to-end redaction figure is dominated by Vision OCR and swings by tens of percent
    /// between runs, so a before/after of `redactionLatencyIsBoundedOnARepresentativeCapture` cannot
    /// resolve an addition this small. This measures the addition itself: the whole marginal cost of
    /// SONNY-139 on a capture is one call to ``ShellSurfaceDetector/verdict(for:)`` over a string
    /// that is already in memory, because the OCR pass it reads was already running.
    ///
    /// The number is printed on every run, following
    /// `redactionLatencyIsBoundedOnARepresentativeCapture`'s precedent in this repo, so it stays
    /// regenerable instead of going stale in a comment. The ceiling is a pathological-regression
    /// guard, not a target.
    @Test
    func theShellCheckCostsMicrosecondsOnARepresentativeDocument() {
        // The largest fixture in the corpus, which is what a full terminal window reads like.
        let document = Self.mustRefuse
            .max { $0.text.count < $1.text.count }
            .map(\.text) ?? ""
        // **Twenty, not two hundred.** At 200 this loop burned roughly 0.8 s of solid CPU, and while
        // `VisionSessionRunTests` still gated on fixed 2–4 s wall-clock deadlines that was enough to
        // fail the parallel suite outright: eight full-suite runs went from 0 passing at 200 to 6 at
        // 20. **SONNY-159/160/161 has since replaced those deadlines with a 30 s hang backstop, so
        // that is no longer why the count is low** — the suite passes 8 of 8 either way now. It stays
        // low because burning most of a CPU-second for a diagnostic is worth avoiding on its own, and
        // it costs the figure nothing: 3,925–4,029 µs isolated at 20 against 3,911–4,261 µs at 200.
        // What is being claimed is milliseconds per call, not a number needing three significant
        // figures.
        let runs = 20

        let clock = ContinuousClock()
        let start = clock.now
        for _ in 0..<runs {
            _ = ShellSurfaceDetector.verdict(for: document)
        }
        let elapsed = clock.now - start

        let totalMicroseconds = Double(elapsed.components.seconds) * 1_000_000
            + Double(elapsed.components.attoseconds) / 1e12
        print("SHELL-CHECK-PER-CALL-MICROSECONDS: \(Int((totalMicroseconds / Double(runs)).rounded())) (\(document.count) characters, \(runs) runs)")
        #expect(elapsed < .seconds(5))
    }

    /// The corpus is not allowed to shrink to nothing without saying so, and both halves must stay
    /// populated — a corpus with an empty negative half would pass by refusing everything.
    /// **The minimal-prompt rule needs both halves, and each half is pinned separately** (PR #57 N2).
    /// Repetition alone refuses a documentation page; a trailing bare sigil alone refuses a comment
    /// block. Asserted as a progression over one screen so the contribution of each is unmistakable.
    @Test
    func aMinimalPromptCountsOnlyWhenItRepeatsAndEndsAtAWaitingPrompt() {
        // One occurrence: a documentation example.
        #expect(ShellSurfaceDetector.verdict(for: "$ npm install -g sonny").signals.isEmpty)
        // Two occurrences, neither waiting: still a page showing two examples.
        #expect(
            ShellSurfaceDetector.verdict(for: "$ npm install -g sonny\nthen\n$ sonny init").signals.isEmpty
        )
        // Two occurrences ending at a waiting prompt: a scrollback.
        #expect(
            ShellSurfaceDetector.verdict(for: "$ npm install -g sonny\nadded 12 packages\n$").signals
                == [.interactivePrompt, .commandRunInAShell]
        )
        // A waiting sigil that is not last does not count — that is a comment block's separator.
        #expect(
            ShellSurfaceDetector.verdict(for: "% cache settings\n%\n% clear on restart").signals.isEmpty
        )
        #expect(ShellSurfaceDetector.minimumMinimalPromptLines == 2)
    }

    /// **`#` and `❯` are deliberately outside the minimal set**, and each exclusion has a document
    /// behind it. A starship or pure prompt is therefore not recognised — the bound this buys.
    @Test
    func theMinimalPromptSetExcludesTheMarkdownAndBulletGlyphs() {
        // `#` is Markdown's heading marker; a root prompt arrives through the colon form instead.
        #expect(ShellSurfaceDetector.verdict(for: "# Getting Started\nsome prose\n#").signals.isEmpty)
        #expect(
            ShellSurfaceDetector.verdict(for: "root@a1b2c3d4:/# ls\ntotal 4\ndrwxr-xr-x  2 root root 4096 Aug 17 09:00 .").signals
                == [.interactivePrompt, .commandRunInAShell, .commandOutputListing]
        )
        // `❯` is a chevron bullet. The cost of excluding it, stated as a test rather than as prose:
        // a starship prompt is invisible even when a command in it failed.
        #expect(
            ShellSurfaceDetector.verdict(for: "\u{276F} ./scripts/deploy.sh\nzsh: permission denied: ./scripts/deploy.sh\n\u{276F}").signals
                == [.shellDiagnostic]
        )
    }

    /// **A prompt sigil glued to a digit is prose, not a prompt** (PR #57 N1) — and a sigil glued to
    /// a closing bracket still is one, which is the Linux default prompt.
    @Test
    func aSigilGluedToADigitIsNotAPromptButOneGluedToABracketIs() {
        for prose in [
            "priya@acme.io 82% open",
            "qa@acme.io 91% top performer this quarter",
            "alice@example.com says the build is 50% faster now."
        ] {
            #expect(ShellSurfaceDetector.verdict(for: prose).signals.isEmpty, "\(prose)")
        }
        #expect(
            ShellSurfaceDetector.verdict(for: "[sauransh@build-01 macos-agent]$ make release").signals
                == [.interactivePrompt, .commandRunInAShell]
        )
    }

    /// **The command must be the first thing typed at the prompt** (PR #57 N1). One command name
    /// anywhere on the line used to be enough, which is how an invoice row refused on the word
    /// `open`.
    @Test
    func onlyTheFirstTokenAfterAPromptCountsAsACommand() {
        // A real prompt shape whose remainder starts with a number, not a command. The prompt signal
        // still fires — this line genuinely has a prompt's shape — but it is now alone, so the
        // session proceeds. That is the residual, stated as an assertion rather than as prose: the
        // fix removes the refusal, not the misread.
        #expect(
            ShellSurfaceDetector.verdict(for: "billing@acme.io Total $ 400 please open the invoice").signals
                == [.interactivePrompt]
        )
        #expect(
            ShellSurfaceDetector.verdict(for: "billing@acme.io Total $ 400 please open the invoice").showsShell == false
        )
        // The same prompt with the command where a shell would actually put it.
        #expect(
            ShellSurfaceDetector.verdict(for: "sauransh@Mac work $ open .").signals
                == [.interactivePrompt, .commandRunInAShell]
        )
        // And a command later on the line does not rescue it.
        #expect(
            ShellSurfaceDetector.verdict(for: "sauransh@Mac work $ 400 please open the invoice").signals
                == [.interactivePrompt]
        )
    }

    /// The near-miss shapes the cycle-3 reviewer measured as *already* at zero. They are pinned so
    /// that a future loosening of the prompt pattern has to walk past them — the reviewer's point
    /// was that the durable half of N1 is the structure rather than any one table, and these are the
    /// edges of that structure.
    @Test
    func theNearMissShapesAroundAnAddressStayAtZero() {
        for line in [
            "| priya@acme.io | 82% | open |",
            "priya@acme.io, 82% open",
            "qa@acme.io #412 open",
            "origin  git@github.com:sauransh/macos-agent.git (fetch)",
            "ping support@example.com # if it breaks"
        ] {
            #expect(ShellSurfaceDetector.verdict(for: line).signals.isEmpty, "\(line)")
        }
    }

    @Test
    func theCorpusCoversBothDirections() {
        #expect(Self.mustRefuse.count >= 16)
        #expect(Self.mustNotRefuse.count >= 22)
        #expect(Self.mustRefuse.allSatisfy { $0.refuses })
        #expect(Self.mustNotRefuse.allSatisfy { !$0.refuses })
        // Names are the test arguments, so a duplicate would silently drop a fixture.
        #expect(Set(Self.corpus.map(\.name)).count == Self.corpus.count)
        // Both halves have to keep exercising the cases the review found, by name, so a later
        // trim cannot quietly remove the coverage that made this corpus able to fail.
        #expect(Self.mustRefuse.filter { $0.name.contains("(F2)") }.count >= 4)
        #expect(Self.mustNotRefuse.filter { $0.name.contains("(F1)") }.count >= 6)
        // Cycle 3's two findings anchor the same way.
        #expect(Self.mustRefuse.filter { $0.name.contains("(N2)") }.count >= 4)
        #expect(Self.mustNotRefuse.filter { $0.name.contains("(N1)") }.count >= 3)
        #expect(Self.mustNotRefuse.filter { $0.name.contains("(N2 adversarial)") }.count >= 5)
        // **SONNY-277's anchor, and it is not decoration** (PR #209 review, F11). Both of the
        // branch's first two section-mark fixtures could be deleted with the suite staying green,
        // because `mustNotRefuse.count >= 22` sat exactly at the count minus two — and deleting the
        // address-and-section-mark sentence alone is what makes the repetition floor's mutant
        // survive, while deleting the legal page alone takes a killer off the minimal-set mutant.
        // The floor is nine because that is what the F1 round left: two from the first version and
        // seven documents from the review's round, one of which is a control rather than an
        // adversary and is counted here so the pair cannot be split.
        #expect(Self.mustNotRefuse.filter { $0.name.contains("(SONNY-277 adversarial)") }.count >= 9)
        #expect(Self.mustNotRefuse.filter { $0.name.contains("(SONNY-277 control)") }.count >= 1)
        // **The three rows the fix round measured and did not pin** (PR #209 cycle 2, N5). Deleting
        // the indented panel alone brings back a mutant that passed the whole suite, which is what a
        // floor on a marker exists to stop; the gap fixture is held for a different reason, that a
        // documented failure quietly becoming undocumented is worse than the failure.
        #expect(Self.mustRefuse.filter { $0.name.contains("(SONNY-277 panel)") }.count >= 2)
        #expect(Self.mustNotRefuse.filter { $0.name.contains("(SONNY-277 gap)") }.count >= 1)
    }
}

private extension ShellSurfaceVerdict {
    func contains(_ signal: ShellSurfaceSignal) -> Bool { signals.contains(signal) }
}

// MARK: - The verdict cannot be forged, and cannot carry screen text

@Suite
struct ShellSurfaceVerdictStructureTests {
    /// The compile-time property under pin: `ShellSurfaceVerdict`'s only initializer is
    /// `fileprivate` and the type is not `Decodable`, so a "no shell" answer cannot be minted by a
    /// call site that forgot to ask or handed one by a decoder. Asserted against the source because
    /// a test target cannot express "this does not compile" — the same shape
    /// `payloadConstructionIsConfinedToTheRedactionServiceFile` uses for `RedactedPayload`.
    @Test
    func verdictConstructionIsConfinedToTheDetectorsOwnFile() throws {
        let declaration = try Self.verdictDeclaration()
        #expect(declaration.contains("fileprivate init("))
        #expect(!declaration.contains("public init"))
        #expect(!declaration.contains("Codable"))
        #expect(!declaration.contains("Decodable"))
        // `showsShell` is computed from `signals`, never stored beside it — the two cannot disagree.
        #expect(!declaration.contains("public let showsShell"))
        #expect(declaration.contains("public var showsShell: Bool"))
    }

    /// **The verdict holds signal names and nothing else, and that is checked rather than assumed**
    /// (PR #57 F4).
    ///
    /// This is the leak shape this repository has shipped twice: a structural guarantee that is only
    /// as wide as the type carrying it, with a later field quietly widening it. The claim "at most
    /// six fixed strings ever cross this boundary" was true when written and nothing would have
    /// failed if someone had added `public let matchedLine: String` to carry a repro into a log.
    ///
    /// Comments are stripped before the check, because the declaration's own prose discusses strings
    /// and a naive substring search over it would be asserting on documentation.
    @Test
    func theVerdictHoldsNothingButSignalsAndThatIsCheckedNotAssumed() throws {
        let code = try Self.verdictDeclaration()
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                let trimmed = line.drop { $0 == " " || $0 == "\t" }
                return trimmed.hasPrefix("///") || trimmed.hasPrefix("//") ? "" : line
            }
            .joined(separator: "\n")

        // Every property the type declares, stored or computed, at any access level — matched on the
        // whole set rather than on "is there a String" alone, so *any* addition has to come through
        // this test rather than only the ones a keyword list anticipated.
        let propertyKeywords = ["let ", "var "]
        let properties = code
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                propertyKeywords.contains { keyword in
                    line.hasPrefix(keyword)
                        || line.hasPrefix("public \(keyword)")
                        || line.hasPrefix("internal \(keyword)")
                        || line.hasPrefix("fileprivate \(keyword)")
                        || line.hasPrefix("private \(keyword)")
                        || line.hasPrefix("public private(set) \(keyword)")
                }
            }
        #expect(properties == [
            "public let signals: [ShellSurfaceSignal]",
            "public var showsShell: Bool {"
        ])

        // And no text-bearing type appears anywhere in the declaration, in a field or otherwise.
        for textBearing in ["String", "Substring", "Character", "Data", "[UInt8]", "URL"] {
            #expect(!code.contains(textBearing), "ShellSurfaceVerdict must not carry \(textBearing)")
        }
    }

    /// The behavioural half of the same property: two screens whose *content* differs completely,
    /// but whose signal classes are identical, produce **equal** verdicts. A field carrying a matched
    /// line, a snippet, or any other screen-derived text would make these differ.
    @Test
    func twoDifferentScreensWithTheSameSignalsProduceEqualVerdicts() {
        let first = ShellSurfaceDetector.verdict(for: """
        sauransh@Mac macos-agent % export API_KEY=sk-Abc123Def456Ghi789JklMno012Pqr
        zsh: permission denied: ./scripts/deploy.sh
        """)
        let second = ShellSurfaceDetector.verdict(for: """
        priya@build-07 releases % cat /etc/shadow
        zsh: no such file or directory: /etc/shadow
        """)
        #expect(first.signals == [.interactivePrompt, .commandRunInAShell, .shellDiagnostic])
        #expect(first == second)
    }

    /// Enumeration half: `ShellSurfaceVerdict(` construction appears in exactly one production file,
    /// the detector's own. `LocalRedactionService` receives one and stores it; it never builds one.
    @Test
    func onlyTheDetectorProducesVerdictsInTheLiveModule() throws {
        let files = try FileManager.default.contentsOfDirectory(at: Self.coreDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(files.count > 50)

        var constructingFiles: Set<String> = []
        for file in files {
            let contents = try String(contentsOf: file, encoding: .utf8)
            if contents.contains("ShellSurfaceVerdict(") {
                constructingFiles.insert(file.lastPathComponent)
            }
        }
        #expect(constructingFiles == ["ShellSurfaceDetector.swift"])
    }

    private static func verdictDeclaration() throws -> String {
        let source = try String(contentsOf: coreFile("ShellSurfaceDetector.swift"), encoding: .utf8)
        let start = try #require(source.range(of: "public struct ShellSurfaceVerdict"))
        let end = try #require(source.range(of: "// MARK: - Detector"))
        return String(source[start.lowerBound..<end.lowerBound])
    }

    private static var coreDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/MacAgentCore")
    }

    private static func coreFile(_ name: String) -> URL {
        coreDirectory.appendingPathComponent(name)
    }
}

// MARK: - The look-alike fold (SONNY-277)

/// **The measuring round SONNY-277 owes, and the check that keeps its answer true.**
///
/// The ticket asks two questions and forbids the change until both are answered: how often the
/// on-device recognizer substitutes a cross-script look-alike inside a shell prompt or a command
/// word at realistic capture sizes, and what folding those look-alikes back does to the two-signal
/// threshold on ordinary pages. SONNY-260 had seen the substitution only at one oversized synthetic
/// width, so "live gap or theoretical one" was genuinely open.
///
/// **The answer, measured here and recorded on the ticket: theoretical for letters, live for the
/// sigil.** No foldable scalar was emitted at any of the seven realistic sizes — and at the three
/// smallest the recognizer read the prompt's `%` as U+00A7 SECTION SIGN on every prompt line, which
/// cost not one signal of two but the whole verdict. The fold is bought as a boundary property; the
/// sigil is the fix for something that happens.
///
/// **Serialized for the reason `LocalRedactionLiveVisionTests` is** (PR #113 review, F5): every test
/// below drives the shared on-device recognizer, and concurrent `VNRecognizeTextRequest`s stall the
/// test process rather than failing it — which arrives as a timeout pointing at no assertion.
@Suite(.serialized)
struct ShellSurfaceLookAlikeFoldTests {
    /// The seven realistic capture sizes SONNY-260 pinned for this same recognizer, with their font
    /// sizes. A measurement at one oversized width is what left this question open, so the sweep is
    /// the population and no single size is the answer.
    static let captureSizes: [(name: String, width: Int, height: Int, fontSize: CGFloat)] = [
        ("1280x800 @ 12pt", 1280, 800, 12),
        ("1280x800 @ 14pt", 1280, 800, 14),
        ("1440x900 @ 13pt", 1440, 900, 13),
        ("1440x900 @ 26pt", 1440, 900, 26),
        ("2560x1600 @ 26pt", 2560, 1600, 26),
        ("2880x1800 @ 28pt", 2880, 1800, 28),
        ("800x600 @ 13pt", 800, 600, 13)
    ]

    /// A terminal panel that must refuse: a prompt, and commands typed at it.
    static let scrollback = [
        "PROBLEMS   OUTPUT   TERMINAL   PORTS",
        "sauransh@Mac macos-agent % ls",
        "README.md  Sources  Tests  docs",
        "sauransh@Mac macos-agent % sudo rm -rf .build",
        "Password:",
        "sauransh@Mac macos-agent % git status",
        "On branch main",
        "sauransh@Mac macos-agent %"
    ]

    /// **The frequency measurement, and the regression guard the sigil fix needs.**
    ///
    /// Renders the panel at each realistic size, reads it with the shipped recognizer, prints what
    /// came back, and asserts that the panel is refused — which is the property that was false at
    /// three of these seven sizes before this branch.
    ///
    /// **It asserts what is durable and prints what is not**, which is SONNY-260's rule after a
    /// fixture was tuned until it passed. Vision improves, so asserting that it *misreads* a glyph
    /// breaks on an OS update: the assertion is that a real terminal panel refuses however the sigil
    /// came back, and the scalar counts go to the record. The `§` case is pinned separately and
    /// exactly, on text the recognizer really produced, by `sectionSignPanel` in the corpus above.
    @Test(arguments: ShellSurfaceLookAlikeFoldTests.captureSizes.map(\.name))
    func aRealTerminalPanelIsRefusedAtEveryRealisticCaptureSize(sizeName: String) async throws {
        let size = try #require(Self.captureSizes.first { $0.name == sizeName })
        let lineHeight = size.fontSize * 1.6
        let lines = Self.scrollback.enumerated().map { index, text in
            (text: text, topLeft: CGPoint(x: 40, y: 40 + CGFloat(index) * lineHeight))
        }
        let png = ImageFixtures.renderedTextPNG(
            width: size.width,
            height: size.height,
            lines: lines,
            fontSize: size.fontSize
        )

        let observations = try await VisionImageTextRecognizer()
            .recognizeText(inPNGData: png, pixelWidth: size.width, pixelHeight: size.height)
        let joined = observations.map(\.string).joined(separator: "\n")

        let nonASCII = joined.unicodeScalars.filter { $0.value >= 0x80 }
        let foldable = zip(joined.unicodeScalars, LatinConfusables.fold(joined).text.unicodeScalars)
            .filter { $0 != $1 }
        let verdict = ShellSurfaceDetector.verdict(for: joined)

        print("SHELL-FOLD-MEASUREMENT \(size.name): observations=\(observations.count) "
            + "nonASCII=\(nonASCII.count) foldable=\(foldable.count) "
            + "scalars=[\(nonASCII.map { String(format: "U+%04X", $0.value) }.joined(separator: " "))] "
            + "signals=\(verdict.signals.map(\.rawValue))")

        // The recognizer returned the panel at all — without this the verdict below is a claim about
        // an empty string, and a recognizer that returned nothing would look like a detector defect.
        #expect(observations.count >= Self.scrollback.count - 2, "the panel was read at \(size.name)")
        #expect(verdict.showsShell, "a real terminal panel must refuse at \(size.name)")
    }

    /// **The cost measurement: what the fold does to the corpus of ordinary pages.**
    ///
    /// The fold turns non-ASCII letters into ASCII ones, so the risk it carries is manufacturing a
    /// prompt or a command word out of another script — the false-refusal direction, the one that
    /// stops a user's real work. Measured over the whole corpus rather than a chosen example.
    ///
    /// **What this test can and cannot do, since the fold moved inside `verdict(for:)`** (PR #209
    /// review, F10). It used to assert `verdict(for: fold(text)) == fixture.signals` and claim that
    /// as a folded-versus-unfolded comparison; the fold is idempotent and now runs inside the
    /// verdict, so that expression was byte-equivalent to the corpus test beside it and had no
    /// unfolded branch to compare against. It compares against the **unfolded** verdict now, which
    /// is reachable because `LatinConfusables` is `@testable`-visible and the pure ASCII path is not
    /// something `verdict(for:)` can undo: a fixture whose text folds to itself is asserted to be
    /// unchanged by the fold, and a fixture that does fold is asserted to reach the same verdict
    /// either way.
    ///
    /// **The property itself is covered by something stronger than this test**, and that is worth
    /// stating rather than leaving to be rediscovered: the pre-existing fixtures carry expected
    /// signal sets authored before the fold existed, so the corpus test passing at all is the
    /// evidence that the fold moved none of them.
    @Test(arguments: ShellSurfaceDetectorTests.corpus.map(\.name))
    func theFoldChangesNoVerdictOnTheExistingCorpus(name: String) throws {
        let fixture = try #require(ShellSurfaceDetectorTests.corpus.first { $0.name == name })
        let folded = LatinConfusables.fold(fixture.text).text
        #expect(
            ShellSurfaceDetector.verdict(for: folded).signals == fixture.signals,
            "the fold moved \(fixture.name)"
        )
        // The half the old version could not perform: for every fixture whose text the fold leaves
        // alone — which on this ASCII corpus is all of them — folding is provably a no-op on the
        // input rather than merely on the output, so the equality above is not an identity.
        #expect(folded == fixture.text, "this corpus is ASCII; a fixture that folds needs its own pin")
    }

    /// The same question asked of text the corpus does not contain: ordinary prose in scripts the
    /// fold reaches. None of it may gain a signal.
    ///
    /// **The control is the second half**, a Cyrillic string shaped like a prompt line, which folds
    /// into one and *does* gain signals. Without it, "the fold changes nothing" would be satisfied by
    /// a fold that never fires, and every assertion above it would be vacuous.
    @Test
    func foldingOrdinaryNonASCIIProseGainsNoSignalAndTheControlFires() {
        let prose = [
            "Documentation en fran\u{00E7}ais \u{2014} installez avec le gestionnaire de paquets.",
            "\u{041F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442}, \u{044D}\u{0442}\u{043E} \u{0441}\u{0442}\u{0440}\u{0430}\u{043D}\u{0438}\u{0446}\u{0430} \u{0434}\u{043E}\u{043A}\u{0443}\u{043C}\u{0435}\u{043D}\u{0442}\u{0430}\u{0446}\u{0438}\u{0438}.",
            "\u{00DC}bersicht: 82% der Nutzer haben priya@acme.io 82% open gelesen.",
            "Se\u{00F1}or Garc\u{00ED}a escribi\u{00F3}: el total es 50% m\u{00E1}s r\u{00E1}pido."
        ]
        for line in prose {
            let scalars = line.unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined(separator: " ")
            #expect(
                ShellSurfaceDetector.verdict(for: line).signals.isEmpty,
                "the fold gained a signal on ordinary prose: \(scalars)"
            )
        }

        // The control: a prompt line with seven of its Latin letters replaced by the Cyrillic
        // look-alikes SONNY-260 measured the recognizer emitting. Written as scalars deliberately —
        // pasting the rendered characters is what `.claude/rules/macagentcore-conventions.md` bans.
        let disguised = "\u{0455}\u{0430}ur\u{0430}nsh@M\u{0430}\u{0441} m\u{0430}\u{0441}os-\u{0430}gent % ls"
        #expect(
            ShellSurfaceDetector.verdict(for: disguised).signals == [.interactivePrompt, .commandRunInAShell],
            "the fold must recover a panel the recognizer disguised"
        )
        #expect(ShellSurfaceDetector.verdict(for: disguised).showsShell, "and it refuses")
        // And the same string with the fold's job undone by hand is what it looked like before: the
        // Cyrillic letters are not in `[A-Za-z0-9._-]`, so no address form can match.
        #expect(disguised.unicodeScalars.contains { $0.value >= 0x80 }, "precondition: it is disguised")
    }
}
