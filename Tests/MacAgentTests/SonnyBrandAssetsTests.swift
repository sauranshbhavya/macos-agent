import Foundation
import Testing
@testable import MacAgent

@MainActor
struct SonnyBrandAssetsTests {
    @Test
    func bundledBrandArtworkLoadsForTheWidgetAndDock() throws {
        let mark = try #require(SonnyBrandAssets.mark(in: Bundle.module))
        let appIcon = try #require(SonnyBrandAssets.appIcon(in: Bundle.module))

        #expect(mark.isTemplate)
        #expect(mark.size.width > 0)
        #expect(mark.size.height > 0)
        #expect(!appIcon.isTemplate)
        #expect(appIcon.size.width == appIcon.size.height)
    }
}
