import Foundation
import MacAgentCore

/// A pack that passes every rule, built as the JSON a pack author writes and decoded through the
/// real loader — so a fixture pack cannot be something the loader would refuse.
///
/// Here rather than in `MacAgentCoreTests` so that the Command Center tests build their catalogue
/// from the same builder the loader's own tests use (SONNY-481).
public enum SkillPackFixtures {
    public static func object(
        id: String = "notion",
        name: String = "Notion",
        domain: String = "notion.so",
        category: String = "knowledge_bases",
        depth: String = "deep"
    ) -> [String: Any] {
        var object: [String: Any] = [
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
        // A shallow pack has no flows and so carries no start-page record, the way the shipped ones do.
        if depth == "deep" {
            object["startPages"] = [startPage(on: domain)]
        }
        return object
    }

    /// The record of where `flow(on:)`'s start page landed: an ordinary sign-in page on the pack's own
    /// site (SONNY-510). A test that moves a flow's start URL replaces this with `startPage(url:…)`, or
    /// the pack does not load for want of a record — which is the rule, not the fixture being fussy.
    public static func startPage(
        on domain: String = "notion.so",
        url: String? = nil,
        landedURL: String? = nil,
        offers: String = "sign-in"
    ) -> [String: Any] {
        [
            "url": url ?? "https://www.\(domain)/",
            "landedURL": landedURL ?? "https://www.\(domain)/login",
            "title": "Log in",
            "heading": "Log in to your account",
            "offers": offers,
            "read": "2026-09-18"
        ]
    }

    /// A flow starting on `domain`'s own site, which every flow has to (PR #241's F4). Its citation is
    /// deliberately on another host, because the rule does not hold citations to the site.
    public static func flow(
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

    public static func data(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    public static func pack(id: String, name: String, domain: String) throws -> SkillPack {
        try SkillPackDecoder.decode(data(object(id: id, name: name, domain: domain)))
    }

    /// Three packs a Command Center test owns: Docusign (shallow), and Linear and Notion (deep), in
    /// that name order.
    ///
    /// **Never read from `Sources/MacAgent/Resources/SkillPacks/`** (SONNY-481). The pack lanes add
    /// packs there, and a test that read that folder for a page's rows or a planner's prompt went red
    /// on the first well-formed pack for no product reason. Only the tests whose job is to load and
    /// validate every shipped pack read the folder, in `SkillPackTests`.
    ///
    /// Decoded through `SkillPackCatalog.load(files:)`, so a fixture the loader would refuse throws
    /// here instead of leaving a test to assert against a shorter list.
    public static func catalogue() throws -> SkillPackCatalog {
        var docusign = object(id: "docusign", name: "Docusign", domain: "docusign.com", category: "documents_storage", depth: "shallow")
        docusign["summary"] = "Electronic signatures and agreements."
        var linear = object(id: "linear", name: "Linear", domain: "linear.app", category: "project_tracking")
        linear["summary"] = "Issue tracking for software teams."
        linear["triggers"] = ["linear issue", "linear.app"]
        var notion = object(id: "notion", name: "Notion", domain: "notion.so")
        notion["summary"] = "Notes, docs and wikis in one workspace."
        notion["triggers"] = ["in notion", "notion page"]

        let catalogue = SkillPackCatalog.load(files: try [docusign, linear, notion].map { pack in
            (fileName: "\(pack["id"]!).skillpack.json", data: try data(pack))
        })
        guard catalogue.failures.isEmpty, catalogue.packs.map(\.id) == ["docusign", "linear", "notion"] else {
            throw FixtureCatalogueRefused(failures: catalogue.failures, loadedIDs: catalogue.packs.map(\.id))
        }
        return catalogue
    }

    public struct FixtureCatalogueRefused: Error, CustomStringConvertible {
        public let failures: [SkillPackLoadFailure]
        public let loadedIDs: [String]

        public var description: String {
            "the fixture catalogue did not load as three packs: loaded \(loadedIDs), refused \(failures)"
        }
    }
}
