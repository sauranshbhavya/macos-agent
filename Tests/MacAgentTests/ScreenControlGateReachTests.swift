import Foundation
import Testing
@testable import MacAgent
@testable import MacAgentCore

/// **"Exactly one gate, and no free capability blocks"** — SONNY-213's acceptance criterion as a
/// population scan rather than as a claim a reviewer has to re-derive.
///
/// The behavioural halves live elsewhere: `ScreenControlGateTests` drives the gate's own rules and
/// runs three free capabilities with no billing wiring in reach, and `VisionSessionRunTests` drives
/// the door and the mid-run halt through the real loop. What only a scan can hold is the *negative*
/// — that nothing else in either target can consult a gate at all — because a capability that has
/// not acquired the dependency looks exactly like one that has and happens not to have been driven
/// by a test.
///
/// Both scans read comment-stripped source through `MacAgentSource`, whose own doc records why a
/// count is trusted where mere presence is not, and both carry a control that fires.
@Suite
@MainActor
struct ScreenControlGateReachTests {
    /// Every name by which the gate, its verdicts or its allowance reader could be reached.
    ///
    /// **Deliberately not `ScreenControlPolicy`, `ScreenControlRefusal` or `ScreenControlVerdict`**:
    /// those are the terminal ban, a different rule that many files legitimately consult, and
    /// folding them in would make this scan fail for reasons that have nothing to do with billing.
    static let gateTokens = [
        "ScreenControlGating",
        "ScreenControlGateDecision",
        "ScreenControlGateRefusal",
        "ScreenControlGateMoment",
        "SonnyScreenControlGate",
        "ClosedScreenControlGate",
        "screenControlGate",
        "ScreenControlAllowance",
        "ScreenControlEntitlementConfirming"
    ]

    /// The files in `Sources/` allowed to name any of the above, and **why each one is on the list**.
    /// Exact equality below, so this fails in both directions: a tenth file acquiring the dependency
    /// fails it, and so does one of these losing it under a rename.
    static let permittedFiles: Set<String> = [
        // The gate itself, and the allowance figure it reads.
        "ScreenControlGate.swift",
        "ScreenControlAllowance.swift",
        // The vision path: the aggregate that carries the gate, the door, the loop's halt, and the
        // refusal the halt ends with.
        "VisionSessionEnvironment.swift",
        "VisionSessionCapabilityAdapter.swift",
        "VisionSessionRunner.swift",
        "VisionSessionContainment.swift",
        // The app's wiring: the property, the factory parameter, and the one line that installs the
        // live gate.
        "AgentViewModel.swift",
        "AgentViewModel+VisionSession.swift",
        "main.swift"
    ]

    @Test
    func onlyTheVisionPathAndItsWiringCanNameTheGate() throws {
        var naming: Set<String> = []
        var scanned = 0

        for url in try MacAgentSource.coreSourceFiles() + MacAgentSource.appSourceFiles() {
            scanned += 1
            let source = try MacAgentSource.read(url)
            if Self.gateTokens.contains(where: source.contains) {
                naming.insert(url.lastPathComponent)
            }
        }

        // A walker that reached nothing reads exactly like a tree with nothing to find, and this
        // repository has had a scan pass by matching no file at all.
        #expect(scanned > 150, "the scan read \(scanned) files — too few to be both source trees")
        #expect(
            naming == Self.permittedFiles,
            Comment(rawValue: """
            The set of files naming the screen-control gate is not the permitted set.
            Unexpected: \(naming.subtracting(Self.permittedFiles).sorted())
            Missing:    \(Self.permittedFiles.subtracting(naming).sorted())
            """)
        )
    }

    /// **No capability adapter but the vision one names the gate**, stated over the adapters as a
    /// population of their own.
    ///
    /// The scan above already implies this, and it is asserted separately because the two fail for
    /// different reasons and a reader chasing "did a free capability start blocking?" should meet a
    /// test that asks exactly that. It also carries its own floor: the adapters are the population
    /// §16.3's guarantee is about.
    @Test
    func noCapabilityAdapterButTheVisionOneNamesTheGate() throws {
        var adapters: [String] = []
        var offenders: [String] = []

        for url in try MacAgentSource.coreSourceFiles()
        where url.lastPathComponent.hasSuffix("CapabilityAdapter.swift") {
            adapters.append(url.lastPathComponent)
            guard url.lastPathComponent != "VisionSessionCapabilityAdapter.swift" else { continue }
            let source = try MacAgentSource.read(url)
            for token in Self.gateTokens where source.contains(token) {
                offenders.append("\(url.lastPathComponent) names \(token)")
            }
        }

        // The floor is a real count of a real population: `DefaultCapabilityAdapters.all()` is what
        // the executor dispatches through, and every one of its members is one of these files.
        #expect(
            adapters.count >= DefaultCapabilityAdapters.all().count,
            "the scan saw \(adapters.count) adapter files against \(DefaultCapabilityAdapters.all().count) registered adapters"
        )
        #expect(adapters.contains("VisionSessionCapabilityAdapter.swift"))
        #expect(
            offenders.isEmpty,
            Comment(rawValue: "a capability adapter consults the billing gate:\n"
                + offenders.joined(separator: "\n"))
        )
    }

    /// **There are exactly two consult sites, and they are the two the ticket names.**
    ///
    /// This is the "exactly one gate" criterion at its sharpest: one gate consulted at two moments
    /// is the design, and a third consult would be a second gate however it was named. A count
    /// rather than a presence check, for `MacAgentSource`'s own recorded reason — a trailing comment
    /// can add a token but cannot remove one, so counts survive what presence does not.
    @Test
    func theGateIsConsultedAtExactlyTwoSitesAndTheyAreTheDoorAndTheBoundary() throws {
        var consultsByFile: [String: Int] = [:]

        for url in try MacAgentSource.coreSourceFiles() + MacAgentSource.appSourceFiles() {
            let source = try MacAgentSource.read(url)
            let count = source.components(separatedBy: "screenControlGate.decide(").count - 1
            if count > 0 {
                consultsByFile[url.lastPathComponent] = count
            }
        }

        #expect(
            consultsByFile == [
                "VisionSessionCapabilityAdapter.swift": 1,
                "VisionSessionRunner.swift": 1
            ],
            "consult sites: \(consultsByFile)"
        )

        // Each site asks about its own moment, and the two are different. A door that asked
        // `.stepBoundary` would silently inherit the boundary's read-failure tolerance and stop
        // failing closed — the exact inversion this ticket is about, invisible to every assertion
        // above.
        let door = try MacAgentSource.read(
            MacAgentSource.coreSourceDirectory.appendingPathComponent("VisionSessionCapabilityAdapter.swift")
        )
        let loop = try MacAgentSource.read(
            MacAgentSource.coreSourceDirectory.appendingPathComponent("VisionSessionRunner.swift")
        )
        #expect(door.contains("screenControlGate.decide(at: .sessionStart)"))
        #expect(!door.contains("screenControlGate.decide(at: .stepBoundary)"))
        #expect(loop.contains("screenControlGate.decide(at: .stepBoundary)"))
        #expect(!loop.contains("screenControlGate.decide(at: .sessionStart)"))
    }

    /// The rule run over a held sample, so it is shown to flag what it names rather than only to
    /// pass against the current tree — the shape `LocalStoreInjectionScanTests` adopted after a
    /// mutant survived a guard that had only ever been run against the real thing.
    @Test
    func theScanWouldFlagAnAdapterThatAcquiredTheGate() throws {
        let planted = """
        import Foundation
        struct OpenAppCapabilityAdapter {
            let gate: any ScreenControlGating
        }
        """
        #expect(Self.gateTokens.contains { planted.contains($0) })

        // And a real free adapter, read the way the scan reads it, names none of them — with a
        // control that the file was actually read, because an empty string satisfies the line above.
        let free = try MacAgentSource.read(
            MacAgentSource.coreSourceDirectory.appendingPathComponent("RunRoutineCapabilityAdapter.swift")
        )
        #expect(!Self.gateTokens.contains { free.contains($0) })
        #expect(free.contains("RunRoutineCapabilityAdapter"))
    }
}
