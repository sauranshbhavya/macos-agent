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
            "flows": depth == "deep" ? [flow()] : []
        ]
    }

    static func flow(
        title: String = "Create a page",
        steps: [String] = ["Click the new page icon.", "Type a title."],
        effect: String = "changes"
    ) -> [String: Any] {
        [
            "title": title,
            "startURL": "https://www.example.com/",
            "steps": steps,
            "source": "https://www.example.com/help/create",
            "effect": effect
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

    // MARK: - Finance packs read only (SONNY-461, decision 4)

    @Test
    func aFinanceFlowThatDeclaresAChangeDoesNotLoad() throws {
        var object = SkillPackFixtures.object(id: "mercury", name: "Mercury", domain: "mercury.com", category: "finance_billing")
        object["flows"] = [SkillPackFixtures.flow(title: "Download a statement", steps: ["Open Statements.", "Pick a month."], effect: "changes")]
        #expect(Self.error(object) == .readOnlyPackChangesSomething(flow: "Download a statement"))
    }

    /// Declaring `reads` is not enough: the wording is checked too, so a money-moving flow cannot
    /// load under a declaration that says otherwise.
    @Test
    func aFinanceFlowThatMovesMoneyDoesNotLoadWhateverItDeclares() throws {
        let cases: [(steps: [String], phrase: String)] = [
            (["Open Payments.", "Send the amount to the vendor."], "send"),
            (["Open Transfers.", "Transfer the balance."], "transfer"),
            (["Open Bills.", "Pay the invoice."], "pay"),
            (["Open Recipients.", "Add a new payee."], "payee"),
            (["Open Settings.", "Update the payment details."], "payment details")
        ]
        for testCase in cases {
            var object = SkillPackFixtures.object(id: "wise", name: "Wise", domain: "wise.com", category: "finance_billing")
            object["flows"] = [SkillPackFixtures.flow(title: "Handle a bill", steps: testCase.steps, effect: "reads")]
            guard case .movesMoney(flow: "Handle a bill", phrase: _)? = Self.error(object) else {
                Issue.record("\(testCase.steps) loaded in a finance pack")
                continue
            }
        }

        // The control: reading statements and transaction history is what a finance pack is for.
        var reading = SkillPackFixtures.object(id: "wise", name: "Wise", domain: "wise.com", category: "finance_billing")
        reading["flows"] = [SkillPackFixtures.flow(title: "Download a statement", steps: ["Open Statements.", "Pick the month and download it."], effect: "reads")]
        #expect(Self.error(reading) == nil)
    }

    /// The unambiguous money-moving phrases are refused in every pack, whatever its category — and
    /// as whole words, so an ordinary sentence that happens to contain a money word still loads.
    @Test
    func anyPackThatMovesMoneyDoesNotLoadButAWordThatOnlyLooksLikeMoneyDoes() throws {
        var refund = SkillPackFixtures.object(id: "shopify", name: "Shopify", domain: "shopify.com", category: "websites_apps_commerce")
        refund["flows"] = [SkillPackFixtures.flow(title: "Issue a refund", steps: ["Open the order.", "Click Refund."])]
        #expect(Self.error(refund) == .movesMoney(flow: "Issue a refund", phrase: "issue a refund"))

        var ownership = SkillPackFixtures.object()
        ownership["flows"] = [SkillPackFixtures.flow(title: "Transfer ownership of a page", steps: ["Open Share.", "Send the page to a teammate."])]
        #expect(Self.error(ownership) == nil)
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

    @Test
    func aURLCarryingACredentialDoesNotLoad() throws {
        var object = SkillPackFixtures.object()
        object["signInURL"] = "https://notion.so/login?token=abc123"
        #expect(Self.error(object) == .urlCarriesCredential(field: "signInURL"))

        object = SkillPackFixtures.object()
        object["signInURL"] = "https://someone:secret@notion.so/login"
        #expect(Self.error(object) == .urlCarriesCredential(field: "signInURL"))
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
