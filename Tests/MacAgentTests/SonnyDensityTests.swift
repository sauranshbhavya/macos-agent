import Foundation
import Testing
@testable import MacAgent

/// The information-density preference (founder ask, 2026-09-09): a value type with no view host —
/// the same reason `JumpToPalettePresentation` is tested directly — plus `SonnyDensityModel`'s
/// persistence, on the `UserDefaults(suiteName:)` fixture pattern this target already uses.
@Suite
struct SonnyDensityTests {
    @Test
    func regularEqualsEveryShippedSonnyMetricsValue() {
        // The whole point of `regular`: a user who never touches the slider sees no change from
        // what shipped before this ticket.
        #expect(SonnyDensity.regular.listRowHeight == SonnyMetrics.listRowHeight)
        #expect(SonnyDensity.regular.navRowHeight == SonnyMetrics.navRowHeight)
        #expect(SonnyDensity.regular.compactRowHeight == SonnyMetrics.compactRowHeight)
        #expect(SonnyDensity.regular.toolbarHeight == SonnyMetrics.toolbarHeight)
        // The four values with no metric token of their own, pinned to the literals the tree used
        // before density existed (the card's SonnySpacing.lg inset and 190 floor, the pages'
        // SonnySpacing.lg gap, rows with no gap), so Default cannot drift for a user who never
        // touches the slider (phase 11 review, F1).
        #expect(SonnyDensity.regular.cardInset == 16)
        #expect(SonnyDensity.regular.cardMinHeight == 190)
        #expect(SonnyDensity.regular.sectionGap == 16)
        #expect(SonnyDensity.regular.rowGap == 0)
    }

    @Test
    func everyNamedValueStrictlyIncreasesFromCompactToComfortable() {
        #expect(SonnyDensity.compact.listRowHeight < SonnyDensity.regular.listRowHeight)
        #expect(SonnyDensity.regular.listRowHeight < SonnyDensity.comfortable.listRowHeight)

        #expect(SonnyDensity.compact.navRowHeight < SonnyDensity.regular.navRowHeight)
        #expect(SonnyDensity.regular.navRowHeight < SonnyDensity.comfortable.navRowHeight)

        #expect(SonnyDensity.compact.compactRowHeight < SonnyDensity.regular.compactRowHeight)
        #expect(SonnyDensity.regular.compactRowHeight < SonnyDensity.comfortable.compactRowHeight)

        #expect(SonnyDensity.compact.toolbarHeight < SonnyDensity.regular.toolbarHeight)
        #expect(SonnyDensity.regular.toolbarHeight < SonnyDensity.comfortable.toolbarHeight)

        #expect(SonnyDensity.compact.cardInset < SonnyDensity.regular.cardInset)
        #expect(SonnyDensity.regular.cardInset < SonnyDensity.comfortable.cardInset)

        #expect(SonnyDensity.compact.rowGap <= SonnyDensity.regular.rowGap)
        #expect(SonnyDensity.regular.rowGap < SonnyDensity.comfortable.rowGap)

        #expect(SonnyDensity.compact.sectionGap < SonnyDensity.regular.sectionGap)
        #expect(SonnyDensity.regular.sectionGap < SonnyDensity.comfortable.sectionGap)

        #expect(SonnyDensity.compact.cardMinHeight < SonnyDensity.regular.cardMinHeight)
        #expect(SonnyDensity.regular.cardMinHeight < SonnyDensity.comfortable.cardMinHeight)
    }

    @Test
    func scaledRoundsAndStaysOrderedAroundTheBaseValue() {
        #expect(SonnyDensity.regular.scaled(56) == 56)
        #expect(SonnyDensity.compact.scaled(56) < 56)
        #expect(SonnyDensity.comfortable.scaled(56) > 56)
        // 44 * 0.85 = 37.4, which must round rather than truncate.
        #expect(SonnyDensity.compact.scaled(44) == 37)
        // 47.6: rounding answers 48 where truncation would answer 47, so a `.rounded(.down)`
        // mutant dies here rather than surviving on fractions under a half (phase 11 review, F2).
        #expect(SonnyDensity.compact.scaled(56) == 48)
        // 52 * 1.2 = 62.4, rounds down; 32 * 1.2 = 38.4, rounds down too — picking one base whose
        // scaled comfortable value would round *up* under naive truncation is the point here.
        #expect(SonnyDensity.comfortable.scaled(32) == 38)
    }

    @Test
    func theSliderRoundTripsEveryStop() {
        for density in SonnyDensity.allCases {
            #expect(SonnyDensity(sliderValue: density.sliderValue) == density)
        }
        // A continuous drag never lands exactly on 0/1/2; the nearest stop wins.
        #expect(SonnyDensity(sliderValue: 0.4) == .compact)
        #expect(SonnyDensity(sliderValue: 0.6) == .regular)
        #expect(SonnyDensity(sliderValue: 1.4) == .regular)
        #expect(SonnyDensity(sliderValue: 1.6) == .comfortable)
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
}
