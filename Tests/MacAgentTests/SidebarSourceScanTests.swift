import Foundation
import Testing
@testable import MacAgent

/// The sidebar's phase 13 rework (founder asks, 2026-09-10): collapsed by default, and its collapse
/// toggle moved to the top — ChatGPT's own placement, which the founders pointed at by name — rather
/// than sitting above the account row at the bottom. This repository has no SwiftUI inspection
/// harness, so both properties are read from the source the way every other structural property in
/// this file is scanned: `MacAgentSource`'s brace-block and region extraction, with both comment
/// syntaxes already stripped (see that type's own doc comment for why a scan any comment could
/// satisfy holds nothing).
@MainActor
@Suite
struct SidebarSourceScanTests {
    /// The seed reads `?? true`, not `?? false`: a Mac that has never touched the toggle now opens
    /// on the rail. `contains` is enough here — there is exactly one seed for this key in the whole
    /// file, and a second one appearing anywhere would itself be the defect a rewiring test should
    /// catch, not a false pass for this string's presence.
    @Test
    func theCollapsedSeedDefaultsToTrue() throws {
        let source = try MacAgentSource.read("CommandCenterView.swift")
        #expect(
            source.contains(
                "UserDefaults.standard.object(forKey: Self.sidebarCollapsedDefaultsKey) as? Bool ?? true"
            )
        )
        // And the old default is gone, not merely joined by the new one.
        #expect(
            !source.contains(
                "UserDefaults.standard.object(forKey: Self.sidebarCollapsedDefaultsKey) as? Bool ?? false"
            )
        )
    }

    /// The sidebar region: `sidebar` itself plus every private member it and its neighbours
    /// (`sidebarWordmark`, `sidebarMark`, `askSonnyButton`, `toggleSidebarCollapsed`,
    /// `sidebarToggleButton`, `profileRow` and the account menu it opens) declare, ending just
    /// before `select(_:)`, which is the first member outside the sidebar's own concerns. One
    /// `sidebar.left` glyph lives in this region — the toggle moved, it did not multiply.
    private func sidebarRegion() throws -> String {
        let source = try MacAgentSource.read("CommandCenterView.swift")
        return try MacAgentSource.region(
            of: source,
            from: "private var sidebar: some View {",
            to: "private func select(_ destination: CommandCenterDestination) {"
        )
    }

    @Test
    func exactlyOneSidebarLeftGlyphLivesInTheSidebarRegion() throws {
        let region = try sidebarRegion()
        #expect(MacAgentSource.count(of: "Image(systemName: \"sidebar.left\")", inText: region) == 1)
    }

    /// The toggle sits inside `sidebarWordmark` now, not above `profileRow`: `sidebar`'s own body
    /// no longer names it directly. `sidebarWordmark` calls it twice — once in the collapsed
    /// branch, once in the expanded one, since only one branch of that `@ViewBuilder` `if`/`else`
    /// ever renders — never zero, and never from `sidebar`'s own body. Brace-blocked directly off
    /// the full source rather than off `sidebarRegion()` — that region is the text *after* the
    /// `sidebar` anchor, so the anchor itself is not inside it to re-find.
    @Test
    func theToggleIsCalledOnlyFromTheWordmarkAndNotFromSidebarsOwnBody() throws {
        let source = try MacAgentSource.read("CommandCenterView.swift")
        let sidebarBody = try MacAgentSource.braceBlock(of: source, openedBy: "private var sidebar: some View {")
        #expect(!sidebarBody.contains("sidebarToggleButton"))

        let wordmark = try MacAgentSource.braceBlock(of: source, openedBy: "private var sidebarWordmark: some View {")
        #expect(MacAgentSource.count(of: "sidebarToggleButton", inText: wordmark) == 2)
    }

    /// The toggle's two labels and two tooltips, by value: "Open sidebar" while collapsed, "Close
    /// sidebar" while expanded, each with its `(⌘⌥S)` tooltip twin. The old "Show"/"Hide" wording is
    /// gone from the whole app target, not merely from this one button.
    @Test
    func theToggleReadsOpenAndCloseByValue() throws {
        let region = try sidebarRegion()
        let toggle = try MacAgentSource.braceBlock(of: region, openedBy: "private var sidebarToggleButton: some View {")
        #expect(toggle.contains(".accessibilityLabel(isSidebarCollapsed ? \"Open sidebar\" : \"Close sidebar\")"))
        #expect(toggle.contains(".help(isSidebarCollapsed ? \"Open sidebar (⌘⌥S)\" : \"Close sidebar (⌘⌥S)\")"))

        for file in try MacAgentSource.appSourceFiles() {
            let text = try MacAgentSource.read(file)
            #expect(!text.contains("Hide sidebar"), "\(MacAgentSource.relativePath(of: file)) still says Hide sidebar")
            #expect(!text.contains("Show sidebar"), "\(MacAgentSource.relativePath(of: file)) still says Show sidebar")
        }
    }

    /// The keyboard-shortcuts sheet's row keeps step with the button it documents.
    @Test
    func theShortcutsSheetNamesTheNewToggleWording() throws {
        let source = try MacAgentSource.read("KeyboardShortcutsView.swift")
        #expect(source.contains("action: \"Open or close the sidebar\""))
        #expect(!source.contains("Hide or show the sidebar"))
    }
}
