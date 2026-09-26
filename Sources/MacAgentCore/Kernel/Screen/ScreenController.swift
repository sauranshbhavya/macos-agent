import Foundation

/// The screen half of the kernel: it looks at an app's window for the gateway and runs screen
/// actions, both through cua-driver in Sonny's own process.
public protocol ScreenControlling: TaskObserver {
    var tools: Set<ScreenToolName> { get }
    func prepare(_ action: ScreenAction, actionID: ActionID) async throws -> PreparedAction
    func execute(_ prepared: PreparedAction) async -> CapabilityOutcome
    /// The task is over: whatever it held for its screen work is let go.
    func taskEnded() async
}

extension ScreenControlling {
    public func taskEnded() async {}
}

/// Which task's screen work is in which app. Two tasks clicking and typing in one app would mix
/// their edits, so an app belongs to one task's screen work at a time, until that task ends or
/// moves on to another app.
public actor ScreenAppClaims {
    public static let shared = ScreenAppClaims()

    private var holders: [String: ObjectIdentifier] = [:]

    public init() {}

    /// Claims the app for `owner`, letting go of any other app it held. False while another owner
    /// holds it.
    func claim(_ bundleID: String, for owner: ObjectIdentifier) -> Bool {
        let key = bundleID.lowercased()
        if let holder = holders[key], holder != owner { return false }
        holders = holders.filter { $0.value != owner }
        holders[key] = owner
        return true
    }

    func release(_ owner: ObjectIdentifier) {
        holders = holders.filter { $0.value != owner }
    }
}

/// One task's screen control (V2 plan section 6, `ScreenCapability`).
///
/// Every look gets a generation, and an element ref means something only in the generation it was
/// read in: an action naming a ref from an older look is refused as stale rather than aimed at
/// whatever now sits there. cua runs under a manifest built for this task's app alone, and a menu
/// action is checked here too, because cua does not tie menus to the manifest's app.
public actor ScreenController: ScreenControlling {
    public struct Dependencies: Sendable {
        public var driver: @Sendable (CuaCapabilityManifest) throws -> any CuaToolInvoking
        public var apps: any ScreenApps
        public var screenshots: any WindowScreenshotting
        public var standing: @Sendable (String) -> AppStanding
        public var lease: ForegroundLease
        public var claims: ScreenAppClaims
        public var attention: any SessionAttentionMonitoring
        public var focusReturn: FocusReturn
        public var ownPID: pid_t

        public init(
            driver: @escaping @Sendable (CuaCapabilityManifest) throws -> any CuaToolInvoking,
            apps: any ScreenApps = WorkspaceScreenApps(),
            screenshots: any WindowScreenshotting = RedactedWindowScreenshots(),
            standing: @escaping @Sendable (String) -> AppStanding = ScreenController.defaultStanding,
            lease: ForegroundLease = .shared,
            claims: ScreenAppClaims = .shared,
            attention: any SessionAttentionMonitoring = SystemSessionAttentionMonitor(),
            focusReturn: FocusReturn = .shared,
            ownPID: pid_t = getpid()
        ) {
            self.driver = driver
            self.apps = apps
            self.screenshots = screenshots
            self.standing = standing
            self.lease = lease
            self.claims = claims
            self.attention = attention
            self.focusReturn = focusReturn
            self.ownPID = ownPID
        }
    }

    /// Nodes sent per look unless the gateway asks for fewer.
    public static let defaultMaxNodes = 400
    /// Characters of labels and values sent per look; past it the tree is marked cut short.
    public static let textBudget = 40_000
    /// Windows smaller than this on either edge are toolbar strips and panels, not the app's window.
    static let minimumWindowEdge: Double = 120

    public nonisolated let tools: Set<ScreenToolName> = Set(ScreenToolName.allCases)

    struct Session {
        let app: ScreenApp
        let pid: pid_t
        let client: CuaDriverClient
    }

    struct Look {
        let generation: Int
        let windowID: Int
        let state: CuaWindowState
        let elements: [String: CuaElement]
        let secureRefs: Set<String>
        let windowFrame: WireRect
        let screenshotSize: (width: Int, height: Int)?
        let hasTextInput: Bool
    }

    struct Planned: Sendable {
        let action: CuaAction
        let pid: pid_t
        let windowID: Int
        /// For set_value: the field was empty, so typing into it is the same edit.
        let typeFallback: CuaAction?
    }

    private let deps: Dependencies
    private var session: Session?
    /// The app this task's screen work last brought forward. When the work ends, the person's own
    /// app comes back only if this one is still in front.
    private var workedIn: pid_t?
    private var looks: [Int: Look] = [:]
    private var latest = 0

    public init(dependencies: Dependencies) {
        self.deps = dependencies
    }

    /// Terminals and shells are refused; the starter list is allowed; anything else needs the user.
    public static let defaultStanding: @Sendable (String) -> AppStanding = { bundleID in
        if ScreenControlPolicy.verdict(bundleIdentifier: bundleID, displayName: bundleID).refusal != nil { return .refused }
        if AppControlStarterList.bundleIdentifiers.contains(ScreenControlPolicy.normalize(bundleID)) { return .allowed }
        return .notAllowed
    }

    // MARK: Looking

    public func observe(_ request: ObserveBody, generation: Int) async -> ObservationBody {
        @Sendable func failure(_ code: ObservationBody.ErrorCode, _ message: String) -> ObservationBody {
            ObservationBody(generation: generation, error: .init(code: code, message: message))
        }
        guard let app = await deps.apps.resolve(request.app) else {
            return failure(.appNotRunning, "No installed app matches \(request.app).")
        }
        guard let pid = app.pid else { return failure(.appNotRunning, "\(app.name) isn't running.") }
        // Terminals and script editors are refused before anything of them is read (V2 plan 7.2).
        if deps.standing(app.bundleID) == .refused {
            return failure(.appRefused, "Sonny doesn't work in \(app.name).")
        }
        guard await deps.claims.claim(app.bundleID, for: ObjectIdentifier(self)) else {
            return failure(.foregroundUnavailable, "Another Sonny task is working in \(app.name). Try again when it has finished.")
        }
        let current: Session
        do {
            current = try sessionFor(app, pid: pid)
        } catch {
            return failure(.unreadable, "Sonny's screen control could not start.")
        }
        do {
            guard try await current.client.accessibilityGranted() else {
                return failure(.permissionDenied, "Sonny needs Accessibility permission to work in apps.")
            }
        } catch {
            return failure(.permissionDenied, "Sonny couldn't check its Accessibility permission.")
        }

        return await deps.lease.hold { [deps] in
            // Checked inside the lease, right before anything moves: a wait for another task's turn
            // can outlast the moment someone locked the screen.
            if let reason = await deps.attention.attention().stopReason {
                return failure(.foregroundUnavailable, reason)
            }
            await self.noteWhereThePersonWas(beforeActivating: pid)
            guard await deps.apps.activate(pid: pid) else {
                return failure(.foregroundUnavailable, "\(app.name) couldn't be brought to the front.")
            }
            return await self.read(request, app: app, pid: pid, client: current.client, generation: generation)
        }
    }

    public func taskEnded() async {
        await deps.claims.release(ObjectIdentifier(self))
        session = nil
        looks = [:]
        await giveThePersonTheirAppBack()
    }

    /// Tells the shared record this task's screen work is bringing an app forward; the first such
    /// work notes the app the person was in. Sonny's own window doesn't count.
    private func noteWhereThePersonWas(beforeActivating pid: pid_t) async {
        workedIn = pid
        await deps.focusReturn.begin(ObjectIdentifier(self), front: await deps.apps.frontmostPID(), target: pid, ownPID: deps.ownPID)
    }

    /// When the last task's screen work is done, the person's app comes back, unless they have
    /// already moved on to something else themselves.
    private func giveThePersonTheirAppBack() async {
        guard let workedIn else { return }
        self.workedIn = nil
        guard let personApp = await deps.focusReturn.end(ObjectIdentifier(self)) else { return }
        await deps.lease.hold { [deps] in
            guard await deps.apps.frontmostPID() == workedIn else { return }
            _ = await deps.apps.activate(pid: personApp)
        }
    }

    private func sessionFor(_ app: ScreenApp, pid: pid_t) throws -> Session {
        if let session, session.app.bundleID == app.bundleID, session.pid == pid { return session }
        let invoker = try deps.driver(.forApp(app.bundleID))
        let fresh = Session(app: app, pid: pid, client: CuaDriverClient(invoker: invoker))
        session = fresh
        looks = [:]
        return fresh
    }

    private func read(_ request: ObserveBody, app: ScreenApp, pid: pid_t, client: CuaDriverClient, generation: Int) async -> ObservationBody {
        func failure(_ code: ObservationBody.ErrorCode, _ message: String) -> ObservationBody {
            ObservationBody(generation: generation, error: .init(code: code, message: message))
        }
        let windows: [CuaWindow]
        do {
            windows = try await client.windows(pid: pid)
        } catch {
            return failure(.unreadable, "Sonny couldn't list \(app.name)'s windows.")
        }
        let usable = windows
            .filter { $0.isOnScreen && ($0.bounds?.width ?? 0) >= Self.minimumWindowEdge && ($0.bounds?.height ?? 0) >= Self.minimumWindowEdge }
            .sorted { $0.area > $1.area }
        guard let window = usable.first else { return failure(.noWindow, "\(app.name) has no window open.") }

        var state: CuaWindowState?
        for attempt in 0..<2 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 300_000_000) }
            state = try? await client.windowState(pid: pid, windowID: window.windowID)
            if let state, !state.elements.isEmpty { break }
        }

        // A shell showing inside an allowed app (an editor's terminal, a web console) is refused the
        // same way: nothing of the window leaves, and no earlier look of it can be acted on.
        if let state, Self.showsShell(state) {
            await refuseForShell()
            return failure(.appRefused, Self.shellRefusal(app))
        }

        var tree: ObservationBody.Tree?
        var elements: [String: CuaElement] = [:]
        var secureRefs: Set<String> = []
        var hasTextInput = false
        if request.ax, let state, !state.elements.isEmpty {
            let built = Self.tree(from: state, maxNodes: min(request.maxNodes ?? Self.defaultMaxNodes, 2000))
            tree = built.tree
            elements = built.elements
            secureRefs = built.secureRefs
            hasTextInput = built.hasTextInput
        }

        var screenshot: ObservationBody.Screenshot?
        if request.screenshot {
            do {
                screenshot = try await deps.screenshots.screenshot(bundleID: app.bundleID)
            } catch ScreenshotRefusal.shellOnScreen {
                await refuseForShell()
                return failure(.appRefused, Self.shellRefusal(app))
            } catch {
                screenshot = nil
            }
        }
        if tree == nil && screenshot == nil {
            return failure(.unreadable, "Sonny couldn't read \(app.name)'s window.")
        }

        let bounds = window.bounds
        let frame = WireRect(x: bounds?.x ?? 0, y: bounds?.y ?? 0, w: bounds?.width ?? 0, h: bounds?.height ?? 0)
        looks[generation] = Look(
            generation: generation,
            windowID: window.windowID,
            state: state ?? CuaWindowState(snapshotID: nil, windowID: window.windowID, elements: []),
            elements: elements,
            secureRefs: secureRefs,
            windowFrame: frame,
            screenshotSize: screenshot.map { ($0.width, $0.height) },
            hasTextInput: hasTextInput
        )
        latest = generation
        looks = looks.filter { $0.key > generation - 3 }

        return ObservationBody(
            generation: generation,
            app: .init(bundleID: app.bundleID, name: app.name, pid: Int(pid)),
            window: .init(id: window.windowID, title: state?.windowTitle.map { Self.masked($0, limit: 500) }, frame: frame),
            ax: tree,
            screenshot: screenshot
        )
    }

    static let textRoles: Set<String> = ["AXTextArea", "AXTextField", "AXSearchField", "AXComboBox", "AXSecureTextField"]

    /// Whether the window's own text shows a shell. The text is read here and never leaves.
    static func showsShell(_ state: CuaWindowState) -> Bool {
        let text = ([state.windowTitle] + state.elements.flatMap { [$0.label, $0.value] })
            .compactMap { $0 }
            .joined(separator: "\n")
        return ShellSurfaceDetector.verdict(for: text).showsShell
    }

    /// Nothing of a window showing a shell can be acted on, and the app isn't kept from other
    /// tasks while this one moves on.
    private func refuseForShell() async {
        looks = [:]
        latest = 0
        session = nil
        await deps.claims.release(ObjectIdentifier(self))
    }

    static func shellRefusal(_ app: ScreenApp) -> String {
        "A shell is showing in \(app.name), and Sonny doesn't work in shells."
    }

    static func isSecure(_ element: CuaElement) -> Bool {
        if element.role.localizedCaseInsensitiveContains("secure") { return true }
        let label = element.label?.lowercased() ?? ""
        return textRoles.contains(element.role) && ["password", "passcode", "passwort", "mot de passe"].contains(where: label.contains)
    }

    /// Secrets never leave the Mac (V2 plan section 7.4): a detected secret is masked, a secure
    /// field's value is never read out, and every field is cut to the contract's length.
    static func masked(_ text: String, limit: Int) -> String {
        let detector = SecretTextDetector()
        let masked = SecretTextDetector.mask(matches: detector.matches(in: text), in: text)
        return String(masked.unicodeScalars.prefix(limit).map(Character.init))
    }

    static func tree(from state: CuaWindowState, maxNodes: Int) -> (tree: ObservationBody.Tree, elements: [String: CuaElement], secureRefs: Set<String>, hasTextInput: Bool) {
        let byIndex = Dictionary(state.elements.map { ($0.index, $0) }, uniquingKeysWith: { first, _ in first })
        var depths: [Int: Int] = [:]
        func depth(_ element: CuaElement) -> Int {
            if let known = depths[element.index] { return known }
            var value = 0
            var next = element.parentIndex
            var seen: Set<Int> = [element.index]
            while let index = next, let parent = byIndex[index], !seen.contains(index), value < 64 {
                seen.insert(index)
                value += 1
                next = parent.parentIndex
            }
            depths[element.index] = value
            return value
        }

        var nodes: [AXNode] = []
        var elements: [String: CuaElement] = [:]
        var secureRefs: Set<String> = []
        var budget = textBudget
        var truncated = false
        var hasTextInput = false
        for element in state.elements.sorted(by: { $0.index < $1.index }) {
            guard nodes.count < maxNodes, element.index < 100_000 else {
                truncated = true
                break
            }
            let ref = "e\(element.index)"
            let secure = isSecure(element)
            if textRoles.contains(element.role) { hasTextInput = true }
            var label = element.label.map { masked($0, limit: 500) }
            var value = secure ? nil : element.value.map { masked($0, limit: 2000) }
            let cost = (label?.count ?? 0) + (value?.count ?? 0)
            if cost > budget {
                truncated = true
                label = label.map { String($0.prefix(80)) }
                value = nil
            }
            budget = max(0, budget - cost)
            nodes.append(AXNode(
                ref: ref,
                depth: depth(element),
                role: String(element.role.prefix(64)),
                label: label,
                value: value,
                enabled: element.enabled,
                selected: element.selected,
                secure: secure ? true : nil,
                frame: element.frame.map { WireRect(x: $0.x, y: $0.y, w: max(0, $0.w), h: max(0, $0.h)) },
                actions: element.actions.isEmpty ? nil : Array(element.actions.prefix(8).map { String($0.prefix(64)) })
            ))
            elements[ref] = element
            if secure { secureRefs.insert(ref) }
        }
        return (ObservationBody.Tree(nodes: nodes, truncated: truncated), elements, secureRefs, hasTextInput)
    }

    // MARK: Acting

    public func prepare(_ action: ScreenAction, actionID: ActionID) async throws -> PreparedAction {
        guard let session, let look = looks[latest] else {
            throw CapabilityPrepareError.stale("Sonny hasn't looked at the window yet.")
        }
        let requested = await deps.apps.resolve(action.app)
        guard requested?.bundleID == session.app.bundleID else {
            throw CapabilityPrepareError.targetRefused("Sonny acts only in the app it looked at, \(session.app.name).")
        }
        let appName = session.app.name

        func element(_ ref: ElementRef) throws -> (String, CuaElement) {
            guard ref.generation == latest else {
                throw CapabilityPrepareError.stale("\(ref.ref) is from an earlier look at the window.")
            }
            guard let found = look.elements[ref.ref] else {
                throw CapabilityPrepareError.stale("\(ref.ref) isn't in the window any more.")
            }
            return (ref.ref, found)
        }
        func cuaRef(_ element: CuaElement) -> CuaElementRef {
            CuaElementRef(element, in: look.state)
        }
        func words(_ element: CuaElement) -> [String] {
            [element.label, element.value].compactMap { $0 }
        }

        let cua: CuaAction
        var fallback: CuaAction?
        let floor: Effect
        var facts = RaiseFacts()
        let target: String
        let content: String
        let preview: ApprovalPreview

        switch action {
        case .press(_, let ref):
            let (id, found) = try element(ref)
            cua = .click(cuaRef(found))
            floor = .navigate
            facts.targetWords = words(found)
            target = id
            content = found.label ?? found.role
            preview = ApprovalPreview(title: "Press \"\(found.label ?? found.role)\" in \(appName)")
        case .setValue(_, let ref, let value):
            let (id, found) = try element(ref)
            cua = .setValue(cuaRef(found), value)
            if (found.value ?? "").isEmpty { fallback = .typeText(cuaRef(found), value) }
            floor = .editLocal
            facts.text = value
            facts.targetIsSecure = look.secureRefs.contains(id)
            facts.targetWords = [found.label].compactMap { $0 }
            target = id
            content = value
            preview = ApprovalPreview(title: "Fill in \"\(found.label ?? found.role)\" in \(appName)", details: [value])
        case .typeText(_, let text, let ref):
            if let ref {
                let (id, found) = try element(ref)
                cua = .typeText(cuaRef(found), text)
                facts.targetIsSecure = look.secureRefs.contains(id)
                facts.targetWords = [found.label].compactMap { $0 }
                target = id
            } else {
                cua = .typeAtFocus(text)
                target = "focus"
            }
            floor = .editLocal
            facts.text = text
            facts.keyChord = text.hasSuffix("\n") ? ["return"] : nil
            facts.focusedTakesText = text.hasSuffix("\n")
            content = text
            preview = ApprovalPreview(title: "Type in \(appName)", details: [text])
        case .key(_, let keys):
            cua = keys.count == 1 ? .pressKey(keys[0]) : .hotkey(keys)
            floor = .navigate
            facts.keyChord = keys
            // cua doesn't say which element has focus, so a window with any text input is treated
            // as if one were focused: Return there may submit, and is raised to external.
            facts.focusedTakesText = look.hasTextInput
            target = "keys"
            content = keys.joined(separator: "+")
            preview = ApprovalPreview(title: "Press \(keys.joined(separator: "+")) in \(appName)")
        case .scroll(_, let direction, _, let ref):
            let found = try ref.map { try element($0).1 }
            cua = .scroll(found.map(cuaRef), direction: direction.rawValue)
            floor = .navigate
            target = "scroll"
            content = direction.rawValue
            preview = ApprovalPreview(title: "Scroll \(direction.rawValue) in \(appName)")
        case .menu(_, let path):
            // cua does not tie invoke_menu to the manifest's app (V2 plan section 12), so the app is
            // checked here: the look's own process, never Sonny's.
            guard session.pid != deps.ownPID else {
                throw CapabilityPrepareError.targetRefused("Sonny doesn't use its own menus.")
            }
            cua = .menu(path)
            floor = .navigate
            facts.targetWords = path
            target = "menu"
            content = path.joined(separator: " › ")
            preview = ApprovalPreview(title: "Choose \(path.joined(separator: " › ")) in \(appName)")
        case .clickPoint(_, let x, let y, let generation, _):
            guard generation == latest, let size = look.screenshotSize, size.width > 0, size.height > 0 else {
                throw CapabilityPrepareError.stale("That point is from an earlier look at the window.")
            }
            let frame = look.windowFrame
            let pointX = frame.x + x * frame.w / Double(size.width)
            let pointY = frame.y + y * frame.h / Double(size.height)
            let hits = look.elements.values
                .filter { $0.frame?.contains(x: pointX, y: pointY) ?? false }
                .sorted { ($0.frame!.w * $0.frame!.h) < ($1.frame!.w * $1.frame!.h) }
            guard let hit = hits.first else {
                throw CapabilityPrepareError.targetNotFound("Nothing Sonny can press is at that point.")
            }
            cua = .click(cuaRef(hit))
            floor = .navigate
            facts.targetWords = words(hit)
            target = "e\(hit.index)"
            content = hit.label ?? hit.role
            preview = ApprovalPreview(title: "Click \"\(hit.label ?? hit.role)\" in \(appName)")
        }

        return PreparedAction(
            actionID: actionID,
            effect: floor,
            targetIdentity: "\(session.app.bundleID):\(look.windowID):\(target)",
            content: content,
            preview: preview,
            retry: .never,
            raiseFacts: facts,
            standing: deps.standing(session.app.bundleID),
            payload: Planned(action: cua, pid: session.pid, windowID: look.windowID, typeFallback: fallback)
        )
    }

    public func execute(_ prepared: PreparedAction) async -> CapabilityOutcome {
        guard let planned = prepared.payload as? Planned, let session else {
            return .failed(.executionError, "The screen action was prepared for another window.")
        }
        let client = session.client
        return await deps.lease.hold { [deps] in
            if let reason = await deps.attention.attention().stopReason {
                return .failed(.foregroundUnavailable, reason)
            }
            await self.noteWhereThePersonWas(beforeActivating: planned.pid)
            guard await deps.apps.activate(pid: planned.pid) else {
                return .failed(.foregroundUnavailable, "The app couldn't be brought to the front.")
            }
            do {
                let report = try await client.perform(planned.action, pid: planned.pid, windowID: planned.windowID)
                return .done(report.evidence)
            } catch let error as CuaToolError {
                if let fallback = planned.typeFallback, error.message.localizedCaseInsensitiveContains("not settable") {
                    if let report = try? await client.perform(fallback, pid: planned.pid, windowID: planned.windowID) {
                        return .done(report.evidence + " (typed, because the field could not be set)")
                    }
                }
                if error.isOutsideCeiling {
                    return CapabilityOutcome(status: .refused, error: OutcomeError(code: .targetRefused, message: "cua refused it: outside this task's app."))
                }
                if error.message.localizedCaseInsensitiveContains("stale") {
                    return CapabilityOutcome(status: .stale, error: OutcomeError(code: .staleReference, message: "The window changed; look again."))
                }
                // cua refused the call before acting, so nothing happened.
                return .failed(.executionError, error.message)
            } catch is CancellationError {
                return .failed(.cancelled, "Stopped.")
            } catch {
                // The call went out and no answer came back: it may or may not have happened.
                return CapabilityOutcome(
                    status: .outcomeUnknown,
                    error: OutcomeError(code: .executionError, message: "Sonny couldn't tell whether this happened.")
                )
            }
        }
    }
}
