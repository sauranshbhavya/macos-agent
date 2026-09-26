import AppKit
import Foundation

/// A kernel capability that runs one of the V1 adapters' execution bodies behind a V2 typed
/// operation (V2 plan section 8: "keep 25 execute bodies as kernel capabilities").
///
/// The typed arguments become the one-step plan the adapter already understands, so its path
/// whitelisting, collision checks, previews and risk escalations all keep working unchanged. The
/// adapter's own escalations raise the operation's floor: a destructive one to `destructive`, one
/// that reaches other people to `external`.
public struct AdapterCapability: Capability {
    public let name: String
    public let version = 1
    let floor: Effect
    let adapter: any CapabilityAdapter
    /// An observe operation answered from the adapter's preview alone; nothing runs.
    let previewOnly: Bool
    let context: @MainActor @Sendable () -> CapabilityExecutionContext
    let steps: @Sendable ([String: JSONValue]) throws -> [AgentStep]
    /// What an adapter pinned the first time an action was prepared. The kernel prepares an action
    /// again just before it runs, and "in five minutes" must still mean five minutes from when Sonny
    /// first read it, or every approval that took a minute would be voided as changed.
    let pins = PreparePins()

    struct Resolved: Sendable {
        let plan: AgentPlan
        let previews: [ActionPreview]
    }

    public func prepare(actionID: ActionID, args: [String: JSONValue]) async throws -> PreparedAction {
        let steps: [AgentStep]
        do {
            steps = try self.steps(args)
        } catch let error as CapabilityPrepareError {
            throw error
        } catch {
            throw CapabilityPrepareError.invalidArguments("\(name) got arguments it can't use.")
        }
        return try await prepareOnMain(actionID: actionID, args: args, steps: steps)
    }

    @MainActor
    private func prepareOnMain(actionID: ActionID, args: [String: JSONValue], steps: [AgentStep]) throws -> PreparedAction {
        let context = self.context()
        let requested = steps
        var steps = steps
        pins.apply(to: &steps, for: actionID)
        let plan = AgentPlan(summary: name, requiresConfirmation: false, steps: steps)
        let resolved: AgentPlan
        let previews: [ActionPreview]
        let risk: CapabilityRiskAssessment
        do {
            resolved = try adapter.resolveDefaultOutputs(in: plan, context: context)
            // An adapter that needs a detail the arguments didn't give turns the step into a
            // question. Nothing runs; the question goes back as the reason, so the planner can ask it.
            if let question = resolved.steps.first(where: { $0.operation == .clarify })?.question {
                throw CapabilityPrepareError.invalidArguments(question)
            }
            previews = try adapter.preview(plan: resolved, context: context)
            risk = try adapter.assessRisk(plan: resolved, context: context)
        } catch {
            throw Self.prepareError(error)
        }
        pins.record(requested: requested, resolved: resolved.steps, for: actionID)
        var effect = floor
        for escalation in risk.escalations {
            switch escalation.consequence {
            case .destructive: effect = effect.raised(to: .destructive)
            case .affectsOthers: effect = effect.raised(to: .external)
            default: break
            }
        }
        let details = previews.flatMap { $0.details } + previews.flatMap { $0.writes.map { "Writes \($0)" } }
        return PreparedAction(
            actionID: actionID,
            effect: effect,
            targetIdentity: "\(name):" + previews.flatMap(\.writes).joined(separator: "|"),
            content: Self.canonical(args) + "\n" + details.joined(separator: "\n"),
            preview: ApprovalPreview(title: previews.first?.title ?? name, details: Array(details.prefix(12))),
            retry: .never,
            payload: Resolved(plan: resolved, previews: previews)
        )
    }

    public func execute(_ prepared: PreparedAction) async -> CapabilityOutcome {
        guard let resolved = prepared.payload as? Resolved else {
            return .failed(.executionError, "\(name) was prepared by another capability.")
        }
        if previewOnly {
            return .done(Self.evidence(summary: nil, previews: resolved.previews))
        }
        if Task.isCancelled { return .failed(.cancelled, "Stopped before \(name) ran.") }
        return await executeOnMain(resolved)
    }

    @MainActor
    private func executeOnMain(_ resolved: Resolved) async -> CapabilityOutcome {
        let context = self.context()
        do {
            let result = try await adapter.execute(plan: resolved.plan, context: context, log: { _, _ in })
            // The files Sonny made (a zip, converted PDFs, a written file) are what "recent files"
            // lists. The action already happened, so a list that can't be updated doesn't fail it.
            _ = try? context.recentArtifactStore.recordGeneratedArtifacts(from: result)
            return .done(Self.evidence(summary: result.summary, previews: result.previews))
        } catch {
            return .failed(.executionError, Self.userMessage(error))
        }
    }

    /// What the gateway reads back: the adapter's own summary and what it listed, within the
    /// contract's 2,000 characters.
    static func evidence(summary: String?, previews: [ActionPreview]) -> String {
        let lines = [summary].compactMap { $0 } + previews.flatMap { [$0.title] + $0.details }
        return String(lines.joined(separator: "\n").prefix(2000))
    }

    static func canonical(_ args: [String: JSONValue]) -> String {
        let encoder = WireCoding.encoder
        return (try? encoder.encode(args)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    static func userMessage(_ error: Error) -> String {
        let text = (error as? LocalizedError)?.errorDescription ?? "It didn't work."
        return String(text.prefix(1000))
    }

    static func prepareError(_ error: Error) -> CapabilityPrepareError {
        if let already = error as? CapabilityPrepareError { return already }
        let message = userMessage(error)
        switch error {
        case is PathValidationError:
            if case PathValidationError.notFound = error { return .targetNotFound(message) }
            return .targetRefused(message)
        default:
            return .invalidArguments(message)
        }
    }
}

/// What adapters resolve from the clock while preparing a step, kept per action so a second prepare
/// of the same action reads the same: a reminder's due time, and a default output path whose name
/// carries a timestamp. Only the most recent actions are kept.
final class PreparePins: @unchecked Sendable {
    private struct Pinned {
        var dueDates: [Date?]
        /// Each step's output path as it was asked for, and what it resolved to.
        var outputs: [(asked: String?, resolved: String?)]
    }

    private let lock = NSLock()
    private var pinned: [ActionID: Pinned] = [:]
    private var order: [ActionID] = []
    static let kept = 256

    func apply(to steps: inout [AgentStep], for action: ActionID) {
        guard let pins = lock.withLock({ pinned[action] }), pins.dueDates.count == steps.count else { return }
        for index in steps.indices {
            if steps[index].resolvedReminderDueDate == nil {
                steps[index].resolvedReminderDueDate = pins.dueDates[index]
            }
            // The same request resolves to the same file, whatever the clock says now.
            if steps[index].outputPath == pins.outputs[index].asked {
                steps[index].outputPath = pins.outputs[index].resolved
            }
        }
    }

    func record(requested: [AgentStep], resolved: [AgentStep], for action: ActionID) {
        guard requested.count == resolved.count else { return }
        let due = resolved.map(\.resolvedReminderDueDate)
        let outputs = zip(requested, resolved).map { (asked: $0.outputPath, resolved: $1.outputPath) }
        let movesAnOutput = outputs.contains { $0.asked != $0.resolved }
        guard due.contains(where: { $0 != nil }) || movesAnOutput else { return }
        lock.withLock {
            guard pinned[action] == nil else { return }
            pinned[action] = Pinned(dueDates: due, outputs: outputs)
            order.append(action)
            if order.count > Self.kept { pinned[order.removeFirst()] = nil }
        }
    }
}

/// Typed arguments, read the way each operation's contract schema says.
struct OperationArgs {
    let values: [String: JSONValue]

    init(_ values: [String: JSONValue]) {
        self.values = values
    }

    func text(_ key: String) throws -> String {
        guard case .string(let value)? = values[key], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CapabilityPrepareError.invalidArguments("\(key) is required.")
        }
        return value
    }

    func optionalText(_ key: String) throws -> String? {
        switch values[key] {
        case nil, .null?: return nil
        case .string(let value)?: return value
        default: throw CapabilityPrepareError.invalidArguments("\(key) must be text.")
        }
    }

    func optionalInt(_ key: String) throws -> Int? {
        switch values[key] {
        case nil, .null?: return nil
        case .number(let value)? where value == value.rounded(): return Int(value)
        default: throw CapabilityPrepareError.invalidArguments("\(key) must be a whole number.")
        }
    }
}

/// The V1 adapters behind the V2 operations they serve, one entry per operation.
public enum AdapterCapabilities {
    static func step(_ operation: AgentOperation, configure: (inout AgentStep) -> Void = { _ in }) -> AgentStep {
        var step = AgentStep(id: UUID().uuidString, operation: operation, description: operation.rawValue)
        configure(&step)
        return step
    }

    public static func all(
        context: @escaping @MainActor @Sendable () -> CapabilityExecutionContext,
        finderRevealer: @escaping RevealInFinderCapabilityAdapter.Reveal
    ) -> [any Capability] {
        func capability(
            _ name: String,
            _ floor: Effect,
            _ adapter: any CapabilityAdapter,
            previewOnly: Bool = false,
            _ steps: @escaping @Sendable (OperationArgs) throws -> [AgentStep]
        ) -> AdapterCapability {
            AdapterCapability(
                name: name,
                floor: floor,
                adapter: adapter,
                previewOnly: previewOnly,
                context: context,
                steps: { try steps(OperationArgs($0)) }
            )
        }

        return [
            capability("switch_app", .navigate, RunningAppSwitchCapabilityAdapter()) { args in
                let app = try args.text("app")
                return [step(.switchRunningApp) { $0.appName = app }]
            },
            capability("open_url", .navigate, OpenSafeURLCapabilityAdapter()) { args in
                let url = try args.text("url")
                let browser = try args.optionalText("browser")
                return [step(.openURL) { $0.targetURL = url; $0.browserName = browser }]
            },
            capability("open_app_search", .navigate, OpenAppSearchURLCapabilityAdapter()) { args in
                let app = try args.text("app")
                let query = try args.text("query")
                return [step(.openAppSearchURL) { $0.appName = app; $0.searchQuery = query }]
            },
            capability("play_media", .navigate, OpenMediaResultCapabilityAdapter()) { args in
                guard let provider = MediaProvider(rawValue: try args.text("provider")) else {
                    throw CapabilityPrepareError.invalidArguments("provider is apple_music or spotify.")
                }
                let title = try args.text("title")
                let artist = try args.optionalText("artist")
                let url = try args.optionalText("url")
                return [step(.playMedia) {
                    $0.mediaProvider = provider
                    $0.mediaTitle = title
                    $0.mediaArtist = artist
                    $0.targetURL = url
                }]
            },
            capability("open_file", .navigate, OpenGeneratedArtifactCapabilityAdapter()) { args in
                let path = try args.text("path")
                return [step(.openGeneratedArtifact) { $0.outputPath = path }]
            },
            capability("reveal_in_finder", .navigate, RevealInFinderCapabilityAdapter(reveal: finderRevealer)) { args in
                let path = try args.text("path")
                return [step(.revealInFinder) { $0.outputPath = path }]
            },
            capability("get_finder_selection", .observe, FinderSelectionCapabilityAdapter()) { _ in
                [step(.getFinderSelection) { $0.contextSource = .finderSelection }]
            },
            capability("find_largest_files", .observe, LargestFilesZipCapabilityAdapter(), previewOnly: true) { args in
                let folder = try args.text("folder")
                let count = try args.optionalInt("count")
                return [step(.scanSelectLargestFiles) { $0.inputPath = folder; $0.count = count }]
            },
            capability("zip_largest_files", .create, LargestFilesZipCapabilityAdapter()) { args in
                let folder = try args.text("folder")
                let count = try args.optionalInt("count")
                let output = try args.optionalText("output_path")
                return [
                    step(.scanSelectLargestFiles) { $0.inputPath = folder; $0.count = count },
                    step(.createZip) { $0.outputPath = output },
                ]
            },
            capability("find_docx", .observe, DocxConversionCapabilityAdapter(), previewOnly: true) { args in
                let folder = try args.text("folder")
                return [step(.scanDocx) { $0.inputPath = folder }]
            },
            capability("convert_docx_to_pdf", .create, DocxConversionCapabilityAdapter()) { args in
                let folder = try args.text("folder")
                let output = try args.optionalText("output_folder")
                return [step(.scanDocx) { $0.inputPath = folder }, step(.convertDocxToPDF) { $0.outputPath = output }]
            },
            capability("write_file", .create, CreateLocalDraftCapabilityAdapter()) { args in
                let content = try args.text("content")
                let title = try args.optionalText("title")
                let path = try args.optionalText("path")
                return [step(.createLocalDraft) { $0.draftContent = content; $0.draftTitle = title; $0.outputPath = path }]
            },
            capability("rename", .destructive, RenameCapabilityAdapter()) { args in
                let path = try args.text("path")
                let name = try args.text("new_name")
                return [step(.rename) { $0.inputPath = path; $0.newName = name }]
            },
            capability("read_calendar", .observe, ReadCalendarEventsCapabilityAdapter()) { args in
                let day = try args.optionalText("day")
                return [step(.readCalendarEvents) { $0.calendarDay = day }]
            },
            capability("create_reminder", .create, CreateReminderCapabilityAdapter()) { args in
                let title = try args.text("title")
                let minutes = try args.optionalInt("minutes_from_now")
                let time = try args.optionalText("time")
                let day = try args.optionalText("day")
                return [step(.createReminder) {
                    $0.reminderTitle = title
                    $0.reminderMinutesFromNow = minutes
                    $0.reminderTime = time
                    $0.calendarDay = day
                }]
            },
            capability("run_shortcut", .unknown, InvokeShortcutCapabilityAdapter()) { args in
                let name = try args.text("name")
                let input = try args.optionalText("input")
                return [step(.invokeShortcut) { $0.shortcutName = name; $0.shortcutInput = input }]
            },
            capability("save_snippet", .editLocal, SnippetSaveCapabilityAdapter()) { args in
                let trigger = try args.text("trigger")
                let text = try args.text("text")
                return [step(.saveSnippet) { $0.searchQuery = trigger; $0.draftContent = text }]
            },
            capability("check_permissions", .observe, PermissionReadinessCapabilityAdapter()) { _ in
                [step(.showPermissionReadiness)]
            },
            capability("start_watching", .create, StandingWatcherCapabilityAdapter()) { args in
                let url = try args.text("url")
                let subject = try args.text("subject")
                return [step(.startWatching) { $0.targetURL = url; $0.watchSubject = subject }]
            },
        ]
    }
}

/// Every typed operation this Mac serves, as the manifest declares them.
public enum StandardCapabilities {
    public static func all(
        context: @escaping @MainActor @Sendable () -> CapabilityExecutionContext,
        // The app hands in the live reveal; nothing in this package names it (SONNY-395).
        finderRevealer: @escaping RevealInFinderCapabilityAdapter.Reveal,
        routines: RoutineGoalStore,
        appleScript: any AppleScriptRunning = OsascriptRunner(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> KernelCapabilities {
        KernelCapabilities(
            [OpenAppCapability(focus: { context().focusRestorer }), SaveRoutineCapability(store: routines, now: now)]
                + AdapterCapabilities.all(context: context, finderRevealer: finderRevealer)
                + MailCapabilities.all(runner: appleScript)
        )
    }
}
