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

    /// No shipping source holds a provider credential's or a model-selection variable's name.
    ///
    /// **`OPENAI_API_KEY` and the three beside it were deliberately absent from this list until
    /// SONNY-136, and are on it now.** SONNY-130's never-touch list required those strings to stay
    /// in four files as the wording of errors the user could still be shown, and
    /// `feature/row-12-degradation` owned removing them; that ticket has run, so what was an
    /// exception with a named owner is now the rule with no exceptions. This is the list of every
    /// provider credential and model-selection variable the client has ever read.
    ///
    /// **Comments are stripped before the search**, per `MacAgentSource.read`, so the doc comments
    /// that record *why* each one went — and quote the sentences they used to produce — do not fail
    /// this. That is the right direction: those paragraphs are the record of a removal, and a scan
    /// that forbade writing one down would push the reasoning out of the tree.
    @Test
    func noShippingSourceNamesAProviderCredentialOrAModelSelectionVariable() throws {
        let forbidden = [
            "CEREBRAS_API_KEY", "CEREBRAS_MODEL", "SONNY_CEREBRAS_STRUCTURED",
            "OPENAI_API_KEY", "TAVILY_API_KEY", "OPENCODE_API_KEY",
            "OPENAI_MODEL", "OPENAI_TRANSCRIBE_MODEL", "SONNY_VISION_MODEL",
        ]
        for source in try shippingSources() {
            for name in forbidden {
                #expect(
                    !source.text.contains(name),
                    "\(source.path) names \(name) — every provider credential and model choice is server-side configuration"
                )
            }
        }
    }

    /// **SONNY-106 section E, as a scan: no environment variable is required for anything.**
    ///
    /// An allow-list rather than a deny-list, and that is the whole value of it. A deny-list stops
    /// the variables somebody thought of; this fails on a *fourth* environment read of any name,
    /// which is the shape the requirement actually has — the packaged app is launched from Finder,
    /// which inherits no shell environment, so any read that gates behaviour is a feature that
    /// silently is not there for every user who is not the founder in a terminal.
    ///
    /// The three that are allowed, each with the reason it is not provider configuration:
    ///
    /// - `MAC_AGENT_MOCK_DOCX` — the DOCX conversion mock, so a test can exercise the converter
    ///   without Microsoft Word. On SONNY-136's never-touch list by name.
    /// - `XCTestConfigurationFilePath` — set by the test runner, read twice to answer "am I in a
    ///   test process". Nothing a user's build can be affected by, because a user's build is not one.
    /// - `overrideEnvironmentVariable` — the debug-only staging pointer, whose whole declaration
    ///   sits inside `#if DEBUG` and is not compiled into a release binary at all. Also on the
    ///   never-touch list, and `SignInReleaseSwitchScanTests` is what holds the `#if` in place.
    ///
    /// **This scan reads a subscript, not a symbol**, so an indirection cannot hide a read from it:
    /// `let p = ProcessInfo.processInfo` followed by `p.environment["X"]` is found, and that shape
    /// is not hypothetical — two of the three allowed reads are written exactly that way, and a
    /// grep for `ProcessInfo.processInfo.environment` finds neither.
    @Test
    func theOnlyEnvironmentReadsLeftAreTheThreeThatAreNotProviderConfiguration() throws {
        let allowed = ["\"MAC_AGENT_MOCK_DOCX\"", "\"XCTestConfigurationFilePath\"", "overrideEnvironmentVariable"]
        let subscripts = try NSRegularExpression(pattern: "\\benvironment\\s*\\[\\s*([^\\]]+?)\\s*\\]")

        var found: [(path: String, key: String)] = []
        for source in try shippingSources() {
            let range = NSRange(source.text.startIndex..., in: source.text)
            for match in subscripts.matches(in: source.text, range: range) {
                guard let keyRange = Range(match.range(at: 1), in: source.text) else { continue }
                found.append((source.path, String(source.text[keyRange])))
            }
        }

        // The scan means nothing if it found nothing: four reads of three allowed names are known
        // to be there — `XCTestConfigurationFilePath` twice, in `InstalledAppResolver` and
        // `LocalStorageEncryption` — so an empty result is a broken scan rather than a clean tree
        // (`CLAUDE.md`, "a clean zero is the one answer that looks like good news"). The count is
        // pinned rather than only the names, so that a *second* read of an allowed name — a new
        // `MAC_AGENT_MOCK_DOCX` gate somewhere else — is a deliberate act rather than a silent one.
        #expect(found.count == 4, "found \(found.map { "\($0.path): \($0.key)" })")
        for read in found {
            #expect(
                allowed.contains(read.key),
                "\(read.path) reads the environment for \(read.key) — SONNY-106 section E requires that a user's build need no environment variable"
            )
        }
        // Each allowed key is actually present, so the list cannot rot into three names that no
        // longer match anything while the scan goes on reporting a clean tree.
        for key in allowed {
            #expect(found.contains { $0.key == key }, "\(key) is allowed but no source reads it")
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
