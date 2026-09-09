import Foundation
import Testing
@testable import MacAgent

/// The information-density preference (founder ask, 2026-09-09): a value type with no view host —
/// the same reason `JumpToPalettePresentation` is tested directly — plus `SonnyDensityModel`'s
/// persistence, on the `UserDefaults(suiteName:)` fixture pattern this target already uses.
///
/// Shipped with three stops in phase 11 (Compact, Default, Comfortable); the founders removed
/// Compact the same round ("remove the compact feature because nobody will choose [it] as it
/// makes the entire app cluttered"), so this suite now covers two. Renamed rather than deleted:
/// `everyNamedValueStrictlyIncreasesFromCompactToComfortable` is
/// `everyNamedValueStrictlyIncreasesFromRegularToComfortable` below, over the two cases that
/// remain.
@Suite
struct SonnyDensityTests {
    @Test
    func twoCasesInThatOrder() {
        #expect(SonnyDensity.allCases == [.regular, .comfortable])
    }

    @Test
    func regularEqualsEveryShippedSonnyMetricsValue() {
        // The whole point of `regular`: a user who never touches the control sees no change from
        // what shipped before this ticket.
        #expect(SonnyDensity.regular.listRowHeight == SonnyMetrics.listRowHeight)
        #expect(SonnyDensity.regular.navRowHeight == SonnyMetrics.navRowHeight)
        #expect(SonnyDensity.regular.compactRowHeight == SonnyMetrics.compactRowHeight)
        #expect(SonnyDensity.regular.toolbarHeight == SonnyMetrics.toolbarHeight)
        // The four values with no metric token of their own, pinned to the literals the tree used
        // before density existed (the card's SonnySpacing.lg inset and 190 floor, the pages'
        // SonnySpacing.lg gap, rows with no gap), so Default cannot drift for a user who never
        // touches the control (phase 11 review, F1).
        #expect(SonnyDensity.regular.cardInset == 16)
        #expect(SonnyDensity.regular.cardMinHeight == 190)
        #expect(SonnyDensity.regular.sectionGap == 16)
        #expect(SonnyDensity.regular.rowGap == 0)
    }

    @Test
    func everyNamedValueStrictlyIncreasesFromRegularToComfortable() {
        #expect(SonnyDensity.regular.listRowHeight < SonnyDensity.comfortable.listRowHeight)
        #expect(SonnyDensity.regular.navRowHeight < SonnyDensity.comfortable.navRowHeight)
        #expect(SonnyDensity.regular.compactRowHeight < SonnyDensity.comfortable.compactRowHeight)
        #expect(SonnyDensity.regular.toolbarHeight < SonnyDensity.comfortable.toolbarHeight)
        #expect(SonnyDensity.regular.cardInset < SonnyDensity.comfortable.cardInset)
        #expect(SonnyDensity.regular.rowGap < SonnyDensity.comfortable.rowGap)
        #expect(SonnyDensity.regular.sectionGap < SonnyDensity.comfortable.sectionGap)
        #expect(SonnyDensity.regular.cardMinHeight < SonnyDensity.comfortable.cardMinHeight)
    }

    @Test
    func scaledRoundsAndStaysOrderedAroundTheBaseValue() {
        #expect(SonnyDensity.regular.scaled(56) == 56)
        #expect(SonnyDensity.comfortable.scaled(56) > 56)
        // 52 * 1.2 = 62.4, rounds down; 32 * 1.2 = 38.4, rounds down too — picking one base whose
        // scaled comfortable value would round *up* under naive truncation is the point here.
        #expect(SonnyDensity.comfortable.scaled(32) == 38)
        // 52.8: rounding answers 53 where truncation would answer 52, so a `.rounded(.down)` mutant
        // dies here now that the compact case that used to hold this is gone.
        #expect(SonnyDensity.comfortable.scaled(44) == 53)
    }

    @Test
    func theSliderRoundTripsEveryStop() {
        for density in SonnyDensity.allCases {
            #expect(SonnyDensity(sliderValue: density.sliderValue) == density)
        }
        // A continuous drag never lands exactly on 0/1; the nearest stop wins.
        #expect(SonnyDensity(sliderValue: 0.4) == .regular)
        #expect(SonnyDensity(sliderValue: 0.6) == .comfortable)
    }

    @Test
    @MainActor
    func theModelPersistsAndDefaultsToRegular() throws {
        let suiteName = "SonnyDensityTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let first = SonnyDensityModel(userDefaults: userDefaults)
        #expect(first.density == .regular)

        first.density = .comfortable
        let second = SonnyDensityModel(userDefaults: userDefaults)
        #expect(second.density == .comfortable)
    }

    @Test
    @MainActor
    func anUnknownStoredStringReadsAsRegular() throws {
        let suiteName = "SonnyDensityTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        userDefaults.set("spacious", forKey: SonnyDensityModel.userDefaultsKey)
        let model = SonnyDensityModel(userDefaults: userDefaults)
        #expect(model.density == .regular)
    }

    @Test
    @MainActor
    func aStoredCompactChoiceFromBeforeItWasRetiredReadsAsRegular() throws {
        // Phase 11 shipped a third stop, Compact, whose raw value was "compact"; the founders
        // retired it in phase 12. A user who had chosen it before the update lands on Default
        // through the same unknown-value fallback `anUnknownStoredStringReadsAsRegular` covers —
        // this test pins that the retired case's own raw string is one of the strings that
        // fallback has to carry, not just an arbitrary unknown one.
        let suiteName = "SonnyDensityTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        userDefaults.set("compact", forKey: SonnyDensityModel.userDefaultsKey)
        let model = SonnyDensityModel(userDefaults: userDefaults)
        #expect(model.density == .regular)
    }
}
