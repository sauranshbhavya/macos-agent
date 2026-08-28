import Foundation
import Testing
@testable import MacAgentCore

/// The plan schema, checked in where the server's tests can read it (SONNY-132, PR #143 F9).
///
/// **Why a fixture at all.** `prunedSchema` in `server/src/model/anthropic.ts` maps the client's
/// JSON Schema onto the subset Anthropic's structured outputs accept, and the branch shipped with
/// no test running the *real* schema through it — so the one input that matters in production was
/// the one input nothing exercised. The schema is authored in Swift and the prune is TypeScript,
/// and the only honest way to join them is a serialized copy both sides read.
///
/// **What stops it drifting.** This test is the guard: it re-serializes `AgentPlanSchema.schema()`
/// and compares it byte for byte with the checked-in file, so a change to the schema that is not
/// carried into the fixture fails here rather than being discovered by a provider months later.
/// Sorted keys, because a fixture that reordered itself between runs could not be compared at all.
@Suite
struct AgentPlanSchemaFixtureTests {
    static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MacAgentCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repository root
            .appendingPathComponent("server/test/fixtures/agent-plan-schema.json")
    }

    static func serialized() throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: AgentPlanSchema.schema(),
            options: [.sortedKeys, .prettyPrinted]
        )
        return (String(data: data, encoding: .utf8) ?? "") + "\n"
    }

    @Test
    func theCheckedInFixtureIsTheRealPlanSchema() throws {
        let expected = try Self.serialized()
        let onDisk = try String(contentsOf: Self.fixtureURL, encoding: .utf8)
        #expect(
            onDisk == expected,
            """
            server/test/fixtures/agent-plan-schema.json is not AgentPlanSchema.schema() any more. \
            The server's Anthropic prune test reads that file, so a schema change that stops here \
            leaves the one input that matters in production unexercised. Regenerate it.
            """
        )
    }

    /// The two properties the server's prune has to survive, asserted on the Swift side too so a
    /// reader of either file finds the same facts.
    @Test
    func theRealSchemaCarriesTheShapesTheAnthropicPruneExistsFor() throws {
        let text = try Self.serialized()
        // A complex array constraint, which structured outputs reject.
        #expect(text.contains("\"minItems\""))
        // Type unions, which are not a documented form of that subset.
        //
        // **53 in the serialized schema, against 27 occurrences in the source, and the difference
        // is not a discrepancy.** PR #143's F9 counted the source
        // (`grep -c '"type": [' Sources/MacAgentCore/AgentPlan.swift` → 27); what reaches a provider
        // is the serialized form, and `AgentPlanSchema.stepSchema` is embedded twice — once for
        // `steps` and once for the nested `routineSteps` — so every union inside it appears twice on
        // the wire. The wire figure is the one `prunedSchema` has to survive, so it is the one
        // asserted here. Counted with a walker rather than a substring scan on the server side
        // (`test/anthropic.test.ts`); this side uses the pretty-printed spelling the fixture has.
        let unions = text.components(separatedBy: "\"type\" : [").count - 1
        #expect(unions == 53, "expected 53 serialized type-union nodes, found \(unions)")
    }
}
