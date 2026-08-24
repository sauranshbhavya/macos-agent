import Foundation

/// What a workspace's restriction scope says about one resource a plan touches.
///
/// Four-valued on purpose, and the fourth value is not fussiness. Both two-valued readings fail
/// against workspaces that already exist on disk: "an empty list denies everything of its kind"
/// would escalate every file action in every workspace on the day file scoping ships (no stored
/// workspace has file locations — the field is new), while "an empty list allows everything" would
/// blanket-bless every path on the machine, which is the exact hazard workspace scoping exists to
/// prevent. Workspace creation requires *at least one* of apps or URLs — `guard !apps.isEmpty ||
/// !urls.isEmpty` throws only when both are empty — so apps-only, URLs-only and both-populated are
/// all normal persisted states, and a two-valued model breaks the first two on the kind they never
/// declared.
public enum ScopeVerdict: String, Codable, Equatable, Sendable, CaseIterable {
    /// The resource matches an entry in the workspace's list for its kind.
    case inScope
    /// That kind *is* configured on this workspace, and the resource matches nothing in it.
    case outOfScope
    /// That kind is not configured on this workspace. Neither permission nor prohibition: it
    /// produces no escalation.
    case unconstrained
    /// The resource cannot be named before execution — a Shortcut's internals, the URLs a web search
    /// has yet to return. It never escalates on scope grounds, because there is nothing to compare,
    /// and it poisons the plan-level roll-up.
    case opaque
}

public enum ScopedResourceKind: String, Codable, Equatable, Sendable, CaseIterable {
    case app
    case webDomain
    case fileLocation
}

/// One thing a plan step will touch, carried in the form the workspace's own lists are compared
/// against.
public enum ScopedResource: Equatable, Hashable, Sendable {
    /// A human app name as a user would type it — canonicalized through the alias table and the
    /// installed-app resolver before matching, never compared raw.
    case app(String)
    /// An app already resolved to its real running identity (SONNY-58): matched by bundle
    /// identifier first, then by the name-fallback key of entries that could not be keyed by bundle —
    /// never by re-resolving the display name, which would hand any app that merely *calls itself*
    /// "Chrome" the real Chrome's scope membership. SONNY-84 shrank what the fallback can reach: an
    /// entry naming any *installed* app now keys by bundle identifier, not just a cataloged one. Built only from a pinned `switch_running_app` step, where the
    /// bundle identifier is the ground truth and the display name exists for the user-facing
    /// sentence.
    case resolvedApp(bundleIdentifier: String, displayName: String)
    /// A host, not a full URL. Whoever builds the resource extracts the host; `WorkspaceScope` only
    /// normalizes it.
    case webDomain(String)
    /// A raw path. Canonicalized through `PathWhitelist` before matching.
    case fileLocation(String)

    public var kind: ScopedResourceKind {
        switch self {
        case .app, .resolvedApp:
            return .app
        case .webDomain:
            return .webDomain
        case .fileLocation:
            return .fileLocation
        }
    }

    /// The user-facing value — for a resolved app, the display name, so an escalation reads
    /// "Xcode is not part of …" rather than naming a bundle identifier.
    public var value: String {
        switch self {
        case .app(let value), .webDomain(let value), .fileLocation(let value):
            return value
        case .resolvedApp(_, let displayName):
            return displayName
        }
    }
}

/// A workspace entry that survived into the scope but can never match anything.
///
/// Exactly three things become inert, and it is worth being precise because the list is shorter than
/// it looks: a file location `PathWhitelist` rejects (the whole reason this type exists — scope
/// narrows the global whitelist and never widens it), a URL `SafeURL` rejects or that carries no
/// host, and a blank app name. An app name that resolves to nothing installed is **not** inert — it
/// falls back to a normalized-name key and still matches, which is what keeps Microsoft Word,
/// running-app switches and any app the user has not installed inside scope checking at all.
///
/// Reported rather than dropped so that a boundary which quietly does nothing is at least
/// observable. **Nothing consumes this yet** — no ticket in this module requires a surface for it,
/// and this ticket ships no UI. It exists so the configuration work (SONNY-40's `edit_workspace`,
/// SONNY-41's detail sheet) can warn at the point the boundary is typed rather than rediscovering
/// the rule, and so a dropped entry is never mistaken for one that matched nothing.
public struct WorkspaceScopeInertEntry: Equatable, Sendable {
    public let kind: ScopedResourceKind
    public let value: String
    public let reason: String

    public init(kind: ScopedResourceKind, value: String, reason: String) {
        self.kind = kind
        self.value = value
        self.reason = reason
    }
}

/// A workspace's contents, canonicalized once into the three lists a scope check compares against.
///
/// `apps` and `urls` are reused as the scope rather than paired with separate `scopeApps` /
/// `scopeDomains` lists: two 95%-identical lists is a DRY violation at the product level and a
/// guaranteed source of "why did it prompt, it's right there in my workspace."
public struct WorkspaceScope: Equatable, Sendable {
    /// The workspace's stored display name, for whoever words the escalation.
    public let workspaceName: String
    /// Canonical app keys — see `appKey(for:catalog:resolver:)` for what makes a key.
    public let appKeys: [String]
    /// Hosts derived from the stored full URLs: lowercased, trailing dots and a leading `www.`
    /// removed.
    public let webDomains: [String]
    /// Canonical roots, already proven admissible to the global `PathWhitelist`.
    public let fileRoots: [URL]
    /// Entries that were configured but can never match. Never silently dropped.
    public let inertEntries: [WorkspaceScopeInertEntry]

    private let catalog: MacAppCatalog
    /// Kept because `verdict(for: .app(_:))` canonicalizes the *queried* name at evaluate time, and
    /// it must go through the identical three stages the stored entries went through — a scope that
    /// keyed its entries one way and its queries another would answer questions about a different
    /// workspace than the one on disk.
    private let resolver: any InstalledAppResolving

    /// Written out rather than synthesized, because `resolver` is an existential and existentials are
    /// not `Equatable`. Every member the synthesized version compared is still compared; only the
    /// collaborator is left out, which is right on its own terms — two scopes holding the same
    /// canonical keys *are* the same boundary, whichever resolver derived them.
    public static func == (lhs: WorkspaceScope, rhs: WorkspaceScope) -> Bool {
        lhs.workspaceName == rhs.workspaceName
            && lhs.appKeys == rhs.appKeys
            && lhs.webDomains == rhs.webDomains
            && lhs.fileRoots == rhs.fileRoots
            && lhs.inertEntries == rhs.inertEntries
            && lhs.catalog == rhs.catalog
    }

    /// Builds the scope, canonicalizing every entry once.
    ///
    /// File locations are validated against `whitelist` here, and one direction only:
    /// **workspace scope narrows the global whitelist and never widens it.** A workspace folder
    /// outside `~/Desktop`/`~/Documents` can never match, because `PathWhitelist` rejects the path
    /// long before scope is consulted — so it is recorded as inert instead of pretending to be a
    /// boundary.
    public init(
        workspace: StoredWorkspace,
        catalog: MacAppCatalog = .default,
        resolver: any InstalledAppResolving = InstalledAppResolver.shared,
        whitelist: PathWhitelist = PathWhitelist()
    ) {
        self.workspaceName = workspace.name
        self.catalog = catalog
        self.resolver = resolver

        var inert: [WorkspaceScopeInertEntry] = []

        var appKeys: [String] = []
        for rawApp in workspace.apps {
            guard let key = Self.appKey(for: rawApp, catalog: catalog, resolver: resolver) else {
                inert.append(
                    WorkspaceScopeInertEntry(kind: .app, value: rawApp, reason: "The app name is empty.")
                )
                continue
            }
            if !appKeys.contains(key) {
                appKeys.append(key)
            }
        }

        var webDomains: [String] = []
        for rawURL in workspace.urls {
            do {
                let url = try SafeURL.validateWebURL(rawURL)
                guard let host = url.host, let domain = Self.normalizedHost(host) else {
                    inert.append(
                        WorkspaceScopeInertEntry(
                            kind: .webDomain,
                            value: rawURL,
                            reason: "The URL has no host to match against."
                        )
                    )
                    continue
                }
                if !webDomains.contains(domain) {
                    webDomains.append(domain)
                }
            } catch {
                inert.append(
                    WorkspaceScopeInertEntry(
                        kind: .webDomain,
                        value: rawURL,
                        reason: error.localizedDescription
                    )
                )
            }
        }

        var fileRoots: [URL] = []
        for rawPath in workspace.effectiveFileLocations {
            do {
                let root = try whitelist.validateInsideWhitelist(rawPath)
                if !fileRoots.contains(root) {
                    fileRoots.append(root)
                }
            } catch {
                inert.append(
                    WorkspaceScopeInertEntry(
                        kind: .fileLocation,
                        value: rawPath,
                        reason: error.localizedDescription
                    )
                )
            }
        }

        self.appKeys = appKeys
        self.webDomains = webDomains
        self.fileRoots = fileRoots
        self.inertEntries = inert
    }

    /// The scope's answer for one resource.
    ///
    /// A kind whose canonical list is empty is `.unconstrained`, and that includes the case where
    /// every entry the user configured turned out to be inert: an inert list restricts nothing, so
    /// reporting `.outOfScope` for it would escalate every action of that kind while enforcing
    /// nothing. `.unconstrained` leaves behavior exactly as it is today, which is the safe reading.
    public func verdict(for resource: ScopedResource) -> ScopeVerdict {
        switch resource {
        case .app(let rawName):
            guard !appKeys.isEmpty else {
                return .unconstrained
            }
            guard let key = Self.appKey(for: rawName, catalog: catalog, resolver: resolver) else {
                return .outOfScope
            }
            return appKeys.contains(key) ? .inScope : .outOfScope

        case .resolvedApp(let bundleIdentifier, let displayName):
            guard !appKeys.isEmpty else {
                return .unconstrained
            }
            if appKeys.contains(Self.bundleKey(bundleIdentifier)) {
                return .inScope
            }
            // The name half matches only stored entries that neither the alias table nor the
            // installed-app resolver could key — either of those produced a `bundle:` key above,
            // never a `name:` key — so this cannot hand a resolved app the identity of whatever its
            // display name happens to be. SONNY-84 narrowed what reaches it: an entry naming an
            // *installed* app now keys by bundle identifier, so an imposter can no longer spend the
            // membership of any installed app, cataloged or not. What is left matching by name is
            // what genuinely has no bundle identity available — an app that is not installed, and
            // Microsoft Word's implicit `convert_docx_to_pdf` resource — which is the same reason
            // the name fallback exists in `appKey` at all.
            return appKeys.contains(Self.nameFallbackKey(displayName)) ? .inScope : .outOfScope

        case .webDomain(let rawHost):
            guard !webDomains.isEmpty else {
                return .unconstrained
            }
            guard let host = Self.normalizedHost(rawHost) else {
                return .outOfScope
            }
            // Suffix on a dot boundary, never a substring: `notgithub.com` contains `github.com`.
            let matches = webDomains.contains { domain in
                host == domain || host.hasSuffix("." + domain)
            }
            return matches ? .inScope : .outOfScope

        case .fileLocation(let rawPath):
            guard !fileRoots.isEmpty else {
                return .unconstrained
            }
            let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return .outOfScope
            }
            // `PathWhitelist`'s own canonicalization and containment, not a second implementation:
            // two path comparisons that disagree about `..` or a symlink is a security bug, not a
            // style one.
            //
            // That inheritance includes what the whitelist does about case, which SONNY-249
            // changed on both sides at once: `canonicalURL` resolves the longest prefix of a path
            // that exists, and macOS answers with the real on-disk spelling of those components, so
            // a differently-cased *folder* is now the folder it names. What is left case-sensitive
            // is the part with nothing on disk to ask — a not-yet-created folder, and the leaf
            // itself — and there the comparison is still a literal one, which is fail-safe in the
            // direction that matters: such a path reads `.outOfScope` and prompts, never `.inScope`.
            // Scope keeps whatever the whitelist does rather than folding case itself, because
            // folding here and not there is exactly the divergence this reuse exists to prevent.
            // `canonical`, not `canonicalURL`: a resolution that did not converge is not inside
            // anything, and `contains` is what enforces that for both this caller and the
            // whitelist's own. Scope has no error to raise, so such a path reads `.outOfScope` and
            // prompts — the fail-safe direction, and the same answer as any other path it cannot
            // place. (SONNY-249's review, F1: a 34-link chain inside a scoped folder read
            // `.inScope` while it led out of it.)
            let candidate = PathWhitelist.canonical(trimmed)
            return fileRoots.contains { PathWhitelist.contains(root: $0, candidate: candidate) }
                ? .inScope
                : .outOfScope
        }
    }

    /// The single canonical form both sides of an app comparison go through.
    ///
    /// **Three stages, and the order is the security property** (SONNY-84):
    ///
    /// 1. **The alias table**, so `"Chrome"` and `"Google Chrome"` are the same app rather than the
    ///    same app matching in one workspace and not another. Unconditional — a cataloged name keys
    ///    to its cataloged bundle identifier whether or not the app is installed, which is not an
    ///    oversight but the stronger answer: if this stage deferred to installation, a workspace
    ///    listing "Chrome" on a Mac without Chrome would key to `name:chrome`, and an app that merely
    ///    *calls itself* Chrome would then match it. Keeping the stage unconditional is also what
    ///    makes catalog-app behavior byte-identical to before this ticket.
    /// 2. **`InstalledAppResolver`**, which extends the same `bundle:` precision to every *installed*
    ///    app. Before SONNY-84 a non-catalog entry — "Figma", stored as a raw string — had only the
    ///    weaker name key, so a process self-reporting that display name earned `.inScope`. The
    ///    resolution authority here is the Launch Services database and never a running process's
    ///    self-reported name, which is precisely the distinction that makes the key worth anything:
    ///    an identity taken from the imposter cannot be used to exclude the imposter.
    /// 3. **The normalized raw name**, for what neither stage can resolve. Names that reach here are
    ///    *not* dropped, because dropping them would remove them from scope checking entirely, which
    ///    is the one outcome a boundary must never produce (SONNY-44). Three real resources land
    ///    here: `switch_running_app` matches against the *running* apps, `convert_docx_to_pdf`
    ///    implicitly drives Microsoft Word, and any listed app that is genuinely not installed. Name
    ///    identity is all anyone has for those, and it is better than nothing.
    ///
    /// The `bundle:` / `name:` prefixes keep a raw name that happens to look like a bundle identifier
    /// from colliding with a real one.
    ///
    /// Resolved at evaluate time and never stored: keys stay derived, the workspace record is
    /// untouched, and there is no schema change — the same "derived, not stored" shape SONNY-44 chose
    /// for scope-only status. It also has to be derived: whether an app is installed changes without
    /// the workspace changing, and a key written to disk in March cannot know that.
    ///
    /// The fallback folds through `MacAppCatalog.normalize` — the catalog's *own* normalization, not
    /// the stores' `normalized(_:)`. The two differ: the stores fold case and diacritics, while the
    /// catalog also strips spaces, hyphens and underscores. Using the weaker one here would make
    /// "Microsoft Word" and "MicrosoftWord" different apps to workspace scope while being the same
    /// app to `resolve`, which is the same class of divergence the shared `PathWhitelist` containment
    /// exists to prevent for paths. One app-name normalization, both branches.
    ///
    /// Module-visible rather than private for the same one-normalizer reason, and *only* that:
    /// `EditWorkspaceCapabilityAdapter` has to decide which stored entry a "remove Chrome" request
    /// names, and a second app-key function there would make "Chrome" and "Google Chrome" the same
    /// app to the evaluator and different apps to the edit path — a removal that appeared to succeed
    /// and left the app in scope. The matching semantics themselves are untouched.
    static func appKey(
        for rawName: String,
        catalog: MacAppCatalog,
        resolver: any InstalledAppResolving
    ) -> String? {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        if let app = catalog.canonicalApp(named: trimmed) {
            return bundleKey(app.bundleIdentifier)
        }
        if let installed = resolver.resolve(trimmed) {
            return bundleKey(installed.bundleIdentifier)
        }
        return nameFallbackKey(trimmed)
    }

    /// The two halves of `appKey`, split out so `verdict(for: .resolvedApp)` builds the identical
    /// keys without duplicating the literals — a drifted prefix would silently unmatch every stored
    /// entry of that half.
    static func bundleKey(_ bundleIdentifier: String) -> String {
        "bundle:" + bundleIdentifier
    }

    static func nameFallbackKey(_ rawName: String) -> String {
        "name:" + MacAppCatalog.normalize(rawName)
    }

    /// Lowercased, trailing DNS root dots removed, then a single leading `www.` removed. Applied to
    /// both sides, so `https://github.com./x` cannot slip past a `github.com` entry.
    ///
    /// Module-visible for the same reason as `appKey(for:catalog:resolver:)`: the edit path matches removal
    /// requests against stored URLs by host, and it must be *this* host normalization.
    static func normalizedHost(_ rawHost: String) -> String? {
        var host = rawHost
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        while host.hasSuffix(".") {
            host.removeLast()
        }
        if host.hasPrefix("www.") {
            host.removeFirst(4)
        }
        return host.isEmpty ? nil : host
    }
}

/// One resource a plan step touches, and what the bound workspace says about it.
public struct WorkspaceScopeFinding: Equatable, Sendable {
    public let stepID: String
    public let operation: AgentOperation
    /// `nil` exactly when `verdict == .opaque`: an opaque step has no resource to name, which is
    /// what makes it opaque.
    public let resource: ScopedResource?
    public let verdict: ScopeVerdict

    public init(stepID: String, operation: AgentOperation, resource: ScopedResource?, verdict: ScopeVerdict) {
        self.stepID = stepID
        self.operation = operation
        self.resource = resource
        self.verdict = verdict
    }

    public var kind: ScopedResourceKind? {
        resource?.kind
    }
}

public struct WorkspaceScopeEvaluation: Equatable, Sendable {
    /// Every resource the plan touches, in step order, with the workspace's verdict on each.
    /// Deliberately not deduplicated: whoever words an escalation decides what to collapse, and a
    /// finding that names its own step is worth more than a tidier list.
    public let findings: [WorkspaceScopeFinding]

    public init(findings: [WorkspaceScopeFinding]) {
        self.findings = findings
    }

    /// Derived, never stored: a roll-up that can be set independently of the findings it summarizes
    /// is a roll-up that can disagree with them.
    public var planVerdict: ScopeVerdict {
        WorkspaceScopeEvaluator.planVerdict(for: findings)
    }

    public var outOfScopeFindings: [WorkspaceScopeFinding] {
        findings.filter { $0.verdict == .outOfScope }
    }
}

/// Walks a resolved plan and reports what each step touches relative to one workspace.
///
/// Knows nothing about risk tiers, approval requirements or escalation. It answers "is this the
/// right place," never "is this the right severity" — a file inside your own workspace folder is
/// still destroyed forever if deleted.
public enum WorkspaceScopeEvaluator {
    public static func evaluate(
        plan: AgentPlan,
        scope: WorkspaceScope,
        searchURLCatalog: AppSearchURLCatalog = .default
    ) -> WorkspaceScopeEvaluation {
        var findings: [WorkspaceScopeFinding] = []

        for step in plan.steps {
            let classification = PlanScopedResources.classification(of: step, searchURLCatalog: searchURLCatalog)
            for resource in classification.resources {
                findings.append(
                    WorkspaceScopeFinding(
                        stepID: step.id,
                        operation: step.operation,
                        resource: resource,
                        verdict: scope.verdict(for: resource)
                    )
                )
            }
            if classification.isOpaque {
                findings.append(
                    WorkspaceScopeFinding(
                        stepID: step.id,
                        operation: step.operation,
                        resource: nil,
                        verdict: .opaque
                    )
                )
            }
        }

        return WorkspaceScopeEvaluation(findings: findings)
    }

    /// The plan-level roll-up.
    ///
    /// `.inScope` only when every resource was statically knowable, at least one matched, none is
    /// out of scope, and no step is opaque.
    ///
    /// `.outOfScope` outranks `.opaque` because it is the actionable one — a plan with both a
    /// Shortcut and a folder outside the workspace still has something concrete to tell the user
    /// about. A plan with no resources at all rolls up `.unconstrained`: nothing matched, and
    /// nothing was violated.
    public static func planVerdict(for findings: [WorkspaceScopeFinding]) -> ScopeVerdict {
        if findings.contains(where: { $0.verdict == .outOfScope }) {
            return .outOfScope
        }
        if findings.contains(where: { $0.verdict == .opaque }) {
            return .opaque
        }
        if findings.contains(where: { $0.verdict == .inScope }) {
            return .inScope
        }
        return .unconstrained
    }
}
