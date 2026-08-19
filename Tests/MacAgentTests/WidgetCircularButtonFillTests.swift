import AppKit
import Foundation
import SwiftUI
import Testing
@testable import MacAgent

/// SONNY-174. The floating widget's "Don't save this task" button was unreadable in its off state —
/// the founder's words at the packaged app: "it looks very bad, it's too light for anyone to figure
/// it out."
///
/// **The property these guard is opacity, and it is here because the first fix got it backwards.**
/// The composer row is `HStack { composerPill; dontSaveButton; micButton }` and only `composerPill`
/// carries `.widgetGlassPill()`; the enclosing stack has no background and the widget's panel is
/// fully transparent. So both circular buttons composite onto whatever window is behind the widget,
/// never onto the widget's dark glass — unlike every untinted-variant button in the app, all of
/// which live inside a `Widget*Panel`. **A fill with opacity below 1 out here takes its contrast
/// from the user's desktop.** The original bug was a 95%-opaque near-white disc; the first fix
/// (`tint: nil`) dropped it to 17% opaque, which reads darker only when something dark happens to
/// be behind the widget and is bit-for-bit the same colour over a white window. (PR #73 review, F1.)
///
/// **These are still regression guards, and they still cannot tell you whether the control reads
/// correctly.** What they can now say is stronger than before: the fills do not depend on the
/// backdrop at all, which is a real property of the tokens and is checkable. Whether an opaque tint
/// renders as itself is a property of `WidgetTintedButtonBackground`'s blend, argued in
/// `dontSaveButton`'s doc comment and not tested here. Only the founder's eye closes this ticket.
@Suite
struct WidgetCircularButtonFillTests {
    /// The invariant F1 exposed: nothing in the composer row may take its contrast from the user's
    /// desktop. Stated over the tokens themselves, so it holds for whatever the row grows next.
    @Test
    func everyFillTheComposerRowCanRenderIsFullyOpaque() throws {
        let rowFills: [(String, Color)] = [
            ("the mic", WidgetTheme.secondaryCircular),
            ("\"Don't save this task\", on", WidgetTheme.primaryAction),
            ("\"Don't save this task\", off", WidgetTheme.panelBase)
        ]

        for (name, fill) in rowFills {
            let resolved = try #require(NSColor(fill).usingColorSpace(.sRGB))
            #expect(
                resolved.alphaComponent == 1.0,
                """
                \(name) renders outside every glass surface in the app, so a fill below alpha 1 \
                composites onto the user's desktop and its contrast becomes whatever that desktop \
                happens to be. Measured alpha: \(resolved.alphaComponent).
                """
            )
        }
    }

    /// The counterpart, and the reason the neutral fill cannot serve out here: it is translucent by
    /// design, which is correct for a button drawn on a panel and disqualifying for one that is not.
    @Test
    func theNeutralButtonFillIsTranslucentAndSoBelongsOnlyOnAPanel() throws {
        let resolved = try #require(NSColor(WidgetTheme.neutralButtonFill).usingColorSpace(.sRGB))
        #expect(
            resolved.alphaComponent < 1.0,
            """
            `neutralButtonFill` is §3.1's `rgba(153,153,153,.17)`. If it is ever made opaque, the \
            reasoning in `dontSaveButton` and in this suite needs rereading rather than \
            reinterpreting — measured alpha: \(resolved.alphaComponent).
            """
        )
    }

    /// The class rule, module-wide: the neutral fill is a *fill*, so any button that reaches for it
    /// as a tint fails here — not only the button that did. A tint takes
    /// `WidgetTintedButtonBackground`'s white-underlay branch, which turns a 17%-opacity grey into
    /// a near-opaque pale disc; that was the original defect and it is not specific to one control.
    @Test
    func theNeutralFillIsNeverPassedAsATint() throws {
        var offenders: [String] = []
        let files = try Self.appSourceFiles()
        // The scan means nothing if it did not really find the module.
        #expect(files.count > 20)

        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for modifier in Self.backgroundModifiers {
                for arguments in Self.arguments(of: modifier, in: source)
                where arguments.contains("neutralButtonFill") {
                    offenders.append("\(file.lastPathComponent): .\(modifier)\(arguments))")
                }
            }
        }

        #expect(
            offenders.isEmpty,
            """
            `WidgetTheme.neutralButtonFill` is the untinted variant's fill, not a tint. Passing it \
            as a tint puts it over a `Color.white.opacity(0.94)` underlay and renders it near-white. \
            Offending call sites: \(offenders)
            """
        )
    }

    /// The site rule, and the half no token test reaches: `FloatingWidgetView`'s **own body** — the
    /// widget chrome, as opposed to the `Widget*Panel` structs below it, which do sit on glass —
    /// must never use the untinted variant or a translucent tint.
    ///
    /// This is the guard that would have caught the first fix. `tint: nil` reads as a deliberate
    /// choice at the call site and is one out here; the boundary is what makes it wrong.
    @Test
    func theWidgetsOwnChromeNeverUsesTheOnGlassButtonTreatment() throws {
        let source = try String(
            contentsOf: Self.appSourceFile(named: "FloatingWidgetView.swift"),
            encoding: .utf8
        )
        // `FloatingWidgetView`'s own body runs to the first `Widget*Panel` type; everything from
        // there down renders inside `styledPanel`, which carries `.widgetGlassPanel()`.
        let panelBoundary = try #require(source.range(of: "\nprivate struct Widget"))
        let chrome = String(source[source.startIndex..<panelBoundary.lowerBound])
        #expect(chrome.contains("private var dontSaveButton"), "the boundary missed the chrome")
        #expect(chrome.contains("private var micButton"), "the boundary missed the chrome")

        var offenders: [String] = []
        for modifier in Self.backgroundModifiers {
            for arguments in Self.arguments(of: modifier, in: chrome) {
                let trimmed = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty || trimmed.contains("nil") || trimmed.contains("neutralButtonFill") {
                    offenders.append(".\(modifier)\(trimmed))")
                }
            }
        }

        #expect(
            offenders.isEmpty,
            """
            These controls composite onto the user's desktop, not onto the widget's glass, so an \
            untinted or translucent fill hands their contrast to whatever window is behind the \
            widget. Pass an opaque tint. Offending call sites: \(offenders)
            """
        )
    }

    /// The two tokens this control actually uses, which is all a test can honestly say about the
    /// on/off distinction the control's whole meaning rests on: two different opaque fills. Whether
    /// the difference is *obvious* is not something this can measure.
    @Test
    func theDontSaveButtonUsesTheTwoOpaqueFillsThisTicketChose() throws {
        let source = try String(
            contentsOf: Self.appSourceFile(named: "FloatingWidgetView.swift"),
            encoding: .utf8
        )

        #expect(
            source.contains(
                ".widgetCircularBackground(tint: isOn ? WidgetTheme.primaryAction : WidgetTheme.panelBase)"
            ),
            """
            The "Don't save this task" button takes `primaryAction` when on and `panelBase` when \
            off — both opaque, so neither depends on the backdrop. If the treatment moved \
            deliberately, the founder re-checks both states by eye over a light window and a dark \
            one; that check is the verification and this test is only its reminder.
            """
        )

        let on = try #require(NSColor(WidgetTheme.primaryAction).usingColorSpace(.sRGB))
        let off = try #require(NSColor(WidgetTheme.panelBase).usingColorSpace(.sRGB))
        #expect(on != off, "on and off must not resolve to the same fill")
    }

    private static let backgroundModifiers = ["widgetCircularBackground(", "widgetCapsuleBackground("]

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
