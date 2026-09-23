import AppKit
import Foundation

/// Runs one `AppInteractionGoal` from start to an honest outcome (V2 plan, Milestone A).
///
/// This is the single owner of the new path's execution: it resolves the app, applies the gates,
/// runs the observe → choose → check → act loop, and verifies the result itself. The UI submits a
/// goal and renders the outcome; nothing here reads which window or task has focus. Cancellation
/// is the calling task's: every loop turn, every wait and every action checks it, and an outcome
/// reached after Sonny typed something says so, because the text stays in the app.
public struct AppInteractionRuntime: Sendable {
    public struct Budget: Equatable, Sendable {
        /// Steps, counting every model decision, including ones that were refused or failed.
        public var maxSteps = 12
        /// How long to wait for a just-opened app to show a window.
        public var windowWait: Duration = .seconds(8)
        public var windowPoll: Duration = .milliseconds(250)
        /// Pause after an action so the app can redraw before the next observation.
        public var settle: Duration = .milliseconds(350)

        public init() {}
    }

    /// The apps Milestone A runs in, lowercased: WhatsApp's native app and its older Electron build.
    /// The policy's rules are shaped by one chat app, and a web view or a call-centred app breaks
    /// their assumptions, so every other app is refused by name until a later milestone widens this
    /// with evidence (PR #289 review, F6).
    public static let milestoneAApps: Set<String> = ["net.whatsapp.whatsapp", "desktop.whatsapp"]

    private let accessibility: any AccessibilityProviding
    private let chooser: any AppInteractionStepChoosing
    private let apps: any AppInteractionAppOpening
    private let appControl: @Sendable (String) async -> AppControlStanding
    private let supportedApps: Set<String>
    private let screenBuilder: AppInteractionScreenBuilder
    private let budget: Budget
    private let sleep: @Sendable (Duration) async throws -> Void

    public init(
        accessibility: any AccessibilityProviding,
        chooser: any AppInteractionStepChoosing,
        apps: any AppInteractionAppOpening,
        appControl: @escaping @Sendable (String) async -> AppControlStanding,
        redact: @escaping @Sendable (String) -> String,
        supportedApps: Set<String> = AppInteractionRuntime.milestoneAApps,
        budget: Budget = Budget(),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.accessibility = accessibility
        self.chooser = chooser
        self.apps = apps
        self.appControl = appControl
        self.supportedApps = Set(supportedApps.map { $0.lowercased() })
        self.screenBuilder = AppInteractionScreenBuilder(redact: redact)
        self.budget = budget
        self.sleep = sleep
    }

    /// What a run has done so far, kept outside the loop so a stop can report it.
    private struct Progress {
        var appName: String?
        /// Everything Sonny set as a field's value, so the policy can tell its own text from the
        /// person's (PR #289 review, F8).
        var written: Set<String> = []
        var typed: Bool { !written.isEmpty }
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
            return .cancelled(typedSomething: progress.typed, app: progress.appName ?? goal.app)
        } catch let error as AppInteractionStop {
            outcome = error.outcome
        } catch {
            if SonnyBackendError.isCancellation(error) {
                return .cancelled(typedSomething: progress.typed, app: progress.appName ?? goal.app)
            }
            if let backend = (error as? SonnyBackendError) ?? (error as? any CarriesBackendError)?.backendError {
                outcome = .failed(.service(SonnyBackendCopy.sentence(for: backend)))
            } else {
                outcome = .failed(.service(nil))
            }
        }
        if case .failed(let failure) = outcome, progress.typed {
            return .failedAfterTyping(failure, app: progress.appName ?? goal.app)
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
        guard supportedApps.contains(app.bundleIdentifier.lowercased()) else { return .failed(.appNotSupported(name)) }

        // `.notApplicable` cannot happen with a bundle identifier in hand; treated as a refusal so a
        // resolver change fails closed rather than open.
        switch await appControl(app.bundleIdentifier) {
        case .allowed: break
        case .needsApproval, .notApplicable: return .failed(.appControlNotAllowed(name))
        }
        guard await accessibility.isTrusted() else { return .failed(.accessibilityNotGranted) }

        try Task.checkCancellation()
        let processIdentifier: pid_t
        do {
            processIdentifier = try await apps.open(bundleIdentifier: app.bundleIdentifier)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .failed(.couldNotOpen(name))
        }
        log("Opened \(name)")

        var history: [AppInteractionHistoryEntry] = []
        for _ in 0..<budget.maxSteps {
            try Task.checkCancellation()
            let snapshot = try await observe(processIdentifier, goal: goal, appName: name)

            // Checked before asking the model, so a goal already met costs no model call — but only
            // a confirmed one. An unconfirmed placement waits for the model to say it is finished,
            // so a draft in the wrong chat gets a turn to be moved (PR #289 review, F3).
            if progress.typed, AppInteractionVerifier.check(snapshot, goal: goal) == .satisfied {
                return .done(AppInteractionReport(appName: name, goal: goal, targetConfirmed: true))
            }

            let built = screenBuilder.build(from: snapshot, goal: goal)
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
                let fresh = try await observe(processIdentifier, goal: goal, appName: name)
                if let outcome = finishedOutcome(fresh, goal: goal, appName: name, typed: progress.typed) {
                    return outcome
                }
                history.append(AppInteractionHistoryEntry(did: "said finished", result: notFinishedReason(fresh, goal: goal)))
            case .step(let kind, let ref):
                guard let id = built.references[ref] else {
                    history.append(AppInteractionHistoryEntry(did: "\(kind.rawValue) \(ref)", result: "no element has that ref"))
                    continue
                }
                let label = built.screen.candidates.first { $0.ref == ref }?.label ?? ref
                let did = "\(kind.rawValue) \(ref) (\(label))"
                switch AppInteractionPolicy.decide(kind, on: id, in: snapshot, goal: goal, sonnyWrote: progress.written) {
                case .refuse(.mightCommit):
                    // Not something to route around: the plan's rule is that a refusal is never a
                    // reason to try another way (§3).
                    return .failed(.stepNotAllowed(name, label))
                case .refuse(.wouldReplaceTypedText):
                    // The person's own words are in that box. Another box would be the wrong chat,
                    // so this ends the run rather than letting the model look elsewhere.
                    return .failed(.typedTextKept(name))
                case .refuse(let refusal):
                    history.append(AppInteractionHistoryEntry(did: did, result: "refused: \(refusal)"))
                case .allow(let action):
                    // The model call can take many seconds; a Stop pressed during it lands here,
                    // before the action rather than after it (PR #289 review, F11).
                    try Task.checkCancellation()
                    do {
                        try await accessibility.perform(action, on: id)
                        if case .setValue(let text) = action { progress.written.insert(text) }
                        log("\(kind.rawValue) on \(label)")
                        history.append(AppInteractionHistoryEntry(did: did, result: "done"))
                    } catch AccessibilityError.notTrusted {
                        return .failed(.accessibilityNotGranted)
                    } catch let error as AccessibilityError {
                        history.append(AppInteractionHistoryEntry(did: did, result: "failed: \(error)"))
                    }
                    try await sleep(budget.settle)
                }
            }
        }
        return .failed(.ranOutOfSteps(name, budget.maxSteps))
    }

    /// The model says it is finished. Sonny agrees only for text it typed itself (PR #289 review,
    /// F7), in a chat that is not visibly someone else's.
    private func finishedOutcome(
        _ snapshot: AccessibilitySnapshot,
        goal: AppInteractionGoal,
        appName: String,
        typed: Bool
    ) -> AppInteractionOutcome? {
        if goal.text != nil, !typed { return nil }
        switch AppInteractionVerifier.check(snapshot, goal: goal) {
        case .satisfied: return .done(AppInteractionReport(appName: appName, goal: goal, targetConfirmed: true))
        case .targetUnconfirmed: return .done(AppInteractionReport(appName: appName, goal: goal, targetConfirmed: false))
        case .otherTargetOpen, .notYet: return nil
        }
    }

    private func notFinishedReason(_ snapshot: AccessibilitySnapshot, goal: AppInteractionGoal) -> String {
        switch AppInteractionVerifier.check(snapshot, goal: goal) {
        case .otherTargetOpen: return "Sonny checked: a different chat is open"
        default: return "Sonny checked and the goal is not met yet"
        }
    }

    /// Observes the app's window, waiting a bounded time for one to appear after a launch.
    private func observe(
        _ processIdentifier: pid_t,
        goal: AppInteractionGoal,
        appName: String
    ) async throws -> AccessibilitySnapshot {
        var limits = AccessibilityLimits()
        // Long enough to read the whole goal text back, or verification would compare a cut copy.
        limits.maxTextLength = max(limits.maxTextLength, (goal.text?.count ?? 0) + 16)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: budget.windowWait)
        while true {
            try Task.checkCancellation()
            do {
                return try await accessibility.observe(processIdentifier: processIdentifier, limits: limits)
            } catch AccessibilityError.noWindow where clock.now < deadline {
                try await sleep(budget.windowPoll)
            } catch AccessibilityError.notTrusted {
                throw AppInteractionStop(.failed(.accessibilityNotGranted))
            } catch AccessibilityError.noWindow {
                throw AppInteractionStop(.failed(.noWindow(appName)))
            } catch AccessibilityError.appNotRunning {
                throw AppInteractionStop(.failed(.appQuit(appName)))
            } catch {
                throw AppInteractionStop(.failed(.unreadable(appName)))
            }
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

    public var summary: String {
        if let text = goal.text {
            if let target = goal.target {
                return targetConfirmed
                    ? "The message is in the \(target) chat in \(appName), not sent: \"\(text)\""
                    : "The message is in a message box in \(appName), but I couldn't see which chat is open, so check it's \(target)'s before you send: \"\(text)\""
            }
            return "The message is in \(appName), not sent: \"\(text)\""
        }
        if let target = goal.target { return "\(target) is open in \(appName)." }
        return "Done in \(appName)."
    }
}

public enum AppInteractionOutcome: Equatable, Sendable {
    case done(AppInteractionReport)
    case needsUserInput(String)
    case failed(AppInteractionFailure)
    /// A failure reached after Sonny had typed into the app: what it typed is still there, unsent.
    case failedAfterTyping(AppInteractionFailure, app: String)
    case cancelled(typedSomething: Bool, app: String)
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
    case stepNotAllowed(String, String)
    case typedTextKept(String)
    case gaveUp(String, String)
    case ranOutOfSteps(String, Int)
    /// The step route failed. Carries the backend's own user-facing sentence when there is one.
    case service(String?)

    public var userMessage: String {
        switch self {
        case .appNotInstalled(let app):
            return "I couldn't find \(app) on this Mac."
        case .refusedApp(let app, _):
            return "I don't control \(app). Terminal apps are off limits."
        case .appNotSupported(let app):
            return "I can only draft in WhatsApp for now, so I left \(app) alone."
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
        case .stepNotAllowed(let app, let label):
            return "I stopped before pressing \"\(label)\" in \(app). I can only open chats and type drafts for now, never send or change anything."
        case .typedTextKept(let app):
            return "The message box in \(app) already has something you typed, so I left it alone. Send or clear it, then ask again."
        case .gaveUp(let app, let reason):
            return "I couldn't do that in \(app): \(reason)"
        case .ranOutOfSteps(let app, let steps):
            return "I couldn't finish in \(app) within \(steps) steps, so I stopped."
        case .service(let sentence):
            return sentence ?? "I couldn't reach Sonny's service to decide the next step. Try again in a moment."
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
    case failedAfterTyping(AppInteractionFailure, app: String)

    public var errorDescription: String? {
        switch self {
        case .needsUserInput(let question):
            // Milestone A has no pause mid-run to answer into, so the question ends the run and says
            // how to go on.
            return "\(question) Ask again with the exact name and I'll try once more."
        case .failed(let failure):
            return failure.userMessage
        case .failedAfterTyping(let failure, let app):
            return "\(failure.userMessage) Anything I typed is still in \(app), unsent."
        }
    }
}

/// A Stop pressed after Sonny typed into an app. The view model treats it as a cancellation, and
/// its sentence replaces the plain "Canceled." because the text is still there (PR #289 review, F8).
public struct AppInteractionStoppedAfterTyping: Error, LocalizedError, Equatable {
    public let app: String

    public init(app: String) {
        self.app = app
    }

    public var summary: String { "Stopped. Anything I typed is still in \(app), unsent." }
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
        case .failedAfterTyping(let failure, let app):
            throw AppInteractionRunError.failedAfterTyping(failure, app: app)
        case .cancelled(typedSomething: true, let app):
            throw AppInteractionStoppedAfterTyping(app: app)
        case .cancelled(typedSomething: false, _):
            throw CancellationError()
        }
    }
}
