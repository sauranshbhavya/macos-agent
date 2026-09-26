import Foundation
import MacAgentTestSupport
import Testing
@testable import MacAgentCore

/// SONNY-242, and again in V2. "write me a short note about today's plan and save it to my Desktop"
/// was refused with `/Users/<user>/my Desktop is outside the writable whitelist`, and that refusal
/// then listed `/Users/<user>/Desktop` as an allowed root: the model copied the possessive into the
/// path, as it is told to ("as the user said it"), and nothing between it and `PathWhitelist` knew
/// that a leading possessive is not part of a folder's name. V2 dropped the fix with V1's executor;
/// `AdapterCapability.prepare` now runs it on every typed operation's path arguments.
@Suite
@MainActor
struct SpokenPathTests {
    // MARK: - The list, and the phrases people actually use

    @Test
    func everyPossessiveAndArticleComesOffTheFolderName() {
        #expect(SpokenPath.normalized("my Desktop") == "Desktop")
        #expect(SpokenPath.normalized("the Desktop") == "Desktop")
        #expect(SpokenPath.normalized("our Documents") == "Documents")
        #expect(SpokenPath.normalized("your Documents") == "Documents")
    }

    /// The match folds case; what survives keeps the case the user gave it. A folder name is
    /// compared against the filesystem, and lowercasing `Desktop` on the way through would hand the
    /// whitelist a string that no longer matches its root on a case-sensitive volume.
    @Test
    func theArticleMatchIgnoresCaseAndTheNameKeepsIts() {
        #expect(SpokenPath.normalized("My Desktop") == "Desktop")
        #expect(SpokenPath.normalized("MY DESKTOP") == "DESKTOP")
        #expect(SpokenPath.normalized("The Documents") == "Documents")
        #expect(SpokenPath.normalized("my desktop") == "desktop")
    }

    /// A bare phrase describing a folder rather than spelling it.
    @Test
    func aTrailingFolderNounComesOffABarePhrase() {
        #expect(SpokenPath.normalized("my downloads folder") == "downloads")
        #expect(SpokenPath.normalized("the Documents folder") == "Documents")
        #expect(SpokenPath.normalized("Desktop folder") == "Desktop")
        #expect(SpokenPath.normalized("my project directory") == "project")
    }

    /// The narrow rule that keeps the trailing noun safe: a value with more than one component is a
    /// path somebody spelled, and a folder can genuinely be called `Client folder`.
    @Test
    func aTrailingFolderNounSurvivesInsideARealPath() {
        #expect(SpokenPath.normalized("Documents/Client folder") == "Documents/Client folder")
        #expect(SpokenPath.normalized("my Documents/Client folder") == "Documents/Client folder")
    }

    /// A `/`-absolute path is a place, not a description. `/Users/me/my Desktop` is a folder
    /// somebody can really have, and rewriting it would send a write somewhere they did not ask for.
    @Test
    func aSlashAbsolutePathIsNeverRewritten() {
        #expect(SpokenPath.normalized("/Users/me/my Desktop") == "/Users/me/my Desktop")
        #expect(SpokenPath.normalized("/Users/me/my downloads folder") == "/Users/me/my downloads folder")
        #expect(SpokenPath.normalized("/my Desktop") == "/my Desktop")
    }

    /// **A tilde path is not the same case, and the first version of this suite pinned the bug as
    /// correct** (PR #106 review, F1). `PathWhitelist.expandPath` expands the tilde and resolves the
    /// rest against the same home directory a bare name goes to, so `~/my Desktop` and `my Desktop`
    /// are one location — the reported command was fixed in one spelling and still threw the
    /// founder's exact error in the other. And the tilde spelling is one a model reaches for.
    ///
    /// The `~` component is a home prefix, not a name, so the article comes off the component after
    /// it — and a component below *that* is a path someone spelled, exactly as in the bare case.
    @Test
    func aTildePathHasItsNamedComponentNormalisedLikeABareOne() {
        #expect(SpokenPath.normalized("~/my Desktop") == "~/Desktop")
        #expect(SpokenPath.normalized("~/the Documents folder") == "~/Documents")
        #expect(SpokenPath.normalized("~/my downloads folder") == "~/downloads")
        #expect(SpokenPath.normalized("~/Documents/Client folder") == "~/Documents/Client folder")
        #expect(SpokenPath.normalized("~/Desktop/my notes") == "~/Desktop/my notes")
        #expect(SpokenPath.normalized("~someone/my Desktop") == "~someone/Desktop")
        #expect(SpokenPath.normalized("~") == "~")
        #expect(SpokenPath.normalized("~/") == "~/")
    }

    /// The separator between an article and the name it precedes is any whitespace, not a literal
    /// U+0020 (PR #106 review, F5). Dictation and pasted rich text produce non-breaking spaces, and
    /// the difference is invisible on screen — the same family as the case folding above.
    @Test
    func aNonBreakingSpaceSeparatesAnArticleJustAsAPlainOneDoes() {
        #expect(SpokenPath.normalized("my\u{00A0}Desktop") == "Desktop")
        #expect(SpokenPath.normalized("the\u{00A0}Documents") == "Documents")
        #expect(SpokenPath.normalized("my downloads\u{00A0}folder") == "downloads")
        #expect(SpokenPath.normalized("~/my\u{00A0}Desktop") == "~/Desktop")
        #expect(SpokenName.withoutLeadingArticle("my\u{00A0}Safari") == "Safari")
    }

    /// Only the leading component is read as a folder name in the home directory, so a possessive
    /// deeper in the path is part of a name the user really typed.
    @Test
    func onlyTheLeadingComponentLosesItsArticle() {
        #expect(SpokenPath.normalized("Desktop/my notes") == "Desktop/my notes")
        #expect(SpokenPath.normalized("my Desktop/my notes") == "Desktop/my notes")
        #expect(SpokenPath.normalized("Desktop/the archive/my plan.md") == "Desktop/the archive/my plan.md")
    }

    /// A path Sonny reported back can come in again as an argument, so the second pass must not
    /// keep eating the name.
    @Test
    func normalisationIsIdempotent() {
        let corpus = [
            "my Desktop", "the Documents folder", "Desktop/my notes", "/tmp/my Desktop",
            "my The Archive", "the the the Desktop",
            "~/my Desktop", "~/my downloads folder", "~", "~/", "my\u{00A0}Desktop"
        ]
        for phrase in corpus {
            let once = SpokenPath.normalized(phrase)
            #expect(SpokenPath.normalized(once) == once)
        }
    }

    /// The path reading strips to a fixed point, which is what makes it idempotent, and the price is
    /// that a relatively-named folder genuinely called `The Archive` reads as `Archive`. Pinned so
    /// the cost is stated rather than discovered: it cannot lose anybody a folder, because a
    /// relative value resolves against the home directory and only `Desktop` and `Documents` can
    /// land inside the whitelist — `~/The Archive` and `~/Archive` are both refused.
    ///
    /// The *name* reading keeps its single strip, because `InstantCommandResolver` matches the
    /// original candidate alongside the stripped one and would otherwise lose `The Archive` as a
    /// routine name.
    @Test
    func thePathReadingStripsToAFixedPointAndTheNameReadingStripsOnce() {
        #expect(SpokenPath.normalized("my The Archive") == "Archive")
        #expect(SpokenPath.normalized("The Archive") == "Archive")
        #expect(SpokenName.withoutLeadingArticle("my The Archive") == "The Archive")
        #expect(SpokenName.withoutLeadingArticle("The Archive") == "Archive")
    }

    /// A value that is nothing but an article keeps its text: `my` on its own is not a folder called
    /// nothing, and returning an empty string would turn an explicit destination into a generated
    /// default without telling anyone.
    @Test
    func aValueThatIsOnlyAnArticleIsLeftAlone() {
        #expect(SpokenPath.normalized("my") == "my")
        #expect(SpokenPath.normalized("the ") == "the")
        #expect(SpokenPath.normalized("folder") == "folder")
        #expect(SpokenPath.normalized("   ") == "")
    }

    // MARK: - One list, two callers

    /// The property the ticket asked for: the possessive list exists once. `InstantCommandResolver`
    /// held `["my ", "the "]` literally and `PathWhitelist` knew nothing, so the product understood
    /// "my Safari" and not "my Desktop". Both readings now come off `SpokenName.leadingArticles`, so
    /// a word added for one caller is a word the other gains.
    @Test
    func theNameAndPathReadingsShareOneList() {
        for article in SpokenName.leadingArticles {
            #expect(SpokenName.withoutLeadingArticle("\(article) Safari") == "Safari")
            #expect(SpokenPath.normalized("\(article) Desktop") == "Desktop")
        }
    }

    // MARK: - The whole step, and nothing but the step

    /// **Which `AgentStep` properties name a filesystem path, asserted in both directions** (PR #106
    /// review, F6). The population comes off `Mirror`; the classification is this table, and the
    /// assertion below fails both when a property is missing from it and when it holds a name no
    /// property has. A new field of any spelling therefore stops the suite until somebody decides
    /// which side it is on.
    private static let stepPropertyNamesAPath: [String: Bool] = [
        "id": false,
        "operation": false,
        "description": false,
        "inputPath": true,
        "outputPath": true,
        "count": false,
        "targetURL": false,
        "appName": false,
        "question": false,
        "mediaProvider": false,
        "mediaTitle": false,
        "mediaArtist": false,
        "contextSource": false,
        "searchQuery": false,
        "draftTitle": false,
        "draftContent": false,
        "shortcutName": false,
        "shortcutInput": false,
        "resolvedAppName": false,
        "resolvedBundleIdentifier": false,
        "browserName": false,
        // SONNY-382. A phrase describing what the user wants to be told about, never a folder.
        "watchSubject": false,
        // SONNY-385. A leaf name and never a path — `RenameCapabilityAdapter` refuses one carrying a
        // separator. The folder half of a rename is `inputPath`, already `true` above.
        "newName": false,
        // SONNY-453. A day, a reminder's words, a number of minutes and a clock time.
        "calendarDay": false,
        "reminderTitle": false,
        "reminderMinutesFromNow": false,
        "reminderTime": false,
        // PR #244, F2. An instant, not a phrase of any kind.
        "resolvedReminderDueDate": false
    ]

    /// Every property the table above calls a path is normalised, and every property it does not is
    /// left exactly as it was. A field this fixture does not set is `nil`, which cannot change under
    /// normalisation — so an unwired path field fails the same assertion.
    @Test
    func everyPathFieldOnAStepIsNormalisedAndNothingElseIs() {
        let phrase = "my Desktop"
        let before = AgentStep(
            id: phrase,
            operation: .createLocalDraft,
            description: phrase,
            inputPath: phrase,
            outputPath: phrase,
            count: 3,
            targetURL: phrase,
            appName: phrase,
            question: phrase,
            mediaProvider: .spotify,
            mediaTitle: phrase,
            mediaArtist: phrase,
            contextSource: .finderSelection,
            searchQuery: phrase,
            draftTitle: phrase,
            draftContent: phrase,
            shortcutName: phrase,
            shortcutInput: phrase,
            browserName: phrase,
            resolvedAppName: phrase,
            resolvedBundleIdentifier: phrase,
            watchSubject: phrase,
            newName: phrase,
            calendarDay: phrase,
            reminderTitle: phrase,
            reminderMinutesFromNow: 5,
            reminderTime: phrase,
            resolvedReminderDueDate: Date(timeIntervalSince1970: 1_800_000_000)
        )

        let after = SpokenPath.normalizingFolderPhrases(in: before)
        let beforeFields = Dictionary(
            uniqueKeysWithValues: Mirror(reflecting: before).children.compactMap { child in
                child.label.map { ($0, String(describing: child.value)) }
            }
        )
        let afterFields = Dictionary(
            uniqueKeysWithValues: Mirror(reflecting: after).children.compactMap { child in
                child.label.map { ($0, String(describing: child.value)) }
            }
        )

        // Both directions: no property the table does not classify, no classification without a
        // property. A field added to `AgentStep` fails here whatever it is called.
        #expect(Set(beforeFields.keys) == Set(Self.stepPropertyNamesAPath.keys))
        #expect(Set(afterFields.keys) == Set(Self.stepPropertyNamesAPath.keys))

        for (label, value) in beforeFields {
            guard let namesAPath = Self.stepPropertyNamesAPath[label] else {
                continue
            }
            if namesAPath {
                #expect(afterFields[label] != value, "\(label) names a path and was not normalised")
            } else {
                #expect(afterFields[label] == value, "\(label) does not name a path and was changed")
            }
        }
    }

    // MARK: - The existence probe

    /// Records what `resolveOutputPath` asks the filesystem about.
    ///
    /// The probe is the whole of the second defect, so this pins the question rather than a
    /// downstream consequence of it — and it needs no real folder to do that, which is what lets
    /// this test say something exact about a relative path without reading the developer's home.
    private final class ProbeRecordingFileManager: FileManager, @unchecked Sendable {
        var probedPaths: [String] = []

        override func fileExists(atPath path: String) -> Bool {
            probedPaths.append(path)
            return super.fileExists(atPath: path)
        }
    }

    /// `resolveOutputPath` used to probe `(rawPath as NSString).expandingTildeInPath`, which leaves
    /// a relative name relative — so it asked the process's *working directory* a question every
    /// other line in that file asks the home directory. A bare `Desktop` therefore answered "no such
    /// directory" from an app whose working directory is `/`, fell through, and named `~/Desktop` —
    /// the folder itself — as the file to write.
    @Test
    func theExistenceProbeAsksAboutThePathThisTypeWouldResolve() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpokenPathTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let whitelist = PathWhitelist(roots: [root])
        let recorder = ProbeRecordingFileManager()
        let home = FileManager.default.homeDirectoryForCurrentUser

        // Throws, because a temp-rooted whitelist contains no home path — the probe has already
        // happened by then, and the probe is what is under test.
        _ = try? whitelist.resolveOutputPath(
            rawPath: "Desktop",
            defaultName: "draft",
            extension: "md",
            fileManager: recorder
        )

        #expect(recorder.probedPaths == [
            home.appendingPathComponent("Desktop", isDirectory: true).resolvingSymlinksInPath().path
        ])
        #expect(!recorder.probedPaths.contains("Desktop"))
    }

    /// The branch the probe exists to reach, on a folder that really is inside the whitelist: an
    /// existing directory takes the generated name *inside* it rather than becoming the file.
    @Test
    func anExistingDirectoryTakesTheGeneratedNameInsideIt() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpokenPathTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let resolved = try PathWhitelist(roots: [root]).resolveOutputPath(
            rawPath: root.path,
            defaultName: "draft",
            extension: "md",
            fileManager: .default
        )

        #expect(resolved.deletingLastPathComponent().path == root.resolvingSymlinksInPath().path)
        #expect(resolved.lastPathComponent == "draft.md")
    }

    // MARK: - The refusal copy

    /// "Outside the writable whitelist" named an implementation detail the reader has no way to know
    /// about. The sentence has to survive the workspace detail sheet rendering it after
    /// "Not in effect — ", which is why the path stays at the front.
    @Test
    func theRefusalCopyIsPlainAndLeadsWithThePath() {
        // `asked: nil` is the ordinary refusal — the person named a folder Sonny cannot use, and
        // nothing resolved the path out from under them. SONNY-249's second sentence, for a path a
        // symbolic link led out of, is pinned in `PathContainmentResolutionTests`.
        let error = PathValidationError.outsideWhitelist(
            path: "/Users/someone/Downloads",
            asked: nil,
            roots: ["/Users/someone/Desktop", "/Users/someone/Documents"]
        )
        #expect(
            error.errorDescription
                == "/Users/someone/Downloads is not one of the folders Sonny can use: /Users/someone/Desktop, /Users/someone/Documents."
        )
    }
}
