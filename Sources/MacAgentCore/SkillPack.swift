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
/// **Finance packs read and never move money** (SONNY-461, decision 4). A pack in the
/// `finance_billing` category may describe statements, invoices and transaction history, and every
/// one of its flows must declare `"effect": "reads"`; sending, transferring, paying, and changing
/// payment details or payees are refused by wording as well as by declaration. The unambiguous
/// money-moving phrases are refused in every pack, whatever its category.
///
/// **No pack carries, asks for or types a credential.** Wording that asks for one is refused, and so
/// is a URL carrying a user name, a password or a token-shaped query parameter.
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

    /// The category whose packs may only read (SONNY-461, decision 4).
    public static let readOnlyCategory = "finance_billing"

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
        flows: [SkillPackFlow]
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
    public let effect: SkillPackFlowEffect

    public init(title: String, startURL: URL, steps: [String], source: URL, effect: SkillPackFlowEffect) {
        self.title = title
        self.startURL = startURL
        self.steps = steps
        self.source = source
        self.effect = effect
    }
}

/// Whether a flow only looks at something or changes something. Declared by the pack, and checked
/// against its wording for the finance rule rather than trusted on its own.
public enum SkillPackFlowEffect: String, Sendable, Equatable {
    case reads
    case changes
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
    case unknownEffect(String)
    case deepPackHasNoFlows
    case shallowPackHasFlows
    case flowHasNoSteps(flow: String)
    case flowHasNoCitation(flow: String)
    case readOnlyPackChangesSomething(flow: String)
    case movesMoney(flow: String, phrase: String)
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
        "triggers", "sections", "depth", "flows"
    ]
    static let flowFields: Set<String> = ["title", "startURL", "steps", "source", "effect"]

    /// Phrases that move money, refused in every pack. Whole words, compared folded, so "refunded
    /// orders" is not "refund" and "transfer ownership of a page" is not "transfer money".
    static let moneyMovementPhrases = [
        "send money", "transfer money", "transfer funds", "make a payment", "pay an invoice",
        "pay a bill", "pay the bill", "issue a refund", "refund", "payout", "withdraw", "payee",
        "payees", "payment details", "payment method", "bank details", "wire transfer"
    ]

    /// Verbs refused on top of those in a read-only pack, where "send" and "pay" can only mean
    /// money or a document that asks for it.
    static let readOnlyRefusedVerbs = [
        "send", "sends", "sending", "transfer", "transfers", "transferring", "pay", "pays", "paying",
        "approve", "approves", "approving", "schedule a payment", "top up", "deposit"
    ]

    /// Wording that asks for or handles a secret, refused in every text field of every pack.
    static let credentialPhrases = [
        "password", "passwords", "passcode", "passphrase", "api key", "api keys", "secret key",
        "access token", "verification code", "one-time code", "2fa code", "recovery code",
        "security code", "private key"
    ]

    /// Query parameter names that carry a credential in a URL.
    static let credentialQueryNames: Set<String> = [
        "token", "access_token", "api_key", "apikey", "key", "password", "pass", "secret", "code", "sig", "signature"
    ]

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
            try decodeFlow(flow, index: index)
        }

        switch depth {
        case .deep where flows.isEmpty:
            throw SkillPackLoadError.deepPackHasNoFlows
        case .shallow where !flows.isEmpty:
            throw SkillPackLoadError.shallowPackHasFlows
        default:
            break
        }

        let isReadOnly = category == SkillPack.readOnlyCategory
        for flow in flows {
            let wording = ([flow.title] + flow.steps).joined(separator: "\n")
            if let phrase = firstPhrase(of: moneyMovementPhrases, in: wording) {
                throw SkillPackLoadError.movesMoney(flow: flow.title, phrase: phrase)
            }
            if isReadOnly {
                guard flow.effect == .reads else {
                    throw SkillPackLoadError.readOnlyPackChangesSomething(flow: flow.title)
                }
                if let phrase = firstPhrase(of: readOnlyRefusedVerbs, in: wording) {
                    throw SkillPackLoadError.movesMoney(flow: flow.title, phrase: phrase)
                }
            }
        }

        let texts: [(field: String, text: String)] =
            [("name", name), ("domain", domain), ("summary", summary)]
            + triggers.map { ("triggers", $0) }
            + sections.map { ("sections", $0) }
            + flows.flatMap { flow in [("flows.title", flow.title)] + flow.steps.map { ("flows.steps", $0) } }
        for entry in texts {
            if let phrase = firstPhrase(of: credentialPhrases, in: entry.text) {
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
            flows: flows
        )
        let bytes = pack.guidance.utf8.count
        guard bytes <= SkillPack.guidanceByteLimit else {
            throw SkillPackLoadError.guidanceTooLong(bytes: bytes)
        }
        return pack
    }

    private static func decodeFlow(_ flow: [String: Any], index: Int) throws -> SkillPackFlow {
        let prefix = "flows[\(index)]."
        try refuseUnknownKeys(in: flow, allowed: flowFields, prefix: prefix)
        let title: String = try requiredText(flow, "title", prefix: prefix)
        let startURL = try requiredHTTPSURL(flow, "startURL", prefix: prefix)
        guard let rawSource = flow["source"] as? String,
              !rawSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SkillPackLoadError.flowHasNoCitation(flow: title)
        }
        let source = try requiredHTTPSURL(flow, "source", prefix: prefix)
        let steps: [String] = try requiredTextList(flow, "steps", prefix: prefix, allowEmpty: true)
        guard !steps.isEmpty else {
            throw SkillPackLoadError.flowHasNoSteps(flow: title)
        }
        let effectText: String = try requiredText(flow, "effect", prefix: prefix)
        guard let effect = SkillPackFlowEffect(rawValue: effectText) else {
            throw SkillPackLoadError.unknownEffect(effectText)
        }
        return SkillPackFlow(title: title, startURL: startURL, steps: steps, source: source, effect: effect)
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
        let carriesSecretQuery = (components.queryItems ?? []).contains {
            credentialQueryNames.contains($0.name.lowercased())
        }
        guard components.user == nil, components.password == nil, !carriesSecretQuery else {
            throw SkillPackLoadError.urlCarriesCredential(field: field)
        }
        return url
    }

    /// The first of `phrases` that appears in `text` as whole words, compared folded.
    static func firstPhrase(of phrases: [String], in text: String) -> String? {
        let haystack = SearchText.normalized(text)
        return phrases.first { SkillPhraseMatch.firstIndex(of: SearchText.normalized($0), in: haystack) != nil }
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
