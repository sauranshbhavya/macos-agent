import Foundation

/// Where one of a deep pack's start pages landed, read by a person in a browser (SONNY-510).
///
/// **The own-domain rule reads the string a pack declares, and what decides where Sonny arrives is
/// where that string lands.** `account.ghost.org/` is on Ghost's own domain and redirected a signed-out
/// visitor to Ghost's account-creation form, with a password field and a terms acceptance — three
/// things the founders' rules forbid a flow — and nothing in this repository could see it, because a
/// test that fetched would put the network inside the suite. So the landing is recorded instead, by
/// whoever wrote or last changed the flow, and the loader holds the record: a flow whose start page
/// nobody opened does not load, and neither does one whose recorded landing is somewhere a flow may not
/// begin.
///
/// **What a record says.** `url` is a start URL exactly as the pack's flows write it, and a pack
/// carries one record for each distinct one. `landedURL` is where it ended up for a visitor who is not
/// signed in, written as a page and not as the session that reached it: no query, no query inside a
/// single-page app's fragment (`#/login`, not `#/login?redirect=/`), and no path segment the site mints
/// per visit (`auth.buffer.com/login`, not `auth.buffer.com/login/8pSZ…`) — a sign-in redirect carries
/// state and return values, and a record is read by whoever opens the pack next. `title` and
/// `heading` are that page's document title and the text of its first `h1` or `h2` in document order,
/// each `""` when the page has none (X's log-in page has no title), which is what a later reader
/// re-opens it and compares against: a single-page app keeps one title across its routes, so the
/// title alone can agree with a page that is not the one it names. The heading is recorded as read,
/// even when it is a cookie banner's or a promotion's — a reading is evidence, not a caption.
/// `offers` is what the page offered that visitor, in one of two words, and `read` is the date of the
/// reading.
///
/// **Every reading is signed out, and how a page must be read is `CLAUDE.md`'s**, in its Claims and
/// evidence section, which is not restated here: a browser, a profile with no sign-ins, the landed page
/// verified by its own title and h1 rather than the address that was asked for, and two reads that
/// agree before either is believed, because a first read can be the previous page or the requested one
/// before it has become itself. A signed-in profile measures a page Sonny on a fresh Mac never sees —
/// `meet.google.com/` lands inside the product signed in and on a marketing page on another host signed
/// out (SONNY-510's comments).
///
/// **The two words that load** (`SkillPackStartPageOffer`):
/// - `sign-in`: the form on the page signs in an account that already exists, **and** the site has a
///   separate route for creating one. It is not a start page when that same form is also how an account
///   gets created, whatever words sit beside it — a form headed "Log in or sign up", an email-first form
///   that opens account creation for an address it does not know, or single sign-on with no other way
///   in, whose first press creates the account (Fireflies, tl;dv). A terms line is evidence, not the
///   test: the same "by continuing you agree" sits under LinkedIn's, X's, Cloudflare's and Notion's real
///   sign-in forms, each of which has a sign-up route of its own. A cookie notice is never relevant. What
///   decides is whether pressing the button does something irreversible (founders, 2026-09-18, replacing
///   both this file's first wording and the terms ruling on SONNY-503 and SONNY-504).
/// - `product`: the product itself, usable without signing in, with the flow's first step on it.
///
/// Anything else is a page a flow may not start on, and there is no third word to write it in: a
/// marketing homepage, an account-creation form, a page that cannot reach the product at all — a
/// self-hosted product's vendor site — or one that could not be read.
///
/// **What the loader checks, and what it cannot** (`SkillPackStartPageRule`). It checks that the record
/// exists for every start URL and for nothing else; that a landing carries no query, in the URL or in its
/// fragment; that the landed host is the pack's own site, or the host of the pack's own sign-in page for
/// a record that says `sign-in` — which is what catches `ads.google.com/` landing on `business.google.com`
/// however `signInURL` is edited, and why a pack whose start page lands on an identity host names that
/// host in its `signInURL` (`accounts.google.com`, `login.microsoftonline.com`), the landing being the
/// evidence for where it signs in; that neither URL names account creation in its path, fragment or (for
/// the declared one) query, which is what catches Ghost's `/signup` even when a reader has written
/// `sign-in` beside it; and which word `offers` is. It cannot check that `offers` is true of the page —
/// that is the reader's judgement, and the loader holds only the words it may be written in — and it
/// cannot see a site change after the reading. `read` is what says how old a record is.
public struct SkillPackStartPage: Equatable, Sendable {
    public let url: URL
    public let landedURL: URL
    public let title: String
    public let heading: String
    public let offers: SkillPackStartPageOffer
    /// `YYYY-MM-DD`.
    public let read: String

    public init(url: URL, landedURL: URL, title: String, heading: String, offers: SkillPackStartPageOffer, read: String) {
        self.url = url
        self.landedURL = landedURL
        self.title = title
        self.heading = heading
        self.offers = offers
        self.read = read
    }
}

/// What a start page offered a visitor who is not signed in, in the only two words a pack may record.
/// `SkillPackStartPage` has what each one means.
public enum SkillPackStartPageOffer: String, Sendable, Equatable {
    case signIn = "sign-in"
    case product
}

/// The loader's reading of a pack's start-page records against its flows. `SkillPackStartPage` has the
/// rule and why it exists.
enum SkillPackStartPageRule {
    /// Path, fragment and query parts that name account creation, compared after lowercasing and dropping
    /// `-` and `_`, so `sign-up`, `sign_up` and `SignUp` are one word. Ghost's `/signup` and PartnerStack's
    /// `/handshake/signup` are the measured cases (SONNY-510's comments).
    ///
    /// **Deliberately short.** `join` is not here because Zoom's `join.zoom.us` and `/join` are joining a
    /// meeting, and `start`, `trial` and `get-started` are not because each is as often a product's own
    /// page as a sales one. What this list misses is left to `offers`, which is where a page that offers
    /// account creation under an ordinary path is refused (StreamYard's home has no path at all).
    static let accountCreationParts: Set<String> = ["signup", "register", "registration", "createaccount"]

    static func check(
        flows: [SkillPackFlow],
        startPages: [SkillPackStartPage],
        domain: String,
        signInURL: URL?
    ) throws {
        let recorded = Dictionary(grouping: startPages, by: \.url.absoluteString)
        for page in startPages where recorded[page.url.absoluteString, default: []].count > 1 {
            throw SkillPackLoadError.startPageRecordedTwice(url: page.url.absoluteString)
        }
        for flow in flows where recorded[flow.startURL.absoluteString] == nil {
            throw SkillPackLoadError.startPageNotRecorded(flow: flow.title)
        }
        let started = Set(flows.map(\.startURL.absoluteString))
        for page in startPages {
            let url = page.url.absoluteString
            guard started.contains(url) else {
                throw SkillPackLoadError.startPageUnused(url: url)
            }
            // A query inside a single-page app's fragment is as much a session as one in the URL's own
            // query (review-272's item 9).
            guard page.landedURL.query == nil, !(page.landedURL.fragment ?? "").contains("?") else {
                throw SkillPackLoadError.landedURLCarriesQuery(url: url)
            }
            let landedHost = (page.landedURL.host ?? "").lowercased()
            let signInHost = signInURL?.host?.lowercased()
            // The sign-in host admits a sign-in page and nothing else. `signInURL` is written in the same
            // file as the record, so without this a pack could name `business.google.com` as its sign-in
            // page and land Google Ads' start page there as `product` (review-272's F3).
            let admittedAsSignIn = landedHost == signInHost && page.offers == .signIn
            guard SkillPackDecoder.isOnSite(host: landedHost, domain: domain) || admittedAsSignIn else {
                throw SkillPackLoadError.landedOffSite(url: url, host: landedHost)
            }
            for named in [page.url, page.landedURL] where namesAccountCreation(named) {
                throw SkillPackLoadError.startPageCreatesAnAccount(url: named.absoluteString)
            }
        }
    }

    /// Whether any part of `url`'s path, fragment or query is one of `accountCreationParts`. The fragment
    /// is read because a single-page app routes there (`#/signup`), and the query because a sign-up
    /// intent is often carried there (`?mode=signup`, Auth0's `?screen_hint=signup`) — which only a
    /// declared start URL can have, since a landing is recorded without one (review-272's F4).
    static func namesAccountCreation(_ url: URL) -> Bool {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let text = [components?.path, components?.fragment, components?.query]
            .map { $0 ?? "" }
            .joined(separator: "/")
        return text.lowercased()
            .split(whereSeparator: { "/#?&=.".contains($0) })
            .map { $0.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "") }
            .contains(where: accountCreationParts.contains)
    }
}
