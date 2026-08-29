import Foundation
import Testing
@testable import MacAgent
@testable import MacAgentCore

/// The two structural properties of the entitlement check that no runtime assertion can reach
/// (SONNY-135).
///
/// Both read comment-stripped source through `MacAgentSource`, whose own doc records the limits of a
/// textual scan and why counts are trusted where mere presence is not.
@Suite
@MainActor
struct EntitlementReleaseSwitchScanTests {
    /// Everything that names the debug-only public-key pointer. The two string literals are what a
    /// `strings` sweep of a release binary would look for; the three identifiers are what a release
    /// build would have to be able to resolve.
    ///
    /// A separate list from `SignInReleaseSwitchScanTests`' by design: that one holds the staging
    /// *base URL* pointer and asserts its file set is exactly one file. Two pointers with one shared
    /// token list would make each scan's file assertion the other's problem.
    static let overrideTokens = [
        "\"SONNY_ENTITLEMENT_PUBLIC_KEYS\"",
        "\"SonnyEntitlementPublicKeys\"",
        "overrideEnvironmentVariable",
        "overrideDefaultsKey",
        "normalizedOverride"
    ]

    @Test
    func everyMentionOfTheEntitlementKeyPointerIsInsideIfDebug() throws {
        // SONNY-106: no environment variable is required for anything in a build a user runs. The
        // compiler is the enforcement — the keys are *declared* inside the conditional, so a
        // release-build caller cannot name them — and this holds the population.
        var offenders: [String] = []
        var mentions = 0

        for url in try MacAgentSource.coreSourceFiles()
        where url.lastPathComponent.hasPrefix("Entitlement")
            || url.lastPathComponent == "EntitlementKeys.swift" {
            let source = try MacAgentSource.read(url)
            let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let guarded = ConditionalRegionScan.debugGuardedLines(of: lines)
            for (index, line) in lines.enumerated() {
                guard Self.overrideTokens.contains(where: line.contains) else { continue }
                mentions += 1
                if !guarded[index] {
                    offenders.append(
                        "\(url.lastPathComponent):\(index + 1) "
                            + line.trimmingCharacters(in: .whitespaces)
                    )
                }
            }
        }

        // A walker that found nothing reads exactly like a tree with nothing to find.
        #expect(mentions >= 5, "the scan saw \(mentions) mentions — too few to be the real declaration")
        #expect(offenders.isEmpty, "outside #if DEBUG:\n\(offenders.joined(separator: "\n"))")
    }

    @Test
    func theShippedKeySetIsEmptyBecauseNoGatewayHasBeenDeployed() {
        // The same fact, and the same shape, as `SonnyBackendHost.productionBaseURL` being nil: no
        // remote deploy has happened, so no signing key exists to hold the public half of. An empty
        // set verifies nothing, which is the fail-closed direction.
        #expect(SonnyEntitlementKeys.shipped.isEmpty)
        #expect(SonnyBackendHost.productionBaseURL == nil)
        // And with no override present, `resolve` answers the shipped set rather than inventing one.
        #expect(SonnyEntitlementKeys.resolve(environment: [:], defaultsValue: { _ in nil }).isEmpty)
    }

    @Test
    func anOverrideIsHonouredOnlyWhenAPairInItParses() {
        let real = String(repeating: "A", count: 43)
        #expect(
            SonnyEntitlementKeys.resolve(
                environment: ["SONNY_ENTITLEMENT_PUBLIC_KEYS": "dev-1:\(real)"],
                defaultsValue: { _ in nil }
            ).keyIdentifiers == ["dev-1"]
        )
        // A `UserDefaults` value works too, and it exists because a Screen Recording grant relaunches
        // the bundle through `open -n`, where an environment variable set for a debug run is gone.
        #expect(
            SonnyEntitlementKeys.resolve(
                environment: [:],
                defaultsValue: { $0 == "SonnyEntitlementPublicKeys" ? "dev-1:\(real)" : nil }
            ).keyIdentifiers == ["dev-1"]
        )
        // A typo falls through to the shipped answer rather than becoming an empty override, so a
        // mistyped `defaults write` reads as "no override" rather than as "no keys".
        for broken in ["", "   ", "dev-1", "dev-1:not*base64", ":\(real)"] {
            #expect(
                SonnyEntitlementKeys.resolve(
                    environment: ["SONNY_ENTITLEMENT_PUBLIC_KEYS": broken],
                    defaultsValue: { _ in nil }
                ).isEmpty,
                "\(broken.debugDescription) was treated as an override"
            )
        }
    }
}

/// The structural half of §5.3.1: **no free path takes the entitlement check as a dependency.**
///
/// `EntitlementFreePathTests` in the core target is the behavioural half — the free capabilities
/// resolve with none of this in existence. This is the half that keeps it true: a later ticket that
/// wired an entitlement check into a local resolver would pass every behavioural test that did not
/// happen to construct one, and fail here.
@Suite
@MainActor
struct EntitlementFreePathScanTests {
    /// The types a file must not name to be a free path.
    static let entitlementTypes = [
        "EntitlementService",
        "EntitlementDecision",
        "EntitlementCapability",
        "EntitlementJudgement",
        "EntitlementKeySet"
    ]

    /// The files that decide what a *free local capability* does, and must therefore never consult
    /// an entitlement.
    ///
    /// Named rather than derived, because "free" is a product fact rather than a property of the
    /// file system — and a derived list would silently shrink to nothing if the derivation broke.
    /// `InstantCommandResolver` is the one the contract names, and the four adapters beside it are
    /// the capabilities the founder's headline manual check exercises.
    static let freePaths = [
        "InstantCommandResolver.swift",
        "RunRoutineCapabilityAdapter.swift",
        "OpenWorkspaceCapabilityAdapter.swift",
        "SnippetExpansionCapabilityAdapter.swift",
        "CalculatorCapabilityAdapter.swift"
    ]

    @Test
    func noFreeLocalPathNamesTheEntitlementCheck() throws {
        var offenders: [String] = []
        var scanned: Set<String> = []

        for url in try MacAgentSource.coreSourceFiles()
        where Self.freePaths.contains(url.lastPathComponent) {
            scanned.insert(url.lastPathComponent)
            let source = try MacAgentSource.read(url)
            for type in Self.entitlementTypes where source.contains(type) {
                offenders.append("\(url.lastPathComponent) names \(type)")
            }
        }

        // The population is real: a scan that matched no file would pass silently, which is exactly
        // what a renamed file would produce.
        #expect(scanned == Set(Self.freePaths), "the scan reached \(scanned.sorted())")
        #expect(
            offenders.isEmpty,
            Comment(rawValue: "a free path consults the entitlement check:\n"
                + offenders.joined(separator: "\n"))
        )
    }

    @Test
    func theScanWouldFlagAFreePathThatAcquiredTheDependency() throws {
        // The rule run over a held sample, so it is shown to flag what it names rather than only to
        // pass against the current tree — the shape `LocalStoreInjectionScanTests` adopted after a
        // mutant survived a guard that had only ever been run against the real thing.
        let planted = """
        import Foundation
        struct Resolver {
            let entitlements: EntitlementService
        }
        """
        #expect(Self.entitlementTypes.contains { planted.contains($0) })

        // And the real resolver, read the way the scan reads it, names none of them.
        let resolver = try MacAgentSource.read(
            MacAgentSource.coreSourceDirectory.appendingPathComponent("InstantCommandResolver.swift")
        )
        #expect(!Self.entitlementTypes.contains { resolver.contains($0) })
        // It really was read: an empty string would satisfy the line above.
        #expect(resolver.contains("InstantCommandResolver"))
    }

    @Test
    func theGatedCapabilitySetIsRowEighteensAndThisRepositoryNamesNoKey() throws {
        // The never-touch list in executable form: this ticket builds the gate and decides nothing
        // about what goes through it. No capability key literal exists under `Sources/` at all —
        // the ones in the suite are in tests, which say so.
        var offenders: [String] = []
        for url in try MacAgentSource.coreSourceFiles() + MacAgentSource.appSourceFiles() {
            let source = try MacAgentSource.read(url)
            guard source.contains("EntitlementCapability(") else { continue }
            // A construction with a literal argument would be this repository naming a key.
            for line in source.split(separator: "\n") where line.contains("EntitlementCapability(\"") {
                offenders.append("\(url.lastPathComponent): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        #expect(
            offenders.isEmpty,
            Comment(rawValue: "a capability key is named in Sources:\n"
                + offenders.joined(separator: "\n"))
        )
    }
}
