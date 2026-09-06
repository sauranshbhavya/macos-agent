import Foundation
import SwiftSoup

/// Decides whether a fetched page **is** a wall — a CAPTCHA gate, a login gate, a paywall — as
/// opposed to a page that merely *talks about* one.
///
/// **Fail-closed is the point of the check and it survives here unchanged.** Sonny does not scrape
/// past a wall; what SONNY-245 replaced is the evidence the refusal acts on, never the refusal.
///
/// **The defect this replaces.** The rule was: lowercase the whole raw HTML, refuse if it contains
/// any of seven substrings. Fetched with the app's own headers on 2026-08-23,
/// `en.wikipedia.org/wiki/Machine_learning` is 1 146 835 bytes and matches twice — `captcha` inside
/// a `<script>` config blob naming Wikipedia's own edit-form CAPTCHA, and `subscription required`
/// inside the `title=` attribute of the little lock icon its citation templates print. Neither is
/// visible to a reader; neither has anything to do with fetching the article. The user asked Sonny
/// to summarize an encyclopedia article and was told "Sonny will not bypass CAPTCHAs".
///
/// **The rule now: a wall phrase is evidence only on a page that has nothing else to show, and what
/// a reader can see is evidence only when it is something only a wall would say.** A wall is a page
/// whose whole purpose is the wall. An article that discusses CAPTCHAs is still an article.
///
/// Two stages, each with its own limit, because the two kinds of evidence are not equally strong:
///
/// 1. **What the page says to the reader** is direct evidence, so it is trusted on any page short
///    enough to be an interstitial (`interstitialVisibleTextLimit`) — but only for `wallSpeechPhrases`,
///    the phrases that address *this reader* about *this page's* access. ScienceDirect's gate — "Are
///    you a robot? Please confirm you are a human by completing the captcha challenge below." — is
///    this shape. SONNY-256 is why that second condition exists, and the measurement is below.
/// 2. **What the page's markup mentions** is circumstantial — a script src, a config key, a CSS
///    class — so it is trusted only when the page shows a reader essentially nothing
///    (`contentlessVisibleTextLimit`). That is the shape of every modern bot wall: the message is
///    drawn by JavaScript Sonny does not run, and the only trace in what the server sent is
///    `captcha-delivery.com` in a `<script src>`.
///
/// **Measured, not guessed.** 48 live pages were fetched on 2026-08-23 with the headers
/// `URLSessionWebPageFetcher` sends, and their visible text measured through this file's own
/// `visibleText`. Every page and number is in SONNY-245's closing comment; the shape of it:
///
/// - **Genuine walls**: zillow 0, indeed 0, facebook 0, pinterest 0, g2 43, wsj 43, barrons 43,
///   etsy 43, yelp 43, sciencedirect 526, bloomberg 657, linkedin 703, medium 720, instagram 792,
///   glassdoor 3 884.
/// - **Innocent pages the old rule refused**: target 2 502, walmart 3 117, scribd 4 212,
///   ticketmaster 4 442, nytimes 6 119, newyorker 7 770, seekingalpha 12 179, harpers 13 232,
///   nature 38 469, wikipedia 130 932.
///
/// Not one of the 48 — wall or article — said any of those seven phrases to a reader except
/// ScienceDirect's gate. That is why stage 2 exists at all: read only what a reader sees and the
/// check stops catching the modern web's walls entirely, which would be the false-accept trade the
/// ticket asks not to make silently.
///
/// A 49th page was fetched afterwards, for the case the corpus of home pages and gates could not
/// supply and the ticket names as the shape of the defect — a page *about* a wall. Wikipedia's
/// CAPTCHA article says the word to a reader 167 times across 30 785 visible characters, and stage
/// 1's limit is what serves it. It is a fixture, not a corpus entry, so none of the counts above
/// include it.
///
/// Six pages are saved verbatim under `Tests/Fixtures/WebResearch/` and
/// `RestrictedContentDetectorTests` runs both the pre-SONNY-245 rule and this one over every one of
/// them. SONNY-256 added the last two; that README is the index.
///
/// **Why the corroboration is a character count and not "did the extractor find an article".**
/// That was the first design, and it is worse: `SwiftSoupReadableWebExtractor` throws
/// `noReadableContent` on expedia and chegg, pages carrying 107 857 and 70 114 characters of
/// visible text. Keying markup evidence to that would license a refusal on a page with a hundred
/// thousand characters on it, which is the failure this ticket is about.
///
/// **Which errors this chooses, stated rather than left to be discovered** (the ticket asks for
/// exactly this). Fail-closed stays the direction, and the rule it serves is
/// `docs/sonny-major-release-spec.md:459` and `:916` — "Sonny must not bypass paywalls, CAPTCHAs,
/// login walls, or robots restrictions".
///
/// - **Gone:** every false refusal driven by *markup* on a page that has an article — Wikipedia,
///   Nature, the NYT, the CAPTCHA article. **That was not the whole reported class, and the first
///   version of this comment said it was** (PR #108 review, F1): a *short* article about a wall was
///   still refused, because the corroboration was an absolute length. `simonwillison.net/2006/Dec/19/botbouncer/`
///   is HTTP 200 with 1 110 visible characters, one sentence of which mentions a CAPTCHA service,
///   and it was refused, while a 2 166-character post on the same blog, same template, same subject,
///   was served. **SONNY-256 closed that**, and the split between `wallSpeechPhrases` and
///   `subjectPhrases` is the whole of the fix.
/// - **Given up, and it is not only "a bare noun" — an earlier version of this bullet said it was**
///   (PR #210 review, F2). The class is *any* wall in the 200-to-2 000 band whose visible text
///   carries a subject noun and none of `wallSpeechPhrases`. Measured over 14 real gate wordings
///   placed in ordinary nav and footer chrome, **5 lose the refusal SONNY-245 gave them**: "Please
///   complete the CAPTCHA below to continue", "Access denied. Please solve the CAPTCHA below to
///   continue to this page", "Access denied. Please solve the CAPTCHA to prove you're not a bot",
///   "Subscription required. This content is available to subscribers only", and "This article is
///   behind our paywall. Members can read it in full". **Three of those five are full instructions
///   to the reader about this page's access**, which is `wallSpeechPhrases`' own definition of wall
///   speech — they are served because they use the noun, not because they are bare nouns. (A sixth,
///   "Checking your browser before accessing this website", is served by SONNY-245 too, so it is not
///   a loss from this split.)
///
///   **Two mitigations, both measured rather than reasoned.** Below `contentlessVisibleTextLimit`
///   all **14 of 14** are still refused — 8 on visible text, 6 on markup — so shrinking the wall's
///   own page does not get past this. And `SwiftSoupReadableWebExtractor` throws `noReadableContent`
///   on **all five** of the newly-served pages, so **no note is written from any of them**: the user
///   gets a different error, not a summarised wall. That is the same distinction this comment
///   already draws for Instagram and Tumblr below, and it is most of the answer to how bad the trade
///   is.
/// - **Accepted, knowingly:** a gate that renders its own form and chrome, where the only trace is
///   a vendor script. The measured instances are **LinkedIn's feed** (HTTP 200, 703 visible
///   characters, and the extractor gets 556 characters of "article" out of the sign-in chrome) and
///   **IEEE Xplore's home page** (200, 717 visible, 617 extracted). Both were refused by the old
///   rule and are served by this one, and both really do produce a thin note from a sign-in screen —
///   a poor note, not a wall bypassed, and nothing was circumvented to get it. **Instagram and
///   Tumblr are served too but are not instances of that**, and an earlier version of this comment
///   named Instagram as one: at 792 and 269 visible characters they clear this check, and then the
///   extractor throws `noReadableContent`, so no note is written from either (PR #108 review, F2).
/// - **Accepted, knowingly:** a paywall that serves a teaser — the first paragraphs plus "Subscribe
///   to continue". It has an article on it, so it clears both limits. Summarizing what a server
///   freely handed an unauthenticated request is not bypassing the wall the way solving a CAPTCHA
///   would be, and the note names its source.
/// - **What the accepted set actually is, since three earlier sentences understated it:** between
///   `contentlessVisibleTextLimit` and `interstitialVisibleTextLimit` — 200 to 2 000 visible
///   characters — **neither stage fires unless the page says a `wallSpeechPhrases` entry to a reader**,
///   and that band is where most real walls measured live (ScienceDirect 526, FT 565, Bloomberg 657,
///   LinkedIn 703, IEEE 717, Medium 720, Instagram 792, Telegraph 888, and — measured by PR #108's
///   reviewer on other URLs — a Tumblr dashboard at 265 and a pixiv artwork page at 335).
///
///   Several of those are caught by something else — a 401 or 403 answered before this code runs, or
///   an extractor that finds no article — but **not all of them, and the earlier claim that "three
///   independent checks fail closed on these pages, not one" was false for exactly the cases the
///   bullets above concede**: LinkedIn passes the status check, is served here, and yields a
///   556-character article. Zero of the three fire. That sentence was the justification for narrowing
///   this check, so it is corrected rather than softened (PR #108 review, F2).
///
///   **Being in the band is not the same as a note being written**, and that distinction is what the
///   Instagram correction above turns on. Of the pages measured in it, the ones where a note really
///   is produced from gate chrome are LinkedIn (556 characters extracted), IEEE Xplore (617) and a
///   Scribd document page (271). Instagram, Tumblr and the pixiv artwork page are served by this
///   check and then yield nothing, because the extractor throws `noReadableContent`.
///
/// **A review is evidence, not authority — and this file carried a record built the wrong way for one
/// round, so the lesson is written where the record was.** PR #108's review reported a ResearchGate
/// publication page as HTTP 200 with a 302-character article and named it among the pages this check
/// now serves. This session measured **403**, on two URLs. Rather than report that the two readings
/// disagreed, it wrote that ResearchGate's "status is evidently not stable" — a sentence whose only
/// job was to let a correct measurement and a mislabel both be true — and the list went on citing a
/// page that answers 403 as an example of a note being written. The reviewer has since retracted it:
/// four consecutive 403s across both sessions, no 200 ever measured. **When your own measurement
/// disagrees with a reviewer's, the disagreement is the finding.** Say so plainly and get it settled;
/// prose that reconciles two numbers builds a false record out of two people each being careful, and
/// it reads exactly like diligence. The pixiv entry beside it is the shape this is *not* — two
/// correct readings of two different URLs, each stated with its URL.
public enum RestrictedContentDetector {
    /// Where the phrase was found, which is what decides how much it is worth.
    public enum Evidence: String, Equatable, Sendable {
        /// In the text a reader would see.
        case visibleText
        /// Anywhere in what the server sent — script bodies, attributes, comments, class names.
        case markup
    }

    public struct Finding: Equatable, Sendable {
        /// The plural noun the refusal names, e.g. `CAPTCHAs`. Reads as "Sonny will not bypass ...".
        public var reason: String
        /// The phrase that matched, so a test (and a future reader) can see what fired.
        public var phrase: String
        public var evidence: Evidence
        /// Characters of visible text on the page, the corroboration both stages turn on.
        public var visibleTextLength: Int

        public init(reason: String, phrase: String, evidence: Evidence, visibleTextLength: Int) {
            self.reason = reason
            self.phrase = phrase
            self.evidence = evidence
            self.visibleTextLength = visibleTextLength
        }
    }

    /// A page saying a wall phrase to the reader is a wall if it is short enough to be an
    /// interstitial rather than an article.
    ///
    /// 2 000 characters sits above every wall in the corpus that both speaks to a reader **and** says
    /// one of the seven phrases — which is one page, ScienceDirect's gate at 526 — and below every
    /// innocent page in the corpus carrying a phrase in *visible* text, of which there were none. So
    /// the limit is doing its work against the case the ticket names rather than against the corpus:
    /// an article *about* CAPTCHAs says the word in its own prose and runs to tens of thousands of
    /// characters.
    ///
    /// **It is not a bound on real walls, and an earlier version of this comment implied it was while
    /// conceding the counterexample in its own parenthetical** (PR #108 review, F4). Glassdoor's wall
    /// speaks at 3 884 characters — 1.9 times this limit — by repeating one short message in ten
    /// languages. It is harmless today for two reasons that are not this limit: its wording matches
    /// none of the seven phrases, and it answers 403. Cloudflare's common "Verifying you are human"
    /// did not match `verify you are human` either, and **that half is closed**: SONNY-256 added
    /// `verifying you are human` to `wallSpeechPhrases`, measured against a corpus sampled on the
    /// wording itself. Glassdoor is untouched by that — its length, not its wording, is the reason
    /// it sits above this limit.
    public static let interstitialVisibleTextLimit = 2_000

    /// Markup evidence needs the page to show a reader essentially nothing.
    ///
    /// 200 characters is deliberately far below the innocent floor measured in the corpus — target
    /// 2 502, a shopping home page whose markup names a CAPTCHA vendor — because the pages this
    /// guard protects are the ones a corpus of popular sites cannot see: a small blog post whose
    /// comment form loads `recaptcha.js`. Every wall in the corpus that draws its message entirely
    /// with JavaScript lands at 43 characters or fewer, so the gap is wide in both directions. The
    /// five walls sitting above it — Bloomberg 657, LinkedIn 703, Medium 720, Instagram 792,
    /// Glassdoor 3 884 — all render something of their own, and are the knowingly-accepted cases the
    /// type doc names. Where the corpus is silent, this errs toward serving the page, which is the
    /// direction SONNY-245 exists to correct.
    public static let contentlessVisibleTextLimit = 200

    /// **Wall speech**: a phrase that addresses *this reader* about *this page's* access. Only a
    /// wall issues one, so it is what visible-text evidence is searched for.
    ///
    /// **Widening this list is its own decision with its own false-refusal risk**, and SONNY-245
    /// said so before SONNY-256 deleted the sentence and proved it. SONNY-256's split — visible text
    /// for speech, markup for nouns — is about the *evidence*. Every entry here is *coverage*, and
    /// coverage is where the risk lives. PR #210's F1 is the worked example: the first version of
    /// this list added `you are human`, `you are a human` and `are you a robot`, cleared by a corpus
    /// whose comment pages had been sampled on the three nouns the split *removes* and never on the
    /// wordings it *adds*, so no counterexample could appear in it. Measured afterwards over 224
    /// pages including 70 sampled on the added wordings themselves, those three matched **17, 18 and
    /// 6 innocent in-band pages** — a Hacker News comment about turning down a company ("if you are
    /// human you will do from time to time") refused as a CAPTCHA gate, and a complaint *about*
    /// robot walls refused as one, which is the exact failure SONNY-256 exists to end.
    ///
    /// **The rule for adding an entry, so the next one is not cleared the same way: it matches zero
    /// innocent in-band pages across a corpus sampled on the wording itself.** That is what admits
    /// the entries below and what excluded those three. It also excluded `prove you are human` (6
    /// innocent, 0 walls), `prove you are a human` (2, 0) and `verify you are a human` (3, 0), which
    /// PR #210's review proposed — the distinction the data draws is not the verb but the *person*.
    /// A wall says what the challenge does: "completing the CAPTCHA **proves** you are human",
    /// "**verifying** you are human", "please **confirm** you are a human". A reader discussing walls
    /// uses the infinitive: "how do you **prove** you are human?".
    ///
    /// **`verify you are human` is SONNY-245's own and is kept unchanged, including its cost.** It
    /// matches 5 innocent pages in that corpus, and SONNY-245's rule refuses all 5 as well — so they
    /// are pre-existing behaviour rather than this split's. Removing it would narrow SONNY-245's
    /// coverage, which is the decision the warning above says has to be made on its own terms, and
    /// it is not SONNY-256's to make.
    static let wallSpeechPhrases: [(phrase: String, reason: String)] = [
        ("verify you are human", "CAPTCHAs"),
        ("verifying you are human", "CAPTCHAs"),
        ("verifying you are a human", "CAPTCHAs"),
        ("confirm you are human", "CAPTCHAs"),
        ("confirm you are a human", "CAPTCHAs"),
        ("proves you are human", "CAPTCHAs"),
        ("proves you are a human", "CAPTCHAs"),
        ("please log in", "login walls"),
        ("sign in to continue", "login walls"),
        ("subscribe to continue", "paywalls")
    ]

    /// **Subject nouns**: a phrase that names the thing rather than addressing the reader. A page is
    /// allowed to have a subject, so these are never visible-text evidence — they are what a page
    /// *about* a wall says, and they were the whole of SONNY-256's false-refusal population.
    ///
    /// They remain full evidence in markup, where `contentlessVisibleTextLimit` corroborates them
    /// and the measurement says that limit is correctly set: no innocent page in the corpus is under
    /// 200 visible characters, and every page that is, is a wall.
    static let subjectPhrases: [(phrase: String, reason: String)] = [
        ("captcha", "CAPTCHAs"),
        ("subscription required", "paywalls"),
        ("paywall", "paywalls")
    ]

    /// What *markup* evidence is searched for: both kinds. A superset of the seven phrases SONNY-245
    /// shipped, since `you are human` contains the `verify you are human` it replaces — so stage 2
    /// loses no coverage to SONNY-256's split.
    static let phrases: [(phrase: String, reason: String)] = wallSpeechPhrases + subjectPhrases

    /// The refusal reason for `html`, or `nil` if the page is not a wall.
    public static func reason(inHTML html: String) -> String? {
        finding(inHTML: html)?.reason
    }

    /// The full finding, so callers and tests can see which evidence fired and on how much text.
    public static func finding(inHTML html: String) -> Finding? {
        let visible = visibleText(inHTML: html)
        let visibleLength = visible.count

        if visibleLength < interstitialVisibleTextLimit,
           let hit = firstPhrase(among: wallSpeechPhrases, in: visible) {
            return Finding(
                reason: hit.reason,
                phrase: hit.phrase,
                evidence: .visibleText,
                visibleTextLength: visibleLength
            )
        }

        if visibleLength < contentlessVisibleTextLimit,
           let hit = firstPhrase(among: phrases, in: html) {
            return Finding(
                reason: hit.reason,
                phrase: hit.phrase,
                evidence: .markup,
                visibleTextLength: visibleLength
            )
        }

        return nil
    }

    /// The text a reader would see: body text with the elements that carry no reader-visible text
    /// removed.
    ///
    /// Attributes, HTML comments and `<script>` bodies never reach here — SwiftSoup's `text()`
    /// collects text nodes, and script bodies are data nodes — so a phrase living in one of those
    /// can only ever be markup evidence, which needs a page with essentially nothing on it. The
    /// removals below are belt-and-braces on top of that. The Wikipedia article's two matches are in
    /// exactly those two places; what clears *that* page, though, is its size — at 130 932 visible
    /// characters neither stage is in range, and stating it the other way round would credit this
    /// function with a verdict the limits decide.
    ///
    /// Site chrome — nav, footer, cookie bars — is counted, deliberately: the question this answers
    /// is "does this page show the reader anything", and chrome is something. The cost is that a
    /// wall drawn inside a site's full layout can clear `interstitialVisibleTextLimit` on chrome
    /// alone; the reason that is the right trade is that the alternative, scoring an article the way
    /// `SwiftSoupReadableWebExtractor` does, makes the refusal depend on a heuristic tuned for a
    /// different job.
    ///
    /// **The `""` on the failure paths below is a value the compiler asks for, not a decision about
    /// malformed input** (PR #108 review, F6). An earlier version of this line said an unparseable
    /// page yields `""` "the fail-closed direction", which reads as a live behaviour and is not one:
    /// SwiftSoup's HTML parse is permissive by construction, and its three parse-path files contain
    /// no `throw` of their own (`grep -c 'throw ' Tokeniser.swift TreeBuilder.swift
    /// HtmlTreeBuilder.swift` in SwiftSoup 2.13.5 answers 0, 0, 0). What can throw there is twelve
    /// `Validate` calls inside `HtmlTreeBuilder`, and they are internal invariants rather than input
    /// checks — four of the seven `Validate.fail` messages read "Should not be reachable". So this
    /// path is reached on the library's own invariant failure, not on bad HTML, and nothing in this
    /// repository exercises it. Stated this way because the same shape — a comment naming a
    /// mechanism the library does not have — already shipped once on this branch and was caught by
    /// running the test without the guard.
    public static func visibleText(inHTML html: String) -> String {
        guard let document = try? SwiftSoup.parse(html) else {
            return ""
        }
        do {
            // A nested match is removed twice and that is safe: an inline `<svg>` holding a
            // `<style>` matches this selector twice, parent first, and SwiftSoup 2.13.5's
            // `Node.remove()` is `try parentNode?.removeChild(self)` — optional-chained, so the
            // orphaned second removal does nothing rather than throwing. It matters which, because
            // an abandoned loop returns "" from the `catch` below, and a page with no visible text
            // is a page judged on its markup: a decorative icon on a page that loads a CAPTCHA
            // widget would be refused. `anInlineIconWithItsOwnStyleDoesNotEraseThePagesVisibleText`
            // holds that property against a future rewrite of this loop.
            for element in try document.select("script, style, noscript, template, svg").array() {
                try element.remove()
            }
            let body = document.body() ?? document
            return normalized(try body.text())
        } catch {
            return ""
        }
    }

    private static func firstPhrase(
        among candidates: [(phrase: String, reason: String)],
        in text: String
    ) -> (phrase: String, reason: String)? {
        let haystack = normalized(text)
        return candidates.first { haystack.contains($0.phrase) }
    }

    /// Case- and diacritic-folded, with every run of whitespace collapsed to one space.
    ///
    /// Collapsing matters for both inputs: SwiftSoup renders `&nbsp;` as U+00A0, and raw markup puts
    /// line breaks and indentation between the words of a phrase. `locale: nil` rather than
    /// `.current`, so the same page cannot be judged differently on two Macs.
    private static func normalized(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
