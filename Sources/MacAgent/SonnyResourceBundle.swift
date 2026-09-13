import Foundation
import MacAgentCore

/// The app target's resource bundle, found where a real packaged `.app` and a bare `swift run` each
/// put it — and the shipped skill packs read out of it.
///
/// **Deliberately not `Bundle.module`** (SwiftPM's generated accessor). That code resolves the bundle
/// at `Bundle.main.bundleURL`'s top level, which is right for a bare executable and wrong for a
/// signed `.app`: codesign refuses to seal anything at the app's top level outside `Contents/`, so
/// `scripts/package-app.sh` copies the bundle into `Contents/Resources/`, where the generated
/// accessor never looks — and it calls `fatalError` when it cannot find it. So this tries both real
/// locations, packaged first, and a caller that finds neither degrades rather than crashing.
///
/// Lifted out of `AppDelegate` when the skill packs became the bundle's second reader (SONNY-452),
/// so the fonts and the packs cannot come to resolve the bundle two different ways.
enum SonnyResourceBundle {
    static func resolved() -> Bundle? {
        let candidateURLs = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/MacAgent_MacAgent.bundle"),
            Bundle.main.bundleURL.appendingPathComponent("MacAgent_MacAgent.bundle")
        ]
        for url in candidateURLs {
            if let bundle = Bundle(url: url) {
                return bundle
            }
        }
        return nil
    }

    /// Every shipped pack that passes the loader's rules.
    ///
    /// An empty catalogue when the bundle cannot be found: the Skills page then lists nothing and no
    /// command carries a pack, which is the app without skills rather than a crash. A pack the loader
    /// refuses is logged by file name and left out; `SkillPackTests` refuses to let one ship.
    static func skillPackCatalog() -> SkillPackCatalog {
        guard let bundle = resolved(), let resourceURL = bundle.resourceURL else {
            print("Sonny could not locate its resource bundle — no skill packs are available.")
            return .empty
        }
        let catalogue = SkillPackCatalog.load(from: resourceURL)
        for failure in catalogue.failures {
            print("Sonny did not load skill pack \(failure.fileName): \(failure.error)")
        }
        return catalogue
    }
}
