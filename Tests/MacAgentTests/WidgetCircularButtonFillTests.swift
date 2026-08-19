import Foundation
import Testing
@testable import MacAgent

/// SONNY-174. The floating widget's "Don't save this task" button was unreadable in its off state —
/// the founder's words at the packaged app: "it looks very bad, it's too light for anyone to figure
/// it out."
///
/// **These are regression guards, not legibility tests, and nothing here can tell you whether the
/// control reads correctly.** The widget's panel is translucent, so its effective contrast changes
/// with whatever window happens to be behind it, and no automated check can judge that. Only the
/// founder's eye can, and the ticket says so explicitly. What these pin is the specific structural
/// mistake that produced the washed-out state, and the fact that the two states are treated
/// differently at all.
///
/// The mistake: `WidgetTheme.neutralButtonFill` is the **untinted** button variant's own fill —
/// `docs/sonny-design-system-reference.md` §3.1, "Neutral/untinted button variant:
/// `rgba(153,153,153,.17)`, same `#A6A6A6` hairline, lighter shadow". Passing it as a `tint`
/// instead sends it down `WidgetTintedButtonBackground`'s other branch, where a
/// `Color.white.opacity(0.94)` underlay sits beneath the tint and `.plusDarker` composites on top —
/// the recipe that turns a solid accent into a solid button, and that turned a 17%-opacity grey
/// into a near-opaque #E2E2E2 carrying a white glyph at 1.3:1.
@Suite
struct WidgetCircularButtonFillTests {
    /// The class, not the one site: the neutral fill is a fill, so any button that reaches for it
    /// as a tint fails here — not only the button that did.
    @Test
    func theNeutralFillIsNeverPassedAsATint() throws {
        var offenders: [String] = []
        let files = try Self.appSourceFiles()
        // The scan means nothing if it did not really find the module.
        #expect(files.count > 20)

        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for modifier in ["widgetCircularBackground(", "widgetCapsuleBackground("] {
                for arguments in Self.arguments(of: modifier, in: source)
                where arguments.contains("neutralButtonFill") {
                    offenders.append("\(file.lastPathComponent): .\(modifier)\(arguments))")
                }
            }
        }

        #expect(
            offenders.isEmpty,
            """
            `WidgetTheme.neutralButtonFill` is the untinted variant's fill, not a tint. Pass \
            `tint: nil` and let `WidgetTintedButtonBackground`'s `else` branch draw it — passing it \
            as a tint puts it over a `Color.white.opacity(0.94)` underlay and renders it near-white. \
            Offending call sites: \(offenders)
            """
        )
    }

    /// The site, and the only thing a test can honestly say about the on/off distinction the
    /// control's whole meaning rests on: the two states are drawn by two different treatments.
    /// Whether the difference is *obvious* is not something this can measure.
    @Test
    func theDontSaveButtonIsTintedOnlyWhenItIsOn() throws {
        let source = try String(
            contentsOf: Self.appSourceFile(named: "FloatingWidgetView.swift"),
            encoding: .utf8
        )

        #expect(
            source.contains(".widgetCircularBackground(tint: isOn ? WidgetTheme.primaryAction : nil)"),
            """
            The "Don't save this task" button must tint only when on and take the untinted variant \
            when off. If this moved deliberately, the founder re-checks both states by eye — that \
            check is the verification, and this test is only its reminder.
            """
        )
    }

    /// Every `<modifier>...)` argument list in `source`, with nesting handled.
    private static func arguments(of modifier: String, in source: String) -> [String] {
        var found: [String] = []
        var searchStart = source.startIndex

        while let opening = source.range(of: modifier, range: searchStart..<source.endIndex) {
            var depth = 1
            var index = opening.upperBound
            while index < source.endIndex, depth > 0 {
                switch source[index] {
                case "(": depth += 1
                case ")": depth -= 1
                default: break
                }
                if depth > 0 {
                    index = source.index(after: index)
                }
            }
            if depth == 0 {
                found.append(String(source[opening.upperBound..<index]))
            }
            searchStart = opening.upperBound
        }

        return found
    }

    private static func appSourceFiles() throws -> [URL] {
        try FileManager.default
            .contentsOfDirectory(at: appSourceDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
    }

    private static func appSourceFile(named name: String) -> URL {
        appSourceDirectory.appendingPathComponent(name)
    }

    private static var appSourceDirectory: URL {
        // <package root>/Tests/MacAgentTests/<this file>
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/MacAgent")
    }
}
