import Foundation
import Testing
@testable import MacAgentCore

/// SONNY-441. "What is selected in Finder?" answered a count — "Finder selection contains 1
/// whitelisted item(s)." — and the founders' pass read exactly that back. The sentence names the
/// items now; these hold its three shapes and the boundary where it starts counting.
@Suite
struct FinderSelectionSummaryTests {
    private static func urls(_ names: [String]) -> [URL] {
        names.map { URL(fileURLWithPath: "/Users/someone/Desktop/\($0)") }
    }

    @Test
    func oneItemIsNamed() {
        #expect(FinderSelectionSummary.sentence(for: Self.urls(["report.pdf"])) == "Selected in Finder: report.pdf.")
    }

    @Test
    func aFewItemsAreAllNamedInOrder() {
        #expect(
            FinderSelectionSummary.sentence(for: Self.urls(["a.pdf", "b.pdf", "c.pdf"]))
                == "Selected in Finder: a.pdf, b.pdf, c.pdf."
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

    /// Exactly the limit names everything; one past it counts the rest, in the executor's own
    /// "and N more" shape, so a fifty-file selection is one line rather than a page.
    @Test
    func pastTheLimitTheRestIsCounted() {
        let five = ["1.txt", "2.txt", "3.txt", "4.txt", "5.txt"]
        #expect(
            FinderSelectionSummary.sentence(for: Self.urls(five))
                == "Selected in Finder: 1.txt, 2.txt, 3.txt, 4.txt, 5.txt."
        )
        #expect(
            FinderSelectionSummary.sentence(for: Self.urls(five + ["6.txt", "7.txt"]))
                == "Selected in Finder: 1.txt, 2.txt, 3.txt, 4.txt, 5.txt, and 2 more."
        )
        #expect(FinderSelectionSummary.namedItemLimit == 5)
    }
}
