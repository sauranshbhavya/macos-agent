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
/// What is asserted, said plainly because it is easy to over-claim: **not** that every shell on
/// every screen is caught. A shell that is not rendered is not seen, and this check reads exactly
/// the surface an attacker controls, which is why the static ten-name deny list stays the primary
/// refusal and why SONNY-102 stays open. What is asserted is that this corpus lands on the right
/// side of a threshold that is a named constant, from both directions.
@Suite
struct ShellSurfaceDetectorTests {
    /// One screen, as the OCR pass would join it: one line per recognized line, in reading order.
    struct Fixture {
        let name: String
        /// What Sonny must do about it. `true` means the session ends.
        let refuses: Bool
        let text: String
    }

    // MARK: - The corpus

    /// **Must refuse.** The five the ticket names, plus two that exist because they are the ground a
    /// name list cannot reach at all: an unlisted terminal, and a shell reached over ssh.
    static let mustRefuse: [Fixture] = [
        Fixture(name: "Terminal", refuses: true, text: """
        Last login: Sat Aug 16 09:14:22 on ttys000
        sauransh@Mac ~ % cd Desktop/macos-agent
        sauransh@Mac macos-agent % git status
        On branch feature/terminal-screen-check
        nothing to commit, working tree clean
        sauransh@Mac macos-agent %
        """),

        Fixture(name: "iTerm", refuses: true, text: """
        sauransh@Mac:~/dev/macos-agent$ ls -la
        total 48
        drwxr-xr-x  12 sauransh  staff   384 16 Aug 09:12 .
        -rw-r--r--@  1 sauransh  staff  1284 15 Aug 21:03 README.md
        sauransh@Mac:~/dev/macos-agent$ ./scripts/plane
        zsh: no such file or directory: ./scripts/plane
        sauransh@Mac:~/dev/macos-agent$
        """),

        // The whole VS Code window, not just its panel — which is what a window capture contains.
        // The editor half carries a shebang on purpose: the same `#!/bin/bash` that must not make an
        // editor refuse on its own does not make this one refuse either, and the panel below it does
        // the refusing.
        Fixture(name: "VS Code integrated terminal panel", refuses: true, text: """
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
        """),

        Fixture(name: "JetBrains run console", refuses: true, text: """
        IntelliJ IDEA — macos-agent
        Run:   deploy  ×
        /bin/bash /Users/sauransh/dev/macos-agent/scripts/deploy.sh
        + echo 'Deploying to staging'
        Deploying to staging
        deploy@staging: Permission denied (publickey).
        Process finished with exit code 255
        """),

        Fixture(name: "notebook cell running shell", refuses: true, text: """
        deploy-notebook.ipynb — Jupyter
        In [3]: !ls -la build
                total 12
                drwxr-xr-x  3 sauransh staff   96 17 Aug 09:02 .
        In [4]: %%bash
                scp build/app.tar.gz deploy@staging:/srv/app/
                deploy@staging: Permission denied (publickey).
        """),

        // The gap the deny list narrows and never closes: a terminal nobody listed. Its prompt is
        // oh-my-zsh's, which no bundle identifier would have told anyone about.
        Fixture(name: "an unlisted terminal running oh-my-zsh", refuses: true, text: """
        \u{279C}  macos-agent git:(main) \u{2717} swift test
        Test run with 1223 tests in 92 suites passed
        \u{279C}  macos-agent git:(main) \u{2717} exit
        logout
        """),

        Fixture(name: "an ssh session inside an unlisted terminal", refuses: true, text: """
        sauransh@Mac ~ % ssh deploy@staging.example.com
        Last login: Fri Aug 15 22:10:04 2026 from 10.0.0.4
        deploy@staging:~$ uptime
        deploy@staging:~$ exit
        Connection to staging.example.com closed.
        """)
    ]

    /// **Must not refuse.** The three the ticket names, plus four more that are the same shape as
    /// something a user does every day. Over-refusing is the correct direction of error for a
    /// categorical rule, and it still has a real product cost, which is what the threshold is for.
    static let mustNotRefuse: [Fixture] = [
        Fixture(name: "a documentation page showing $ npm install", refuses: false, text: """
        Getting Started — Sonny Docs
        Installation
        Install the command line tool with npm:
        $ npm install -g sonny
        Then run sonny --help to see everything it can do. If you prefer Homebrew,
        brew install sonny works too.
        Requirements: macOS 14 or later, Node 20 or later.
        """),

        Fixture(name: "a chat message quoting a command", refuses: false, text: """
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
        // thing in ordinary shell source to a `user@host:path$` prompt, and the prompt pattern must
        // not read it as one.
        Fixture(name: "an editor displaying shell script source", refuses: false, text: """
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

        Fixture(name: "a README rendered in a browser", refuses: false, text: """
        macos-agent / README.md
        Building
        Run swift build, then swift test with the flags below. Plain swift test
        does not link.
        swift build
        swift test --disable-sandbox
        Contributing
        Open a pull request against main. Every commit message names its ticket.
        """),

        // Quoted reply lines start with `>`, which is a prompt sigil. This is the reason
        // `shellCommandNames` is a vocabulary rather than "any word after a sigil".
        Fixture(name: "an email thread with quoted reply lines", refuses: false, text: """
        Re: staging deploy — Mail
        From: Priya
        > can you run the deploy script tonight?
        > it needs to land before the release tag
        Yes, I will do it after the standup. The runbook is in the wiki, and the
        exit criteria are the same as last time.
        """),

        Fixture(name: "a Dockerfile open in an editor", refuses: false, text: """
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
        Fixture(name: "Sonny's own Security & Access settings page", refuses: false, text: """
        Security & Access
        Screen Control
        Once Screen Recording and Accessibility are granted, Sonny can control any
        app installed on this Mac — clicking, typing and scrolling in it the way
        you would. Sonny will never control Terminal, iTerm, or any other terminal app.
        Permission Readiness
        """)
    ]

    static var corpus: [Fixture] { mustRefuse + mustNotRefuse }

    // MARK: - The corpus, asserted

    @Test(arguments: ShellSurfaceDetectorTests.corpus.map(\.name))
    func everyCorpusFixtureLandsOnTheSideItMust(name: String) throws {
        let fixture = try #require(Self.corpus.first { $0.name == name })
        let verdict = ShellSurfaceDetector.verdict(for: fixture.text)
        #expect(
            verdict.showsShell == fixture.refuses,
            "\(fixture.name): showsShell=\(verdict.showsShell), signals=\(verdict.signals.map(\.rawValue))"
        )
    }

    /// The editor case, asserted by name because the ticket names it — and asserted on the signal
    /// count rather than only on the verdict, because "does not refuse" would also be true of a
    /// fixture sitting at exactly one sign for a reason nobody intended.
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
    func theBoundaryIsTwoDistinctSignalsFromBothSides() throws {
        let onePage = try #require(
            Self.mustNotRefuse.first { $0.name == "a documentation page showing $ npm install" }
        )
        let oneSign = ShellSurfaceDetector.verdict(for: onePage.text)
        #expect(oneSign.signals == [.shellCommandEcho])
        #expect(oneSign.showsShell == false)

        // The same page with one line added — a shell's own error message, a different class of
        // evidence entirely. Nothing else about the page changed.
        let twoSigns = ShellSurfaceDetector.verdict(
            for: onePage.text + "\nzsh: command not found: sonny"
        )
        #expect(twoSigns.signals == [.shellCommandEcho, .shellDiagnostic])
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

        let manyEchoedCommands = """
        $ npm install
        $ npm run build
        $ npm test
        $ git push
        """
        let echoes = ShellSurfaceDetector.verdict(for: manyEchoedCommands)
        #expect(echoes.signals == [.shellCommandEcho])
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
            .shellCommandEcho: "$ npm install",
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
            "shell_command_echo",
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
        let runs = 200

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
    @Test
    func theCorpusCoversBothDirections() {
        #expect(Self.mustRefuse.count >= 7)
        #expect(Self.mustNotRefuse.count >= 7)
        #expect(Self.mustRefuse.allSatisfy { $0.refuses })
        #expect(Self.mustNotRefuse.allSatisfy { !$0.refuses })
        // Names are the test arguments, so a duplicate would silently drop a fixture.
        #expect(Set(Self.corpus.map(\.name)).count == Self.corpus.count)
    }
}

// MARK: - The verdict cannot be forged

@Suite
struct ShellSurfaceVerdictStructureTests {
    /// The compile-time property under pin: `ShellSurfaceVerdict`'s only initializer is
    /// `fileprivate` and the type is not `Decodable`, so a "no shell" answer cannot be minted by a
    /// call site that forgot to ask or handed one by a decoder. Asserted against the source because
    /// a test target cannot express "this does not compile" — the same shape
    /// `payloadConstructionIsConfinedToTheRedactionServiceFile` uses for `RedactedPayload`.
    @Test
    func verdictConstructionIsConfinedToTheDetectorsOwnFile() throws {
        let source = try String(contentsOf: Self.coreFile("ShellSurfaceDetector.swift"), encoding: .utf8)
        let start = try #require(source.range(of: "public struct ShellSurfaceVerdict"))
        let end = try #require(source.range(of: "// MARK: - Detector"))
        let declaration = source[start.lowerBound..<end.lowerBound]

        #expect(declaration.contains("fileprivate init("))
        #expect(!declaration.contains("public init"))
        #expect(!declaration.contains("Codable"))
        #expect(!declaration.contains("Decodable"))
        // `showsShell` is computed from `signals`, never stored beside it — the two cannot disagree.
        #expect(!declaration.contains("public let showsShell"))
        #expect(declaration.contains("public var showsShell: Bool"))
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
