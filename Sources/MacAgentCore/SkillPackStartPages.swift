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
/// state and return values, and a record is read by whoever opens the pack next. `title` is that
/// page's document title once it has settled, read after arriving through `url` the way the flow
/// arrives and not by opening `landedURL` fresh, because a redirect can race the title's update
/// (Otter's and DeepL's each show a second title for a moment). A page that races records every other
/// title it was read reporting in `otherTitles`, because one reading of a race is a sample and not a
/// fact; the field is absent for a page that does not race, and no refusal reads either title.
/// `heading` is the text of the first `h1` or `h2`, in document order, that a visitor can see: one with
/// rendered area, not `display: none`, not `visibility: hidden`, not clipped to nothing the way a
/// screen-reader-only heading is, and carrying text. So a hidden cookie dialog's heading is not the
/// page's (Cloudinary's "Privacy Preference Center"), and a visible promotion's is (Klaviyo's). Opacity
/// is deliberately not read: a card that fades in sits at opacity 0 in a window that is not on screen,
/// and a reading taken there would call Clerk's and Discord's headings hidden (founders' definition,
/// 2026-09-18, on SONNY-510). Each is `""` when the page has none (X's log-in page has no title), and
/// the two are what a later reader re-opens the page and compares against: a single-page app keeps one
/// title across its routes, so the title alone can agree with a page that is not the one it names.
/// `offers` is what the page offered that visitor, in one of two words, and `read` is the date of the
/// reading: a real calendar date, `YYYY-MM-DD`, and no earlier than `SkillPackStartPageRule.firstReadingDay`,
/// so a typo such as `2026-13-45` or a placeholder such as `1970-01-01` does not load (SONNY-529).
///
/// **The word is judged at each flow's own first step, not at the page's shape** (SONNY-510's round five).
/// So two pages of one shape can carry different words, and that is the rule working. eBay's homepage and
/// Etsy's are the same shape — a marketplace with a demoted "Sign in" — and eBay's record says `product`
/// because its one flow begins in the search box, which works signed out, while Etsy's says `sign-in`
/// because both of its flows begin in Your account or Shop Manager, which only a signed-in visitor has.
/// Had eBay's Watchlist flow stayed, its record could not have said `product` for that flow; that is why
/// the flow was left out rather than the word changed (SONNY-529).
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
///   both this file's first wording and the terms ruling on SONNY-503 and SONNY-504). The separate route
///   is read at the page: a visible registration control, a tab, a button or a link to a page of its
///   own. A page that shows none is held, because what a form does with an address nobody may type into
///   it cannot be seen from outside.
///
///   **With one exception: a product that offers no self-serve sign-up anywhere passes**, because an
///   admin or a sales team creates every account (founders, 2026-09-18; Ashby and Lever). The visible
///   route was only ever a proxy for "this form cannot create an account", and on such a product the
///   proxy reads backwards. On tl;dv and Fireflies its absence means the provider button is the sign-up.
///   On Ashby it means no account can be created on that page at all. Same evidence, opposite meaning.
///   So the exception is a check of the site, not of the sign-in page: if self-serve sign-up exists
///   anywhere on it (a free plan, a trial, a "Get started" that creates an account) and the sign-in page
///   merely hides it, that is tl;dv's shape and the page is held. Where each reader looked is recorded on
///   SONNY-510, site by site.
///
///   **And a consent to biometric capture or to recording, bound to the control that signs in, holds the
///   page whatever its sign-up route** (founders, 2026-09-18; Runway's "we and our vendors may scan faces
///   or capture voiceprints", Fireflies' consent to recording the visitor's voice). It is a separate
///   ground because the rule above is about account creation and is blind to it: a faceprint granted by a
///   press is not terms boilerplate, and closing the account does not undo it. It is narrow on purpose,
///   biometric and recording consent only and never consent in general, or it would swallow the terms
///   line above.
/// - `product`: the product itself, usable without signing in, with the flow's first step on it.
///
/// Anything else is a page a flow may not start on, and there is no third word to write it in: a
/// marketing homepage, an account-creation form, a page that cannot reach the product at all — a
/// self-hosted product's vendor site — or one that could not be read.
///
/// **What the loader checks, and what it cannot** (`SkillPackStartPageRule`). It checks that the record
/// exists for every start URL and for nothing else; that a landing carries no query, in the URL or in its
/// fragment; that the landed host is the pack's own site or a listed identity host that signs in for the
/// pack's site (`SkillPackStartPageRule.identityHosts`) — which is what catches `ads.google.com/` landing
/// on `business.google.com`, whatever the pack's `signInURL` says — and that any landing on a listed
/// identity host, on the pack's own site or off it, says `sign-in`;
/// that neither URL names account creation in its path, fragment, host or (for the declared one) query,
/// which is what catches Ghost's `/signup` even when a reader has written `sign-in` beside it; and which word
/// `offers` is. It cannot check that `offers` is true of the page —
/// that is the reader's judgement, and the loader holds only the words it may be written in — and it
/// cannot see a site change after the reading. `read` is what says how old a record is.
public struct SkillPackStartPage: Equatable, Sendable {
    public let url: URL
    public let landedURL: URL
    public let title: String
    /// The other titles a page reported on its way to `title`, when it races; empty otherwise.
    public let otherTitles: [String]
    public let heading: String
    public let offers: SkillPackStartPageOffer
    /// `YYYY-MM-DD`.
    public let read: String

    public init(
        url: URL,
        landedURL: URL,
        title: String,
        otherTitles: [String] = [],
        heading: String,
        offers: SkillPackStartPageOffer,
        read: String
    ) {
        self.url = url
        self.landedURL = landedURL
        self.title = title
        self.otherTitles = otherTitles
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
    /// The words that name account creation. A URL names it when one of its path, fragment or query parts,
    /// or a host label left of the site's own name, carries one of these as a run of its words
    /// (`accountCreationWords(in:)`): so `sign-up`, `sign_up` and `SignUp` are one word, and so are
    /// `/signup-free`, `/register-now` and `signup.<site>`. Ghost's `/signup` and PartnerStack's
    /// `/handshake/signup` are the measured cases (SONNY-510's comments).
    ///
    /// **Deliberately short, and the list stayed short when the match widened** (SONNY-529). The words are
    /// the same four; what changed is that a word may now be part of a longer slug or be a host's first
    /// label, which review-272b found missed. Measured before widening, over every declared and landed URL
    /// the shipped start pages record: the wider match refuses none of them, and neither does the old one.
    /// A match on a word's *prefix* was measured too and rejected: `/registered-users` starts with
    /// `register` and is not account creation, and a prefix match refuses it. `join` is not here because
    /// Zoom's `join.zoom.us` and `/join` are joining a meeting, and `start`, `trial` and `get-started` are
    /// not because each is as often a product's own page as a sales one. What this list misses is left to
    /// `offers`, which is where a page that offers account creation under an ordinary path is refused
    /// (StreamYard's home has no path at all).
    static let accountCreationParts: Set<String> = ["signup", "register", "registration", "createaccount"]

    /// The first day any start page was read under this rule: SONNY-510 was filed on 2026-09-17 and its
    /// first readings are dated that day (Outlook Calendar's record still is). A record dated earlier
    /// describes a reading that could not have happened, which is the shape a placeholder takes.
    static let firstReadingDay = "2026-09-17"

    /// Whether `text` is a real calendar date on or after `firstReadingDay`. Its `YYYY-MM-DD` shape is the
    /// decoder's to check first, so the comparison with `firstReadingDay` is between two strings of one
    /// fixed shape, where text order is date order. No upper bound, deliberately: the loader runs on every
    /// launch, and a Mac whose clock is wrong would refuse every pack read after that clock's today.
    static func isAReadingDay(_ text: String) -> Bool {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone
        let day = DateComponents(calendar: calendar, year: parts[0], month: parts[1], day: parts[2])
        return day.isValidDate && text >= firstReadingDay
    }

    /// **Where a start page may land off its own pack's site: this list, and nowhere else** (the
    /// founders' decision of 2026-09-18 on SONNY-524). Each key is a host a shipped start page was read
    /// landing on, signed out, and its value is the sites whose packs it signs in for. A landing there is
    /// admitted only for a record that says `sign-in`, and only when the pack's `domain` is on one of
    /// those sites, so Google's sign-in host admits a Google pack and not Notion's. The list is the whole
    /// population of off-site landings the shipped packs make — the second round's sweep found it, and
    /// SONNY-529 added the two pairings Microsoft 365 and Zoho Desk came back with, each read on
    /// 2026-09-18 — and `theIdentityHostListIsExactlyTheLandingsTheShippedPacksMake` holds that it stays
    /// exactly that.
    ///
    /// **The refusal is the point.** A pack whose start page lands on a host not listed here does not
    /// load, so somebody sees it. The allowance this replaced read the pack's own `signInURL`, which the
    /// same author writes in the same file, so a wrong value admitted a bad landing silently: review-272
    /// loaded a Google Ads pack that named `business.google.com` as its sign-in page, through the real
    /// decoder. `signInURL` is not read by this rule at all now.
    ///
    /// **To add a host**, read the start page signed out, confirm it lands on a sign-in page on that
    /// host, and add the host with the site it signs in for in the same change as the pack, citing the
    /// reading. A new product on a listed site needs no edit: a calendar pack on `calendar.google.com`
    /// already signs in through `accounts.google.com`. The refusal says which pairing is missing,
    /// `landingHostNotPairedWithSite(url:host:site:)`, because the list is kept one pairing at a time: a
    /// host already listed for another site is still refused for this one, and the fix is that pairing,
    /// not the host. That is why the refusal is not named for an unpaired host: Microsoft 365's landing on
    /// `login.microsoftonline.com` was refused while that host was listed for Outlook and Teams (SONNY-529).
    static let identityHosts: [String: Set<String>] = [
        "accounts.google.com": ["google.com", "youtube.com"],
        // microsoft365.com: www.microsoft365.com/login, read signed out 2026-09-18 (SONNY-529).
        "login.microsoftonline.com": ["office.com", "microsoft.com", "microsoft365.com"],
        "login.live.com": ["live.com"],
        "id.atlassian.com": ["trello.com"],
        "app.frontapp.com": ["front.com"],
        "app.notion.com": ["notion.so"],
        "authenticator.cursor.sh": ["cursor.com"],
        "identity.getpostman.com": ["postman.com"],
        // desk.zoho.com/agent, read signed out 2026-09-18 (SONNY-529).
        "accounts.zoho.com": ["zoho.com"],
        "carrd.com": ["carrd.co"]
    ]

    /// Whether `host` is a listed identity host that signs in for a pack on `domain`.
    static func signsIn(on host: String, forPackOn domain: String) -> Bool {
        identityHosts[host]?.contains { SkillPackDecoder.isOnSite(host: domain.lowercased(), domain: $0) } ?? false
    }

    static func check(
        flows: [SkillPackFlow],
        startPages: [SkillPackStartPage],
        domain: String
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
            if !SkillPackDecoder.isOnSite(host: landedHost, domain: domain) {
                guard signsIn(on: landedHost, forPackOn: domain) else {
                    throw SkillPackLoadError.landingHostNotPairedWithSite(url: url, host: landedHost, site: domain.lowercased())
                }
            }
            // An identity host admits a sign-in page and nothing else (review-272's F3): a `product`
            // record there is a reader's mistake, not a page Sonny can start a task on. It is asked of
            // every landing on a listed host, on the pack's own site too, because the Google pack's
            // domain is `google.com` and `accounts.google.com` is its own site.
            if identityHosts[landedHost] != nil, page.offers != .signIn {
                throw SkillPackLoadError.identityHostLandingIsNotSignIn(url: url, host: landedHost)
            }
            for named in [page.url, page.landedURL] where namesAccountCreation(named) {
                throw SkillPackLoadError.startPageCreatesAnAccount(url: named.absoluteString)
            }
        }
    }

    /// Whether any part of `url`'s path, fragment or query, or any host label left of the last two, names
    /// account creation (`accountCreationParts`). The fragment is read because a single-page app routes
    /// there (`#/signup`), and the query because a sign-up intent is often carried there (`?mode=signup`,
    /// Auth0's `?screen_hint=signup`) — which only a declared start URL can have, since a landing is
    /// recorded without one (review-272's F4). The host is read because a site can put its sign-up on a
    /// host of its own (`signup.<site>`, SONNY-529); its last two labels are left out, so a site whose own
    /// name is one of the words is not refused for being itself.
    static func namesAccountCreation(_ url: URL) -> Bool {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let text = [components?.path, components?.fragment, components?.query]
            .map { $0 ?? "" }
            .joined(separator: "/")
        let parts = text.split(whereSeparator: { "/#?&=.".contains($0) }).map(String.init)
        let hostLabels = (components?.host ?? "").split(separator: ".").dropLast(2).map(String.init)
        return (parts + hostLabels).contains { !accountCreationWords(in: $0).isEmpty }
    }

    /// The account-creation words a single URL part carries, as runs of its words. A part's words are cut
    /// at `-`, at `_` and where a lowercase letter meets an uppercase one, then lowercased; every run of
    /// consecutive words is joined and looked up. So `sign-up-free` carries `signup`, `create_account_now`
    /// carries `createaccount`, and `SignUpNow` carries `signup`, while `registered-users` carries nothing,
    /// because `registered` is a word of its own and not a run ending at `register`.
    static func accountCreationWords(in part: String) -> [String] {
        var words: [String] = []
        var word = ""
        var previous: Character?
        for character in part {
            if character == "-" || character == "_" {
                words.append(word)
                word = ""
            } else {
                if let previous, previous.isLowercase, character.isUppercase {
                    words.append(word)
                    word = ""
                }
                word.append(character)
            }
            previous = character
        }
        words.append(word)
        let folded = words.filter { !$0.isEmpty }.map { $0.lowercased() }
        var found: [String] = []
        for start in folded.indices {
            var run = ""
            for next in folded[start...] {
                run += next
                if accountCreationParts.contains(run) {
                    found.append(run)
                }
            }
        }
        return found
    }
}
