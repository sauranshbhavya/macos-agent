import Foundation
import Testing
@testable import MacAgentCore

/// SONNY-441. "What is selected in Finder?" answered a count — "Finder selection contains 1
/// whitelisted item(s)." — and the founders' pass read exactly that back. The sentence names the
/// items now; these hold its shapes, the boundary where it starts counting, the budget that keeps
/// it on the widget's three lines, and that the names are the items the user selected.
@Suite
struct FinderSelectionSummaryTests {
    private static func urls(_ names: [String]) -> [URL] {
        names.map { URL(fileURLWithPath: "/Users/someone/Desktop/\($0)") }
    }

    private static let screenshots = (2...8).map { "Screenshot 2026-09-11 at 09.14.0\($0).png" }

    @Test
    func oneItemIsNamed() {
        #expect(FinderSelectionSummary.sentence(for: Self.urls(["report.pdf"])) == "Selected in Finder: report.pdf.")
    }

    /// More than one item opens with the total, so a panel that clips the end never loses the count.
    @Test
    func aFewItemsAreAllNamedInOrderBehindTheirCount() {
        #expect(
            FinderSelectionSummary.sentence(for: Self.urls(["a.pdf", "b.pdf", "c.pdf"]))
                == "3 selected in Finder: a.pdf, b.pdf, c.pdf."
        )
    }

    /// A name with spaces is a name, not a path: the sentence carries it as Finder shows it.
    @Test
    func aNameWithSpacesIsCarriedWhole() {
        #expect(
            FinderSelectionSummary.sentence(for: Self.urls(["Q3 report final.docx"]))
                == "Selected in Finder: Q3 report final.docx."
        )
    }

    /// Exactly the limit names everything; the first item past it is counted (PR #228's F3 — six
    /// is the boundary, and a mutant naming the sixth passed five and seven); further past it the
    /// count grows, in the executor's own "and N more" shape.
    @Test
    func pastTheLimitTheRestIsCounted() {
        let five = ["1.txt", "2.txt", "3.txt", "4.txt", "5.txt"]
        #expect(
            FinderSelectionSummary.sentence(for: Self.urls(five))
                == "5 selected in Finder: 1.txt, 2.txt, 3.txt, 4.txt, 5.txt."
        )
        #expect(
            FinderSelectionSummary.sentence(for: Self.urls(five + ["6.txt"]))
                == "6 selected in Finder: 1.txt, 2.txt, 3.txt, 4.txt, 5.txt, and 1 more."
        )
        #expect(
            FinderSelectionSummary.sentence(for: Self.urls(five + ["6.txt", "7.txt"]))
                == "7 selected in Finder: 1.txt, 2.txt, 3.txt, 4.txt, 5.txt, and 2 more."
        )
        #expect(FinderSelectionSummary.namedItemLimit == 5)
    }

    /// Long names stop being named where the sentence would pass the budget, and the rest is
    /// counted — seven screenshot names read three names and "and 4 more", exactly at the budget
    /// (a fourth name would take the sentence past it), and an eighth character on each name
    /// leaves room for two.
    @Test
    func longNamesAreCountedOnceTheSentenceWouldPassTheBudget() {
        let sentence = FinderSelectionSummary.sentence(for: Self.urls(Self.screenshots))
        #expect(
            sentence
                == "7 selected in Finder: Screenshot 2026-09-11 at 09.14.02.png, Screenshot 2026-09-11 at 09.14.03.png, Screenshot 2026-09-11 at 09.14.04.png, and 4 more."
        )
        #expect(sentence.count == FinderSelectionSummary.characterBudget)
        let longer = Self.screenshots.map { $0.replacingOccurrences(of: ".png", with: " 2.png") }
        #expect(
            FinderSelectionSummary.sentence(for: Self.urls(longer))
                == "7 selected in Finder: Screenshot 2026-09-11 at 09.14.02 2.png, Screenshot 2026-09-11 at 09.14.03 2.png, and 5 more."
        )
        #expect(FinderSelectionSummary.characterBudget == 150)
    }

    /// The first name is always given: one item with a name longer than the whole budget is still
    /// named rather than counted away, and two such items name the first and count the second.
    @Test
    func theFirstNameIsAlwaysGivenHoweverLong() {
        let long = String(repeating: "x", count: 200) + ".txt"
        #expect(FinderSelectionSummary.sentence(for: Self.urls([long])) == "Selected in Finder: \(long).")
        #expect(
            FinderSelectionSummary.sentence(for: Self.urls([long, "b.txt"]))
                == "2 selected in Finder: \(long), and 1 more."
        )
    }

    /// **The names are the items the user selected, not the paths the whitelist resolved** (PR
    /// #228's F2): a selected symbolic link reads by the link's name while the whitelisted path is
    /// its target, and a name with a trailing space keeps the space the whitelist's check trims.
    /// Real files in a temporary folder that is the whitelist's only root, through the real
    /// resolver.
    @Test
    func theSentenceNamesTheSelectedItemsAndTheWhitelistedPathsAreResolved() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FinderSelectionSummaryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("q3-final-v7.pdf")
        try Data("pdf".utf8).write(to: target)
        let link = root.appendingPathComponent("Latest report.pdf")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let spaced = root.appendingPathComponent("report ")
        try Data("txt".utf8).write(to: spaced)

        let items = try FinderSelectionResolver.whitelistedItems(
            whitelist: PathWhitelist(roots: [root]),
            finderContextReader: StaticFinderContextReader(selection: [link, spaced])
        )

        #expect(items.map(\.name) == ["Latest report.pdf", "report "])
        #expect(items.map(\.whitelisted.lastPathComponent) == ["q3-final-v7.pdf", "report"])
        #expect(
            FinderSelectionSummary.sentence(naming: items.map(\.name))
                == "2 selected in Finder: Latest report.pdf, report ."
        )
        // The path the run acts on is the whitelisted one, unchanged from before: the link's target.
        #expect(items[0].whitelisted.resolvingSymlinksInPath() == target.resolvingSymlinksInPath())
    }

    private struct StaticFinderContextReader: FinderContextReading {
        let selection: [URL]

        func selectedItems() throws -> [URL] {
            selection
        }
    }
}
