import Foundation
import Testing
@testable import MacAgentCore

/// SONNY-242. "write me a short note about today's plan and save it to my Desktop" was refused with
/// `/Users/<user>/my Desktop is outside the writable whitelist` — the refusal copy as it stood at
/// `961b9c2`, which this branch also rewrote — and that refusal then listed `/Users/<user>/Desktop`
/// as an allowed root. Two things had to be true for it: the planner copied the possessive into
/// `outputPath`, which its prompt tells it to do ("Include user-supplied paths exactly as written"),
/// and nothing between the plan and `PathWhitelist` knew that a leading possessive is not part of a
/// folder's name — even though `InstantCommandResolver` had known exactly that about app names.
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

    /// An absolute or tilde path is a place, not a description. `/Users/me/my Desktop` is a folder
    /// somebody can really have, and rewriting it would send a write somewhere they did not ask for.
    @Test
    func aPathThatIsAlreadyAPathIsNeverRewritten() {
        #expect(SpokenPath.normalized("/Users/me/my Desktop") == "/Users/me/my Desktop")
        #expect(SpokenPath.normalized("~/my Desktop") == "~/my Desktop")
        #expect(SpokenPath.normalized("/Users/me/my downloads folder") == "/Users/me/my downloads folder")
    }

    /// Only the leading component is read as a folder name in the home directory, so a possessive
    /// deeper in the path is part of a name the user really typed.
    @Test
    func onlyTheLeadingComponentLosesItsArticle() {
        #expect(SpokenPath.normalized("Desktop/my notes") == "Desktop/my notes")
        #expect(SpokenPath.normalized("my Desktop/my notes") == "Desktop/my notes")
        #expect(SpokenPath.normalized("Desktop/the archive/my plan.md") == "Desktop/the archive/my plan.md")
    }

    /// The resolve phase runs at all three executor gates, so the second pass must not keep eating
    /// the name.
    @Test
    func normalisationIsIdempotent() {
        for phrase in ["my Desktop", "the Documents folder", "Desktop/my notes", "/tmp/my Desktop", "my The Archive", "the the the Desktop"] {
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

    /// Derives the population by reflecting over `AgentStep` rather than by reading the list in
    /// `SpokenPath.normalizingFolderPhrases(in:)`, so a fifth path field added later and not wired
    /// in fails here instead of shipping. A field this fixture does not set is `nil`, which cannot
    /// change under normalisation — so the omission fails the same assertion.
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
            routineName: phrase,
            routineSteps: [],
            workspaceName: phrase,
            workspaceApps: [phrase],
            workspaceURLs: [phrase],
            workspaceFileLocations: [phrase],
            workspaceAppsToRemove: [phrase],
            workspaceURLsToRemove: [phrase],
            workspaceFileLocationsToRemove: [phrase],
            sourceURLs: [phrase],
            searchQuery: phrase,
            draftTitle: phrase,
            draftContent: phrase,
            shortcutName: phrase,
            shortcutInput: phrase,
            browserName: phrase,
            resolvedAppName: phrase,
            resolvedBundleIdentifier: phrase,
            resolvedFromFinderSelection: true,
            visionGoal: phrase
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

        #expect(beforeFields.count == afterFields.count)
        var normalisedLabels: Set<String> = []
        for (label, value) in beforeFields {
            let namesAPath = label.hasSuffix("Path") || label.lowercased().contains("filelocation")
            if namesAPath {
                #expect(afterFields[label] != value, "\(label) names a path and was not normalised")
                normalisedLabels.insert(label)
            } else {
                #expect(afterFields[label] == value, "\(label) does not name a path and was changed")
            }
        }
        #expect(normalisedLabels == ["inputPath", "outputPath", "workspaceFileLocations", "workspaceFileLocationsToRemove"])
    }

    /// `SaveRoutineCapabilityAdapter` persists `routineSteps` exactly as the plan carried them, so a
    /// phrase left inside one is a phrase stored in the routine's own record.
    @Test
    func aPhraseNestedInsideARoutineIsNormalisedToo() throws {
        let plan = AgentPlan(
            summary: "Teach a routine.",
            requiresConfirmation: false,
            steps: [
                AgentStep(
                    id: "save-routine",
                    operation: .saveRoutine,
                    description: "Save the routine.",
                    routineName: "Morning",
                    routineSteps: [
                        AgentStep(
                            id: "draft",
                            operation: .createLocalDraft,
                            description: "Draft the note.",
                            outputPath: "my Desktop",
                            draftContent: "Body."
                        )
                    ]
                )
            ]
        )

        let normalised = SpokenPath.normalizingFolderPhrases(in: plan)
        #expect(normalised.steps.count == 1)
        let outer = try #require(normalised.steps.first)
        let nested = try #require(outer.routineSteps?.first)
        #expect(nested.outputPath == "Desktop")
    }

    // MARK: - The reported command, end to end

    /// A `create_local_draft` step carrying the phrase the planner copied out of "save it to my
    /// Desktop". `prepare` resolves, previews and never writes, so this reads the real home
    /// directory and touches nothing in it.
    private func draftPlan(savedTo destination: String) -> AgentPlan {
        AgentPlan(
            summary: "Write a short note about today's plan.",
            requiresConfirmation: false,
            steps: [
                AgentStep(
                    id: "draft",
                    operation: .createLocalDraft,
                    description: "Write the note.",
                    outputPath: destination,
                    draftTitle: "Today's plan",
                    draftContent: "Body."
                )
            ]
        )
    }

    @Test
    func theReportedCommandLandsInDesktopRatherThanASiblingThatDoesNotExist() throws {
        let desktop = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop", isDirectory: true)
            .resolvingSymlinksInPath()
        try #require(FileManager.default.fileExists(atPath: desktop.path))

        let prepared = try AgentActionExecutor().prepare(plan: draftPlan(savedTo: "my Desktop"))
        let resolved = try #require(prepared.plan.steps.first?.outputPath)

        #expect(URL(fileURLWithPath: resolved).deletingLastPathComponent().path == desktop.path)
        #expect(resolved.hasSuffix(".md"))
        #expect(!resolved.contains("my Desktop"))
        #expect(!FileManager.default.fileExists(atPath: resolved))
    }

    /// The second half of the same journey, and a defect of its own (SONNY-242).
    /// `PathWhitelist.resolveOutputPath` probed for an existing directory with
    /// `expandingTildeInPath`, which leaves a relative name relative — so it was asking the
    /// *working directory* a question every other line in that file asks the home directory. A bare
    /// `Desktop` therefore answered "no such directory", fell through, and named `~/Desktop` itself
    /// as the file to write. The draft write would then have failed on a directory.
    @Test
    func aBareFolderNameNamesTheFolderRatherThanBecomingTheFile() throws {
        let desktop = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop", isDirectory: true)
            .resolvingSymlinksInPath()
        try #require(FileManager.default.fileExists(atPath: desktop.path))

        let prepared = try AgentActionExecutor().prepare(plan: draftPlan(savedTo: "Desktop"))
        let resolved = try #require(prepared.plan.steps.first?.outputPath)

        #expect(resolved != desktop.path)
        #expect(URL(fileURLWithPath: resolved).deletingLastPathComponent().path == desktop.path)
    }

    // MARK: - The refusal, when the folder really is out of bounds

    /// A folder Sonny cannot reach is still refused — the point of the fix is that the refusal now
    /// names the folder the person meant instead of a sibling nobody has.
    @Test
    func aRefusalNamesTheFolderThePersonMeant() {
        var thrown: Error?
        do {
            _ = try AgentActionExecutor().prepare(plan: draftPlan(savedTo: "my Downloads folder"))
        } catch {
            thrown = error
        }

        guard case .outsideWhitelist(let path, _)? = thrown as? PathValidationError else {
            Issue.record("Expected .outsideWhitelist, got \(String(describing: thrown))")
            return
        }
        let downloads = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads", isDirectory: true)
        #expect(path == downloads.resolvingSymlinksInPath().path)
        #expect(!path.contains("folder"))
    }

    /// The copy itself. "Outside the writable whitelist" named an implementation detail the reader
    /// has no way to know about; the sentence has to survive the workspace detail sheet rendering it
    /// after "Not in effect — ", which is why the path stays at the front.
    @Test
    func theRefusalCopyIsPlainAndLeadsWithThePath() {
        let error = PathValidationError.outsideWhitelist(
            "/Users/someone/Downloads",
            ["/Users/someone/Desktop", "/Users/someone/Documents"]
        )
        #expect(
            error.errorDescription
                == "/Users/someone/Downloads is not one of the folders Sonny can use: /Users/someone/Desktop, /Users/someone/Documents."
        )
    }
}
