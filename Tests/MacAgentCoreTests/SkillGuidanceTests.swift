import Foundation
import MacAgentTestSupport
import Testing
@testable import MacAgentCore

/// Which added skills join a command's plan request (SONNY-452).
@Suite
struct SkillGuidanceTests {
    /// The property the whole seam rests on: guidance is built from the added packs alone, so a pack
    /// the user never added cannot reach a prompt however plainly the command names its site.
    @Test
    func aPackTheUserNeverAddedNeverJoinsEvenWhenTheCommandNamesIt() throws {
        let notion = try SkillPackFixtures.pack(id: "notion", name: "Notion", domain: "notion.so")
        let linear = try SkillPackFixtures.pack(id: "linear", name: "Linear", domain: "linear.app")
        let catalogue = SkillPackCatalog(packs: [linear, notion], failures: [])
        let guidance = SkillGuidance(addedPacks: catalogue.packs.filter { ["linear"].contains($0.id) })

        #expect(guidance.matchingPacks(for: "create a page in Notion called wave 7 notes") == [])
        #expect(guidance.block(for: "create a page in Notion called wave 7 notes") == nil)
        #expect(guidance.block(for: "open notion.so") == nil)

        // The control: the same guidance does join for the pack that was added.
        #expect(guidance.matchingPacks(for: "file a Linear issue").map(\.id) == ["linear"])
    }

    /// Two added packs a command names both join, in the order the command names them, after the
    /// header that says no rule above them moves.
    @Test
    func twoAddedPacksTheCommandNamesBothJoinInTheOrderItNamesThem() throws {
        let notion = try SkillPackFixtures.pack(id: "notion", name: "Notion", domain: "notion.so")
        let linear = try SkillPackFixtures.pack(id: "linear", name: "Linear", domain: "linear.app")
        let guidance = SkillGuidance(addedPacks: [notion, linear])

        let block = try #require(guidance.block(for: "copy the linear issue into a Notion page"))

        #expect(block == [SkillGuidance.header, linear.guidance, notion.guidance].joined(separator: "\n\n"))
    }

    /// **Only a trigger names a pack** (founders, 2026-09-13, option A on PR #241's F3). The site's
    /// name and domain join a command only when the pack lists them as triggers; matching stays
    /// folded and by whole word.
    @Test
    func onlyATriggerNamesAPackNotItsNameOrDomainAlone() throws {
        var object = SkillPackFixtures.object(id: "google_calendar", name: "Google Calendar", domain: "calendar.google.com")
        object["triggers"] = ["gcal", "google calendar"]
        let calendar = try SkillPackDecoder.decode(SkillPackFixtures.data(object))
        let guidance = SkillGuidance(addedPacks: [calendar])

        #expect(guidance.matchingPacks(for: "add lunch to GOOGLE CALENDAR").map(\.id) == ["google_calendar"])
        #expect(guidance.matchingPacks(for: "what's on my gcal today").map(\.id) == ["google_calendar"])
        #expect(guidance.matchingPacks(for: "open my gcalendar export").isEmpty)
        // The domain is not a trigger here, so naming it joins nothing.
        #expect(guidance.matchingPacks(for: "open https://calendar.google.com/r").isEmpty)

        var nameless = SkillPackFixtures.object(id: "notion", name: "Notion", domain: "notion.so")
        nameless["triggers"] = ["notion page"]
        let notion = try SkillPackDecoder.decode(SkillPackFixtures.data(nameless))
        #expect(SkillGuidance(addedPacks: [notion]).matchingPacks(for: "open Notion").isEmpty)
        #expect(SkillGuidance(addedPacks: [notion]).matchingPacks(for: "open my Notion page").map(\.id) == ["notion"])
    }

    /// **The review's cases** (PR #241's F3), each of which joined a pack by its everyday name at
    /// `12ebe84a`: Make took a slot from Slack, "close Safari" joined Close, and "1280 x 800" joined X.
    /// With triggers anchored to their sites, none joins, and a command naming a listed trigger still
    /// joins its pack.
    @Test
    func aSiteCalledByAnEverydayWordJoinsOnlyOnItsOwnTriggers() throws {
        func pack(_ id: String, _ name: String, _ domain: String, _ triggers: [String]) throws -> SkillPack {
            var object = SkillPackFixtures.object(id: id, name: name, domain: domain)
            object["triggers"] = triggers
            return try SkillPackDecoder.decode(SkillPackFixtures.data(object))
        }
        let guidance = SkillGuidance(addedPacks: [
            try pack("make", "Make", "make.com", ["make scenario", "make.com"]),
            try pack("linear", "Linear", "linear.app", ["linear issue", "linear.app"]),
            try pack("notion", "Notion", "notion.so", ["notion page", "in notion"]),
            try pack("slack", "Slack", "slack.com", ["in slack", "slack channel"]),
            try pack("close", "Close", "close.com", ["close crm", "close.com"]),
            try pack("x", "X", "x.com", ["x.com", "post on x"])
        ])

        #expect(guidance.matchingPacks(for: "make a Linear issue from my Notion page and post it in Slack").map(\.id) == ["linear", "notion", "slack"])
        #expect(guidance.matchingPacks(for: "close Safari").isEmpty)
        #expect(guidance.matchingPacks(for: "close all my Finder windows").isEmpty)
        #expect(guidance.matchingPacks(for: "resize the window to 1280 x 800").isEmpty)
        #expect(guidance.matchingPacks(for: "build a Make scenario for new leads").map(\.id) == ["make"])
        #expect(guidance.matchingPacks(for: "log the call in close.com").map(\.id) == ["close"])
    }

    @Test
    func nonlinearIsNotLinear() throws {
        let linear = try SkillPackFixtures.pack(id: "linear", name: "Linear", domain: "linear.app")
        #expect(SkillGuidance(addedPacks: [linear]).block(for: "plot a nonlinear curve") == nil)
    }

    /// At most `maximumPacksPerCommand` join, and the ones kept are the first named.
    @Test
    func aCommandNamingMorePacksThanTheCapJoinsTheFirstOnesItNames() throws {
        let names = ["Asana", "Linear", "Notion", "Trello"]
        let packs = try names.map { try SkillPackFixtures.pack(id: $0.lowercased(), name: $0, domain: "\($0.lowercased()).com") }
        let guidance = SkillGuidance(addedPacks: packs)

        let matched = guidance.matchingPacks(for: "move trello cards to notion, linear and asana")

        #expect(SkillGuidance.maximumPacksPerCommand == 3)
        #expect(matched.map(\.id) == ["trello", "notion", "linear"])
    }

    /// The worst plan request skills can produce, encoded the way `OpenAIPlanner.plan` encodes it —
    /// three packs, each within a few bytes of the per-pack ceiling, all named by one command — against
    /// the gateway's plan route body limit, `BODY_LIMIT_BYTES.plan` = 1,048,576 in
    /// `server/src/model/limits.ts`. Measured on the decoded body, which is what that limit is.
    @Test
    func theLargestPlanRequestSkillsCanProduceIsFarInsideThePlanRoutesBodyLimit() throws {
        let packs = try ["Asana", "Linear", "Notion"].map { name -> SkillPack in
            var object = SkillPackFixtures.object(id: name.lowercased(), name: name, domain: "\(name.lowercased()).com")
            object["flows"] = [SkillPackFixtures.flow(steps: Array(repeating: String(repeating: "x", count: 190), count: 29), on: "\(name.lowercased()).com")]
            return try SkillPackDecoder.decode(SkillPackFixtures.data(object))
        }
        for pack in packs {
            #expect(pack.guidance.utf8.count > SkillPack.guidanceByteLimit - 250, "the fixture is not near the ceiling")
        }
        let command = "move the asana tasks into linear and notion"
        let guidance = SkillGuidance(addedPacks: packs)
        #expect(guidance.matchingPacks(for: command).count == 3)

        let system = OpenAIPlanner.systemPrompt(toolRegistry: .default, command: command, skillGuidance: guidance)
        let body = try SonnyTextRouteBody(
            context: ModelRouteFixtures.standardContext,
            messages: [(role: "system", text: system), (role: "user", text: command)],
            schemaName: AgentPlanSchema.name,
            schema: AgentPlanSchema.schema()
        ).encoded()
        let unskilled = try SonnyTextRouteBody(
            context: ModelRouteFixtures.standardContext,
            messages: [(role: "system", text: OpenAIPlanner.systemPrompt(toolRegistry: .default)), (role: "user", text: command)],
            schemaName: AgentPlanSchema.name,
            schema: AgentPlanSchema.schema()
        ).encoded()

        #expect(body.count - unskilled.count <= SkillGuidance.largestBlockBytes + 4_096, "JSON escaping aside, the growth is the block")
        #expect(body.count < 1_048_576 / 4, "the plan request is \(body.count) bytes")
    }

    /// The bound the test above measures a request against: the header plus the cap's worth of packs
    /// at the byte ceiling.
    @Test
    func theLargestBlockAnyCommandCanAddIsBounded() throws {
        #expect(SkillGuidance.largestBlockBytes == SkillGuidance.header.utf8.count + 3 * (6_000 + 2))
        #expect(SkillGuidance.largestBlockBytes < 20_000)
    }
}
