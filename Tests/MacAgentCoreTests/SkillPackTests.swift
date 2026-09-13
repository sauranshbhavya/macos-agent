import Foundation
import Testing
@testable import MacAgentCore

/// A pack that passes every rule, built as the JSON a pack author writes and decoded through the
/// real loader — so a fixture pack cannot be something the loader would refuse.
enum SkillPackFixtures {
    static func object(
        id: String = "notion",
        name: String = "Notion",
        domain: String = "notion.so",
        category: String = "knowledge_bases",
        depth: String = "deep"
    ) -> [String: Any] {
        [
            "format": 1,
            "id": id,
            "name": name,
            "domain": domain,
            "category": category,
            "summary": "A site used in tests.",
            "signInURL": "https://\(domain)/login",
            "triggers": [name.lowercased()],
            "sections": [],
            "depth": depth,
            "flows": depth == "deep" ? [flow(on: domain)] : []
        ]
    }

    /// A flow starting on `domain`'s own site, which every flow has to (PR #241's F4). Its citation is
    /// deliberately on another host, because the rule does not hold citations to the site.
    static func flow(
        title: String = "Create a page",
        steps: [String] = ["Click the new page icon.", "Type a title."],
        on domain: String = "notion.so"
    ) -> [String: Any] {
        [
            "title": title,
            "startURL": "https://www.\(domain)/",
            "steps": steps,
            "source": "https://www.example.com/help/create"
        ]
    }

    static func data(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func pack(id: String, name: String, domain: String) throws -> SkillPack {
        try SkillPackDecoder.decode(data(object(id: id, name: name, domain: domain)))
    }
}

@Suite
struct SkillPackTests {
    // MARK: - The shipped packs and the committed catalogue

    /// Every pack the app ships loads, with no failure — read from the source tree, which is the
    /// directory the app target's `Resources/` rule copies, so this is the population that ships.
    @Test
    func everyShippedPackLoadsAndEveryOneIsARowOfTheCommittedCatalogue() throws {
        let files = SkillPackCatalog.packFileURLs(in: Self.shippedPacksDirectory)
        // The control: the walk found the files at all, so an empty failure list below is not an
        // empty directory agreeing with itself.
        #expect(files.count >= 3)

        let catalogue = SkillPackCatalog.load(fileURLs: files)

        #expect(catalogue.failures == [])
        #expect(catalogue.packs.count == files.count)
        #expect(Set(catalogue.packs.map(\.id)).isSuperset(of: ["notion", "linear", "docusign"]))

        let rows = try Self.catalogueRows()
        let rowsByID = Dictionary(uniqueKeysWithValues: rows.map { ($0["id"]!, $0) })
        for pack in catalogue.packs {
            let row = try #require(rowsByID[pack.id], "\(pack.id) ships as a pack but is not a catalogue row")
            #expect(row["domain"] == pack.domain, "\(pack.id)'s domain disagrees with its catalogue row")
            #expect(row["category"] == pack.category, "\(pack.id)'s category disagrees with its catalogue row")
            #expect(row["task_flow_docs"] == pack.depth.rawValue, "\(pack.id)'s depth disagrees with its catalogue row")
        }
    }

    /// The catalogue is the SONNY-461 list with the founders' 2026-09-12 decisions applied: the four
    /// unresolved names and the four password managers out, Zapier, Make and n8n in.
    @Test
    func theCommittedCatalogueIsTheListTheFoundersDecided() throws {
        let rows = try Self.catalogueRows()
        let ids = rows.map { $0["id"]! }

        #expect(rows.count == 473)
        #expect(Set(ids).count == ids.count, "an id appears twice")
        for dropped in ["affiliates", "content_admin", "support_console", "user_insights",
                        "lastpass", "onepassword", "bitwarden", "dashlane"] {
            #expect(!ids.contains(dropped), "\(dropped) was dropped by founder decision")
        }
        for added in ["zapier", "make", "n8n"] {
            #expect(ids.contains(added), "\(added) was added by founder decision")
        }
        #expect(Set(rows.map { $0["task_flow_docs"]! }) == ["deep", "shallow"])
        #expect(rows.filter { $0["why_in_list"]!.hasPrefix("founder-named") }.count == 100)
        for row in rows {
            #expect(!row["domain"]!.isEmpty, "\(row["id"]!) has no domain")
        }
    }

    /// **Every shipped trigger is distinctive or anchored to its own site** (founders, 2026-09-13,
    /// option A on PR #241's F3: a pack matches only on its triggers, and the validating test refuses
    /// a trigger that would match ordinary language).
    ///
    /// How "ordinary language" is decided, and it is decided here rather than at launch — the loader
    /// runs on every launch and this runs before a pack ships (launch-time validation is SONNY-476):
    /// - **One word** is refused when it is two characters or fewer, only digits, or a word in macOS's
    ///   own word list (`/usr/share/dict/words`), so "make", "close", "x", "hey", "slack", "notion"
    ///   and "linear" are refused and "docusign", "zapier" and "n8n" are not.
    /// - **A phrase** is refused when every word in it is ordinary *and* none of them is the site's
    ///   own name, so "new page" is refused while "in notion" and "make scenario" are not.
    /// - **A dotted trigger** ("make.com") is allowed: ordinary language does not carry a dot inside a
    ///   word.
    @Test
    func everyShippedTriggerIsDistinctiveOrAnchoredToItsSite() throws {
        let ordinary = try Self.ordinaryWords()
        let catalogue = SkillPackCatalog.load(fileURLs: SkillPackCatalog.packFileURLs(in: Self.shippedPacksDirectory))
        #expect(catalogue.packs.count >= 3)
        for pack in catalogue.packs {
            #expect(!pack.triggers.isEmpty)
            for trigger in pack.triggers {
                #expect(Self.triggerProblem(trigger, siteName: pack.name, ordinary: ordinary) == nil, "\(pack.id): \(trigger)")
            }
        }
    }

    /// The check itself, held to the review's words in both directions, so a check that let
    /// everything through could not pass the shipped packs vacuously.
    @Test
    func theTriggerCheckRefusesOrdinaryLanguageAndAllowsTheSitesOwnWords() throws {
        let ordinary = try Self.ordinaryWords()
        let refused: [(trigger: String, site: String)] = [
            ("make", "Make"), ("close", "Close"), ("x", "X"), ("hey", "HEY"), ("front", "Front"),
            ("instantly", "Instantly"), ("segment", "Segment"), ("notion", "Notion"), ("linear", "Linear"),
            ("slack", "Slack"), ("1280", "Probe"), ("new page", "Notion"), ("post it", "Slack")
        ]
        for entry in refused {
            #expect(Self.triggerProblem(entry.trigger, siteName: entry.site, ordinary: ordinary) != nil, "\(entry.trigger) was allowed")
        }
        let allowed: [(trigger: String, site: String)] = [
            ("docusign", "Docusign"), ("zapier", "Zapier"), ("n8n", "n8n"), ("make.com", "Make"),
            ("make scenario", "Make"), ("in notion", "Notion"), ("post on x", "X"), ("linear issue", "Linear")
        ]
        for entry in allowed {
            #expect(Self.triggerProblem(entry.trigger, siteName: entry.site, ordinary: ordinary) == nil, "\(entry.trigger) was refused")
        }
    }

    // MARK: - What a pack must carry

    @Test
    func aWellFormedPackLoads() throws {
        let pack = try SkillPackDecoder.decode(SkillPackFixtures.data(SkillPackFixtures.object()))
        #expect(pack.id == "notion")
        #expect(pack.flows.count == 1)
        #expect(pack.flows[0].source.absoluteString == "https://www.example.com/help/create")
        #expect(pack.guidance.contains("(steps from https://www.example.com/help/create)"))
    }

    @Test(arguments: ["format", "id", "name", "domain", "category", "summary", "signInURL", "triggers", "sections", "depth", "flows"])
    func aPackMissingAFieldDoesNotLoad(field: String) throws {
        var object = SkillPackFixtures.object()
        object.removeValue(forKey: field)
        #expect(Self.error(object) == .missingField(field))
    }

    @Test
    func aBlankFieldIsAMissingOne() throws {
        var object = SkillPackFixtures.object()
        object["summary"] = "   "
        #expect(Self.error(object) == .missingField("summary"))
        object = SkillPackFixtures.object()
        object["triggers"] = []
        #expect(Self.error(object) == .missingField("triggers"))
    }

    /// A pack cannot carry a field this build does not understand — which is what makes "a pack
    /// cannot make anything ask less" structural rather than a promise about today's fields.
    @Test
    func aFieldTheFormatDoesNotKnowIsRefusedRatherThanIgnored() throws {
        var object = SkillPackFixtures.object()
        object["approval"] = "none"
        #expect(Self.error(object) == .unknownField("approval"))

        object = SkillPackFixtures.object()
        var flow = SkillPackFixtures.flow()
        flow["preApprovedApps"] = ["Safari"]
        object["flows"] = [flow]
        #expect(Self.error(object) == .unknownField("flows[0].preApprovedApps"))
    }

    @Test
    func aURLThatIsNotHTTPSDoesNotLoad() throws {
        var object = SkillPackFixtures.object()
        object["signInURL"] = "http://notion.so/login"
        #expect(Self.error(object) == .notHTTPS(field: "signInURL"))

        object = SkillPackFixtures.object()
        var flow = SkillPackFixtures.flow()
        flow["startURL"] = "notion.so"
        object["flows"] = [flow]
        #expect(Self.error(object) == .notHTTPS(field: "flows[0].startURL"))
    }

    @Test
    func aDeepPackWithNoFlowsAndAShallowPackWithFlowsBothFail() throws {
        var deep = SkillPackFixtures.object()
        deep["flows"] = []
        #expect(Self.error(deep) == .deepPackHasNoFlows)

        var shallow = SkillPackFixtures.object(depth: "shallow")
        shallow["flows"] = [SkillPackFixtures.flow()]
        #expect(Self.error(shallow) == .shallowPackHasFlows)

        // The control: a shallow pack with no flows and a null sign-in page is a pack.
        var bare = SkillPackFixtures.object(depth: "shallow")
        bare["signInURL"] = NSNull()
        #expect(Self.error(bare) == nil)
    }

    /// The founders' evidence rule (SONNY-461): a step nobody can check against a public page is
    /// Sonny doing the wrong thing on a live account.
    @Test
    func aFlowWithNoCitationDoesNotLoad() throws {
        for source in [nil, "", "  "] as [String?] {
            var object = SkillPackFixtures.object()
            var flow = SkillPackFixtures.flow()
            flow["source"] = source
            object["flows"] = [flow]
            #expect(Self.error(object) == .flowHasNoCitation(flow: "Create a page"))
        }
    }

    @Test
    func aFlowWithNoStepsDoesNotLoad() throws {
        var object = SkillPackFixtures.object()
        object["flows"] = [SkillPackFixtures.flow(steps: [])]
        #expect(Self.error(object) == .flowHasNoSteps(flow: "Create a page"))
    }

    // MARK: - No flow moves money, in any pack (founders, 2026-09-13)

    /// The founders' rule names no category, so neither does this test: every money-moving flow is
    /// refused in a finance pack, a store, a CRM and a knowledge base alike. As first built the rule
    /// held finance packs alone, and a store pack could have taught Sonny to issue a refund.
    ///
    /// **The second half of the table is PR #241's F1**, every row of which loaded at `12ebe84a`:
    /// payouts, SEPA, ACH and bank transfers, a currency amount, a wire, adding a recipient or a
    /// beneficiary, replacing a bank account, updating a card, running payroll, reimbursing, capturing
    /// a payment, and "send money" spelled with two spaces, a tab and a no-break space.
    @Test(arguments: ["finance_billing", "websites_apps_commerce", "sales_crm", "knowledge_bases"])
    func aFlowThatMovesMoneyDoesNotLoadWhateverTheCategory(category: String) throws {
        let flows: [(title: String, steps: [String])] = [
            ("Pay a vendor", ["Open Bills.", "Pay the invoice."]),
            ("Send money", ["Open Payments.", "Send money to the vendor."]),
            ("Move the balance", ["Open Transfers.", "Transfer funds to savings."]),
            ("Issue a refund", ["Open the order.", "Click Refund."]),
            ("Pay out a partner", ["Open Payouts.", "Pay out the balance."]),
            ("Update a payee", ["Open Recipients.", "Edit the payee."]),
            ("Change how you are paid", ["Open Settings.", "Update the payment details."]),
            ("Charge a customer", ["Open Customers.", "Charge the card on file."]),
            ("Approve a bill", ["Open Bills.", "Approve the bill."]),
            ("Take money out", ["Open the account.", "Withdraw the balance."]),
            ("Create a payout", ["Open Balances.", "Click Payout and confirm the amount."]),
            ("Send a SEPA transfer", ["Go to Transfers and click New transfer.", "Choose a beneficiary, or add a new one with their IBAN.", "Enter the amount and a reference, then confirm."]),
            ("Transfer $500 to savings", ["Open Accounts.", "Transfer 500 USD to the savings account."]),
            ("Send a wire", ["Open Payments.", "Send a wire to the recipient."]),
            ("Add a recipient", ["Open Recipients.", "Add a new recipient with their bank account."]),
            ("Change the bank account", ["Open Settings.", "Replace the bank account used for payouts."]),
            ("Update the card on file", ["Open Billing.", "Update the card."]),
            ("Run payroll", ["Open Payroll.", "Review the payroll and submit it."]),
            ("Reimburse an expense", ["Open Expenses.", "Reimburse the employee."]),
            ("Capture a payment", ["Open the payment.", "Click Capture."]),
            ("Initiate an ACH transfer", ["Open Transfers.", "Initiate an ACH transfer."]),
            ("Settle up with a vendor", ["Open Vendors.", "Send  money to the vendor."]),
            ("Move savings", ["Open Accounts.", "Transfer\tfunds to savings."]),
            ("Settle a debt", ["Open Contacts.", "Send\u{00A0}money to them."])
        ]
        for testFlow in flows {
            var object = SkillPackFixtures.object(id: "store", name: "Store", domain: "store.example.com", category: category)
            object["flows"] = [SkillPackFixtures.flow(title: testFlow.title, steps: testFlow.steps, on: "store.example.com")]
            guard case .movesMoney(field: "flows[0]", words: _)? = Self.error(object) else {
                Issue.record("\(testFlow.title) did not refuse as moving money in a \(category) pack: \(String(describing: Self.error(object)))")
                continue
            }
        }
    }

    /// The summary and the sections reach the planner too, so they are read by the same rule — each
    /// section on its own, so two harmless labels cannot pair into a refusal (PR #241's F1).
    @Test
    func aSummaryOrASectionThatMovesMoneyDoesNotLoad() throws {
        var summary = SkillPackFixtures.object(domain: "wise.com")
        summary["summary"] = "Send money and pay bills."
        #expect(Self.error(summary) == .movesMoney(field: "summary", words: "pay"))

        var sections = SkillPackFixtures.object(domain: "wise.com", depth: "shallow")
        sections["sections"] = ["Home", "Pay bills", "Send money", "Refunds"]
        #expect(Self.error(sections) == .movesMoney(field: "sections[1]", words: "pay"))

        // The controls: a summary and sections that only name money load.
        var reading = SkillPackFixtures.object(domain: "wise.com", depth: "shallow")
        reading["summary"] = "Payouts, balances and statements for a business account."
        reading["sections"] = ["Home", "Payments", "Payouts", "Refunds", "Create", "Settings"]
        #expect(Self.error(reading) == nil)
    }

    /// What a pack may still say: reading orders, invoices, statements and payouts — the founders'
    /// named allowance — and the ordinary "send", "transfer", "add a recipient" and "move a card" that
    /// have nothing to do with money. Whole words, so "refunded" is not "refund" and "payouts" is not
    /// "pay"; and a *recipient* or a *card* counts as money only beside a money word.
    @Test
    func readingMoneyAndAnOrdinarySendOrTransferStillLoad() throws {
        let flows: [(title: String, steps: [String])] = [
            ("Download a statement", ["Open Statements.", "Pick the month and download it."]),
            ("Review payouts", ["Open Payouts.", "Filter the payouts and payments by date."]),
            ("Check a payout's status", ["Open Payouts.", "Find the payout and read its status."]),
            ("Find refunded orders", ["Open Orders.", "Filter to refunded orders."]),
            ("Read an invoice", ["Open Invoices.", "Open the invoice to see its lines."]),
            ("Export payments", ["Open Payments.", "Export the list as a CSV file."]),
            ("Share a page", ["Open Share.", "Send the page to a teammate."]),
            ("Transfer ownership of a page", ["Open the page's settings.", "Transfer ownership to a teammate."]),
            ("Address an email", ["Open Compose.", "Add a recipient."]),
            ("Move a card", ["Open the board.", "Move the card to Done."])
        ]
        for testFlow in flows {
            var object = SkillPackFixtures.object(id: "wise", name: "Wise", domain: "wise.com", category: "finance_billing")
            object["flows"] = [SkillPackFixtures.flow(title: testFlow.title, steps: testFlow.steps, on: "wise.com")]
            #expect(Self.error(object) == nil, "\(testFlow.title) was refused: \(String(describing: Self.error(object)))")
        }
    }

    /// The fields the category rule used to read are gone from the format, so a pack still carrying
    /// one is refused like any other unknown field rather than read under a rule that no longer exists.
    @Test
    func aFlowStillDeclaringAnEffectIsAnUnknownField() throws {
        var object = SkillPackFixtures.object()
        var flow = SkillPackFixtures.flow()
        flow["effect"] = "reads"
        object["flows"] = [flow]
        #expect(Self.error(object) == .unknownField("flows[0].effect"))
    }

    // MARK: - No credentials

    @Test
    func aPackThatAsksForACredentialDoesNotLoad() throws {
        var object = SkillPackFixtures.object()
        object["flows"] = [SkillPackFixtures.flow(steps: ["Open the sign-in page.", "Type the user's password."])]
        #expect(Self.error(object) == .mentionsCredential(field: "flows.steps", phrase: "password"))

        object = SkillPackFixtures.object()
        object["summary"] = "Where your API key lives."
        #expect(Self.error(object) == .mentionsCredential(field: "summary", phrase: "api key"))
    }

    /// **The usual words for a credential** (PR #241's F2), every one of which loaded at `12ebe84a`,
    /// with an uppercase `PIN` refused and the lowercase "pin" of a chat tool left alone.
    @Test(arguments: [
        "Enter your credentials.", "Type your PIN.", "Paste the API token.", "Enter the OTP.",
        "Enter the two-factor code.", "Use a backup code.", "Paste the client secret.",
        "Enter the one-time password.", "Type the 2FA code from your phone."
    ])
    func aStepNamingAnyUsualCredentialDoesNotLoad(step: String) throws {
        var object = SkillPackFixtures.object()
        object["flows"] = [SkillPackFixtures.flow(steps: ["Open the sign-in page.", step])]
        guard case .mentionsCredential(field: "flows.steps", phrase: _)? = Self.error(object) else {
            Issue.record("\(step) loaded: \(String(describing: Self.error(object)))")
            return
        }
    }

    @Test
    func aChatToolsLowercasePinStillLoads() throws {
        var object = SkillPackFixtures.object()
        object["flows"] = [SkillPackFixtures.flow(steps: ["Open the channel.", "Pin the message to the channel."])]
        #expect(Self.error(object) == nil)
    }

    @Test
    func aURLCarryingACredentialDoesNotLoad() throws {
        var object = SkillPackFixtures.object()
        object["signInURL"] = "https://notion.so/login?token=abc123"
        #expect(Self.error(object) == .urlCarriesCredential(field: "signInURL"))

        object = SkillPackFixtures.object()
        object["signInURL"] = "https://someone:secret@notion.so/login"
        #expect(Self.error(object) == .urlCarriesCredential(field: "signInURL"))

        // The fragment too (PR #241's F2): an implicit-grant sign-in hands a token back there.
        object = SkillPackFixtures.object()
        var flow = SkillPackFixtures.flow()
        flow["startURL"] = "https://www.notion.so/#access_token=abc123"
        object["flows"] = [flow]
        #expect(Self.error(object) == .urlCarriesCredential(field: "flows[0].startURL"))

        // The control: a fragment that is only a page anchor loads.
        object = SkillPackFixtures.object()
        flow = SkillPackFixtures.flow()
        flow["startURL"] = "https://www.notion.so/help#sharing"
        object["flows"] = [flow]
        #expect(Self.error(object) == nil)
    }

    // MARK: - A flow starts on the pack's own site (PR #241's F4)

    @Test
    func aFlowWhoseStartPageIsOnAnotherSiteDoesNotLoad() throws {
        var object = SkillPackFixtures.object()
        var flow = SkillPackFixtures.flow()
        flow["startURL"] = "https://evil.example.org/"
        object["flows"] = [flow]
        #expect(Self.error(object) == .startPageOffSite(flow: "Create a page", host: "evil.example.org"))

        // A look-alike that only ends in the domain's letters is another site.
        object = SkillPackFixtures.object()
        flow = SkillPackFixtures.flow()
        flow["startURL"] = "https://notnotion.so/"
        object["flows"] = [flow]
        #expect(Self.error(object) == .startPageOffSite(flow: "Create a page", host: "notnotion.so"))

        // The controls: the domain itself and a subdomain load, and a citation on another host
        // loads, because a help centre often lives elsewhere.
        for startURL in ["https://notion.so/", "https://www.notion.so/new"] {
            object = SkillPackFixtures.object()
            flow = SkillPackFixtures.flow()
            flow["startURL"] = startURL
            flow["source"] = "https://www.notion.com/help/create-your-first-page"
            object["flows"] = [flow]
            #expect(Self.error(object) == nil, "\(startURL) was refused")
        }
    }

    // MARK: - Bounds and identity

    @Test
    func aPackWhoseGuidanceIsOverTheCeilingDoesNotLoad() throws {
        var object = SkillPackFixtures.object()
        object["flows"] = [SkillPackFixtures.flow(steps: Array(repeating: String(repeating: "Click the button. ", count: 20), count: 20))]
        guard case .guidanceTooLong(let bytes)? = Self.error(object) else {
            Issue.record("an oversized pack loaded")
            return
        }
        #expect(bytes > SkillPack.guidanceByteLimit)
    }

    @Test
    func anUnknownFormatOrAnIDThatIsNotASlugDoesNotLoad() throws {
        var object = SkillPackFixtures.object()
        object["format"] = 2
        #expect(Self.error(object) == .unsupportedFormat(2))

        object = SkillPackFixtures.object()
        object["id"] = "Notion!"
        #expect(Self.error(object) == .invalidID("Notion!"))
    }

    /// Two packs claiming one id are both refused — nothing says which is right, and keeping the one
    /// that sorted first would make that an accident of file naming — and a malformed file costs its
    /// own site and nothing else.
    @Test
    func duplicateIDsAreAllRefusedAndOneBadFileCostsOnlyItself() throws {
        let catalogue = SkillPackCatalog.load(files: [
            ("a.skillpack.json", try SkillPackFixtures.data(SkillPackFixtures.object(id: "notion"))),
            ("b.skillpack.json", try SkillPackFixtures.data(SkillPackFixtures.object(id: "notion"))),
            ("c.skillpack.json", try SkillPackFixtures.data(SkillPackFixtures.object(id: "linear", name: "Linear", domain: "linear.app"))),
            ("d.skillpack.json", Data("not json".utf8))
        ])

        #expect(catalogue.packs.map(\.id) == ["linear"])
        #expect(catalogue.failures == [
            SkillPackLoadFailure(fileName: "d.skillpack.json", error: .notAJSONObject),
            SkillPackLoadFailure(fileName: "a.skillpack.json", error: .duplicateID("notion")),
            SkillPackLoadFailure(fileName: "b.skillpack.json", error: .duplicateID("notion"))
        ])
    }

    // MARK: - Helpers

    static func error(_ object: [String: Any]) -> SkillPackLoadError? {
        do {
            _ = try SkillPackDecoder.decode(SkillPackFixtures.data(object))
            return nil
        } catch let error as SkillPackLoadError {
            return error
        } catch {
            Issue.record("unexpected error \(error)")
            return nil
        }
    }

    /// macOS's own word list, lowercased. Required rather than skipped when absent: a trigger check
    /// that quietly stopped reading ordinary language would pass every pack.
    static func ordinaryWords() throws -> Set<String> {
        let text = try String(contentsOf: URL(fileURLWithPath: "/usr/share/dict/words"), encoding: .utf8)
        let words = Set(text.split(separator: "\n").map { $0.lowercased() })
        try #require(words.count > 100_000, "the system word list is missing or truncated")
        return words
    }

    /// Why `trigger` would match ordinary language for a site called `siteName`, or `nil`.
    static func triggerProblem(_ trigger: String, siteName: String, ordinary: Set<String>) -> String? {
        let folded = SearchText.normalized(trigger)
        if folded.contains(".") && !folded.contains(" ") {
            return nil
        }
        let words = SkillWords.cut(folded)
        guard !words.isEmpty else { return "has no words" }
        if words.count == 1 {
            let word = words[0]
            if word.count <= 2 { return "\(word) is two characters or fewer" }
            if word.allSatisfy(\.isNumber) { return "\(word) is only digits" }
            if ordinary.contains(word) { return "\(word) is an ordinary word" }
            return nil
        }
        let nameWords = Set(SkillWords.cut(SearchText.normalized(siteName)))
        let anchored = words.contains { nameWords.contains($0) }
        let allOrdinary = words.allSatisfy { ordinary.contains($0) || $0.count <= 2 }
        return allOrdinary && !anchored ? "every word of \(trigger) is ordinary and none is the site's name" : nil
    }

    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    static var shippedPacksDirectory: URL {
        repositoryRoot.appendingPathComponent("Sources/MacAgent/Resources/SkillPacks")
    }

    /// The committed catalogue's rows as column-name dictionaries, refusing a row with the wrong
    /// number of columns rather than reading it shifted.
    static func catalogueRows() throws -> [[String: String]] {
        let text = try String(contentsOf: repositoryRoot.appendingPathComponent("docs/sonny-skill-sites.tsv"), encoding: .utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let header = try #require(lines.first).components(separatedBy: "\t")
        #expect(header == ["id", "name", "domain", "category", "rank_in_category", "why_in_list", "sign_in_url", "task_flow_docs", "doc_url_1", "doc_url_2", "doc_url_3"])
        return try lines.dropFirst().map { line in
            let columns = line.components(separatedBy: "\t")
            try #require(columns.count == header.count, "a catalogue row has \(columns.count) columns: \(line.prefix(40))")
            return Dictionary(uniqueKeysWithValues: zip(header, columns))
        }
    }
}
