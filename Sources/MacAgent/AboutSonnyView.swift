import SwiftUI

/// The app's identity, opened from the account menu. No title row — the centered content is the
/// title — and no links or sentences: the founders' rule against explanatory copy leaves this
/// screen with nothing to say beyond what it is and which build it is.
struct AboutSonnySheet: View {
    @Binding var isPresented: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: SonnySpacing.md) {
                Spacer()

                ZStack {
                    RoundedRectangle(cornerRadius: SonnyRadius.card)
                        .fill(SonnyTheme.accentSubtle)
                    Image(systemName: "wand.and.stars")
                        .font(SonnyType.icon(SonnyMetrics.iconEmptyState, weight: .semibold))
                        .foregroundStyle(SonnyTheme.accent)
                }
                .frame(width: 64, height: 64)

                VStack(spacing: SonnySpacing.xs) {
                    Text("Sonny")
                        .font(SonnyType.settingsContentTitle)
                        .foregroundStyle(SonnyTheme.text)

                    Text(versionLine)
                        .font(SonnyType.caption)
                        .foregroundStyle(SonnyTheme.muted)
                }

                Text("© 2026 Sonny")
                    .font(SonnyType.micro)
                    .foregroundStyle(SonnyTheme.textTertiary)

                Spacer()
            }
            .frame(maxWidth: .infinity)

            SonnyDialogCloseButton(accessibilityLabel: "Close About Sonny") {
                isPresented = false
            }
            .padding(.top, SonnySpacing.md)
            .padding(.trailing, SonnySpacing.md)
        }
        .sonnyDialogFrame(.compact)
    }

    /// "Version X (Y)" from the bundle's own short version and build number, or "development
    /// build" when either is missing — a bare `swift run` has neither.
    private var versionLine: String {
        let info = Bundle.main.infoDictionary
        guard
            let shortVersion = info?["CFBundleShortVersionString"] as? String,
            let build = info?["CFBundleVersion"] as? String
        else {
            return "development build"
        }
        return "Version \(shortVersion) (\(build))"
    }
}
