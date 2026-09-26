import Foundation

public struct AgentPlan: Codable, Equatable, Sendable {
    public var summary: String
    public var requiresConfirmation: Bool
    public var steps: [AgentStep]

    public init(summary: String, requiresConfirmation: Bool, steps: [AgentStep]) {
        self.summary = summary
        self.requiresConfirmation = requiresConfirmation
        self.steps = steps
    }
}

/// One step an adapter body runs. `AdapterCapabilities` builds these from a typed operation's
/// arguments; the `resolved…` fields are written only by an adapter's own resolve phase, never from
/// the arguments.
public struct AgentStep: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var operation: AgentOperation
    public var description: String
    public var inputPath: String?
    public var outputPath: String?
    public var count: Int?
    public var targetURL: String?
    public var appName: String?
    public var question: String?
    public var mediaProvider: MediaProvider?
    public var mediaTitle: String?
    public var mediaArtist: String?
    public var contextSource: FinderContextSource?
    public var searchQuery: String?
    public var draftTitle: String?
    public var draftContent: String?
    public var shortcutName: String?
    public var shortcutInput: String?
    /// The app a `switch_running_app` step will actually activate — pinned exactly once, by
    /// `RunningAppSwitchCapabilityAdapter.resolveDefaultOutputs`, before anything previews or runs
    /// the step (SONNY-58). Once set, the pin is the identity: the preview names it, and execution
    /// activates it or fails — nothing re-resolves the query.
    public var resolvedAppName: String?
    /// The pinned app's bundle identifier — the half of the pin execution acts by. Written together
    /// with `resolvedAppName`, never separately.
    public var resolvedBundleIdentifier: String?

    /// The browser the user named for a URL-opening step, verbatim, or `nil` when they named none.
    ///
    /// **A name, not an identity, and deliberately not resolved here.**
    /// `CapabilityExecutionContext.browser(named:)` turns it into a `MacApp` at execution time
    /// through the same `installedAppResolver` every other app-name path uses; if it resolves to
    /// nothing installed, the step falls back to the system default rather than failing.
    public var browserName: String?

    /// What the user asked Sonny to watch for, in their own words — "the price on that page", "the
    /// status going to shipped" (SONNY-382).
    ///
    /// **A label and nothing more.** Nothing compares it, and no part of deciding whether the page
    /// changed reads it — that is `StandingWatcherEvaluator.digest(of:)` over the page's own text. It
    /// exists because the notification has to name the thing the user asked about rather than a URL.
    /// `StandingWatcher.subject` is where it lands, capped there at
    /// `StandingWatcher.maxSubjectCharacters`.
    public var watchSubject: String?

    /// What the user wants a file or folder called instead — a **name**, never a path (SONNY-385).
    ///
    /// **A leaf name, and the refusal of anything else is the operation's definition rather than a
    /// validation nicety.** `RenameCapabilityAdapter` refuses a value containing a path separator,
    /// and refuses `.` and `..`, because a rename that could name a path would be a *move* — a
    /// different action, with a different destination folder for the user to have been shown. The
    /// destination is always `inputPath`'s own parent directory with this name in it.
    public var newName: String?

    /// The day a `read_calendar_events` step reads, or the day a `create_reminder` step is due, in
    /// the closed vocabulary `CalendarDay.startOfDay(named:now:calendar:)` accepts (SONNY-453).
    ///
    /// **Read once by the resolve phase.** For a read, the resolver writes the real date back as
    /// `YYYY-MM-DD` before anything previews the step, so every gate after that reads one day. For a
    /// reminder the day is only half of a time, and a time can occur twice, so the resolver pins
    /// `resolvedReminderDueDate` instead and leaves this field as it was given.
    public var calendarDay: String?

    /// What a `create_reminder` step reminds the user about, in their own words (SONNY-453).
    public var reminderTitle: String?

    /// How many minutes from now a `create_reminder` step is due — "in 5 minutes" is 5 (SONNY-453).
    ///
    /// **Read once.** The resolve phase turns it into `resolvedReminderDueDate`, and every gate after
    /// that reads the pin: resolving "in 5 minutes" again at execution would move the reminder by
    /// exactly as long as the approval sat open.
    public var reminderMinutesFromNow: Int?

    /// The clock time a `create_reminder` step is due, `HH:mm` on a 24-hour clock (SONNY-453).
    public var reminderTime: String?

    /// **The instant a `create_reminder` step is due, pinned once by the resolve phase** (PR #244,
    /// F2). Nil until `CreateReminderCapabilityAdapter.resolveDefaultOutputs` runs.
    ///
    /// **An instant rather than the wall-clock `calendarDay` and `reminderTime` it came from**, and
    /// that is the whole reason this field exists. Turning those two back into a date at every gate
    /// is ambiguous for the hour a daylight-saving fall-back repeats: Foundation resolves a repeated
    /// time to its first occurrence, so "in 90 minutes" at 00:50 before the change pinned `01:20` and
    /// was added thirty minutes from now. An instant has no second occurrence.
    public var resolvedReminderDueDate: Date?

    public init(
        id: String,
        operation: AgentOperation,
        description: String,
        inputPath: String? = nil,
        outputPath: String? = nil,
        count: Int? = nil,
        targetURL: String? = nil,
        appName: String? = nil,
        question: String? = nil,
        mediaProvider: MediaProvider? = nil,
        mediaTitle: String? = nil,
        mediaArtist: String? = nil,
        contextSource: FinderContextSource? = nil,
        searchQuery: String? = nil,
        draftTitle: String? = nil,
        draftContent: String? = nil,
        shortcutName: String? = nil,
        shortcutInput: String? = nil,
        browserName: String? = nil,
        resolvedAppName: String? = nil,
        resolvedBundleIdentifier: String? = nil,
        watchSubject: String? = nil,
        newName: String? = nil,
        calendarDay: String? = nil,
        reminderTitle: String? = nil,
        reminderMinutesFromNow: Int? = nil,
        reminderTime: String? = nil,
        resolvedReminderDueDate: Date? = nil
    ) {
        self.id = id
        self.operation = operation
        self.description = description
        self.inputPath = inputPath
        self.outputPath = outputPath
        self.count = count
        self.targetURL = targetURL
        self.appName = appName
        self.question = question
        self.mediaProvider = mediaProvider
        self.mediaTitle = mediaTitle
        self.mediaArtist = mediaArtist
        self.contextSource = contextSource
        self.searchQuery = searchQuery
        self.draftTitle = draftTitle
        self.draftContent = draftContent
        self.shortcutName = shortcutName
        self.shortcutInput = shortcutInput
        self.browserName = browserName
        self.resolvedAppName = resolvedAppName
        self.resolvedBundleIdentifier = resolvedBundleIdentifier
        self.watchSubject = watchSubject
        self.newName = newName
        self.calendarDay = calendarDay
        self.reminderTitle = reminderTitle
        self.reminderMinutesFromNow = reminderMinutesFromNow
        self.reminderTime = reminderTime
        self.resolvedReminderDueDate = resolvedReminderDueDate
    }
}

/// The operations the kept V1 adapter bodies run. `clarify` is what a resolve phase or the instant
/// path returns when a step needs a detail it was not given.
public enum AgentOperation: String, Codable, CaseIterable, Sendable {
    case scanSelectLargestFiles = "scan_select_largest_files"
    case createZip = "create_zip"
    case scanDocx = "scan_docx"
    case convertDocxToPDF = "convert_docx_to_pdf"
    case openApp = "open_app"
    case openAppSearchURL = "open_app_search_url"
    case openURL = "open_url"
    case playMedia = "play_media"
    case getFinderSelection = "get_finder_selection"
    case revealInFinder = "reveal_in_finder"
    case showPermissionReadiness = "show_permission_readiness"
    case openGeneratedArtifact = "open_generated_artifact"
    case createLocalDraft = "create_local_draft"
    case calculateUtility = "calculate_utility"
    case lookupClipboardHistory = "lookup_clipboard_history"
    case expandSnippet = "expand_snippet"
    case saveSnippet = "save_snippet"
    case switchRunningApp = "switch_running_app"
    case lookupRecentArtifacts = "lookup_recent_artifacts"
    case invokeShortcut = "invoke_shortcut"
    /// Sonny waits for a public page to change and tells the user when it does (SONNY-382).
    ///
    /// **The step starts a watcher; it is not the watching.** Executing it reads the page once,
    /// stores that reading as the baseline, and returns — the checking happens afterwards on
    /// `TaskDesk.checkWatchers`'s own pulse, with no task behind it. Stopping is the Routines page's
    /// Stop control (`TaskDesk.stopWatching`), because the thing a user needs to stop is one of a list
    /// they are looking at.
    case startWatching = "start_watching"
    /// Sonny gives one file or folder a different name, in the folder it already sits in
    /// (SONNY-385).
    ///
    /// **Destructive by the consequence rule (2026-08-13).** The name a file is filed under is user
    /// data: renaming replaces it, nothing in the product undoes it, and
    /// `RenameCapabilityAdapter.assessRisk` therefore raises an unconditional `.destructive`
    /// escalation. One item, and a batch is refused rather than guessed at (founder decision
    /// 2026-09-03): a wrong bulk rename cannot be undone through the product and a question is cheap.
    case rename
    /// Sonny reads one day of the user's calendars and answers with a short list (SONNY-453). A read
    /// of the user's own data that changes nothing; the one prompt it can raise is macOS's own, the
    /// first time, which is the Calendars permission rather than an approval.
    case readCalendarEvents = "read_calendar_events"
    /// Sonny adds one reminder, with an alert, to the user's default Reminders list (SONNY-453).
    /// `CreateReminderCapabilityAdapter.assessRisk` carries an escalation that asks; its doc comment
    /// has the classification and why.
    case createReminder = "create_reminder"
    case clarify
    case unsupported
}

public enum MediaProvider: String, Codable, CaseIterable, Sendable {
    case appleMusic = "apple_music"
    case spotify

    public var displayName: String {
        switch self {
        case .appleMusic:
            return "Apple Music"
        case .spotify:
            return "Spotify"
        }
    }
}
