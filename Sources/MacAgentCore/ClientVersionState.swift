import Foundation

/// What the gateway has said about the build the user is running — contract §8.
///
/// **Three states, because §8 describes exactly three and the middle one is the whole point of the
/// section.** `minimum_supported_client` is a wall and `recommended_client` is a warning, and §8.4's
/// own sentence for why both exist is that the warning "exists so nobody ever hits the wall by
/// surprise". A client that only modelled the wall would be a client that never warned.
///
/// **The link is a `URL` rather than the string the wire carries, and it is already validated.**
/// `upgrade_url` and `Sonny-Deprecation-Info` are server-supplied strings that end at
/// `NSWorkspace.open`, so the check belongs where the value enters rather than at the press —
/// ``ClientUpgradeLink/openable(_:)`` is the one place it happens, and a link this type carries has
/// been through it. `nil` therefore means "no link, or one the app will not open", which the founder's
/// decision of 2026-09-04 makes one case: the message shows and the button does not.
public enum ClientVersionState: Equatable, Sendable {
    /// This deployment serves this build and has asked for nothing.
    case current
    /// §8.4: served normally, and below `recommended_client`. Everything still works.
    case updateAvailable(link: URL?)
    /// §8.3: `410 version.unsupported`. Nothing that needs the gateway can succeed.
    case tooOld(link: URL?)

    /// The link the Update control opens, when there is one this app will open.
    public var link: URL? {
        switch self {
        case .current: return nil
        case .updateAvailable(let link), .tooOld(let link): return link
        }
    }

    /// Whether this state has anything to say to the user at all.
    public var isSomethingToSay: Bool {
        if case .current = self { return false }
        return true
    }
}

/// The one place a server-supplied upgrade link is turned into something this app will open.
///
/// **The rule is the founder's, taken on 2026-09-04 and recorded on SONNY-402: http or https, or no
/// button.** Opening it is `NSWorkspace.open` on a string this Mac did not author, and while the
/// gateway already refuses to start with an `UPGRADE_URL` that is not one of those two schemes
/// (`server/src/config.ts`'s `checkedUpgradeUrl`), that restriction protects the operator's
/// deployment and not this Mac against a different one. So the app checks again, here.
///
/// **Deliberately not `SafeURL.validateWebURL`, which is stricter in a way that is wrong for this
/// value.** That function also refuses loopback, RFC1918 and `.local` hosts, because its subject is a
/// URL *the planner or a web page* supplied and its job is to stop Sonny's own fetches reaching
/// services on this machine. This URL is going to the user's browser at the user's press, and the
/// deployment a founder points a manual test at is a locally configured gateway whose `UPGRADE_URL`
/// is very often exactly such a host — so reusing that function would refuse the link in the one
/// situation this state is tested in. Two different questions, two different rules.
///
/// **A host is required, and that is inside "parses as http or https" rather than an addition to
/// it.** `URL(string: "https://")` has the scheme and no host; handing it to `NSWorkspace.open`
/// opens nothing, so the button would be a control that does nothing rather than a link.
public enum ClientUpgradeLink {
    public static func openable(_ raw: String?) -> URL? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host,
              !host.isEmpty else {
            return nil
        }
        return url
    }
}

/// The `GET /v1/meta` document of contract §8.3, as this client keeps it.
///
/// **Kept rather than consulted per request, which is §8.3's own instruction** — "The client calls
/// `GET /v1/meta` on launch and on any `410`. It does not call it per request." What the kept copy is
/// *for* here is the upgrade link: a deprecation header or a `410` body normally carries one, and
/// this is what answers when neither does.
///
/// **The version bounds are decoded and are deliberately not compared here.** Which band this build
/// is in is the gateway's answer — a `410`, or §8.4's two headers — and re-deriving it on this side
/// would be a second implementation of §8's arithmetic, in a second language, that can disagree with
/// the one that actually decides. `server/src/version/policy.ts` carries that arithmetic and the
/// reasons it is subtle (build metadata dropped, one to three components, prerelease suffixes).
///
/// `entitlement_keys` is not decoded here. §5.3's key set is `EntitlementKeys`' subject and giving it
/// a second reader would be two answers to which key verifies a claim.
public struct SonnyMetaDocument: Equatable, Sendable {
    public let apiVersion: String
    public let minimumSupportedClient: String
    public let recommendedClient: String
    /// The wire string, unvalidated — ``ClientUpgradeLink/openable(_:)`` is what decides whether it
    /// is something this app opens, and it decides that at the state rather than here, so a reader
    /// of this document sees what the deployment actually published.
    public let upgradeURL: String?
    public let serverTime: Date?

    public init(
        apiVersion: String,
        minimumSupportedClient: String,
        recommendedClient: String,
        upgradeURL: String?,
        serverTime: Date?
    ) {
        self.apiVersion = apiVersion
        self.minimumSupportedClient = minimumSupportedClient
        self.recommendedClient = recommendedClient
        self.upgradeURL = upgradeURL
        self.serverTime = serverTime
    }

    /// `nil` when the bytes are not a document this build can read.
    ///
    /// **A failure keeps whatever was already kept rather than clearing it**, which is the caller's
    /// rule and is stated here because it is the reason this returns an optional instead of throwing:
    /// §8.3's whole premise is a client that predates whatever changed, so a `/v1/meta` whose shape
    /// has moved past this build is an expected outcome and not an error to report.
    public static func decode(_ data: Data) -> SonnyMetaDocument? {
        guard let wire = try? JSONDecoder().decode(WireMetaDocument.self, from: data) else {
            return nil
        }
        return SonnyMetaDocument(
            apiVersion: wire.api_version,
            minimumSupportedClient: wire.minimum_supported_client,
            recommendedClient: wire.recommended_client,
            upgradeURL: wire.upgrade_url,
            serverTime: wire.server_time.flatMap(SonnyISO8601.parse)
        )
    }
}

/// §8.3's document as it arrives.
///
/// The three version fields are required and the other two are not: a deployment that answered
/// without them is still telling this client which builds it serves, which is the field this state
/// machine is about. §2.1's "clients ignore unknown response fields" is what makes the absent
/// `entitlement_keys` here correct rather than lossy.
private struct WireMetaDocument: Decodable {
    let api_version: String
    let minimum_supported_client: String
    let recommended_client: String
    let upgrade_url: String?
    let server_time: String?
}
