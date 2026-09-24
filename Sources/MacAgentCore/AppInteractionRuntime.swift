import AppKit
import Foundation

/// Runs one `AppInteractionGoal` from start to an honest outcome (V2 plan, Milestone A).
///
/// This is the single owner of the new path's execution: it resolves the app, applies the gates,
/// runs the observe → choose → check → act loop through cua-driver, and verifies the result
/// itself. The UI submits a goal and renders the outcome; nothing here reads which window or task
/// has focus. Cancellation is the calling task's: every loop turn, every wait and every call
/// checks it, and an outcome reached after Sonny changed something in the app says so, because the
/// change stays there.
public struct AppInteractionRuntime: Sendable {
    public struct Budget: Equatable, Sendable {
        /// Steps, counting every model decision, including ones that were refused or failed.
        public var maxSteps = 12
        /// How long to wait for a just-opened app to show a window cua can read.
        public var windowWait: Duration = .seconds(8)
        public var windowPoll: Duration = .milliseconds(250)
        /// Pause after an action so the app can redraw before the next reading.
        public var settle: Duration = .milliseconds(350)

        public init() {}
    }

    /// An app the runtime works in, and the little it needs to know about that app.
    public struct SupportedApp: Equatable, Sendable {
        /// Exactly as the app declares it; compared without case.
        public let bundleIdentifier: String
        /// The menu path of the app's own command that starts a fresh item, which Sonny runs itself
        /// before the model's first step. Nil when the goal works on what is open.
        public let startingMenuPath: [String]?
        /// What that command makes, in the person's words: "note".
        public let itemNoun: String
        /// The folder Sonny opens when the starting command is greyed out where the app is, then
        /// tries once more: Notes cannot make a note in a shared view, a smart folder or Recently
        /// Deleted (the first live run, 2026-09-24).
        public let defaultFolder: String?

        public init(bundleIdentifier: String, startingMenuPath: [String]?, itemNoun: String, defaultFolder: String? = nil) {
            self.bundleIdentifier = bundleIdentifier
            self.startingMenuPath = startingMenuPath
            self.itemNoun = itemNoun
            self.defaultFolder = defaultFolder
        }
    }

    /// Notes, where Milestone A makes a new note holding the person's text. Sonny starts the note
    /// with Notes' own File › New Note, through cua's `invoke_menu`, in whichever folder is open, so
    /// the model's part is placing the text and nothing the model may press widens for it
    /// (founders, 2026-09-24). The path is Notes' English one: on a Mac in another language the
    /// command is not found and the run says so.
    ///
    /// Notes is the only app, here and in cua's own manifest. WhatsApp and Messages were the first
    /// picks; both are Catalyst apps whose window has no Mac list, scroll area or text field, and on
    /// the one live run chat names reached the model. Mail's message body is a web view that takes
    /// no text through Accessibility. They wait for later milestones (measured 2026-09-24; the V2
    /// plan's top section).
    public static let notes = SupportedApp(
        bundleIdentifier: "com.apple.Notes",
        startingMenuPath: ["File", "New Note"],
        itemNoun: "note",
        defaultFolder: "Notes"
    )

    private let driver: CuaDriverClient
    private let chooser: any AppInteractionStepChoosing
    private let apps: any AppInteractionAppOpening
    private let appControl: @Sendable (String) async -> AppControlStanding
    private let supportedApps: [SupportedApp]
    private let screenBuilder: AppInteractionScreenBuilder
    private let budget: Budget
    private let sleep: @Sendable (Duration) async throws -> Void

    public init(
        driver: CuaDriverClient,
        chooser: any AppInteractionStepChoosing,
        apps: any AppInteractionAppOpening,
        appControl: @escaping @Sendable (String) async -> AppControlStanding,
        redact: @escaping @Sendable (String) -> String,
        supportedApps: [SupportedApp] = [AppInteractionRuntime.notes],
        budget: Budget = Budget(),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.driver = driver
        self.chooser = chooser
        self.apps = apps
        self.appControl = appControl
        self.supportedApps = supportedApps
        self.screenBuilder = AppInteractionScreenBuilder(redact: redact)
        self.budget = budget
        self.sleep = sleep
    }

    /// What a run has done so far, kept outside the loop so a stop can report it.
    private struct Progress {
        var appName: String?
        /// The noun of the item Sonny started with the app's own command, once it has.
        var startedItem: String?
        /// The folder Sonny opened because the starting command was greyed out where the app was.
        var openedFolder: String?
        /// Everything Sonny set as a field's value, so the policy can tell its own text from the
        /// person's (PR #289 review, F8).
        var written: Set<String> = []

        /// Whether Sonny placed the goal's text itself, as opposed to only the name into search.
        func typedMessage(of goal: AppInteractionGoal) -> Bool {
            goal.text.map { written.contains($0) } ?? false
        }

        /// What the run changed in the app, the most telling first; nil when it changed nothing.
        func leftBehind(for goal: AppInteractionGoal) -> AppInteractionLeftBehind? {
            if typedMessage(of: goal) { return .text }
            if !written.isEmpty { return .searchedName }
            if let startedItem { return .newItem(startedItem) }
            return openedFolder.map { .openedFolder($0) }
        }
    }

    public func run(
        _ goal: AppInteractionGoal,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) async -> AppInteractionOutcome {
        var progress = Progress()
        let outcome: AppInteractionOutcome
        do {
            outcome = try await attempt(goal, progress: &progress, log: log)
        } catch is CancellationError {
            return .cancelled(app: progress.appName ?? goal.app, left: progress.leftBehind(for: goal))
        } catch let error as AppInteractionStop {
            outcome = error.outcome
        } catch {
            if SonnyBackendError.isCancellation(error) {
                return .cancelled(app: progress.appName ?? goal.app, left: progress.leftBehind(for: goal))
            }
            if let backend = (error as? SonnyBackendError) ?? (error as? any CarriesBackendError)?.backendError {
                outcome = .failed(.service(SonnyBackendCopy.sentence(for: backend)))
            } else {
                outcome = .failed(.service(nil))
            }
        }
        if case .failed(let failure) = outcome, let left = progress.leftBehind(for: goal) {
            return .failedAfterChange(failure, app: progress.appName ?? goal.app, left: left)
        }
        return outcome
    }

    // MARK: - The loop

    private func attempt(
        _ goal: AppInteractionGoal,
        progress: inout Progress,
        log: @escaping @Sendable (String) -> Void
    ) async throws -> AppInteractionOutcome {
        guard let app = apps.resolve(goal.app) else { return .failed(.appNotInstalled(goal.app)) }
        let name = app.displayName
        progress.appName = name

        // The same refusal screen control applies: a terminal stays out of reach whichever backend
        // would drive it (plan §12).
        let verdict = ScreenControlPolicy.verdict(bundleIdentifier: app.bundleIdentifier, displayName: name)
        if let refusal = verdict.refusal { return .failed(.refusedApp(name, refusal)) }
        guard let supported = supportedApps.first(where: {
            $0.bundleIdentifier.lowercased() == app.bundleIdentifier.lowercased()
        }) else { return .failed(.appNotSupported(name)) }

        // `.notApplicable` cannot happen with a bundle identifier in hand; treated as a refusal so a
        // resolver change fails closed rather than open.
        switch await appControl(app.bundleIdentifier) {
        case .allowed: break
        case .needsApproval, .notApplicable: return .failed(.appControlNotAllowed(name))
        }
        guard try await accessibilityGranted() else { return .failed(.accessibilityNotGranted) }

        try Task.checkCancellation()
        let processIdentifier: pid_t
        do {
            // Opening brings the app forward, which cua needs: it reads only windows on the current
            // Space (measured 2026-09-24).
            processIdentifier = try await apps.open(bundleIdentifier: app.bundleIdentifier)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .failed(.couldNotOpen(name))
        }
        log("Opened \(name)")
        let windowID = try await mainWindow(of: processIdentifier, appName: name)

        if let path = supported.startingMenuPath {
            var started = try await runMenu(path, pid: processIdentifier, windowID: windowID, appName: name, log: log)
            if !started, let folder = supported.defaultFolder {
                // Founders, 2026-09-24: when the command is greyed out where the app is, open the
                // default folder and try once more. Sonny finds it by name on this Mac, from cua's
                // own rendering of the window; the model has no part in it and never sees the names.
                let state = try await observe(processIdentifier, windowID: windowID, appName: name)
                if let row = state.rows(named: folder).first {
                    try Task.checkCancellation()
                    do {
                        try await driver.perform(.click(CuaElementRef(row, in: state)), pid: processIdentifier, windowID: windowID)
                        progress.openedFolder = folder
                        log("Opened the \(folder) folder in \(name)")
                        try await sleep(budget.settle)
                        started = try await runMenu(path, pid: processIdentifier, windowID: windowID, appName: name, log: log)
                    } catch let error as CuaToolError {
                        if error.isOutsideCeiling { return .failed(.outsideCeiling(name)) }
                        log("Opening the \(folder) folder failed: \(error.message)")
                    }
                } else {
                    log("\(name) has no folder named \(folder)")
                }
            }
            guard started else { return .failed(.couldNotStartItem(name, supported.itemNoun)) }
            progress.startedItem = supported.itemNoun
            log("Started a new \(supported.itemNoun) in \(name)")
            try await sleep(budget.settle)
        }

        var history: [AppInteractionHistoryEntry] = []
        for _ in 0..<budget.maxSteps {
            try Task.checkCancellation()
            let state = try await observe(processIdentifier, windowID: windowID, appName: name)

            // Checked before asking the model, so a goal already met costs no model call — but only
            // a confirmed one. An unconfirmed placement waits for the model to say it is finished,
            // so text in the wrong item gets a turn to be moved (PR #289 review, F3).
            if progress.typedMessage(of: goal), AppInteractionVerifier.check(state, goal: goal) == .satisfied {
                return .done(AppInteractionReport(appName: name, goal: goal, targetConfirmed: true, newItem: progress.startedItem, folder: progress.openedFolder))
            }

            let built = screenBuilder.build(from: state, goal: goal, sonnyWrote: progress.written)
            try Task.checkCancellation()
            let decision: AppInteractionModelDecision
            do {
                decision = try await chooser.chooseStep(goal: goal, screen: built.screen, history: history)
            } catch AppInteractionDecisionError.malformed {
                history.append(AppInteractionHistoryEntry(did: "answered", result: "the answer was not valid JSON for the schema"))
                continue
            }

            switch decision {
            case .askUser(let question):
                return .needsUserInput(question)
            case .giveUp(let reason):
                return .failed(.gaveUp(name, reason))
            case .finished:
                try await sleep(budget.settle)
                let fresh = try await observe(processIdentifier, windowID: windowID, appName: name)
                if let outcome = finishedOutcome(fresh, goal: goal, appName: name, progress: progress) {
                    return outcome
                }
                history.append(AppInteractionHistoryEntry(did: "said finished", result: notFinishedReason(fresh, goal: goal)))
            case .step(let step):
                let described = describe(step, in: built)
                if let refusal = unoffered(step, in: built) {
                    history.append(AppInteractionHistoryEntry(did: described, result: refusal))
                    continue
                }
                switch AppInteractionPolicy.decide(step, in: state, goal: goal, sonnyWrote: progress.written) {
                case .refuse(.mightCommit):
                    // Not something to route around: the plan's rule is that a refusal is never a
                    // reason to try another way (§3).
                    return .failed(.stepNotAllowed(name, label(of: step, in: built, state: state)))
                case .refuse(.wouldReplaceTypedText):
                    // The person's own words are in that box. Another box would be the wrong place,
                    // so this ends the run rather than letting the model look elsewhere.
                    return .failed(.typedTextKept(name))
                case .refuse(let refusal):
                    history.append(AppInteractionHistoryEntry(did: described, result: "refused: \(refusal)"))
                case .allow(let action):
                    // The model call can take many seconds; a Stop pressed during it lands here,
                    // before the action rather than after it (PR #289 review, F11).
                    try Task.checkCancellation()
                    do {
                        try await perform(action, pid: processIdentifier, windowID: windowID)
                        if case .setValue(_, let text) = action { progress.written.insert(text) }
                        log("\(step.kind.rawValue) on \(label(of: step, in: built, state: state))")
                        history.append(AppInteractionHistoryEntry(did: described, result: "done"))
                    } catch let error as CuaToolError {
                        if error.isOutsideCeiling { return .failed(.outsideCeiling(name)) }
                        history.append(AppInteractionHistoryEntry(did: described, result: "failed: \(error.message)"))
                    }
                    try await sleep(budget.settle)
                }
            }
        }
        return .failed(.ranOutOfSteps(name, budget.maxSteps))
    }

    /// Runs the app's starting menu command: true when it ran, false when the app has it missing or
    /// greyed out, with cua's reason in the activity log so a failure can be read rather than
    /// guessed at. A refusal by cua's own ceiling ends the run.
    private func runMenu(
        _ path: [String], pid: pid_t, windowID: Int, appName: String,
        log: @escaping @Sendable (String) -> Void
    ) async throws -> Bool {
        try Task.checkCancellation()
        do {
            try await driver.perform(.menu(path), pid: pid, windowID: windowID)
            return true
        } catch let error as CuaToolError {
            if error.isOutsideCeiling { throw AppInteractionStop(.failed(.outsideCeiling(appName))) }
            log("\(path.joined(separator: " › ")) did not run: \(error.message)")
            return false
        }
    }

    /// Sets a field's value, and inserts the text instead when the field takes no whole value:
    /// what cua's `type_text` does, at the field's selection, still without a key being typed.
    private func perform(_ action: CuaAction, pid: pid_t, windowID: Int) async throws {
        do {
            try await driver.perform(action, pid: pid, windowID: windowID)
        } catch let error as CuaToolError where !error.isOutsideCeiling {
            guard case .setValue(let ref, let text) = action else { throw error }
            try await driver.perform(.typeText(ref, text), pid: pid, windowID: windowID)
        }
    }

    /// Why a step the screen never offered is not taken, or nil when it was on offer.
    private func unoffered(_ step: AppInteractionStep, in built: AppInteractionScreenBuilder.Built) -> String? {
        guard let ref = step.ref else {
            return step.kind.takesRef ? "not offered: that step needs a ref" : nil
        }
        guard let candidate = built.screen.candidates.first(where: { $0.ref == ref }) else {
            return "no element has that ref"
        }
        return candidate.can.contains(step.kind.rawValue)
            ? nil
            : "not offered: that element can only \(candidate.can.joined(separator: ", "))"
    }

    /// What the step lands on, as the person would call it: the candidate's label, or for a click at
    /// a point, the name of the element there.
    private func label(of step: AppInteractionStep, in built: AppInteractionScreenBuilder.Built, state: CuaWindowState? = nil) -> String {
        if let ref = step.ref { return built.screen.candidates.first { $0.ref == ref }?.label ?? "" }
        if let x = step.x, let y = step.y { return state?.element(atX: x, y: y)?.label ?? "" }
        return ""
    }

    private func describe(_ step: AppInteractionStep, in built: AppInteractionScreenBuilder.Built) -> String {
        var words = [step.kind.rawValue]
        if let ref = step.ref { words.append("\(ref) (\(label(of: step, in: built)))") }
        if let input = step.input { words.append(input) }
        if let x = step.x, let y = step.y { words.append("at \(Int(x)),\(Int(y))") }
        return words.joined(separator: " ")
    }

    /// The model says it is finished. Sonny agrees only for the text it placed itself — not for
    /// having typed the name into search (PR #289 review, F7, and its delta) — somewhere that is not
    /// visibly the wrong item.
    private func finishedOutcome(
        _ state: CuaWindowState,
        goal: AppInteractionGoal,
        appName: String,
        progress: Progress
    ) -> AppInteractionOutcome? {
        if goal.text != nil, !progress.typedMessage(of: goal) { return nil }
        switch AppInteractionVerifier.check(state, goal: goal) {
        case .satisfied:
            return .done(AppInteractionReport(appName: appName, goal: goal, targetConfirmed: true, newItem: progress.startedItem, folder: progress.openedFolder))
        case .targetUnconfirmed:
            return .done(AppInteractionReport(appName: appName, goal: goal, targetConfirmed: false, newItem: progress.startedItem, folder: progress.openedFolder))
        case .otherTargetOpen, .notYet: return nil
        }
    }

    private func notFinishedReason(_ state: CuaWindowState, goal: AppInteractionGoal) -> String {
        switch AppInteractionVerifier.check(state, goal: goal) {
        case .otherTargetOpen: return "Sonny checked: a different item is open"
        default: return "Sonny checked and the goal is not met yet"
        }
    }

    private func accessibilityGranted() async throws -> Bool {
        do {
            return try await driver.accessibilityGranted()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return false
        }
    }

    /// The app's largest window on screen, waiting a bounded time for one after a launch. The
    /// largest, because a full-screen app draws its toolbar as a window of its own (measured on
    /// Notes, 2026-09-24).
    private func mainWindow(of processIdentifier: pid_t, appName: String) async throws -> Int {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: budget.windowWait)
        while true {
            try Task.checkCancellation()
            let windows = (try? await driver.windows(pid: processIdentifier)) ?? []
            if let window = windows.filter(\.isOnScreen).max(by: { $0.area < $1.area }) {
                return window.windowID
            }
            guard clock.now < deadline else { throw AppInteractionStop(.failed(.noWindow(appName))) }
            try await sleep(budget.windowPoll)
        }
    }

    /// Reads the window, waiting a bounded time while cua cannot resolve it yet — just after the
    /// app came forward, or while it animates a new item in.
    private func observe(_ processIdentifier: pid_t, windowID: Int, appName: String) async throws -> CuaWindowState {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: budget.windowWait)
        while true {
            try Task.checkCancellation()
            do {
                let state = try await driver.windowState(pid: processIdentifier, windowID: windowID)
                if state.degradedReason == nil, !state.elements.isEmpty { return state }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as CuaToolError where error.message.contains("not a live window") {
                throw AppInteractionStop(.failed(.appQuit(appName)))
            } catch {
                // Read again until the deadline; what is left is reported below.
            }
            guard clock.now < deadline else { throw AppInteractionStop(.failed(.unreadable(appName))) }
            try await sleep(budget.windowPoll)
        }
    }
}

/// Carries a terminal outcome out of a nested helper.
private struct AppInteractionStop: Error {
    let outcome: AppInteractionOutcome
    init(_ outcome: AppInteractionOutcome) { self.outcome = outcome }
}

// MARK: - Outcome

public struct AppInteractionReport: Equatable, Sendable {
    public let appName: String
    public let goal: AppInteractionGoal
    /// False when the text is in place but Sonny could not see that the target is what is open.
    public let targetConfirmed: Bool
    /// The noun of the item Sonny started itself, such as "note", when it did.
    public let newItem: String?
    /// The folder Sonny opened first, when the app could not start one where it was.
    public let folder: String?

    public init(appName: String, goal: AppInteractionGoal, targetConfirmed: Bool, newItem: String? = nil, folder: String? = nil) {
        self.appName = appName
        self.goal = goal
        self.targetConfirmed = targetConfirmed
        self.newItem = newItem
        self.folder = folder
    }

    public var summary: String {
        if let text = goal.text {
            if let target = goal.target {
                return targetConfirmed
                    ? "The message is in the \(target) chat in \(appName), not sent: \"\(text)\""
                    : "The message is in a message box in \(appName), but I couldn't see which chat is open, so check it's \(target)'s before you send: \"\(text)\""
            }
            if let newItem, let folder { return "I opened your \(folder) folder and made a new \(newItem) there: \"\(text)\"" }
            if let newItem { return "I made a new \(newItem) in \(appName): \"\(text)\"" }
            return "The text is in \(appName): \"\(text)\""
        }
        if let target = goal.target { return "\(target) is open in \(appName)." }
        return "Done in \(appName)."
    }
}

/// What a run that did not finish left changed in the app, so the person is told plainly.
public enum AppInteractionLeftBehind: Equatable, Sendable {
    /// Sonny started a new item with the app's own command and placed nothing in it yet.
    case newItem(String)
    /// Sonny typed only the target's name into a search field.
    case searchedName
    /// The goal's text is in the app.
    case text
    /// Sonny opened this folder, the app's starting command having been greyed out where it was.
    case openedFolder(String)

    func sentence(app: String) -> String {
        switch self {
        case .newItem(let noun): return "I had already started a new \(noun) in \(app)."
        case .searchedName: return "I left the name I searched for in \(app)'s search field."
        case .text: return "The text I added is still in \(app)."
        case .openedFolder(let folder): return "I switched \(app) to your \(folder) folder."
        }
    }
}

public enum AppInteractionOutcome: Equatable, Sendable {
    case done(AppInteractionReport)
    case needsUserInput(String)
    case failed(AppInteractionFailure)
    /// A failure reached after Sonny had changed something in the app, which is still there.
    case failedAfterChange(AppInteractionFailure, app: String, left: AppInteractionLeftBehind)
    /// Stopped by the person; `left` is what Sonny had changed by then, if anything.
    case cancelled(app: String, left: AppInteractionLeftBehind?)
}

public enum AppInteractionFailure: Equatable, Sendable {
    case appNotInstalled(String)
    case refusedApp(String, ScreenControlRefusal)
    case appNotSupported(String)
    case appControlNotAllowed(String)
    case accessibilityNotGranted
    case couldNotOpen(String)
    case noWindow(String)
    case appQuit(String)
    case unreadable(String)
    /// The app's own New command was missing or greyed out: app, then what it makes.
    case couldNotStartItem(String, String)
    case stepNotAllowed(String, String)
    case typedTextKept(String)
    case gaveUp(String, String)
    case ranOutOfSteps(String, Int)
    /// The step route failed. Carries the backend's own user-facing sentence when there is one.
    case service(String?)
    /// cua-driver's library would not start.
    case driverUnavailable
    /// cua's own ceiling refused a step Sonny's rules allowed. Never expected: the two lists are
    /// meant to agree, and the run stops rather than trying another way.
    case outsideCeiling(String)

    public var userMessage: String {
        switch self {
        case .appNotInstalled(let app):
            return "I couldn't find \(app) on this Mac."
        case .refusedApp(let app, _):
            return "I don't control \(app). Terminal apps are off limits."
        case .appNotSupported(let app):
            return "I can only make new notes in Notes for now, so I left \(app) alone."
        case .appControlNotAllowed(let app):
            return "I'm not allowed to control \(app) in your current mode. Allow it in Settings, or switch to Normal mode."
        case .accessibilityNotGranted:
            return "I need the Accessibility permission to work in other apps. Turn Sonny on in System Settings › Privacy & Security › Accessibility, then try again."
        case .couldNotOpen(let app):
            return "I couldn't open \(app)."
        case .noWindow(let app):
            return "\(app) didn't show a window I could work in. Open it and try again."
        case .appQuit(let app):
            return "\(app) closed while I was working in it."
        case .unreadable(let app):
            return "I couldn't read \(app)'s window."
        case .couldNotStartItem(let app, let noun):
            return "\(app) wouldn't start a new \(noun). Open an ordinary folder there, like Notes, and try again."
        case .stepNotAllowed(let app, let label):
            // A control can have no name the app exposes; quoting an empty one read as a glitch.
            let what = label.isEmpty ? "a button" : "\"\(label)\""
            return "I stopped before pressing \(what) in \(app), because it could send or change something."
        case .typedTextKept(let app):
            return "\(app) already had text there that I didn't write, so I left it alone."
        case .gaveUp(let app, let reason):
            return "I couldn't do that in \(app): \(reason)"
        case .ranOutOfSteps(let app, let steps):
            return "I couldn't finish in \(app) within \(steps) steps, so I stopped."
        case .service(let sentence):
            return sentence ?? "I couldn't reach Sonny's service to decide the next step. Try again in a moment."
        case .driverUnavailable:
            return "I couldn't start controlling other apps. Quit and reopen Sonny, then try again."
        case .outsideCeiling(let app):
            return "I stopped in \(app): that step is outside what I'm set up to do there."
        }
    }
}

// MARK: - Opening the app

/// Finds an app by the name the user said, and opens or brings it forward.
public protocol AppInteractionAppOpening: Sendable {
    func resolve(_ name: String) -> InstalledApp?
    /// Opens the app, or activates it if it is running, and returns its process.
    func open(bundleIdentifier: String) async throws -> pid_t
}

public struct LiveAppInteractionAppOpener: AppInteractionAppOpening {
    private let resolver: any InstalledAppResolving

    public init(resolver: any InstalledAppResolving = InstalledAppResolver()) {
        self.resolver = resolver
    }

    public func resolve(_ name: String) -> InstalledApp? {
        resolver.resolve(name)
    }

    public func open(bundleIdentifier: String) async throws -> pid_t {
        try await WorkspaceAppOpener().open(bundleIdentifier: bundleIdentifier)
        // `openApplication` returns once Launch Services accepted the request; the process can
        // take a moment to register.
        for _ in 0..<40 {
            try Task.checkCancellation()
            let running = await MainActor.run {
                NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
                    .first(where: { !$0.isTerminated })?.processIdentifier
            }
            if let running { return running }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw AppOpeningError.failedToOpen(bundleIdentifier)
    }
}


// MARK: - Into a run result

/// How a finished interaction reaches the rest of the app: a done outcome is a result, and every
/// other outcome is an error carrying the sentence the person sees.
public enum AppInteractionRunError: Error, LocalizedError, Equatable {
    case needsUserInput(String)
    case failed(AppInteractionFailure)
    case failedAfterChange(AppInteractionFailure, app: String, left: AppInteractionLeftBehind)

    public var errorDescription: String? {
        switch self {
        case .needsUserInput(let question):
            // Milestone A has no pause mid-run to answer into, so the question ends the run and says
            // how to go on.
            return "\(question) Ask again with the exact name and I'll try once more."
        case .failed(let failure):
            return failure.userMessage
        case .failedAfterChange(let failure, let app, let left):
            return "\(failure.userMessage) \(left.sentence(app: app))"
        }
    }
}

/// A Stop pressed after Sonny changed something in an app. The view model treats it as a
/// cancellation, and its sentence replaces the plain "Canceled." because the change is still there
/// (PR #289 review, F8).
public struct AppInteractionStoppedAfterChange: Error, LocalizedError, Equatable {
    public let app: String
    public let left: AppInteractionLeftBehind

    public init(app: String, left: AppInteractionLeftBehind) {
        self.app = app
        self.left = left
    }

    public var summary: String {
        "Stopped. \(left.sentence(app: app))"
    }
    public var errorDescription: String? { summary }
}

extension AppInteractionOutcome {
    public func runResult(plan: AgentPlan, previews: [ActionPreview]) throws -> AgentRunResult {
        switch self {
        case .done(let report):
            return AgentRunResult(plan: plan, previews: previews, summary: report.summary)
        case .needsUserInput(let question):
            throw AppInteractionRunError.needsUserInput(question)
        case .failed(let failure):
            throw AppInteractionRunError.failed(failure)
        case .failedAfterChange(let failure, let app, let left):
            throw AppInteractionRunError.failedAfterChange(failure, app: app, left: left)
        case .cancelled(let app, let left?):
            throw AppInteractionStoppedAfterChange(app: app, left: left)
        case .cancelled(_, nil):
            throw CancellationError()
        }
    }
}
