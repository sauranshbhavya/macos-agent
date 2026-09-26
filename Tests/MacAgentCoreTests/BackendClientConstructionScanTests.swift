import Foundation
import Testing
@testable import MacAgentCore

/// `Sources/` builds exactly one `SonnyBackendClient`, and the matcher that counts it.
@Suite
struct BackendClientConstructionScanTests {
    /// **`Sources/` builds one `SonnyBackendClient`, and the property is load-bearing rather than
    /// tidy** (SONNY-130; PR #139's F12).
    ///
    /// This client holds the **Keychain session every packaged build on this Mac shares**, so a second
    /// one is a second reader and a second deleter of the founder's own sign-in.
    ///
    /// **And a second client is a live defect even when both are correct.** The client holds the
    /// single-flight generation counter that makes ten concurrent `401 auth.token_expired`s cause
    /// one rotation; the server reads a second rotation presented past its ten-second overlap as
    /// theft and revokes the whole family (contract §3.3). Two clients means two counters, so the
    /// guard would be guarding half the callers — and PR #133 recorded that this goes live "the
    /// moment SONNY-130 and SONNY-131 add a second concurrent authenticated caller", which SONNY-130
    /// is. `main.swift` therefore asks `SonnyAccountModel` for the one client and hands that same
    /// instance to the kernel, and neither has a default for it.
    ///
    /// **The compiler cannot see this one at all**, which is why it is a scan: both undefaulted
    /// parameters are satisfied by *a* client, and nothing in the type system says it must be the
    /// same client. `SignInSurfaceTests.theProductionClientDoesNotRunOnTheSharedSession` counts the
    /// constructions inside one file; this counts them across `Sources/`, which is where a second
    /// one would actually appear.
    @Test
    func theOnlyBackendClientConstructionInSourcesIsTheRealKeychainFactory() throws {
        let sources = Self.repositoryRoot.appendingPathComponent("Sources")
        guard let walker = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil) else {
            Issue.record("could not enumerate Sources/")
            return
        }

        var constructionSites: [String: Int] = [:]
        var declaringFileCode = ""
        var filesRead = 0
        for case let url as URL in walker where url.pathExtension == "swift" {
            filesRead += 1
            let code = TestSourceTree.codeLines(of: try String(contentsOf: url, encoding: .utf8))
                .map(\.text)
                .joined(separator: "\n")
            let count = Self.constructions(of: "SonnyBackendClient", in: code).count
            if count > 0 {
                constructionSites[url.lastPathComponent] = count
            }
            if url.lastPathComponent == "SonnyBackendClient.swift" {
                declaringFileCode = code
            }
        }

        #expect(filesRead > 50, "the enumerator saw \(filesRead) sources — too few to be the real tree")
        let found = constructionSites.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }
        #expect(
            constructionSites == ["SignInView.swift": 1],
            """
            Sources/ constructs a SonnyBackendClient in \(found) — it may do so in exactly one             place, SonnyAccountModel.atItsRealKeychainLocation(). A second one is a second token             cache and a second single-flight refresh guard over the same Keychain account, which             the server reads as a stolen refresh token and answers by revoking the whole family.
            """
        )
        // The same door from inside the type, where the name is optional.
        #expect(!declaringFileCode.isEmpty, "SonnyBackendClient.swift was not read")
        for spelling in ["Self(", ".init("] {
            #expect(
                !declaringFileCode.contains(spelling),
                """
                SonnyBackendClient.swift uses `\(spelling)`, which constructs the type without                 naming it, so the count above cannot see it. If this is legitimate, the count needs                 to learn the spelling rather than this check being dropped.
                """
            )
        }
    }

    /// **The count knows every spelling that names the type, shown on held text** (SONNY-248, T3).
    ///
    /// The matcher used to search for one literal, `Name(`, and `Name.init(…)` is the same
    /// construction written the other ordinary way — so a count keyed on the first spelling passed
    /// over the second.
    ///
    /// **Held samples rather than the tree alone**: a rule run only over a tree that satisfies it
    /// cannot be shown to flag anything. Each positive below is a spelling `swiftc` accepts for a
    /// `final class` with a plain `init`; each negative is a thing that looks like one and
    /// constructs nothing.
    @Test
    func theConstructionCountRecognisesEverySpellingThatNamesTheType() {
        let constructing = [
            "SonnyBackendClient(session: session)",
            "SonnyBackendClient.init(session: session)",
            "SonnyBackendClient (session: session)",
            "SonnyBackendClient\n            .init(session: session)",
            "SonnyBackendClient . init(session: session)",
            "MacAgent.SonnyBackendClient(session: session)",
            "MacAgent.SonnyBackendClient.init(session: session)"
        ]
        // A floor on the table: each loop asserts once per sample and nothing else asserts how many
        // samples there are, so deleting one would otherwise fail nothing.
        #expect(constructing.count == 7, "a spelling was dropped from the positive samples")

        for text in constructing {
            #expect(
                Self.constructions(of: "SonnyBackendClient", in: text) == ["session: session"],
                "spelling not counted as a construction: \(text)"
            )
        }

        let notConstructing = [
            "let client: SonnyBackendClient",
            "@ObservedObject var client: SonnyBackendClient",
            "extension SonnyBackendClient {",
            "SonnyBackendClient.self",
            "SonnyBackendClient.initialize(now)",
            "SonnyBackendClientFactory(session: session)",
            "makeSonnyBackendClient(session: session)",
            "Legacy.SonnyBackendClient(session: session)"
        ]
        #expect(notConstructing.count == 8, "a look-alike was dropped from the negative samples")

        for text in notConstructing {
            #expect(
                Self.constructions(of: "SonnyBackendClient", in: text).isEmpty,
                "counted as a construction: \(text)"
            )
        }
    }

    /// The repository root, from this file's own location. `TestSourceTree.root` is `Tests/`, so
    /// the repository root is its parent.
    static var repositoryRoot: URL {
        TestSourceTree.root.deletingLastPathComponent()
    }

    /// Every argument list of a construction of `name`, depth-matched on parentheses so a nested
    /// construction inside the argument list is not read as the end of the call.
    ///
    /// It counts `Name(…)` and `Name.init(…)`, either with whitespace or a line break where Swift
    /// allows one, and either qualified by the module that declares it. What it cannot see, because
    /// none of them writes the type's name beside its own parenthesis: a construction through a
    /// `typealias`, through a metatype value, or a bare contextual `.init(…)`.
    ///
    /// The character before the name is checked so a longer identifier ending in the name cannot
    /// match. A dotted prefix is a *different* type — `SomeType.Store(` is `SomeType`'s nested
    /// `Store` — unless the prefix is one of this repository's own module names.
    static func constructions(of name: String, in source: String) -> [String] {
        var results: [String] = []
        var searchStart = source.startIndex
        while let found = source.range(of: name, range: searchStart..<source.endIndex) {
            searchStart = found.upperBound
            guard namesThisType(at: found, in: source),
                  let open = openingParenthesis(afterNameEndingAt: found.upperBound, in: source),
                  let closed = closingParenthesis(matching: open, in: source) else {
                continue
            }
            results.append(String(source[source.index(after: open)..<closed]))
            searchStart = closed
        }
        return results
    }

    /// The module names a type of this repository's own can be qualified by, which are the two
    /// SwiftPM targets. Swift has no source-level import aliasing, so this list is the whole set of
    /// prefixes that mean "the same type".
    static let moduleQualifiers: Set<String> = ["MacAgent", "MacAgentCore"]

    /// Whether the occurrence at `range` is the type's own name rather than the tail of a longer
    /// identifier or the last component of some other type's nested name.
    private static func namesThisType(at range: Range<String.Index>, in source: String) -> Bool {
        guard range.lowerBound > source.startIndex else {
            return true
        }
        let previousIndex = source.index(before: range.lowerBound)
        let previous = source[previousIndex]
        if previous.isLetter || previous.isNumber || previous == "_" {
            return false
        }
        guard previous == "." else {
            return true
        }
        return moduleQualifiers.contains(identifier(endingAt: previousIndex, in: source))
    }

    /// The identifier immediately before `index`, or "" if there is none — the qualifier in
    /// `MacAgentCore.RoutineStore(`, and nothing at all in a contextual `.init(`.
    private static func identifier(endingAt index: String.Index, in source: String) -> String {
        var start = index
        while start > source.startIndex {
            let candidate = source.index(before: start)
            let character = source[candidate]
            guard character.isLetter || character.isNumber || character == "_" else {
                break
            }
            start = candidate
        }
        return String(source[start..<index])
    }

    /// The `(` that opens a construction written after the name, across both spellings and any
    /// whitespace Swift permits between the pieces, or `nil` if this occurrence constructs nothing.
    private static func openingParenthesis(
        afterNameEndingAt nameEnd: String.Index,
        in source: String
    ) -> String.Index? {
        var index = skippingWhitespace(from: nameEnd, in: source)
        guard index < source.endIndex else {
            return nil
        }
        if source[index] == "(" {
            return index
        }
        guard source[index] == "." else {
            return nil
        }
        index = skippingWhitespace(from: source.index(after: index), in: source)
        guard source[index...].hasPrefix("init") else {
            return nil
        }
        // `.initialize(` starts with `init` and constructs nothing: what follows has to be the
        // argument list itself, not more of a longer name.
        index = skippingWhitespace(from: source.index(index, offsetBy: 4), in: source)
        guard index < source.endIndex, source[index] == "(" else {
            return nil
        }
        return index
    }

    private static func skippingWhitespace(from index: String.Index, in source: String) -> String.Index {
        var index = index
        while index < source.endIndex, source[index].isWhitespace {
            index = source.index(after: index)
        }
        return index
    }

    /// The `)` matching an opening parenthesis, or `nil` for text that never closes it.
    private static func closingParenthesis(matching open: String.Index, in source: String) -> String.Index? {
        var depth = 0
        var index = open
        while index < source.endIndex {
            if source[index] == "(" {
                depth += 1
            } else if source[index] == ")" {
                depth -= 1
                if depth == 0 {
                    return index
                }
            }
            index = source.index(after: index)
        }
        return nil
    }
}
