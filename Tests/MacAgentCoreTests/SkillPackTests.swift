import Foundation
import MacAgentTestSupport
import Testing
@testable import MacAgentCore

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
            // The pack's `signInURL` decides and the row mirrors it (SONNY-524): `SkillPack.signInURL`'s doc
            // comment says why. An empty cell is a pack with no sign-in page of its own.
            #expect(row["sign_in_url"] == (pack.signInURL?.absoluteString ?? ""), "\(pack.id)'s sign-in page disagrees with its catalogue row")
            // A deep pack needs a row whose flows rest on evidence somebody read — documentation
            // (`deep`) or the live site (`site`). A shallow pack may sit on any row: every site gets one
            // before its flows are written (founders, SONNY-463 decision 2).
            let evidence = try #require(row["task_flow_docs"])
            let pages = try ["doc_url_1", "doc_url_2", "doc_url_3"].map { try #require(row[$0]) }
            let problem = Self.depthProblem(pack.depth, taskFlowDocs: evidence, pages: pages)
            #expect(problem == nil, "\(pack.id) \(problem ?? "")")
        }
    }

    /// **Every catalogue row has exactly one pack**, the direction the test above does not hold
    /// (review-247's R4, SONNY-492). That test looks each pack up among the rows, and its count check
    /// compares the files with the packs they load, so a row whose pack file is missing passes it:
    /// both counts drop by one and nothing looks the row up. The deep-pack lanes rewrite these files.
    ///
    /// **A count of 2 cannot occur, and that is the loader rather than this test** (PR #251's review,
    /// R2). `SkillPackCatalog.load(files:)` refuses *every* file claiming an id another file claims —
    /// `duplicateIDsAreAllRefusedAndOneBadFileCostsOnlyItself` holds that — so a pack file copied
    /// under a second name leaves its row with no pack at all, and this test's message reads "0 loaded
    /// packs" for what is really a duplicate. The review measured exactly that. `== 1` is written
    /// because one pack per row is the property, not because 2 is reachable. A duplicated catalogue
    /// *row* is a different thing and is not this test's job:
    /// `theCommittedCatalogueIsTheListTheFoundersDecided` fails on it, while this loop would find that
    /// row's one pack twice over and pass.
    @Test
    func everyCatalogueRowHasExactlyOnePack() throws {
        let rows = try Self.catalogueRows()
        // The control: the catalogue was read, so a loop that finds nothing wrong is not a loop over
        // no rows.
        #expect(rows.count >= 3)

        let catalogue = SkillPackCatalog.load(fileURLs: SkillPackCatalog.packFileURLs(in: Self.shippedPacksDirectory))
        let packsByID = Dictionary(grouping: catalogue.packs, by: \.id)
        for row in rows {
            let id = try #require(row["id"])
            #expect(packsByID[id]?.count == 1, "\(id) is a catalogue row with \(packsByID[id]?.count ?? 0) loaded packs")
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
        // Two of the column's three values are in use: the flows rest on re-openable documentation on
        // 424 rows and on the running product on the other 49, and no row says `shallow` any more
        // (`awk -F'\t' 'NR > 1 {c[$8]++} END {for (k in c) print k, c[k]}' docs/sonny-skill-sites.tsv`).
        // No SHA beside those numbers deliberately: this assertion re-counts them on every run, so
        // unlike a stamped figure they cannot describe a tree that has since moved. It is also the
        // whole vocabulary check — a fourth word, or a near-miss spelling of one of these two, cannot
        // make this dictionary equal, so a separate set-membership assertion added only a message
        // (review-260's F3).
        let evidence = rows.map { $0["task_flow_docs"]! }
        #expect(Dictionary(evidence.map { ($0, 1) }, uniquingKeysWith: +) == ["deep": 425, "site": 48])
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
    /// - **A word is ordinary** when it, or its singular form (`-s`, `-es`, `-ies` → `-y`), is in
    ///   macOS's own word list (`/usr/share/dict/words`), in `modernWords` or in
    ///   `ordinaryWordsTheSystemListLacks` below. So "make",
    ///   "close", "x", "slack", "notion", "teams", "docs", "sheets" and "email" are ordinary, and
    ///   "docusign", "zapier", "gmail" and "n8n" are not.
    /// - **One word** is refused when it is ordinary, two characters or fewer, or only digits.
    /// - **A phrase** is refused when every word in it is ordinary *and* it does not carry the site's
    ///   whole name, so "new page" and "new docs" (for Google Docs) are refused while "in notion",
    ///   "make scenario" and "google docs" are not.
    /// - **A dotted trigger** ("make.com") is allowed: ordinary language does not carry a dot inside a
    ///   word.
    ///
    /// **Why the singular form and a short list, and not a vendored word list** (PR #241's delta pass).
    /// The system list is a 1934 list of headwords with almost no plurals and few modern words, so
    /// "teams", "docs", "sheets", "forms", "slides", "tasks", "email" and "inbox" passed while "team",
    /// "doc" and "sheet" were refused — and the catalogue holds Microsoft Teams, Google Docs, Sheets,
    /// Forms, Slides, Tasks and Gmail. The singular form closes the systematic gap, plurals, with one
    /// rule; `modernWords` names the post-1934 words a work tool's trigger is likeliest to be, and it
    /// is short enough to read in review. Vendoring an inflected list was the other road: it would
    /// remove the dependency on the operating system's file, but it brings a third-party list to
    /// license, vet and keep current, several megabytes to commit, and a list nobody reviews. The delta
    /// pass judged the system list not machine state (it is on the sealed system volume, and the test
    /// fails loudly when it is missing); **the residual it named stands**: Apple can change that file
    /// in a macOS update, and what this test refuses would then move with nothing in this repository
    /// changing.
    ///
    /// **The system list has gaps for ordinary words as well as modern ones** (SONNY-492). It spells
    /// neither "box" nor "boxes", while "cat", "fox" and "tax" are all there. So `box`, `expo`, `grok`
    /// and `podia` passed as one-word triggers until a person reading every one caught them, and they
    /// are in this file's own lists now. Nothing predicts where the next gap is.
    ///
    /// **What this check still cannot catch:** an ordinary phrase that contains the site's name
    /// ("close deal"); a modern word, or an ordinary word the system list does not spell, that neither
    /// of this file's lists holds; an irregular plural the system list does not spell and the suffix
    /// rules do not reach ("women", "feet" — "people" is in the list and is refused); and what a
    /// command means.
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

    /// **Only this file reads the shipped packs folder** (SONNY-481). The pack lanes add packs there, and
    /// a test elsewhere that reads it for a page's rows or a planner's prompt goes red on a well-formed
    /// pack for no product reason — the Skills suite in `MemoryCommandCenterTests` did, until it moved to
    /// `SkillPackFixtures.catalogue()`. Every Swift file under `Tests/` goes through
    /// `readsTheShippedPacks(_:)`, and so do the held samples, so the check the files meet is the check
    /// the samples prove.
    ///
    /// **What it does not see** (PR #245's review): a path assembled from pieces; a read of the built
    /// resource bundle (`Bundle(url:)` and its `resourceURL`), which is how `SonnyResourceBundle` itself
    /// reads the packs; a call to `AgentViewModel.atItsRealStoreLocations()`, which reads them through
    /// `SonnyResourceBundle`; and a CRLF file whose first line is a line comment, because `"\r\n"` is
    /// one `Character`, so the file never splits and reads as one comment line. And the exemption is
    /// the whole of this file, not only its validating tests: a test added here could pin shipped
    /// contents and pass.
    ///
    /// **The `readers` assertion does not show the validating tests read the folder.** This file's own
    /// sample lines and `shippedPacksDirectory` satisfy it on their own. What shows the read is the
    /// validating tests' own count checks: `catalogue.packs.count == files.count` and `>= 3`.
    @Test
    func onlyTheValidatingTestsReadTheShippedPacksFolder() throws {
        let root = Self.repositoryRoot.standardizedFileURL.path + "/"
        let enumerator = try #require(FileManager.default.enumerator(at: Self.repositoryRoot.appendingPathComponent("Tests"), includingPropertiesForKeys: nil))
        var scanned: Set<String> = []
        var readers: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let path = url.standardizedFileURL.path.replacingOccurrences(of: root, with: "")
            scanned.insert(path)
            if Self.readsTheShippedPacks(try String(contentsOf: url, encoding: .utf8)) {
                readers.append(path)
            }
        }

        // The control: the walk reached this file and the suite that used to read the folder.
        #expect(scanned.isSuperset(of: ["Tests/MacAgentCoreTests/SkillPackTests.swift", "Tests/MacAgentTests/MemoryCommandCenterTests.swift"]))
        // This file's own sample lines satisfy this on their own; the validating tests' count checks
        // are what show they read the folder.
        #expect(readers == ["Tests/MacAgentCoreTests/SkillPackTests.swift"])

        #expect(Self.readsTheShippedPacks(#"    .appendingPathComponent("Sources/MacAgent/Resources/SkillPacks")"#))
        #expect(Self.readsTheShippedPacks("    let catalogue = SonnyResourceBundle.skillPackCatalog()"))
        #expect(Self.readsTheShippedPacks("    let files = SkillPackCatalog.packFileURLs(in: SkillPackTests.shippedPacksDirectory)"))
        #expect(!Self.readsTheShippedPacks("    /// Never read from `Sources/MacAgent/Resources/SkillPacks/`."))
    }

    /// Whether a Swift file names the shipped packs folder, or a way to it, on a line that is not a
    /// line comment.
    static func readsTheShippedPacks(_ source: String) -> Bool {
        source.split(separator: "\n", omittingEmptySubsequences: false).contains { line in
            !line.drop(while: { $0 == " " || $0 == "\t" }).hasPrefix("//")
                && ["Resources/SkillPacks", "SonnyResourceBundle", "shippedPacksDirectory"].contains { line.contains($0) }
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
            ("slack", "Slack"), ("1280", "Probe"), ("new page", "Notion"), ("post it", "Slack"),
            // PR #241's delta pass: plurals and modern words that passed the first version.
            ("teams", "Microsoft Teams"), ("team", "Microsoft Teams"), ("docs", "Google Docs"),
            ("doc", "Google Docs"), ("sheets", "Google Sheets"), ("sheet", "Google Sheets"),
            ("forms", "Google Forms"), ("slides", "Google Slides"), ("tasks", "Google Tasks"),
            ("notes", "Apple Notes"), ("issues", "Linear"), ("tickets", "Zendesk"), ("email", "Gmail"),
            ("inbox", "Gmail"), ("app", "Probe"), ("website", "Probe"), ("download", "Probe"),
            ("new docs", "Google Docs"), ("my files", "Dropbox"),
            // SONNY-492: ordinary and modern words the system list does not spell, and one by ruling.
            ("box", "Box"), ("boxes", "Box"), ("expo", "Expo"), ("grok", "Grok"), ("podia", "Podia"),
            ("luma", "Luma")
        ]
        for entry in refused {
            #expect(Self.triggerProblem(entry.trigger, siteName: entry.site, ordinary: ordinary) != nil, "\(entry.trigger) was allowed")
        }
        let allowed: [(trigger: String, site: String)] = [
            ("docusign", "Docusign"), ("zapier", "Zapier"), ("n8n", "n8n"), ("make.com", "Make"),
            ("make scenario", "Make"), ("in notion", "Notion"), ("post on x", "X"), ("linear issue", "Linear"),
            ("gmail", "Gmail"), ("google docs", "Google Docs"), ("microsoft teams", "Microsoft Teams"),
            // SONNY-492's rulings: a closed compound whose everyday spelling is two words, and rare
            // headwords a command does not use in these spellings.
            ("basecamp", "Basecamp"), ("homebase", "Homebase"), ("firebase", "Firebase"), ("okta", "Okta")
        ]
        for entry in allowed {
            #expect(Self.triggerProblem(entry.trigger, siteName: entry.site, ordinary: ordinary) == nil, "\(entry.trigger) was refused")
        }
    }

    /// The depth check itself, held in both directions, so a check that let everything through could
    /// not pass the shipped packs vacuously. Both packs are decoded through the real loader and meet
    /// `depthProblem`, the same function the shipped packs meet — a depth written as a literal here
    /// would prove nothing about the loader or about the check (SONNY-388: a sample that enters
    /// downstream of the mechanism tests only what already works).
    ///
    /// **These samples are the whole guard for the first condition, and that is why the near misses are
    /// here** (SONNY-501). The shipped packs cannot hold that narrowing any more: no row says
    /// `shallow`, so the loop over every pack has nothing to refuse and would pass exactly as warmly
    /// with the narrowing gone. Widening `evidenceForADeepPack` by one more word, or emptying
    /// `depthProblem`, dies here or nowhere. The page condition is the other way round: every shipped
    /// deep pack sits on a row that names a page, so the loop holds that one on a live population and
    /// these samples only say what the rule is. **The count is deliberately not in that sentence.** It
    /// grows with every pack wave and moves under a rebase without anything in the branch saying so —
    /// this read 95 until a delta pass caught it eight packs later, which is the whole of review-260's
    /// finding. The sentence needs only that the population is not empty; the size is a reading at a
    /// commit, and this is one — 143 at `8e4ca1c6`, against 330 for the `shallow` twin and 0 for a
    /// depth no pack has, that last being the control saying the pattern can come back empty. It read
    /// 103 one update from `main` ago and 95 before that, on this one branch, which is the point:
    ///
    ///     grep -rl '"depth": "deep"' Sources/MacAgent/Resources/SkillPacks | wc -l
    ///
    /// Every value a loop reads is written out rather than taken from the declaration under test: a
    /// loop over `evidenceForADeepPack`, or over a list of the column's words, passes whatever that
    /// declaration says, which is the vacuous direction this test exists to avoid (review-260's F3
    /// found one such loop here and it is gone).
    @Test
    func aDeepPackNeedsDocumentedOrSiteReadFlowsAndAShallowPackSitsOnAnyRow() throws {
        let deep = try SkillPackDecoder.decode(SkillPackFixtures.data(SkillPackFixtures.object(depth: "deep")))
        let shallow = try SkillPackDecoder.decode(SkillPackFixtures.data(SkillPackFixtures.object(depth: "shallow")))
        // The control: each fixture loaded as the depth it claims, so what follows is a check about a
        // deep pack rather than about a pack that quietly came back shallow.
        #expect(deep.depth == .deep)
        #expect(shallow.depth == .shallow)
        let page = ["https://example.com/help/create", "", ""]
        let noPage = ["", "", ""]

        for evidence in ["deep", "site"] {
            #expect(Self.depthProblem(deep.depth, taskFlowDocs: evidence, pages: page) == nil, "a deep pack was refused on a \(evidence) row")
        }
        // Exactly one value was added, so every near miss is still refused: the word the 54 rows used
        // to carry, an empty cell, and four spellings that are not the new value.
        for evidence in ["shallow", "", "Site", "site ", "site_read", "live_site"] {
            #expect(Self.depthProblem(deep.depth, taskFlowDocs: evidence, pages: page) != nil, "a deep pack was allowed on a \(evidence) row")
        }
        // A shallow pack sits on any row, including one whose cell is a word the column does not have,
        // and it owes no page: nobody has read its flows yet, which is what `shallow` says.
        for evidence in ["deep", "site", "shallow", "", "Site"] {
            #expect(Self.depthProblem(shallow.depth, taskFlowDocs: evidence, pages: noPage) == nil, "a shallow pack was refused on a \(evidence) row")
        }
        // The page condition, on both kinds of row and in both directions (review-260's F4). A `site`
        // row is the case it exists for: the browser reading it claims left no artifact anywhere else.
        for evidence in ["deep", "site"] {
            #expect(Self.depthProblem(deep.depth, taskFlowDocs: evidence, pages: noPage) != nil, "a deep pack with no page was allowed on a \(evidence) row")
            #expect(Self.depthProblem(deep.depth, taskFlowDocs: evidence, pages: ["", "", "https://example.com/help/third"]) == nil, "the third cell did not count as a page on a \(evidence) row")
        }
        // A cell has to name a page somebody can open, not merely carry text — otherwise a note about
        // having read one satisfies the rule that exists because the reading left no artifact.
        for cell in ["read in a browser 2026-09-17", "example.com/help", " https://example.com/help"] {
            #expect(Self.depthProblem(deep.depth, taskFlowDocs: "site", pages: [cell, "", ""]) != nil, "\(cell) was taken for a page")
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

    @Test(arguments: ["format", "id", "name", "domain", "category", "summary", "signInURL", "triggers", "sections", "depth", "flows", "startPages"])
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
            ("Settle a debt", ["Open Contacts.", "Send\u{00A0}money to them."]),
            // PR #241's delta pass: a money verb neither list held, and five phrases the replaced
            // list refused that the first version of this rule let load as single steps.
            ("Pay a vendor by wire", ["Open it.", "Wire money to the vendor."]),
            ("Wire the vendor", ["Open it.", "Wire funds to the vendor."]),
            ("Remit to a supplier", ["Open it.", "Remit $200 to the supplier."]),
            ("Disburse", ["Open it.", "Disburse the funds."]),
            ("Cash out", ["Open it.", "Cash out the balance to your bank."]),
            ("Request a payout", ["Open Payouts.", "Click Request payout."]),
            ("Tip", ["Open it.", "Tip the driver $5."]),
            ("Get paid", ["Open it.", "Click Get paid now."]),
            // Neutral titles, so each of these three is refused by its step's phrase and by nothing
            // else: removing a phrase from the rule turns this table red (PR #241's second scoped
            // round — "Move money" and "Put money in" were refused by their titles).
            ("Finish the month", ["Open it.", "Make a transfer."]),
            ("Transfer out", ["Open it.", "Send a transfer."]),
            ("Start the week", ["Open it.", "Make a deposit."])
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

    /// A listed money object written in the plural is refused exactly as its singular is (PR #241's
    /// second scoped round: every plural here loaded at `9d0f8942` while its singular was refused).
    /// Each pair has to fail with the same words, so the plural is read as the same object rather than
    /// refused for some other reason.
    @Test
    func aMoneyObjectInThePluralIsRefusedAsItsSingularIs() throws {
        func error(_ step: String) -> SkillPackLoadError? {
            var object = SkillPackFixtures.object(id: "store", name: "Store", domain: "store.example.com")
            object["flows"] = [SkillPackFixtures.flow(title: "Do a thing", steps: ["Open it.", step], on: "store.example.com")]
            return Self.error(object)
        }
        let pairs: [(singular: String, plural: String)] = [
            ("Add the IBAN.", "Add the IBANs."),
            ("Update the account number.", "Update the account numbers."),
            ("Change the routing number.", "Change the routing numbers."),
            ("Update the sort code.", "Update the sort codes."),
            ("Set up direct deposit.", "Set up direct deposits."),
            ("Update the card on file.", "Update the cards on file."),
            ("Add the SWIFT code.", "Add the SWIFT codes."),
            ("Update the card number.", "Update the card numbers.")
        ]
        for pair in pairs {
            let singular = error(pair.singular)
            #expect(singular != nil, "\(pair.singular) loaded")
            #expect(error(pair.plural) == singular, "\(pair.plural) → \(String(describing: error(pair.plural)))")
        }
        // The control: naming them without an action verb still loads.
        #expect(error("Find the account numbers and the cards on file.") == nil)
    }

    /// A money context word or a contextual object in the plural counts exactly as its singular does
    /// (SONNY-479: "at the banks" and "in two currencies" loaded at `65a50865` while "at the bank" was
    /// refused). Each pair has to fail with the same words. The context list's other two missing
    /// plurals, IBANs and wires, are not here because both words are money objects as well, so a unit
    /// naming either is refused before its context is read.
    @Test
    func aContextWordOrAContextualObjectInThePluralCountsAsItsSingularDoes() throws {
        func error(_ step: String) -> SkillPackLoadError? {
            var object = SkillPackFixtures.object(id: "store", name: "Store", domain: "store.example.com")
            object["flows"] = [SkillPackFixtures.flow(title: "Do a thing", steps: ["Open it.", step], on: "store.example.com")]
            return Self.error(object)
        }
        let pairs: [(singular: String, plural: String)] = [
            ("Update the account at the bank.", "Update the account at the banks."),
            ("Update the balance in one currency.", "Update the balance in two currencies."),
            ("Update the account on the invoice.", "Update the account on the invoices."),
            ("Update the recipient of the transfer.", "Update the recipient of the transfers."),
            ("Update the card at the bank.", "Update the cards at the bank."),
            ("Update the amount in one currency.", "Update the amounts in one currency.")
        ]
        for pair in pairs {
            let singular = error(pair.singular)
            #expect(singular != nil, "\(pair.singular) loaded")
            #expect(error(pair.plural) == singular, "\(pair.plural) → \(String(describing: error(pair.plural)))")
        }
        // The controls: a plural context word with no contextual object loads, and so does a plural
        // contextual object with no money word beside it.
        #expect(error("Update the list of banks and currencies.") == nil)
        #expect(error("Move the cards to Done.") == nil)
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
            ("Move a card", ["Open the board.", "Move the card to Done."]),
            // PR #241's delta pass's reading flows.
            ("Draft an invoice", ["Open Invoices.", "Create an invoice for the client."]),
            ("Share an invoice", ["Open Invoices.", "Send the invoice to the client."]),
            ("Plan the week", ["Open the board.", "Add a card to the To do list."]),
            ("Trim the draft", ["Open the draft.", "Remove a recipient."]),
            ("See wires", ["Open Payments.", "Filter the list to wires."]),
            ("Get started", ["Open Help.", "Read the tips for your first week."])
        ]
        for testFlow in flows {
            var object = SkillPackFixtures.object(id: "wise", name: "Wise", domain: "wise.com", category: "finance_billing")
            object["flows"] = [SkillPackFixtures.flow(title: testFlow.title, steps: testFlow.steps, on: "wise.com")]
            #expect(Self.error(object) == nil, "\(testFlow.title) was refused: \(String(describing: Self.error(object)))")
        }
    }

    /// **A flow that ends in a purchase does not load either** (SONNY-506). The founders' rule is
    /// that no flow moves money, and buying is money leaving the user — but the rule's first two
    /// tests were built for money *movement*, so barely a purchase word sat on any list until this
    /// table did: **15 of the 17 rows it then held loaded** at `981c6e56` — this file as it stood
    /// *before review-268 added the last five rows*, run against that tree's
    /// `SkillPackContentRules.swift` and `SkillGuidance.swift`, where it records 15 issues, every one
    /// of them `did not refuse as moving money: nil`. (That intermediate state is described rather
    /// than cited: it was a head on this branch, and two hops onto `main` have since orphaned every
    /// one of those. `981c6e56` is on `main` and still resolves.) The five rows added after that measurement have
    /// a control of their own and a sharper one: delete the list entry each exists for and exactly
    /// that row turns red, naming the word. The two that did not are "Pick a courier",
    /// whose "Confirm and pay" refuses on test 1's `pay`, and "Top up the balance", whose title is a
    /// money verb — both kept, because they are what makes leaving those spellings off
    /// `purchaseActs` a measurement rather than an assumption.
    ///
    /// **Each row names the word that fires, and that is the point of the table rather than
    /// decoration** (review-268's F2). It was written with `words: _`, and the wildcard hid four dead
    /// list entries behind rows that refuse for another reason entirely: "Buy another seat" refuses
    /// on `buy` and never reaches `checkout + seat`, and "Keep the account open" on `renew + billing`
    /// and never on `trial`. Deleting `checkout`, `check out`, `seat` and `trial` left all 34 tests
    /// passing. The last five rows are what make those four and `postage` load-bearing, and the exact
    /// word is asserted so no future entry can hide the same way.
    @Test
    func aFlowThatEndsInAPurchaseDoesNotLoad() throws {
        let flows: [(title: String, steps: [String], words: String)] = [
            ("Buy postage for an order", ["Open the order.", "Click Buy Postage."], "buy"),
            ("Print a shipping label", ["Open the order.", "Buy the label from the carrier you picked."], "buy"),
            ("Order more credits", ["Open Credits.", "Purchase another bundle."], "purchase"),
            ("Get the report", ["Open Reports.", "Purchasing it unlocks the full export."], "purchasing"),
            ("Send a gift", ["Open the store.", "Place your order."], "place your order"),
            ("Send a gift, the other way round", ["Open the store.", "Place an order for the item."], "place an order"),
            ("Finish an order", ["Open the cart.", "Proceed to checkout."], "proceed to checkout"),
            ("Finish an order, the shorter control", ["Open the cart.", "Go to checkout, then confirm."], "go to checkout"),
            ("Take the seat", ["Open Members.", "Complete the purchase for the extra member."], "purchase"),
            // The two an earlier test already reached when this table was first written, kept so that
            // leaving "Confirm and pay" and "Top up" off `purchaseActs` stays a measurement.
            ("Pick a courier", ["Open the shipment.", "Choose a service, then Confirm and pay."], "pay"),
            ("Top up the balance", ["Open Billing.", "Add funds to the account."], "top up"),
            // Dialpad's own wording, read off Add & Remove Team Members by the lane that left this
            // path out by hand (SONNY-502's branch). No money object sat beside those verbs before
            // `billing change` did, so this flow loaded.
            ("Add a team member", [
                "Open your Dialpad Admin Settings and go to Office Settings, then select Users.",
                "Select Add Users, then enter the new user's name and email address.",
                "Confirm any billing changes and add the user(s)."
            ], "add + billing change"),
            // Test 4: the control is ordinary and the unit says what it costs.
            ("Move to the Business plan", ["Open Settings, then Plan.", "Pick the Business plan and click Upgrade to see the price."], "upgrade + plan"),
            ("Start a paid plan", ["Open Pricing.", "Choose the Business plan and click Subscribe."], "subscribe + plan"),
            ("Keep the account open", ["Open Billing.", "Click Renew before the trial ends."], "renew + billing"),
            ("Buy another seat", ["Open Members.", "Click Checkout to add the seat."], "buy"),
            // The one row whose only priced word is a plural, so that the fourth test's plural
            // reading is held by something: with it off, "plans" stops being "plan" and this loads.
            ("Move up a tier", ["Open Settings.", "Compare the plans, then click Upgrade."], "upgrade + plan"),
            // review-268's F2: one row per list entry that nothing else reaches. Delete the entry and
            // exactly one of these turns red, naming it.
            ("Get the shipment ready", ["Open the order.", "Add postage to the shipment."], "add + postage"),
            ("Finish the order", ["Open the cart.", "Click Checkout and confirm the price."], "checkout + price"),
            ("Finish the order, the two-word control", ["Open the cart.", "Click Check out, then confirm the price."], "check out + price"),
            ("Add a teammate", ["Open Members.", "Click Upgrade to add a seat."], "upgrade + seat"),
            ("Keep the account open past the trial", ["Open Settings.", "Click Renew before the trial ends."], "renew + trial")
        ]
        for testFlow in flows {
            var object = SkillPackFixtures.object(id: "store", name: "Store", domain: "store.example.com")
            object["flows"] = [SkillPackFixtures.flow(title: testFlow.title, steps: testFlow.steps, on: "store.example.com")]
            #expect(
                Self.error(object) == .movesMoney(field: "flows[0]", words: testFlow.words),
                "\(testFlow.title) → \(String(describing: Self.error(object)))"
            )
        }
    }

    /// The other side of SONNY-506's table, held **by value** so that the next session widening the
    /// purchase words finds out immediately which real packs it broke.
    ///
    /// The first six rows are the wording of shipped packs at `dc73131c`, quoted rather than
    /// paraphrased: a subscription tier a feature is gated on, a product that *is* a checkout, and a
    /// Workspace edition whose name ends in "Upgrade" are all ordinary description. The rest are the
    /// free controls the fourth test exists to leave alone.
    @Test
    func purchaseWordsThatAreNotPurchasesStillLoad() throws {
        let units: [(what: String, texts: [String])] = [
            ("google_meet, a paid edition named Upgrade", ["Take attendance in a meeting",
             "Attendance tracking is available to Google Workspace Essentials, Business Plus, Enterprise Starter, Enterprise Essentials, Enterprise Standard, Enterprise Plus, Education Plus and Teaching and Learning Upgrade users.",
             "During the meeting, click Host controls at the bottom, then toggle Attendance tracking on or off in the side panel that opens."]),
            ("slack, a feature gated on a paid plan", ["Create a channel",
             "Click the plus sign in the sidebar.",
             "Select Channel. On a paid plan, select Blank channel for a regular channel, or choose a template.",
             "Enter a channel name, choose whether it is public or private, then click Create."]),
            ("miro, a feature gated on paid plans", ["Restore a deleted board",
             "Open Trash by clicking your avatar in the upper right of the dashboard. Trash is on paid and Education plans, and a board can be restored within 90 days.",
             "Click the three dots (...) menu next to the board and click Restore."]),
            ("manychat, a precondition naming a paid plan", ["Clone an account's automations to another account",
             "Go to Settings, then General, and click Clone This Account.",
             "If your source account is on a paid plan, your destination account must also be on a compatible paid plan for cloning to work."]),
            ("samcart's summary, a product that is a checkout", ["Checkout pages and online sales platform."]),
            ("thrivecart's summary, a product that is a cart", ["Shopping cart and checkout pages."]),
            ("a free Subscribe button", ["Subscribe to a channel", "Open the channel page.", "Click Subscribe."]),
            ("reading what a plan includes", ["See what your plan includes", "Open Settings.", "Open Plan to read the current limits."]),
            ("renewing something that is not bought", ["Renew a shared link", "Open the file.", "Click Renew to extend the link's expiry."]),
            ("checking out a branch", ["Switch branches", "Open the repository.", "Check out the branch you want."])
        ]
        for unit in units {
            #expect(SkillPackMoneyRule.violation(in: unit.texts) == nil, "\(unit.what) was refused")
        }
    }

    /// **What the money rule cannot see, kept here so nobody concludes it can** (SONNY-506).
    ///
    /// The rule reads a pack's words. Where a flow *leaves* the user is a property of the page, and
    /// the two come apart whenever the control that charges is named something ordinary. This is not
    /// a gap waiting to be closed by one more word on one more list: no list can tell that
    /// ShipStation's "Create + Print Label" button is the one that spends money and Trello's "Create"
    /// button is not.
    ///
    /// The flow below is ShipStation's *Create & Print Your First Label*, whose help page was read in
    /// a browser on 2026-09-17. It loads, and it should not be shipped. A lane left it out by hand;
    /// that judgement is what this repository relies on, and this test is here so a later session
    /// reading the purchase words above does not conclude the class is covered.
    ///
    /// **The second flow is the same page's next sentence, kept.** That one is refused — so what the
    /// rule is blind to is a flow written *tersely*, not a page that hides its money. The remedy a
    /// pack lane owes is therefore writing down where the flow leaves the user, not finding better
    /// words for the button.
    ///
    /// Run against `981c6e56` — this test as it stood before review-268's round — it records
    /// exactly **one** issue, and it is the header assertion below: both expectations about the money rule already
    /// held there, unchanged by everything SONNY-506 added. That is what "the rule cannot see it" means, measured rather than
    /// asserted.
    ///
    /// **If this test ever goes red** because the first flow is refused, the rule has grown past what
    /// this records: delete the test and the limitation from `SkillPackMoneyRule`'s doc comment
    /// together, rather than loosening the assertion.
    @Test
    func theMoneyRuleCannotSeeAPurchaseTheStepsDoNotName() throws {
        let terse = [
            "Create & Print Your First Label",
            "Open the order in ShipStation.",
            "Set the Ship From location, the shipment weight, the service class and the package type.",
            "Click the Create + Print Label button.",
            "Choose the browser print icon, select your label printer, and click Print."
        ]
        #expect(SkillPackMoneyRule.violation(in: terse) == nil, "the rule has grown — see this test's doc comment")

        let faithful = terse.dropLast() + [
            "You are prompted here to add your label payment method and add funds to the balance used to purchase your labels."
        ]
        #expect(SkillPackMoneyRule.violation(in: Array(faithful)) == "add + funds")

        // What stands in the first flow's way instead, since a pack's words cannot: the block every
        // pack is read under says so, and the approval gates are unchanged by any pack. Asserted here
        // rather than only in `SkillGuidanceTests` so that removing the sentence removes this record
        // of why it exists.
        #expect(SkillGuidance.header.contains(
            "A skill never authorises spending the user's money either: a control that buys, pays, "
            + "subscribes or upgrades is the user's to approve, however ordinary the step beside it reads."
        ))
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
        "Enter the one-time password.", "Type the 2FA code from your phone.",
        // PR #241's delta pass.
        "Enter your login and pass.", "Paste your token.", "Enter the code we emailed you.",
        "Enter the 6-digit code from the authenticator app."
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

    /// The credential phrases the delta round added are phrases, so the ordinary words inside them
    /// still load: a design token, and passing something to a teammate.
    @Test
    func anOrdinaryTokenOrPassStillLoads() throws {
        var object = SkillPackFixtures.object()
        object["flows"] = [SkillPackFixtures.flow(steps: ["Open the styles.", "Use the design token for spacing.", "Pass the page to a teammate."])]
        #expect(Self.error(object) == nil)
    }

    /// **A control legitimately named "secret" is not a credential** (SONNY-508). Pinterest's board
    /// privacy toggle is named "Keep board secret" — read from
    /// `help.pinterest.com/en/business/article/create-a-board` in a browser on 2026-09-17, whose own
    /// sentence is "turn on the switch next to Keep board secret if you want the board to be secret".
    /// The rule refused that clause, so the pack shipped without it rather than renaming a control
    /// nobody could then find. SONNY-492 answered the same question the same way in the trigger
    /// check: teach the check the words. Run against `981c6e56` the same way — this test as it stood
    /// before review-268 added the boundary table — it records **6 issues**: every row
    /// of the first table, and **none** of the second, which is what says the change is a narrowing
    /// of one word rather than a loosening of the rule.
    ///
    /// **The tables below the first are the whole reason this is safe, and they are held by value on
    /// purpose.** Every row of them is a credential step that must still be refused, so the next
    /// session widening this rule finds out immediately which ones it broke. The shapes they turn on:
    /// a word beside the credential's own modifier, a word that is merely *near* a privacy object
    /// rather than beside it, a text where one occurrence is excused and another is not, and — since
    /// review-268's F1 — a word that is beside it only because the punctuation between them was
    /// discarded.
    ///
    /// **What a pack writes is the page's clause up to the control's name**, and the page's own full
    /// sentence is refused, because "if you want the board to be secret" puts the word beside `be`.
    /// Both are here by value (F5): the shortened clause in `loads`, the full sentence in `refused`.
    /// That is the rule working rather than a gap — what the fix buys is a pack that can name the
    /// control, not one that can quote the whole page.
    @Test
    func aControlNamedSecretLoadsAndACredentialNamedSecretStillDoesNot() throws {
        let loads: [String] = [
            // The clause a pack writes: the page's sentence up to and including the control's name.
            // Its own full sentence is in `refused` below, and that is not a gap — see this test's
            // doc comment.
            "Enter a name for your board, add collaborators, or turn on the switch next to Keep board secret.",
            "Turn on Keep board secret, then tap Create.",
            "Create a secret board for the ideas you are not ready to share.",
            "Open the group's settings and make the group secret.",
            "Start a secret chat with them.",
            "Save it as a secret gist."
        ]
        for step in loads {
            var object = SkillPackFixtures.object()
            object["flows"] = [SkillPackFixtures.flow(steps: ["Open the page.", step])]
            #expect(Self.error(object) == nil, "refused a real control's real name: \(step)")
        }

        let refused: [String] = [
            "Paste the client secret into the field.",
            "Copy the secret and store it somewhere safe.",
            "Your secret is shown once, so save it now.",
            "Open Settings, then Secrets, and add a repository secret.",
            "Paste the app secret from the developer page.",
            // Near a privacy object, and not beside one: a chat is where a credential gets pasted,
            // which is exactly the shape a looser proximity rule would have excused.
            "Paste the secret into the chat.",
            "Send the secret to the group.",
            // One occurrence excused, one not — the text is refused on the one that is not.
            "Keep the board secret, then paste the API secret below.",
            // review-268's F5, by value: Pinterest's own full sentence is still refused, because its
            // trailing predicate puts `secret` beside `be`. Held here so the shortened clause above
            // cannot be read as "the page's wording loads".
            "Enter a name for your board, add collaborators or turn on the switch next to Keep board secret if you want the board to be secret"
        ]
        for step in refused {
            var object = SkillPackFixtures.object()
            object["flows"] = [SkillPackFixtures.flow(steps: ["Open the page.", step])]
            guard case .mentionsCredential(field: "flows.steps", phrase: _)? = Self.error(object) else {
                Issue.record("a credential step loaded: \(step)")
                continue
            }
        }

        // review-268's F1, by value. `SkillWords.cut` discards punctuation, so before the gap array
        // existed the word after "secret." was the first word of the next sentence and supplied the
        // excuse. Each is a credential step whose next clause happens to name a thing a site makes
        // private, which is ordinary help-centre prose — 495 of the 1767 shipped steps carry a
        // sentence boundary and 4 already put one of `privacyObjects` straight after one.
        //
        // The control, run rather than argued: with the two `unit.joinedToPrevious` reads deleted
        // from `namesAThing`, this test records exactly **9** issues, one per row here, and nothing
        // else in it moves. That pair of numbers — nine, and nothing else — is what says these rows
        // hold the boundary and not something they share with the tables above.
        let acrossABoundary: [String] = [
            "Copy the client ID and the secret. Boards are listed on the left.",
            "Paste the API secret. Boards you own appear under Saved.",
            "Copy the secret, boards are on the left.",
            "Copy the secret; chats are unaffected.",
            "Copy the secret: conversations stay private.",
            "Paste the signing secret (boards are unaffected).",
            "Store the webhook secret. Album settings are elsewhere.",
            // A line break is a boundary too, and a hyphen: "board-secret" is two words that are not
            // beside each other, which is the fail-closed direction.
            "Copy the secret\nBoards are listed on the left.",
            "Paste the board-secret value from the developer page."
        ]
        for step in acrossABoundary {
            var object = SkillPackFixtures.object()
            object["flows"] = [SkillPackFixtures.flow(steps: ["Open the page.", step])]
            guard case .mentionsCredential(field: "flows.steps", phrase: _)? = Self.error(object) else {
                Issue.record("a credential step loaded across a boundary: \(step)")
                continue
            }
        }

        // The word a credential step has always been refused on does not change, so a pack author
        // reading the error sees what they saw before.
        #expect(SkillPackCredentialRule.violation(in: "Paste the client secret.") == "secret")
    }

    /// The array the rule above reads its adjacency from, held on its own because a parallel array is
    /// exactly where an off-by-one hides and because nothing else in the tree reads it
    /// (review-268's F1).
    ///
    /// `joinedToPrevious` is always as long as `words`, its first entry is `false` — nothing stands
    /// before the first word — and an entry is `true` only when spaces alone separate that word from
    /// the one before it.
    @Test
    func theWordCutRecordsWhetherEachWordIsJoinedToTheOneBeforeIt() throws {
        let cases: [(text: String, words: [String], joined: [Bool])] = [
            ("Keep board secret", ["keep", "board", "secret"], [false, true, true]),
            ("the secret. Boards", ["the", "secret", "boards"], [false, true, false]),
            ("the secret, boards", ["the", "secret", "boards"], [false, true, false]),
            ("board-secret", ["board", "secret"], [false, false]),
            ("a\tsecret board", ["a", "secret", "board"], [false, true, true]),
            ("secret\nboard", ["secret", "board"], [false, false]),
            ("secret", ["secret"], [false]),
            ("", [], [])
        ]
        for testCase in cases {
            let unit = SkillWords(testCase.text)
            #expect(unit.words == testCase.words, "\(testCase.text)")
            #expect(unit.joinedToPrevious == testCase.joined, "\(testCase.text)")
            #expect(unit.joinedToPrevious.count == unit.words.count, "\(testCase.text)")
        }
        // Over the wording this rule exists for, the two arrays stay the same length whatever the
        // punctuation, and the words are the ones `cut` has always produced — the gap array is
        // additive, and every other rule in the file still reads the same words it did.
        for text in [
            "Keep board secret.", "a. b, c; d: e (f) g\nh-i", "...", "1 2 3", "",
            "Send  money", "Transfer\tfunds", "Send\u{00A0}money", "Pay-out", "café", "IBANs."
        ] {
            let unit = SkillWords(text)
            #expect(unit.joinedToPrevious.count == unit.words.count, "\(text)")
            #expect(unit.words == SkillWords.cut(SearchText.normalized(text)), "\(text)")
        }
    }

    /// **The minting test refuses no shipped text, measured over a population shown to hold the words it
    /// reads and with an instrument shown able to refuse** (SONNY-534; the rule's own tables are
    /// `SkillPackMintingTests`, and this one is here because only this file may read the shipped folder).
    ///
    /// `everyShippedPackLoadsAndEveryOneIsARowOfTheCommittedCatalogue` already fails on a refused pack.
    /// What it cannot say is whether a clean result means anything, and a rule about `key` and `token`
    /// run over texts that never say either would be clean by construction. So this counts the texts
    /// that do, requires some, and plants a minting line among the same texts to show the same call
    /// refuses it. **The population is thin and the doc comment says so rather than hiding it**: 12 of
    /// 4826 texts at `856bb7ee`, because every lane so far has left credential flows out by hand —
    /// `python3 -c "import json,glob,re; t=[x for f in glob.glob('Sources/MacAgent/Resources/SkillPacks/' + '*.skillpack.json') for p in [json.load(open(f))] for x in [p['name'],p['domain'],p['summary']]+p['triggers']+p['sections']+[y for fl in p['flows'] for y in [fl['title']]+fl['steps']]]; print(len(t), sum(1 for x in t if re.search(r'(^|[^a-z0-9])(keys?|tokens?)([^a-z0-9]|$)', x.lower())))"`
    /// → `4826 12`. So this measures that the widening breaks nothing shipped; how often it will refuse
    /// a future pack's honest wording is `knownRefusalsOfTheMintingTestAreHeld`'s to record, not this
    /// count's to predict. No figure is asserted, because the pack lanes change the population weekly.
    @Test
    func theMintingTestIsMeasuredOverTheShippedTextsThatNameAKeyOrAToken() throws {
        let catalogue = SkillPackCatalog.load(fileURLs: SkillPackCatalog.packFileURLs(in: Self.shippedPacksDirectory))
        try #require(catalogue.packs.count > 100, "the walk loaded \(catalogue.packs.count) packs")
        let texts = catalogue.packs.flatMap { pack in
            [pack.name, pack.domain, pack.summary] + pack.triggers + pack.sections
                + pack.flows.flatMap { [$0.title] + $0.steps }
        }
        let namingOne = texts.filter { !Set(SkillWords($0).words).isDisjoint(with: SkillPackCredentialRule.mintedObjects) }
        #expect(namingOne.count >= 5, "only \(namingOne.count) shipped texts name a key or a token, so a clean result says little")
        #expect(texts.compactMap(SkillPackCredentialRule.violation(in:)) == [])

        let planted = texts.prefix(1_000) + ["Click the Add key drop-down menu, then select Create new key."] + texts.dropFirst(1_000)
        #expect(planted.compactMap(SkillPackCredentialRule.violation(in:)) == ["add + key"])
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
        object["startPages"] = [SkillPackFixtures.startPage(url: "https://www.notion.so/help#sharing")]
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
            object["startPages"] = [SkillPackFixtures.startPage(url: startURL)]
            #expect(Self.error(object) == nil, "\(startURL) was refused")
        }
    }

    // MARK: - A flow's start page is recorded where it lands (SONNY-510)

    /// **The five shapes SONNY-510 recorded, each as a pack a person would write after reading it
    /// honestly, and each refused by the loader.** Every sample is JSON decoded through
    /// `SkillPackDecoder.decode`, so the rule is on the path of every one of them (SONNY-388: a sample
    /// entering downstream of the mechanism it holds tests only what already works). The first two are
    /// refused by what the record *says* — the landed URL — even with `sign-in` written beside it, which
    /// is a reader getting the page wrong; the last three are refused by the word a reader who got it
    /// right would have to write.
    @Test
    func aStartPageThatLandsWhereAFlowMayNotBeginDoesNotLoad() throws {
        // 1. Ghost: the bare origin redirects to account creation on the site's own host.
        #expect(Self.landing(
            start: "https://account.ghost.org/", landed: "https://account.ghost.org/signup",
            domain: "ghost.org", signIn: "https://account.ghost.org/signin/"
        ) == .startPageCreatesAnAccount(url: "https://account.ghost.org/signup"))
        // 2. Google Ads: the declared host is the site's, the landed host is another site's.
        #expect(Self.landing(
            start: "https://ads.google.com/", landed: "https://business.google.com/us/google-ads/",
            domain: "ads.google.com", signIn: "https://ads.google.com/nav/login"
        ) == .landingHostNotPairedWithSite(url: "https://ads.google.com/", host: "business.google.com", site: "ads.google.com"))
        // 3. StreamYard: nothing moved, and the page is itself the sign-up.
        #expect(Self.landing(
            start: "https://streamyard.com/", landed: "https://streamyard.com/", offers: "sign-up", domain: "streamyard.com"
        ) == .startPageNotAStartPage(url: "https://streamyard.com/", offers: "sign-up"))
        // 4. Mattermost: a self-hosted product's vendor site cannot reach a channel at all.
        #expect(Self.landing(
            start: "https://mattermost.com/", landed: "https://mattermost.com/", offers: "unreachable", domain: "mattermost.com", signIn: nil
        ) == .startPageNotAStartPage(url: "https://mattermost.com/", offers: "unreachable"))
        // 5. n8n: the own-domain rule leaves only the marketing homepage, and it is one.
        #expect(Self.landing(
            start: "https://n8n.io/", landed: "https://n8n.io/", offers: "marketing", domain: "n8n.io", signIn: "https://app.n8n.cloud/login"
        ) == .startPageNotAStartPage(url: "https://n8n.io/", offers: "marketing"))
    }

    /// The controls for the test above, through the same decoder: what an ordinary start page's record
    /// looks like loads, including the two cases the host rule exists to allow — a landing on a subdomain
    /// of the site, and one on a listed identity host that signs in for the pack's site, which is how a
    /// Google product lands on `accounts.google.com`. The second loads with no `signInURL` at all, and
    /// with one naming another host, because the rule does not read it.
    @Test
    func anOrdinaryStartPageRecordLoads() throws {
        #expect(Self.landing(start: "https://www.notion.so/", landed: "https://www.notion.so/login") == nil)
        #expect(Self.landing(start: "https://notion.so/", landed: "https://app.notion.so/sign-in") == nil)
        for signIn in [nil, "https://meet.google.com/", "https://accounts.google.com/ServiceLogin"] {
            #expect(Self.landing(
                start: "https://meet.google.com/landing", landed: "https://accounts.google.com/v3/signin/identifier",
                domain: "meet.google.com", signIn: signIn
            ) == nil, "\(signIn ?? "no signInURL")")
        }
        #expect(Self.landing(
            start: "https://teams.microsoft.com/", landed: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize",
            domain: "teams.microsoft.com", signIn: nil
        ) == nil)
        #expect(Self.landing(start: "https://www.notion.so/", landed: "https://www.notion.so/", offers: "product") == nil)
        // A single-page app's route lives in the fragment, and a fragment is recorded as it is.
        #expect(Self.landing(start: "https://app.notion.so/#/home", landed: "https://app.notion.so/#/login") == nil)
        // A page with no heading or no title records an empty one rather than leaving the field out or
        // being given one — X's log-in page has no title.
        var untitled = Self.startPageObject(start: "https://www.notion.so/", landed: "https://www.notion.so/login")
        var page = try #require((untitled["startPages"] as? [[String: Any]])?.first)
        page["heading"] = ""
        page["title"] = ""
        untitled["startPages"] = [page]
        #expect(Self.error(untitled) == nil)
    }

    /// **The landed host, held on both sides of its line.** It is the pack's own site, or a listed
    /// identity host that signs in for that site, and nothing else: not a look-alike ending in the
    /// domain's letters, not a subdomain of a listed host (the allowance is that host, exactly), and not a
    /// listed host that signs in for some other site.
    ///
    /// **And `signInURL` buys nothing** (founders' decision C of 2026-09-18). It is written in the same
    /// file as the record, so while the rule read it, naming `business.google.com` as the sign-in page let
    /// Google Ads' own shape back in: review-272's probe, which loaded. Now that pack is refused whatever
    /// word its record says, and an identity host admits a sign-in page only (review-272's F3).
    ///
    /// **Every refusal names the pairing that is missing** — the landed host and the pack's own site —
    /// because the list is kept one pairing at a time: Notion's landing on `accounts.google.com` is
    /// refused with `site: "notion.so"` although that host is listed, and the fix a reader looks for is
    /// that pairing, not the host.
    @Test
    func aLandingOnAnotherSiteIsRefusedWhateverTheRecordSays() throws {
        #expect(Self.landing(start: "https://www.notion.so/", landed: "https://notnotion.so/login")
            == .landingHostNotPairedWithSite(url: "https://www.notion.so/", host: "notnotion.so", site: "notion.so"))
        #expect(Self.landing(
            start: "https://meet.google.com/landing", landed: "https://evil.accounts.google.com/signin",
            domain: "meet.google.com", signIn: "https://accounts.google.com/ServiceLogin"
        ) == .landingHostNotPairedWithSite(url: "https://meet.google.com/landing", host: "evil.accounts.google.com", site: "meet.google.com"))
        // Google's sign-in host signs in for Google's sites, not Notion's, however the pack names it.
        for signIn in [nil, "https://accounts.google.com/ServiceLogin"] {
            #expect(Self.landing(
                start: "https://www.notion.so/", landed: "https://accounts.google.com/signin", signIn: signIn
            ) == .landingHostNotPairedWithSite(url: "https://www.notion.so/", host: "accounts.google.com", site: "notion.so"), "\(signIn ?? "no signInURL")")
        }
        // `offers: product` buys nothing here: the host rule reads the URL, not the reader's word.
        #expect(Self.landing(start: "https://ads.google.com/", landed: "https://business.google.com/", offers: "product", domain: "ads.google.com")
            == .landingHostNotPairedWithSite(url: "https://ads.google.com/", host: "business.google.com", site: "ads.google.com"))
        // Review-272's probe: the sign-in page edited to be the marketing host. Refused as either word.
        for offers in ["product", "sign-in"] {
            #expect(Self.landing(
                start: "https://ads.google.com/", landed: "https://business.google.com/us/google-ads/", offers: offers,
                domain: "ads.google.com", signIn: "https://business.google.com/"
            ) == .landingHostNotPairedWithSite(url: "https://ads.google.com/", host: "business.google.com", site: "ads.google.com"), "\(offers)")
        }
        // A listed identity host that does sign in for the pack's site admits a sign-in page only.
        #expect(Self.landing(
            start: "https://meet.google.com/landing", landed: "https://accounts.google.com/v3/signin/identifier", offers: "product",
            domain: "meet.google.com", signIn: "https://accounts.google.com/ServiceLogin"
        ) == .identityHostLandingIsNotSignIn(url: "https://meet.google.com/landing", host: "accounts.google.com"))
        // On the pack's own site `product` is still a word a landing may say.
        #expect(Self.landing(start: "https://www.notion.so/", landed: "https://app.notion.so/", offers: "product") == nil)
        // A site Google's sign-in host does not sign in for is refused there, naming that site (the
        // full review's widening mutant loaded exactly this).
        #expect(Self.landing(
            start: "https://www.figma.com/", landed: "https://accounts.google.com/v3/signin/identifier",
            domain: "figma.com", signIn: nil
        ) == .landingHostNotPairedWithSite(url: "https://www.figma.com/", host: "accounts.google.com", site: "figma.com"))
        // A listed identity host admits a sign-in page only even on the pack's own site: the Google
        // pack's domain is google.com, so accounts.google.com is its own site (the full review's F4).
        #expect(Self.landing(
            start: "https://myaccount.google.com/", landed: "https://accounts.google.com/v3/signin/identifier", offers: "product",
            domain: "google.com", signIn: nil
        ) == .identityHostLandingIsNotSignIn(url: "https://myaccount.google.com/", host: "accounts.google.com"))
        #expect(Self.landing(
            start: "https://myaccount.google.com/", landed: "https://accounts.google.com/v3/signin/identifier",
            domain: "google.com", signIn: nil
        ) == nil)
    }

    /// **The identity-host list is exactly the landings the shipped packs make, and its expected answer
    /// never comes from the list.** For every shipped pack file, read as raw JSON rather than through
    /// the loader (which consults the list), every start page that lands off its pack's own site
    /// contributes its landed host, paired with the pack's registrable site (`registrableSite(of:)`:
    /// `mail.google.com` → `google.com`, and `app.example.co.uk` → `example.co.uk`). That map, built without reading
    /// `SkillPackStartPageRule.identityHosts`, must equal the list. So a site added to a host nobody
    /// lands from fails here, a host added that no pack lands on fails here, and a pairing a pack needs
    /// fails `everyShippedPackLoads…` instead. The first version of this test read each host's sites
    /// out of the list inside its own loop and compared the list with itself, and the full review's
    /// mutant pairing Google's sign-in host with every `.com` site passed it (SONNY-388's trap).
    @Test
    func theIdentityHostListIsExactlyTheLandingsTheShippedPacksMake() throws {
        let files = SkillPackCatalog.packFileURLs(in: Self.shippedPacksDirectory)
        var landings: [String: Set<String>] = [:]
        for file in files {
            let parsed = try JSONSerialization.jsonObject(with: Data(contentsOf: file))
            let object = try #require(parsed as? [String: Any])
            let domain = try #require(object["domain"] as? String).lowercased()
            for page in object["startPages"] as? [[String: Any]] ?? [] {
                let landedText = try #require(page["landedURL"] as? String)
                let landed = try #require(URL(string: landedText))
                let host = (landed.host ?? "").lowercased()
                guard host != domain, !host.hasSuffix("." + domain) else { continue }
                landings[host, default: []].insert(Self.registrableSite(of: domain))
            }
        }
        #expect(files.count > 100, "the walk found \(files.count) pack files")
        #expect(!landings.isEmpty, "no shipped start page lands off its own site")
        #expect(SkillPackStartPageRule.identityHosts == landings)
    }

    /// **A pack's site is not always its domain's last two labels** (SONNY-529, from review-272b's delta
    /// pass). Taking two labels made a pack on `app.example.co.uk` demand a pairing for `co.uk`, which is
    /// not a site, and the failure read as a missing pairing — sending its reader to
    /// `SkillPackStartPageRule.identityHosts` for a fault in this test. No shipped pack sits on such a
    /// domain yet, so these samples are the whole guard for it, and each goes through the one helper the
    /// population test uses.
    @Test
    func aPacksSiteIsItsRegistrableDomainEvenUnderACountrysSecondLevel() {
        let samples: [(domain: String, site: String)] = [
            ("mail.google.com", "google.com"), ("google.com", "google.com"), ("calendar.notion.so", "notion.so"),
            ("zcal.co", "zcal.co"), ("app.zcal.co", "zcal.co"), ("desk.zoho.com", "zoho.com"),
            ("example.co.uk", "example.co.uk"), ("app.example.co.uk", "example.co.uk"),
            ("shop.example.com.au", "example.com.au"), ("Portal.Example.Co.JP", "example.co.jp")
        ]
        for sample in samples {
            #expect(Self.registrableSite(of: sample.domain) == sample.site, "\(sample.domain)")
        }
    }

    /// The registrable site of `domain`: its last two labels, or its last three when the two before the
    /// country code are one of the second levels countries sell names under (`co.uk`, `com.au`, `co.jp`).
    /// This is a short rule, not the public-suffix list: Foundation carries no copy of that list, and a
    /// vendored one is a file nobody here would review. What the rule gets wrong it gets wrong loudly —
    /// the population test fails naming the host and the site it derived.
    static func registrableSite(of domain: String) -> String {
        let labels = domain.lowercased().split(separator: ".").map(String.init)
        let underACountry = labels.count >= 3
            && labels[labels.count - 1].count == 2
            && secondLevelsUnderACountry.contains(labels[labels.count - 2])
        return labels.suffix(underACountry ? 3 : 2).joined(separator: ".")
    }

    static let secondLevelsUnderACountry: Set<String> = ["co", "com", "net", "org", "ac", "gov", "edu", "ne", "or", "go", "ltd", "plc"]

    /// Every spelling of account creation `accountCreationParts` folds together, in the landed path, in
    /// a single-page app's fragment, and in the declared URL itself — and the near misses a sign-in or
    /// meeting page really uses still load, so the list is held from both sides.
    @Test
    func aStartPageWhosePathNamesAccountCreationDoesNotLoad() throws {
        for landed in [
            "https://www.notion.so/signup", "https://www.notion.so/sign-up", "https://www.notion.so/sign_up",
            "https://www.notion.so/SignUp", "https://www.notion.so/register", "https://www.notion.so/users/registration",
            "https://www.notion.so/create-account", "https://www.notion.so/handshake/signup/", "https://www.notion.so/#/signup"
        ] {
            #expect(Self.landing(start: "https://www.notion.so/", landed: landed) == .startPageCreatesAnAccount(url: landed), "\(landed)")
        }
        #expect(Self.landing(start: "https://www.notion.so/signup", landed: "https://www.notion.so/login")
            == .startPageCreatesAnAccount(url: "https://www.notion.so/signup"))
        // The declared URL's query is read too, since a sign-up intent is often carried there and a
        // landing is recorded without one (review-272's F4).
        for start in ["https://www.notion.so/login?mode=signup", "https://www.notion.so/authorize?screen_hint=signup"] {
            #expect(Self.landing(start: start, landed: "https://www.notion.so/login") == .startPageCreatesAnAccount(url: start), "\(start)")
        }
        for start in ["https://www.notion.so/login?mode=login", "https://www.notion.so/api/auth/login?next=%2F"] {
            #expect(Self.landing(start: start, landed: "https://www.notion.so/login") == nil, "\(start) was refused")
        }
        for landed in [
            "https://www.notion.so/signin", "https://www.notion.so/sign-in", "https://www.notion.so/users/sign_in",
            "https://www.notion.so/login", "https://www.notion.so/join", "https://www.notion.so/registered-users"
        ] {
            #expect(Self.landing(start: "https://www.notion.so/", landed: landed) == nil, "\(landed) was refused")
        }
    }

    /// **The same four words, inside a longer slug or as a host's first label** (SONNY-529). review-272b
    /// found `/signup-free`, `/register-now` and `signup.<site>` passing; each is refused now, in the landed
    /// URL and in the declared one. The near misses that decided how far the match reaches still load:
    /// `registered-users` (why a prefix match was rejected), a `join` host (Zoom's), a site whose own name
    /// is one of the words under a suffix of one label, which the host check leaves alone by reading only
    /// the labels left of the last two, and a query key that merely contains a word (founders' ruling on
    /// PR #282: Snov's own sign-in address carries `signup_source=landing`). A key that is one of the words
    /// whole is still read.
    @Test
    func aStartPageNamingAccountCreationInsideASlugOrAHostDoesNotLoad() throws {
        for landed in [
            "https://www.notion.so/signup-free", "https://www.notion.so/register-now", "https://www.notion.so/sign-up-free",
            "https://www.notion.so/SignUpNow", "https://www.notion.so/create-account-now", "https://www.notion.so/#/free_signup",
            "https://signup.notion.so/", "https://register.notion.so/login"
        ] {
            #expect(Self.landing(start: "https://www.notion.so/", landed: landed) == .startPageCreatesAnAccount(url: landed), "\(landed)")
        }
        for start in [
            "https://signup.notion.so/", "https://www.notion.so/login?intent=signup_free", "https://www.notion.so/login?signup",
            "https://www.notion.so/login?Sign-Up=1", "https://www.notion.so/#/login?screen_hint=signup"
        ] {
            #expect(Self.landing(start: start, landed: "https://www.notion.so/login") == .startPageCreatesAnAccount(url: start), "\(start)")
        }
        // A key is cut at `/#?&=.`, `main`'s own separators, and each piece read whole, so a page routed
        // through the query is refused as it is on `main` (review-282's delta pass: the first four loaded
        // while the key was read as one word).
        // `index.php?/register` is how an app without URL rewriting routes.
        for start in [
            "https://www.notion.so/index.php?/register", "https://www.notion.so/index.php?/auth/signup",
            "https://www.notion.so/?/signup", "https://www.notion.so/login?user.register=1",
            // A second `?` inside the query carries the word behind it (review-282's scoped pass: all five
            // loaded while the key was cut at `/` and `.` only).
            "https://www.notion.so/index.php?/register?ref=home", "https://www.notion.so/?/signup?utm=x",
            "https://www.notion.so/login?register?x", "https://www.notion.so/login?a?signup",
            "https://www.notion.so/#/login?/register?x=1"
        ] {
            #expect(Self.landing(start: start, landed: "https://www.notion.so/login") == .startPageCreatesAnAccount(url: start), "\(start)")
        }
        // And a second `#` inside a route's own query, which a cut at `/`, `.` and `?` still let through:
        // found by testing every short URL of the class rather than a list of examples. The decoder writes
        // the second `#` as `%23`, and the matcher reads the fragment decoded, so the refusal names the
        // decoder's spelling.
        for (start, named) in [
            ("https://www.notion.so/#/login?register#top", "https://www.notion.so/#/login?register%23top"),
            ("https://www.notion.so/#?signup#x", "https://www.notion.so/#?signup%23x")
        ] {
            #expect(Self.landing(start: start, landed: "https://www.notion.so/login") == .startPageCreatesAnAccount(url: named), "\(start)")
        }
        // A piece is read whole: a tracking key that only contains a word loads, in the query and in a route's.
        for start in [
            "https://www.notion.so/login?lang=en&signup_source=landing&signup_page=notion.so%2Findex&cta_type=button",
            "https://www.notion.so/#/login?signup_source=landing"
        ] {
            #expect(Self.landing(start: start, landed: "https://www.notion.so/login") == nil, "\(start) was refused")
        }
        for landed in [
            "https://www.notion.so/registered-users", "https://join.notion.so/", "https://www.notion.so/signin-help",
            "https://www.notion.so/SignIn"
        ] {
            #expect(Self.landing(start: "https://www.notion.so/", landed: landed) == nil, "\(landed) was refused")
        }
        // A site whose registrable name is one of the words is not refused for being itself — under a suffix
        // of one label. Under a suffix of two it is: `knownRefusalsOfTheWiderMatchAreHeld`.
        #expect(Self.landing(start: "https://www.signup.com/", landed: "https://www.signup.com/login", domain: "signup.com") == nil)
        // The runs, read directly: what each slug carries, and that a word of its own is not a run.
        #expect(SkillPackStartPageRule.accountCreationWords(in: "sign-up-free") == ["signup"])
        #expect(SkillPackStartPageRule.accountCreationWords(in: "Create_Account_Now") == ["createaccount"])
        #expect(SkillPackStartPageRule.accountCreationWords(in: "registered-users") == [])
        #expect(SkillPackStartPageRule.accountCreationWords(in: "register") == ["register"])
    }

    /// **What the wider match refuses although the page may not create an account** (review-282's F4,
    /// recorded as known refusals by the founders' ruling on PR #282). No address a shipped pack carries is
    /// one of the path, query and host samples. **Trello's is the exception, held last:** its shipped sign-in
    /// address is refused for a run in a value, and it can never be a start page because it is off Trello's
    /// own site. Each is here so that a change freeing one is made on purpose, and so the doc comment on
    /// `SkillPackStartPageRule.accountCreationParts` that lists them cannot drift from what the loader does.
    @Test
    func knownRefusalsOfTheWiderMatchAreHeld() throws {
        for landed in [
            "https://www.notion.so/event-registration", "https://www.notion.so/domain-registration",
            "https://www.notion.so/Register-Domain", "https://www.notion.so/account/register-device",
            "https://www.notion.so/un-register", "https://www.notion.so/de-register", "https://www.notion.so/newsletter-signup"
        ] {
            #expect(Self.landing(start: "https://www.notion.so/", landed: landed) == .startPageCreatesAnAccount(url: landed), "\(landed)")
        }
        for start in [
            "https://www.notion.so/login?next=%2Fregister-success", "https://www.notion.so/login?utm_campaign=signup-q3",
            "https://www.notion.so/login?ref=signup_page"
        ] {
            #expect(Self.landing(start: start, landed: "https://www.notion.so/login") == .startPageCreatesAnAccount(url: start), "\(start)")
        }
        // A site named for one of the words under a suffix of two labels: the host check drops only two.
        #expect(Self.landing(start: "https://www.register.co.uk/", landed: "https://www.register.co.uk/login", domain: "register.co.uk")
            == .startPageCreatesAnAccount(url: "https://www.register.co.uk/"))
        // Trello's shipped sign-in address, which cannot be a start page because it is off Trello's site.
        let trello = try #require(URL(string: "https://id.atlassian.com/login?application=trello--direct-signup&continue=https%3A%2F%2Ftrello.com%2F"))
        #expect(SkillPackStartPageRule.namesAccountCreation(trello))
    }

    /// **Only two words load**, and a near miss of either is not one of them — so a reader who has to
    /// write down a page that was not a start page has no word to write it in.
    @Test
    func onlySignInAndProductAreWordsAStartPageMayOffer() throws {
        for offers in ["sign-up", "marketing", "unreadable", "account-creation", "Sign-in", "sign in", "signin", "products"] {
            #expect(Self.landing(start: "https://www.notion.so/", landed: "https://www.notion.so/login", offers: offers)
                == .startPageNotAStartPage(url: "https://www.notion.so/", offers: offers), "\(offers)")
        }
        #expect(Self.landing(start: "https://www.notion.so/", landed: "https://www.notion.so/login", offers: " ")
            == .missingField("startPages[0].offers"))
    }

    /// **One record per start URL, for every start URL and for nothing else.** A flow whose start page
    /// nobody opened does not load, and the match is the exact URL — a trailing slash is another page,
    /// which is what makes adding one a change somebody has to read. A record no flow uses is refused too,
    /// or a start URL could change beside a reading of its predecessor and both would look recorded.
    @Test
    func everyStartURLHasExactlyOneRecordAndEveryRecordAFlow() throws {
        var unrecorded = Self.startPageObject(start: "https://www.notion.so/", landed: "https://www.notion.so/login")
        var second = SkillPackFixtures.flow(title: "Share a page")
        second["startURL"] = "https://www.notion.so/share"
        unrecorded["flows"] = [SkillPackFixtures.flow(), second]
        #expect(Self.error(unrecorded) == .startPageNotRecorded(flow: "Share a page"))

        #expect(Self.landing(start: "https://www.notion.so", recordedAs: "https://www.notion.so/", landed: "https://www.notion.so/login")
            == .startPageNotRecorded(flow: "Create a page"))

        var unused = Self.startPageObject(start: "https://www.notion.so/", landed: "https://www.notion.so/login")
        unused["startPages"] = [
            SkillPackFixtures.startPage(url: "https://www.notion.so/"),
            SkillPackFixtures.startPage(url: "https://www.notion.so/old")
        ]
        #expect(Self.error(unused) == .startPageUnused(url: "https://www.notion.so/old"))

        var twice = Self.startPageObject(start: "https://www.notion.so/", landed: "https://www.notion.so/login")
        twice["startPages"] = [SkillPackFixtures.startPage(url: "https://www.notion.so/"), SkillPackFixtures.startPage(url: "https://www.notion.so/")]
        #expect(Self.error(twice) == .startPageRecordedTwice(url: "https://www.notion.so/"))

        // Two flows sharing one start page need one record, not two.
        var shared = Self.startPageObject(start: "https://www.notion.so/", landed: "https://www.notion.so/login")
        shared["flows"] = [SkillPackFixtures.flow(), SkillPackFixtures.flow(title: "Share a page")]
        #expect(Self.error(shared) == nil)

        // A pack with no flows owes no record, and a record on one is a record no flow uses.
        var shallow = SkillPackFixtures.object(depth: "shallow")
        #expect(shallow["startPages"] == nil)
        #expect(Self.error(shallow) == nil)
        shallow["startPages"] = []
        #expect(Self.error(shallow) == nil)
        shallow["startPages"] = [SkillPackFixtures.startPage()]
        #expect(Self.error(shallow) == .startPageUnused(url: "https://www.notion.so/"))
    }

    /// The shape of a record, field by field: a landing is a page and not a session, so a query is
    /// refused; `read` is a date; the key set is closed, like every other object in a pack.
    @Test
    func aStartPageRecordHoldsItsShape() throws {
        #expect(Self.landing(start: "https://www.notion.so/", landed: "https://www.notion.so/login?next=%2Fhome")
            == .landedURLCarriesQuery(url: "https://www.notion.so/"))
        // A query inside a single-page app's fragment is refused the same way (review-272's item 9); the
        // route alone loads.
        #expect(Self.landing(start: "https://app.notion.so/", landed: "https://app.notion.so/#/login?redirect=/")
            == .landedURLCarriesQuery(url: "https://app.notion.so/"))
        #expect(Self.landing(start: "https://app.notion.so/", landed: "https://app.notion.so/#/login") == nil)
        #expect(Self.landing(start: "https://www.notion.so/", landed: "http://www.notion.so/login")
            == .notHTTPS(field: "startPages[0].landedURL"))

        func withField(_ key: String, _ value: Any?) -> SkillPackLoadError? {
            var object = Self.startPageObject(start: "https://www.notion.so/", landed: "https://www.notion.so/login")
            var page = (object["startPages"] as? [[String: Any]])?.first ?? [:]
            page[key] = value
            object["startPages"] = [page]
            return Self.error(object)
        }
        for key in ["url", "landedURL", "title", "heading", "offers", "read"] {
            #expect(withField(key, nil) == .missingField("startPages[0].\(key)"), "\(key)")
        }
        for read in ["18 September 2026", "2026-9-18", "2026-09-18T10:00", "20260918"] {
            #expect(withField("read", read) == .wrongType("startPages[0].read"), "\(read)")
        }
        // The right shape is not a date (SONNY-529): a month or a day that does not exist, a leap day in a
        // year without one, and a day before any reading under this rule could have been taken.
        for read in ["2026-13-45", "2026-00-10", "2026-09-00", "2026-02-30", "2027-02-29", "1970-01-01", "0000-00-00", "2026-09-16"] {
            #expect(withField("read", read) == .wrongType("startPages[0].read"), "\(read)")
        }
        for read in ["2026-09-17", "2026-09-18", "2028-02-29", "2031-12-31"] {
            #expect(withField("read", read) == nil, "\(read) was refused")
        }
        #expect(withField("signedIn", true) == .unknownField("startPages[0].signedIn"))
        // A racing page records its other titles; the field is optional, and never empty when present.
        #expect(withField("otherTitles", ["Otter Voice Meeting Notes - Otter.ai"]) == nil)
        #expect(withField("otherTitles", "Otter Voice Meeting Notes - Otter.ai") == .wrongType("startPages[0].otherTitles"))
        #expect(withField("otherTitles", [String]()) == .missingField("startPages[0].otherTitles"))
        #expect(withField("otherTitles", ["  "]) == .missingField("startPages[0].otherTitles"))

        var notAList = SkillPackFixtures.object()
        notAList["startPages"] = SkillPackFixtures.startPage()
        #expect(Self.error(notAList) == .wrongType("startPages"))
    }

    /// **Every shipped deep pack records where each of its start pages landed**, and the walk reached
    /// them. The loader already refuses a pack that does not — `everyShippedPackLoads…` holds that — so
    /// what this adds is the control that the population is not empty: a rule that no shipped pack ever
    /// met would pass exactly as warmly with the check deleted.
    @Test
    func everyShippedDeepPackRecordsWhereItsStartPagesLanded() throws {
        let catalogue = SkillPackCatalog.load(fileURLs: SkillPackCatalog.packFileURLs(in: Self.shippedPacksDirectory))
        let deep = catalogue.packs.filter { $0.depth == .deep }
        #expect(deep.count >= 3)
        for pack in deep {
            #expect(!pack.startPages.isEmpty, "\(pack.id) is deep and records no start page")
            #expect(Set(pack.startPages.map(\.url)) == Set(pack.flows.map(\.startURL)), "\(pack.id)")
        }
        for pack in catalogue.packs where pack.depth == .shallow {
            #expect(pack.startPages.isEmpty, "\(pack.id) is shallow and records a start page")
        }
    }

    /// **Every flow is judged at its own first step, and the check that found eBay's Watchlist flow runs
    /// here** (SONNY-529). SONNY-510's round five built it as a command in its changelog entry, and nothing
    /// ran it, so the next pack to bring the shape back would have met no guard. It asks three things of
    /// every shipped flow, through `firstStepFindings(in:)`:
    /// - a `product` record that more than one flow starts at, because one record standing for flows reached
    ///   differently is how eBay's Watchlist flow rode on its search flow's word;
    /// - a flow under a `product` record whose first step names a place a visitor who is not signed in may
    ///   not reach (My …, Watching, Settings, Account and the rest of `signedInPlaces`);
    /// - a flow of any kind whose first step names account creation (`accountCreationSteps`).
    ///
    /// **It reads words, so what it finds is judged, not refused.** A finding a person has read and judged
    /// is written into `judgedFirstStepFindings` with the reason, and the two sets must be equal both ways:
    /// a new finding fails here until somebody reads the flow, and a judgement whose flow has changed or
    /// gone fails too. A first step that names a signed-in place in other words passes; that is the limit
    /// of reading words, and the judgements are why a person reads each `product` flow as well.
    ///
    /// **Its guard travelled with it.** The command's first draft printed a clean zero by globbing the
    /// wrong folder, and it gained an exit 1 on reading no packs; here that is the `#require` on the pack
    /// count, and the counts after it are the control that the population it judges is not empty.
    @Test
    func everyFlowIsJudgedAtItsOwnFirstStep() throws {
        let catalogue = SkillPackCatalog.load(fileURLs: SkillPackCatalog.packFileURLs(in: Self.shippedPacksDirectory))
        try #require(catalogue.packs.count > 100, "the walk loaded \(catalogue.packs.count) packs")
        let flows = catalogue.packs.flatMap(\.flows)
        let productRecords = catalogue.packs.flatMap(\.startPages).filter { $0.offers == .product }
        #expect(flows.count > 100, "the walk found \(flows.count) flows")
        #expect(!productRecords.isEmpty, "no shipped start page says product, so the first two questions ask nothing")

        #expect(Self.firstStepFindings(in: catalogue.packs) == Self.judgedFirstStepFindings)
    }

    /// The check, held on the shapes it exists for, each decoded through `SkillPackDecoder` and sent
    /// through the same `firstStepFindings(in:)` the shipped packs meet (SONNY-388: a sample that enters
    /// downstream of the mechanism tests only what already works). eBay's pack as it stood before round
    /// five raises the first two questions; a sign-in flow that starts at "Sign up" raises the third; and
    /// the controls — a `product` flow in a search box, and a `sign-in` flow that starts in Settings, which
    /// is where a signed-in visitor begins — raise nothing.
    @Test
    func theFirstStepCheckFindsEachShapeItExistsFor() throws {
        func decoded(_ object: [String: Any]) throws -> SkillPack {
            try SkillPackDecoder.decode(SkillPackFixtures.data(object))
        }
        var ebay = SkillPackFixtures.object(id: "ebay", name: "eBay", domain: "ebay.com", category: "websites_apps_commerce")
        ebay["flows"] = [
            SkillPackFixtures.flow(title: "Save a search", steps: ["Search eBay for the item."], on: "ebay.com"),
            SkillPackFixtures.flow(title: "View and tidy your Watchlist", steps: ["Go to My eBay and select Watching."], on: "ebay.com")
        ]
        ebay["startPages"] = [SkillPackFixtures.startPage(on: "ebay.com", landedURL: "https://www.ebay.com/", offers: "product")]
        #expect(Self.firstStepFindings(in: [try decoded(ebay)]) == [
            "ebay | https://www.ebay.com/ | one product record starts 2 flows",
            "ebay | View and tidy your Watchlist | a signed-in place: My eBay, Watching | Go to My eBay and select Watching."
        ])

        var signUp = SkillPackFixtures.object()
        signUp["flows"] = [SkillPackFixtures.flow(steps: ["Click Sign up and create an account."])]
        #expect(Self.firstStepFindings(in: [try decoded(signUp)]) == [
            "notion | Create a page | account creation: Sign up, create an account | Click Sign up and create an account."
        ])

        var search = SkillPackFixtures.object(id: "ebay", name: "eBay", domain: "ebay.com", category: "websites_apps_commerce")
        search["flows"] = [SkillPackFixtures.flow(title: "Save a search", steps: ["Type the item into the search box."], on: "ebay.com")]
        search["startPages"] = [SkillPackFixtures.startPage(on: "ebay.com", landedURL: "https://www.ebay.com/", offers: "product")]
        var settings = SkillPackFixtures.object()
        settings["flows"] = [SkillPackFixtures.flow(steps: ["Open Settings, then My connections."])]
        #expect(Self.firstStepFindings(in: [try decoded(search), try decoded(settings)]) == [])
    }

    /// What `everyFlowIsJudgedAtItsOwnFirstStep` asks of each flow, as one line per finding:
    /// `<pack id> | <start URL> | one product record starts N flows`, `<pack id> | <flow title> | a signed-in
    /// place: … | <first step>` and `<pack id> | <flow title> | account creation: … | <first step>`, the
    /// words in the order the step names them. **The step's whole text is in the line** (review-282's F5):
    /// a finding keyed on the matched words alone let a judged step be rewritten to start somewhere
    /// signed-in, with the same words, and still pass as judged.
    static func firstStepFindings(in packs: [SkillPack]) -> Set<String> {
        var findings: Set<String> = []
        for pack in packs {
            let offers = Dictionary(uniqueKeysWithValues: pack.startPages.map { ($0.url, $0.offers) })
            let productStarts = pack.flows.filter { offers[$0.startURL] == .product }.map(\.startURL)
            for (url, count) in Dictionary(productStarts.map { ($0, 1) }, uniquingKeysWith: +) where count > 1 {
                findings.insert("\(pack.id) | \(url.absoluteString) | one product record starts \(count) flows")
            }
            for flow in pack.flows {
                let firstStep = flow.steps.first ?? ""
                let places = matches(of: signedInPlaces, in: firstStep)
                if offers[flow.startURL] == .product, !places.isEmpty {
                    findings.insert("\(pack.id) | \(flow.title) | a signed-in place: \(places.joined(separator: ", ")) | \(firstStep)")
                }
                let creation = matches(of: accountCreationSteps, in: firstStep)
                if !creation.isEmpty {
                    findings.insert("\(pack.id) | \(flow.title) | account creation: \(creation.joined(separator: ", ")) | \(firstStep)")
                }
            }
        }
        return findings
    }

    /// Places a first step can name that a visitor who is not signed in may not reach. The pattern is
    /// round five's, word for word, including its case: "Settings" as a place and not "settings" in a
    /// sentence.
    static let signedInPlaces = #"\bMy \w+|\bWatch(?:ing|list)\b|\bSaved\b|\bSettings\b|\bAccount\b|\bProfile\b|\bHistory\b|\bLibrary\b|\bDashboard\b|\bInbox\b|\bWorkspaces?\b|\bProjects?\b|\bSign in\b|\bLog in\b"#

    /// Words a first step can use to send a visitor into account creation, in any case. Round five's
    /// pattern, word for word.
    static let accountCreationSteps = #"(?i)\bsign ?up\b|\bcreate (?:an |a |your )?(?:free )?account\b|\bregister\b|\bfree trial\b|\bget started\b"#

    /// Each distinct match of `pattern` in `text`, in the order the text names them.
    static func matches(of pattern: String, in text: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            Issue.record("the pattern did not compile: \(pattern)")
            return []
        }
        let found = expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
        return found.reduce(into: []) { unique, word in
            if !unique.contains(word) { unique.append(word) }
        }
    }

    /// The findings a person has read and judged, each with the reason it stands. A flow here passed that
    /// reading; a new finding fails the check until somebody reads its flow too.
    ///
    /// - Grok's question flow names Settings, Sign in and Sign up only while describing the row across the
    ///   top of the page. Its action is the prompt box in the middle, which SONNY-510's round four read
    ///   signed out on 2026-09-18 and found usable. It is also the control that both patterns find their
    ///   words in real step text.
    /// - Pipedrive's import flow names "Get started" as the import wizard's own button, reached through the
    ///   account menu, Tools and apps and Import data inside the signed-in app; the flow starts at a
    ///   `sign-in` record, and the button imports a spreadsheet rather than creating an account. Judged on
    ///   the step's own text when SONNY-518's pack arrived at this branch's hop (2026-09-19), and confirmed
    ///   on the cited support article by review-282, read in a drawing window at 19:33:59Z that day: "Go to
    ///   account menu > Tools and apps > Import data > Import from spreadsheet, then click 'Get started'".
    static let judgedFirstStepFindings: Set<String> = [
        "grok | Ask Grok a question | a signed-in place: Settings, Sign in | \(grokFirstStep)",
        "grok | Ask Grok a question | account creation: Sign up | \(grokFirstStep)",
        "pipedrive | Import people, organizations or deals from a spreadsheet | account creation: Get started | \(pipedriveImportFirstStep)"
    ]

    /// Pipedrive's judged import step, whole. Editing it is re-judging the step.
    static let pipedriveImportFirstStep = "Go to the account menu > Tools and apps > Import data > Import from spreadsheet, click Get started, then click Next."

    /// The judged step, whole. Review-282 re-read it on screen on 2026-09-19 and the judgement stands: the
    /// "Ask Grok anything" box is present and enabled signed out, and the top-right row holds Imagine, a
    /// settings icon, Sign in and Sign up. Editing this string is re-judging the step, which is the point.
    static let grokFirstStep = "Go to grok.com. There is no side navigation: Imagine, Settings, Sign in and Sign up sit in one row across the top right, and the prompt box is in the middle of the page."

    /// A deep fixture pack whose one flow starts at `start` and whose record says it landed on `landed`.
    static func startPageObject(
        start: String,
        recordedAs: String? = nil,
        landed: String,
        offers: String = "sign-in",
        domain: String = "notion.so",
        signIn: String? = "https://notion.so/login"
    ) -> [String: Any] {
        var object = SkillPackFixtures.object(domain: domain)
        object["signInURL"] = signIn.map { $0 as Any } ?? NSNull()
        var flow = SkillPackFixtures.flow(on: domain)
        flow["startURL"] = start
        object["flows"] = [flow]
        object["startPages"] = [SkillPackFixtures.startPage(url: recordedAs ?? start, landedURL: landed, offers: offers)]
        return object
    }

    /// What the loader says about `startPageObject`'s pack.
    static func landing(
        start: String,
        recordedAs: String? = nil,
        landed: String,
        offers: String = "sign-in",
        domain: String = "notion.so",
        signIn: String? = "https://notion.so/login"
    ) -> SkillPackLoadError? {
        error(startPageObject(start: start, recordedAs: recordedAs, landed: landed, offers: offers, domain: domain, signIn: signIn))
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

    /// Post-1934 words a work tool's trigger is likeliest to be, each one absent from the system list
    /// (`grep -ixc <word> /usr/share/dict/words` → 0 for every entry, on macOS 26.6.2). Singular forms
    /// only: `isOrdinary` reads each word's singular too. A duplicate here would trap the test process,
    /// since a `Set` literal refuses one.
    ///
    /// `luma` is here by ruling rather than by gap (SONNY-492): it is the word video and photo editors
    /// use for brightness, as in a luma key or a luma matte, so a command about editing would bring in
    /// the Luma events pack.
    static let modernWords: Set<String> = [
        "email", "inbox", "app", "website", "online", "offline", "download", "logout", "signup", "dm",
        "sms", "blog", "podcast", "webinar", "emoji", "hashtag", "username", "wifi", "laptop",
        "smartphone", "spreadsheet", "workspace", "homepage", "chatbot", "url", "pdf", "csv",
        "screenshot", "selfie", "meme", "livestream", "ebook", "todo", "checklist", "whiteboard",
        "expo", "grok", "luma"
    ]

    /// Ordinary words the system list does not spell at all, though nothing about them is modern
    /// (SONNY-492). `grep -ixc box /usr/share/dict/words` → 0, and the same for `boxes`, while `cat`
    /// answers 2, and `dog`, `fox`, `tax` and `mix` answer 1 each (macOS 26.6.2). So the gaps are
    /// scattered rather than a broken list, and no rule predicts one. `podia` is the plural of
    /// `podium`, which the list does spell, and no suffix rule reaches it. Both were found by a person
    /// reading every shipped one-word trigger, not by this check.
    ///
    /// The search is case-insensitive because `ordinaryWords()` lowercases the list, so a capitalised
    /// `Box` in it would already refuse this word (PR #251's review, R1). The two searches differ on
    /// this file — `grep -xc cat` → 1 against `grep -ixc cat` → 2 — so which one a figure came from
    /// has to be said.
    static let ordinaryWordsTheSystemListLacks: Set<String> = ["box", "podia"]

    /// Whether `word` or one of its singular forms is ordinary. The forms come from
    /// `SkillWords.singularCandidates(of:)`, the copy the money rule reads plurals through as well.
    static func isOrdinary(_ word: String, ordinary: Set<String>) -> Bool {
        SkillWords.singularCandidates(of: word).contains {
            ordinary.contains($0) || modernWords.contains($0) || ordinaryWordsTheSystemListLacks.contains($0)
        }
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
            if isOrdinary(word, ordinary: ordinary) { return "\(word) is an ordinary word" }
            return nil
        }
        // Anchored means the phrase carries the site's **whole** name. One word of a longer name is not
        // enough: "docs" is Google Docs' own word and an ordinary one, so "new docs" would join
        // "tidy my new docs" — the delta pass's case, which a per-word anchor let through.
        let nameWords = SkillWords.cut(SearchText.normalized(siteName))
        let anchored = SkillWords(folded).contains(nameWords)
        let allOrdinary = words.allSatisfy { isOrdinary($0, ordinary: ordinary) || $0.count <= 2 }
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

    /// The two values of a catalogue row's `task_flow_docs` that let a pack be deep, out of the three
    /// the column has. `deep` is a documentation page anybody can re-open at the cited URL; `site` is
    /// the running product, where no artifact exists — what each one means is stated once, in
    /// `SkillPack`'s depth doc comment, and how any of these pages must be read is stated once in
    /// `CLAUDE.md`'s Claims and evidence section. `shallow` is neither, and a row saying it
    /// keeps every pack on it shallow; no row says it today, and it stays a legal word because a site
    /// added before anyone has read its flows has nothing else to say — which is a statement about
    /// `depthProblem`'s answer, held below in `aDeepPackNeedsDocumentedOrSiteReadFlowsAndAShallowPackSitsOnAnyRow`,
    /// rather than about a list of words. There was such a list, `taskFlowEvidence`; neither of its
    /// uses pinned it, and removing `shallow` from it passed the whole suite (review-260's F3), so it
    /// is gone rather than pinned: the tally in `theCommittedCatalogueIsTheListTheFoundersDecided`
    /// already refuses any word the column does not have, by counting.
    static let evidenceForADeepPack: Set<String> = ["deep", "site"]

    /// Why a pack of this depth may not sit on this row, or `nil` when it may. Two conditions, both
    /// about evidence: the row names a kind somebody read, and it names at least one page it was read
    /// from. The second is review-260's F4 — a documentation reading leaves an artifact anyone can
    /// re-open, a browser reading leaves none, so for a `site` row the cells are the only place that
    /// evidence exists at all.
    static func depthProblem(_ depth: SkillPackDepth, taskFlowDocs: String, pages: [String]) -> String? {
        guard depth == .deep else { return nil }
        guard evidenceForADeepPack.contains(taskFlowDocs) else {
            return "is deep, and its catalogue row's task_flow_docs says \(taskFlowDocs.isEmpty ? "nothing" : taskFlowDocs)"
        }
        guard pages.contains(where: { $0.hasPrefix("http") }) else {
            return "is deep, and its catalogue row names no page its flows were read from"
        }
        return nil
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
