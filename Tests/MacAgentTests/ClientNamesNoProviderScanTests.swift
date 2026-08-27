import Foundation
import Testing
@testable import MacAgent

/// The client names no model provider, and holds no provider credential (SONNY-132).
///
/// **A test rather than a grep run once, because a grep run once is a claim about the day it was
/// run.** SONNY-132's acceptance criteria ask for a demonstration that `SONNY_PLANNER` no longer
/// exists in the client and that nothing in the app mentions a provider name; the founder's own
/// manual pass checks the second by eye. What neither catches is a later branch putting one back,
/// which is the ordinary way a property like this is lost — and the property is load-bearing rather
/// than cosmetic. `docs/sonny-backend-api-contract.md` §4.2: "the client does not know which
/// mechanism was used and must not need to." Spec §16.5: "Provider credentials never ship to
/// client." A client that names a provider is a client that has an opinion about routing, and
/// routing is what row 12 moved to the server so SONNY-110 could be a redeploy.
///
/// **What a textual scan can and cannot say, per `MacAgentSource`'s own doc.** Comments are stripped
/// before the search, so a token surviving in prose does not fail this. String literals are not
/// distinguishable from code, which here is the *safe* direction: a provider name inside a literal
/// is exactly the thing being refused, so a literal that satisfied this scan would be a real
/// finding rather than a false one. And it reads both shipping targets, because provider-shaped code
/// lived in `MacAgentCore` — that is where `CerebrasPlanner` was.
@Suite
@MainActor
struct ClientNamesNoProviderScanTests {
    /// Every source file of both shipping targets, with its path, comments already stripped.
    private func shippingSources() throws -> [(path: String, text: String)] {
        var sources: [(path: String, text: String)] = []
        for url in try MacAgentSource.appSourceFiles() {
            sources.append(("MacAgent/" + MacAgentSource.relativePath(of: url), try MacAgentSource.read(url)))
        }
        for url in try MacAgentSource.coreSourceFiles() {
            sources.append((
                "MacAgentCore/" + MacAgentSource.coreRelativePath(of: url),
                try MacAgentSource.read(url)
            ))
        }
        return sources
    }

    /// The population is asserted before it is searched, so an empty scan cannot pass as a clean one.
    ///
    /// This is the failure mode `CLAUDE.md`'s exit-code rule describes from the other side: a scan
    /// whose file list came back empty finds nothing, reports nothing, and is indistinguishable from
    /// a tree that genuinely holds nothing.
    @Test
    func theScanReadsBothShippingTargetsAndNotAnEmptyList() throws {
        let sources = try shippingSources()
        #expect(sources.count > 50, "the scan read \(sources.count) files, which is too few to be the tree")
        #expect(sources.contains { $0.path == "MacAgent/AgentViewModel.swift" })
        #expect(sources.contains { $0.path == "MacAgentCore/OpenAIPlanner.swift" })
    }

    /// `SONNY_PLANNER` is gone, which is the ticket's fourth requirement made checkable.
    ///
    /// It was the only way to reach the Cerebras planner, and the last environment variable naming a
    /// provider choice. Cerebras is now a `MODEL_ROUTE_PLAN` entry on the gateway.
    @Test
    func noShippingSourceReadsAPlannerSelectionEnvironmentVariable() throws {
        for source in try shippingSources() {
            #expect(
                !source.text.contains("SONNY_PLANNER"),
                "\(source.path) still reads SONNY_PLANNER — planner choice is MODEL_ROUTE_PLAN on the gateway"
            )
        }
    }

    /// No shipping source holds a provider credential's variable name.
    ///
    /// **`OPENAI_API_KEY` is deliberately not on this list and its absence is not an oversight.**
    /// SONNY-130's never-touch list required that string to stay in four files as the wording of an
    /// error the user can still be shown, and `feature/row-12-degradation` (SONNY-136) owns removing
    /// it. What this list holds is the ones no ticket has a reason to keep: the credential
    /// `CerebrasPlanner` read, and the two model-selection variables it read beside it.
    @Test
    func noShippingSourceNamesTheCerebrasCredentialOrItsModelVariables() throws {
        let forbidden = ["CEREBRAS_API_KEY", "CEREBRAS_MODEL", "SONNY_CEREBRAS_STRUCTURED"]
        for source in try shippingSources() {
            for name in forbidden {
                #expect(
                    !source.text.contains(name),
                    "\(source.path) names \(name) — that credential is the gateway's since SONNY-132"
                )
            }
        }
    }

    /// No shipping source reaches a model vendor's endpoint.
    ///
    /// The hostnames rather than the vendor names: a *name* legitimately survives in a type name
    /// (`OpenAIPlanner`, which §4.2 cites and which is not OpenAI-specific any more), while a
    /// hostname can only be one thing — this client opening a socket to a provider. That is the
    /// property spec §16.5 is actually about, and it is the one a scan can hold without arguing
    /// about identifiers.
    @Test
    func noShippingSourceNamesAModelProvidersEndpoint() throws {
        let endpoints = [
            "api.openai.com",
            "api.anthropic.com",
            "api.cerebras.ai",
            "api.tavily.com",
        ]
        for source in try shippingSources() {
            for endpoint in endpoints {
                #expect(
                    !source.text.contains(endpoint),
                    "\(source.path) names \(endpoint) — every provider endpoint is server-side configuration"
                )
            }
        }
    }

    /// The client-side router is gone, symbol by symbol.
    ///
    /// Named individually rather than checked as one string, so a partial revival — the registry
    /// back without the selection, say — fails with the symbol that came back rather than with a
    /// generic message.
    @Test
    func theClientSidePlannerRouterIsGone() throws {
        let removed = [
            "PlannerProviderRegistry",
            "PlannerProviderResolution",
            "SelectedPlanner",
            "CerebrasPlanner",
            "CerebrasChatResponseParser",
            "plannerFallbackNotice",
        ]
        for source in try shippingSources() {
            for symbol in removed {
                #expect(
                    !source.text.contains(symbol),
                    "\(source.path) still references \(symbol), which SONNY-132 deleted"
                )
            }
        }
    }
}
