import Foundation

/// What Sonny knows about one site, shipped in the app as a JSON file and added by the user on
/// Command Center's Skills page (SONNY-452).
///
/// **A pack is instructions, never permission.** It teaches the planner where a site lives and how a
/// task is done there; it carries no field that could make anything ask less, pre-approve an app or
/// widen Normal mode's list, and the loader refuses any key it does not know, so such a field cannot
/// be smuggled in under a new name either. Every gate a command meets without a pack it still meets
/// with one.
///
/// **Two depths, decided by evidence rather than by effort** (SONNY-461, founders 2026-09-12). No
/// session can sign into these tools, so a step nobody can check is Sonny doing the wrong thing on a
/// live account. A `deep` pack carries task flows, and every flow cites the public page its steps
/// came from — a flow without a citation does not load. A `shallow` pack carries only facts a lookup
/// settles: the name, the domain, the sign-in URL, the words that mean it, and its top-level
/// sections. Shallow still earns its place: it tells Sonny the tool exists and where it lives.
///
/// **Two kinds of evidence, and a row says which one its flows rest on** (founders, 2026-09-16 on
/// SONNY-501; the two values redefined by the founders 2026-09-17 on SONNY-512).
/// `docs/sonny-skill-sites.tsv`'s `task_flow_docs` column says `deep` when the flows came from a
/// documentation page anybody can re-open at the URL the row cites, `site` when they came from the
/// running product, where no artifact exists and the row's `doc_url` cells are the only record of
/// what was read, and `shallow` when neither — which keeps every pack on that row shallow.
///
/// **The value names the kind of evidence, not who read it or how, and neither value is scoped to a
/// set of rows.** A documentation page is read in a browser like everything else; the rule for how
/// any of these pages must be read is `CLAUDE.md`'s, named below. Any row whose flows came from the
/// running product says `site`, wherever that row came from; any row whose documentation carries the
/// flows says `deep`. A row is not held to the value it arrived with: one whose documentation turns
/// out to carry step-level flows becomes `deep` the day somebody reads them there.
///
/// *How the column got here, kept because knowing the definition changed is worth having — history,
/// not scope.* The first wording said `site` meant the flows were "read off the live site instead",
/// which put every browser reading on one side and made the column record the reader rather than the
/// evidence. It was introduced for 54 rows that had been grouped on a research claim — that their
/// public documentation carries no step-level flows — and SONNY-512 measured that claim false for the
/// first two of them it opened, Canva and Zoho Desk, whose own help pages carry numbered click paths.
/// Those two are `deep` now. **The other 52 are not re-classified on that evidence**: two sites is a
/// small sample, and a count of rows carrying a help link is a count of links rather than a claim
/// about what those pages contain. A row moves one at a time, when somebody opens that site's
/// documentation and finds flows in it.
///
/// The catalogue is validated in `SkillPackTests`, which allows a deep pack on a `deep` or a `site`
/// row and on nothing else and requires that row to name at least one page the flows were read from;
/// that narrowing is what stops a pack being deep on evidence nobody has, or on evidence no row
/// records.
///
/// **What a lane owes before it writes `site` on a row — how those pages must have been read, and why
/// a fetch of them is not a reading — is stated once, in `CLAUDE.md`'s Claims and evidence section,
/// in the clean-zero family it belongs to** (review-255's F4, recorded on SONNY-463): none of it is
/// restated here, deliberately, because a rule with two copies is a rule with one stale copy, and
/// nothing in a file says which of the two a reader got (review-260's F1).
///
/// **No flow moves money, in any pack, whatever its category** (founders, 2026-09-13 on SONNY-452,
/// widening SONNY-461's decision 4). A flow may not send, transfer, pay, refund or pay out money, or
/// change payment details or payees; a pack may still describe reading orders, invoices, statements
/// and payouts. **The rule names no category, deliberately**: it held finance packs alone as first
/// built, and a store or billing pack could then have taught Sonny to issue a refund or change a
/// payout account, which moves money exactly as a finance flow would. The rule exists because money
/// moves, not because of a label. It is read off a flow's title and steps, the summary and each
/// section — `SkillPackMoneyRule` has what that catches and, in as many words, what it cannot.
///
/// **No pack carries, asks for or types a credential.** Wording that asks for one is refused, and so
/// is a URL carrying a user name, a password, or a token-shaped name in its query or its fragment —
/// `SkillPackCredentialRule`.
///
/// **A flow starts on the pack's own site** (PR #241's F4): its `startURL`'s host is the pack's domain
/// or a subdomain of it, so a copy-paste slip between two pack files cannot send one site's task to
/// another. Citations and the sign-in page are deliberately not held to it — a site's help centre and
/// its sign-in host often live elsewhere (`notion.com` for `notion.so`, `accounts.google.com`).
///
/// **And a flow's start page is recorded where it lands** (SONNY-510): that rule reads the string a
/// pack declares, and what decides where Sonny arrives is where the string lands, so a pack with flows
/// carries `startPages`, a signed-out reading of each start URL, and the loader holds it —
/// `SkillPackStartPage` has the rule, what it catches and what it cannot.
public struct SkillPack: Equatable, Sendable, Identifiable {
    /// The one format this build reads. A pack declaring another does not load rather than being
    /// read under rules it was not written for.
    public static let formatVersion = 1

    /// The suffix a shipped pack's file name carries. Enumerated by suffix rather than by folder
    /// because SwiftPM's `.process` rule flattens `Resources/` into the bundle's top level — the
    /// fonts beside these files already sit there — and a suffix finds a pack in either layout.
    public static let fileSuffix = ".skillpack.json"

    /// The ceiling on one pack's rendered guidance, in UTF-8 bytes.
    ///
    /// A pack over it does not load, rather than being truncated when it joins a prompt: a flow cut
    /// off half way is a set of instructions that stops before the step that mattered.
    public static let guidanceByteLimit = 6_000

    public let id: String
    public let name: String
    public let domain: String
    public let category: String
    public let summary: String
    public let signInURL: URL?
    public let triggers: [String]
    public let sections: [String]
    public let depth: SkillPackDepth
    public let flows: [SkillPackFlow]
    /// One signed-out reading per distinct start URL the flows use; empty for a pack with no flows.
    /// Evidence for whoever reads the pack next, never part of `guidance`.
    public let startPages: [SkillPackStartPage]

    public init(
        id: String,
        name: String,
        domain: String,
        category: String,
        summary: String,
        signInURL: URL?,
        triggers: [String],
        sections: [String],
        depth: SkillPackDepth,
        flows: [SkillPackFlow],
        startPages: [SkillPackStartPage]
    ) {
        self.id = id
        self.name = name
        self.domain = domain
        self.category = category
        self.summary = summary
        self.signInURL = signInURL
        self.triggers = triggers
        self.sections = sections
        self.depth = depth
        self.flows = flows
        self.startPages = startPages
    }

    /// The text this pack adds to a planning request when a command names it.
    ///
    /// Plain lines rather than JSON: it is read by a model beside the rest of the system prompt,
    /// which is prose. Every flow keeps its citation beside its steps, so the source of each
    /// instruction travels with it.
    public var guidance: String {
        var lines = ["Skill: \(name) (\(domain))", summary]
        if let signInURL {
            lines.append("Sign-in page: \(signInURL.absoluteString)")
        }
        if !sections.isEmpty {
            lines.append("Top-level sections: \(sections.joined(separator: ", "))")
        }
        if !flows.isEmpty {
            lines.append("Tasks:")
            for flow in flows {
                lines.append("- \(flow.title), starting at \(flow.startURL.absoluteString):")
                for (index, step) in flow.steps.enumerated() {
                    lines.append("  \(index + 1). \(step)")
                }
                lines.append("  (steps from \(flow.source.absoluteString))")
            }
        }
        return lines.joined(separator: "\n")
    }
}

public enum SkillPackDepth: String, Sendable, Equatable {
    case deep
    case shallow
}

/// One task a deep pack describes.
public struct SkillPackFlow: Equatable, Sendable {
    public let title: String
    public let startURL: URL
    public let steps: [String]
    /// The public page these steps were taken from. Required: a flow nobody can check against a
    /// page is a flow nobody can trust on a live account.
    public let source: URL

    public init(title: String, startURL: URL, steps: [String], source: URL) {
        self.title = title
        self.startURL = startURL
        self.steps = steps
        self.source = source
    }
}

/// Why a pack did not load. Each case names the thing a pack author has to fix.
public enum SkillPackLoadError: Error, Equatable, Sendable {
    case notAJSONObject
    case unknownField(String)
    case missingField(String)
    case wrongType(String)
    case unsupportedFormat(Int)
    case invalidID(String)
    case duplicateID(String)
    case notHTTPS(field: String)
    case unknownDepth(String)
    case deepPackHasNoFlows
    case shallowPackHasFlows
    case flowHasNoSteps(flow: String)
    case flowHasNoCitation(flow: String)
    case startPageOffSite(flow: String, host: String)
    /// The start-page records (`SkillPackStartPage`). Each `url` is the start URL the record is for,
    /// except `startPageCreatesAnAccount`'s, which is whichever URL named account creation.
    case startPageNotRecorded(flow: String)
    case startPageRecordedTwice(url: String)
    case startPageUnused(url: String)
    case startPageNotAStartPage(url: String, offers: String)
    case landedURLCarriesQuery(url: String)
    /// The landing is on `host`, off the pack's own site `site`, and `SkillPackStartPageRule.identityHosts`
    /// has no pairing of `host` with `site`. It names the pairing because the list is kept one pairing at
    /// a time: the fix is either the record (the page landed somewhere a flow may not start) or, when
    /// `host` really is where `site` signs in, the pairing `host` → `site` added after reading the page.
    case landedOnUnpairedHost(url: String, host: String, site: String)
    /// `host` is paired with the pack's site, and the record landing there says `product`: an identity
    /// host admits a sign-in page and nothing else.
    case identityHostLandingIsNotSignIn(url: String, host: String)
    case startPageCreatesAnAccount(url: String)
    /// `field` is `summary`, `sections[n]` or `flows[n]`; `words` is what moved money — a money verb,
    /// or an action verb and its money object ("create + payout").
    case movesMoney(field: String, words: String)
    case mentionsCredential(field: String, phrase: String)
    case urlCarriesCredential(field: String)
    case guidanceTooLong(bytes: Int)
}

/// One file that did not become a pack, and why.
public struct SkillPackLoadFailure: Equatable, Sendable {
    public let fileName: String
    public let error: SkillPackLoadError

    public init(fileName: String, error: SkillPackLoadError) {
        self.fileName = fileName
        self.error = error
    }
}

/// Every pack that loaded, and every file that did not.
///
/// **A refused pack is absent, never half-loaded.** The loader reads each file on its own, so one
/// malformed pack costs that site its skill and nothing else; the failures are kept so a test can
/// name them rather than a missing row going unexplained.
public struct SkillPackCatalog: Equatable, Sendable {
    public static let empty = SkillPackCatalog(packs: [], failures: [])

    /// In name order, so the Skills page lists them the way a person scans for a site.
    public let packs: [SkillPack]
    public let failures: [SkillPackLoadFailure]

    public init(packs: [SkillPack], failures: [SkillPackLoadFailure]) {
        self.packs = packs
        self.failures = failures
    }

    public func pack(id: String) -> SkillPack? {
        packs.first { $0.id == id }
    }

    /// Every file under `directory`, at any depth, whose name ends in `SkillPack.fileSuffix`, in
    /// file-name order.
    public static func packFileURLs(in directory: URL, fileManager: FileManager = .default) -> [URL] {
        guard let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        return enumerator
            .compactMap { $0 as? URL }
            .filter { $0.lastPathComponent.hasSuffix(SkillPack.fileSuffix) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Loads every pack file under `directory`.
    public static func load(from directory: URL, fileManager: FileManager = .default) -> SkillPackCatalog {
        load(fileURLs: packFileURLs(in: directory, fileManager: fileManager))
    }

    public static func load(fileURLs: [URL]) -> SkillPackCatalog {
        load(files: fileURLs.map { url in
            (fileName: url.lastPathComponent, data: (try? Data(contentsOf: url)) ?? Data())
        })
    }

    /// Decodes and validates each file, then refuses **every** file sharing an id with another.
    ///
    /// All of them rather than all but the first, because nothing says which of two packs claiming
    /// one site is the right one, and keeping whichever sorted first would make that an accident of
    /// file naming.
    public static func load(files: [(fileName: String, data: Data)]) -> SkillPackCatalog {
        var decoded: [(fileName: String, pack: SkillPack)] = []
        var failures: [SkillPackLoadFailure] = []
        for file in files {
            do {
                decoded.append((file.fileName, try SkillPackDecoder.decode(file.data)))
            } catch let error as SkillPackLoadError {
                failures.append(SkillPackLoadFailure(fileName: file.fileName, error: error))
            } catch {
                failures.append(SkillPackLoadFailure(fileName: file.fileName, error: .notAJSONObject))
            }
        }

        let idCounts = Dictionary(grouping: decoded, by: \.pack.id).mapValues(\.count)
        var packs: [SkillPack] = []
        for entry in decoded {
            if idCounts[entry.pack.id, default: 0] > 1 {
                failures.append(SkillPackLoadFailure(fileName: entry.fileName, error: .duplicateID(entry.pack.id)))
            } else {
                packs.append(entry.pack)
            }
        }
        packs.sort {
            let order = $0.name.localizedCaseInsensitiveCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
        return SkillPackCatalog(packs: packs, failures: failures)
    }
}

/// Reads one pack file and holds it to every rule on `SkillPack`.
///
/// `JSONSerialization` rather than `Decodable`, deliberately: `JSONDecoder` ignores keys it does not
/// know, and the property that a pack cannot carry a field this build does not understand — an
/// approval override, an allow-list — is only structural if an unknown key is refused.
public enum SkillPackDecoder {
    static let packFields: Set<String> = [
        "format", "id", "name", "domain", "category", "summary", "signInURL",
        "triggers", "sections", "depth", "flows", "startPages"
    ]
    static let flowFields: Set<String> = ["title", "startURL", "steps", "source"]
    static let startPageFields: Set<String> = ["url", "landedURL", "title", "heading", "offers", "read"]

    public static func decode(_ data: Data) throws -> SkillPack {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else {
            throw SkillPackLoadError.notAJSONObject
        }
        try refuseUnknownKeys(in: root, allowed: packFields, prefix: "")

        let format: Int = try required(root, "format")
        guard format == SkillPack.formatVersion else {
            throw SkillPackLoadError.unsupportedFormat(format)
        }

        let id: String = try requiredText(root, "id")
        guard id.range(of: "^[a-z0-9][a-z0-9_]*$", options: .regularExpression) != nil else {
            throw SkillPackLoadError.invalidID(id)
        }
        let name: String = try requiredText(root, "name")
        let domain: String = try requiredText(root, "domain")
        let category: String = try requiredText(root, "category")
        let summary: String = try requiredText(root, "summary")
        let signInURL = try optionalHTTPSURL(root, "signInURL")
        let triggers: [String] = try requiredTextList(root, "triggers", allowEmpty: false)
        let sections: [String] = try requiredTextList(root, "sections", allowEmpty: true)

        let depthText: String = try requiredText(root, "depth")
        guard let depth = SkillPackDepth(rawValue: depthText) else {
            throw SkillPackLoadError.unknownDepth(depthText)
        }

        guard let rawFlows = root["flows"] else {
            throw SkillPackLoadError.missingField("flows")
        }
        guard let flowObjects = rawFlows as? [[String: Any]] else {
            throw SkillPackLoadError.wrongType("flows")
        }
        let flows = try flowObjects.enumerated().map { index, flow in
            try decodeFlow(flow, index: index, domain: domain)
        }

        switch depth {
        case .deep where flows.isEmpty:
            throw SkillPackLoadError.deepPackHasNoFlows
        case .shallow where !flows.isEmpty:
            throw SkillPackLoadError.shallowPackHasFlows
        default:
            break
        }

        let startPages = try decodeStartPages(root["startPages"], hasFlows: !flows.isEmpty)
        try SkillPackStartPageRule.check(flows: flows, startPages: startPages, domain: domain)

        // The money rule reads everything that reaches the planner as description of the site: each
        // flow as one unit (its money act is often split between title and steps), the summary, and
        // each section on its own, so two section labels cannot pair into a refusal.
        let moneyUnits: [(field: String, texts: [String])] =
            flows.enumerated().map { index, flow in ("flows[\(index)]", [flow.title] + flow.steps) }
            + [("summary", [summary])]
            + sections.enumerated().map { index, section in ("sections[\(index)]", [section]) }
        for unit in moneyUnits {
            if let words = SkillPackMoneyRule.violation(in: unit.texts) {
                throw SkillPackLoadError.movesMoney(field: unit.field, words: words)
            }
        }

        let texts: [(field: String, text: String)] =
            [("name", name), ("domain", domain), ("summary", summary)]
            + triggers.map { ("triggers", $0) }
            + sections.map { ("sections", $0) }
            + flows.flatMap { flow in [("flows.title", flow.title)] + flow.steps.map { ("flows.steps", $0) } }
        for entry in texts {
            if let phrase = SkillPackCredentialRule.violation(in: entry.text) {
                throw SkillPackLoadError.mentionsCredential(field: entry.field, phrase: phrase)
            }
        }

        let pack = SkillPack(
            id: id,
            name: name,
            domain: domain,
            category: category,
            summary: summary,
            signInURL: signInURL,
            triggers: triggers,
            sections: sections,
            depth: depth,
            flows: flows,
            startPages: startPages
        )
        let bytes = pack.guidance.utf8.count
        guard bytes <= SkillPack.guidanceByteLimit else {
            throw SkillPackLoadError.guidanceTooLong(bytes: bytes)
        }
        return pack
    }

    private static func decodeFlow(_ flow: [String: Any], index: Int, domain: String) throws -> SkillPackFlow {
        let prefix = "flows[\(index)]."
        try refuseUnknownKeys(in: flow, allowed: flowFields, prefix: prefix)
        let title: String = try requiredText(flow, "title", prefix: prefix)
        let startURL = try requiredHTTPSURL(flow, "startURL", prefix: prefix)
        let startHost = (startURL.host ?? "").lowercased()
        guard isOnSite(host: startHost, domain: domain) else {
            throw SkillPackLoadError.startPageOffSite(flow: title, host: startHost)
        }
        guard let rawSource = flow["source"] as? String,
              !rawSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SkillPackLoadError.flowHasNoCitation(flow: title)
        }
        let source = try requiredHTTPSURL(flow, "source", prefix: prefix)
        let steps: [String] = try requiredTextList(flow, "steps", prefix: prefix, allowEmpty: true)
        guard !steps.isEmpty else {
            throw SkillPackLoadError.flowHasNoSteps(flow: title)
        }
        return SkillPackFlow(title: title, startURL: startURL, steps: steps, source: source)
    }

    /// The pack's own site: its domain, or a subdomain of it. `host` is already lowercased.
    static func isOnSite(host: String, domain: String) -> Bool {
        let siteDomain = domain.lowercased()
        return host == siteDomain || host.hasSuffix("." + siteDomain)
    }

    /// `startPages` is required of a pack with flows and optional for one without, so none of the
    /// shallow packs has to say it has nothing to record. Whether each record matches a flow is
    /// `SkillPackStartPageRule`'s; this reads only its shape.
    private static func decodeStartPages(_ raw: Any?, hasFlows: Bool) throws -> [SkillPackStartPage] {
        guard let raw else {
            if hasFlows {
                throw SkillPackLoadError.missingField("startPages")
            }
            return []
        }
        guard let objects = raw as? [[String: Any]] else {
            throw SkillPackLoadError.wrongType("startPages")
        }
        return try objects.enumerated().map { index, object in
            let prefix = "startPages[\(index)]."
            try refuseUnknownKeys(in: object, allowed: startPageFields, prefix: prefix)
            let url = try requiredHTTPSURL(object, "url", prefix: prefix)
            let landedURL = try requiredHTTPSURL(object, "landedURL", prefix: prefix)
            // Both present, and both allowed to be empty: a page with no title or no heading is
            // recorded as having none rather than being given one (X's log-in page has no title).
            let title: String = try required(object, "title", prefix: prefix)
            let heading: String = try required(object, "heading", prefix: prefix)
            let offersText = try requiredText(object, "offers", prefix: prefix)
            guard let offers = SkillPackStartPageOffer(rawValue: offersText) else {
                throw SkillPackLoadError.startPageNotAStartPage(url: url.absoluteString, offers: offersText)
            }
            let read = try requiredText(object, "read", prefix: prefix)
            guard read.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil else {
                throw SkillPackLoadError.wrongType(prefix + "read")
            }
            return SkillPackStartPage(
                url: url,
                landedURL: landedURL,
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                heading: heading.trimmingCharacters(in: .whitespacesAndNewlines),
                offers: offers,
                read: read
            )
        }
    }

    private static func refuseUnknownKeys(in object: [String: Any], allowed: Set<String>, prefix: String) throws {
        if let unknown = object.keys.sorted().first(where: { !allowed.contains($0) }) {
            throw SkillPackLoadError.unknownField(prefix + unknown)
        }
    }

    private static func required<Value>(_ object: [String: Any], _ key: String, prefix: String = "") throws -> Value {
        guard let raw = object[key] else {
            throw SkillPackLoadError.missingField(prefix + key)
        }
        guard let value = raw as? Value else {
            throw SkillPackLoadError.wrongType(prefix + key)
        }
        return value
    }

    /// A string that is present and not blank. A blank field is reported as missing: to the page
    /// that renders it, it is.
    private static func requiredText(_ object: [String: Any], _ key: String, prefix: String = "") throws -> String {
        let value: String = try required(object, key, prefix: prefix)
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SkillPackLoadError.missingField(prefix + key)
        }
        return trimmed
    }

    private static func requiredTextList(
        _ object: [String: Any],
        _ key: String,
        prefix: String = "",
        allowEmpty: Bool
    ) throws -> [String] {
        let values: [String] = try required(object, key, prefix: prefix)
        let trimmed = values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !trimmed.contains(where: \.isEmpty) else {
            throw SkillPackLoadError.missingField(prefix + key)
        }
        guard allowEmpty || !trimmed.isEmpty else {
            throw SkillPackLoadError.missingField(prefix + key)
        }
        return trimmed
    }

    private static func requiredHTTPSURL(_ object: [String: Any], _ key: String, prefix: String = "") throws -> URL {
        let text: String = try requiredText(object, key, prefix: prefix)
        return try httpsURL(text, field: prefix + key)
    }

    /// `signInURL` may be `null`: a few sites have no sign-in page of their own (the catalogue's
    /// draw.io, Gladly, Streak and Mattermost rows). Absent is still refused, so a pack author says
    /// so rather than forgetting.
    private static func optionalHTTPSURL(_ object: [String: Any], _ key: String) throws -> URL? {
        guard let raw = object[key] else {
            throw SkillPackLoadError.missingField(key)
        }
        if raw is NSNull {
            return nil
        }
        guard let text = raw as? String else {
            throw SkillPackLoadError.wrongType(key)
        }
        return try httpsURL(text.trimmingCharacters(in: .whitespacesAndNewlines), field: key)
    }

    private static func httpsURL(_ text: String, field: String) throws -> URL {
        guard let components = URLComponents(string: text),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              let url = components.url else {
            throw SkillPackLoadError.notHTTPS(field: field)
        }
        guard components.user == nil, components.password == nil,
              !SkillPackCredentialRule.urlCarriesCredential(components) else {
            throw SkillPackLoadError.urlCarriesCredential(field: field)
        }
        return url
    }
}

/// Whole-word phrase search over folded text: a match must not have a letter or digit immediately
/// before or after it, so "linear" is found in "open linear" and not in "nonlinear".
enum SkillPhraseMatch {
    static func firstIndex(of needle: String, in haystack: String) -> String.Index? {
        guard !needle.isEmpty else { return nil }
        var searchStart = haystack.startIndex
        while let range = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
            let beforeIsBoundary = range.lowerBound == haystack.startIndex
                || !isWordCharacter(haystack[haystack.index(before: range.lowerBound)])
            let afterIsBoundary = range.upperBound == haystack.endIndex
                || !isWordCharacter(haystack[range.upperBound])
            if beforeIsBoundary && afterIsBoundary {
                return range.lowerBound
            }
            searchStart = haystack.index(after: range.lowerBound)
        }
        return nil
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }
}
