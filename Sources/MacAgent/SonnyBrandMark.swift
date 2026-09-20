import AppKit
import SwiftUI

enum SonnyBrandAssets {
    static let mark = SonnyResourceBundle.resolved().flatMap { mark(in: $0) }
    static let appIcon = SonnyResourceBundle.resolved().flatMap { appIcon(in: $0) }

    static func mark(in bundle: Bundle) -> NSImage? {
        image(named: "SonnyMark", fileExtension: "svg", isTemplate: true, in: bundle)
    }

    static func appIcon(in bundle: Bundle) -> NSImage? {
        image(named: "SonnyAppIcon", fileExtension: "png", isTemplate: false, in: bundle)
    }

    private static func image(
        named name: String,
        fileExtension: String,
        isTemplate: Bool,
        in bundle: Bundle
    ) -> NSImage? {
        guard
            let url = bundle.url(forResource: name, withExtension: fileExtension),
            let image = NSImage(contentsOf: url)
        else {
            return nil
        }
        image.isTemplate = isTemplate
        return image
    }
}

struct SonnyBrandMark: View {
    let size: CGFloat

    var body: some View {
        Group {
            if let image = SonnyBrandAssets.mark {
                Image(nsImage: image)
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
            } else {
                Image(systemName: "wand.and.stars.inverse")
                    .resizable()
                    .scaledToFit()
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
