import Foundation

/// A piece of pack text as the content rules read it: folded the way every search in the app folds
/// (case and diacritics), and cut into words on anything that is not a letter or a digit.
///
/// **Words rather than substrings, and that is what makes the whitespace fold free.** "Send  money"
/// with two spaces, "Transfer<TAB>funds", "Send<U+00A0>money" and "Pay-out" all become the same
/// words as their plain spellings, because every run of separators — spaces of any width,
/// tabs, line breaks, hyphens, punctuation — is one boundary. A phrase is matched as a run of
/// whole words, so "linear" is not found in "nonlinear" and "pay" is not found in "payouts".
struct SkillWords {
    let words: [String]
    /// The text's own spelling, cut the same way, for the one rule that needs case: an uppercase
    /// `PIN` is a credential, and a lowercase "pin" is Slack pinning a message.
    let casedWords: [String]
    /// The folded text, for the currency-amount pattern, which needs symbols the word cut drops.
    let folded: String

    /// Each word with the singular forms it might be, for the phrases that read plurals.
    let singularForms: [[String]]

    /// For each word, whether only spaces stand between it and the word before it — no punctuation,
    /// no line break. `false` for the first word, which has nothing before it. Always the same length
    /// as `words`.
    ///
    /// **Every rule here reads words and ignores what separates them, except one** (SONNY-508,
    /// review-268's F1). That is right for a phrase: "Pay-out" and "pay out" are the same act, and
    /// the doc above says so. It is wrong for the credential rule's `secret`, whose whole question is
    /// whether the word beside it *belongs with it* — because `cut` discards the full stop, "Copy the
    /// client ID and the secret. Boards are listed on the left." made `boards` the next word and
    /// excused a credential step. Nine steps of that shape are held by value in
    /// `aControlNamedSecretLoadsAndACredentialNamedSecretStillDoesNot`, and every one of them loaded
    /// before this array existed. The shape is not exotic, and the count depends on which
    /// punctuation is called a boundary, so the instrument is named with the number:
    /// `python3 -c "import json,glob,re; steps=[s for f in glob.glob('Sources/MacAgent/Resources/SkillPacks/' + '*.skillpack.json') for fl in json.load(open(f))['flows'] for s in fl['steps']]; print(len(steps), sum(1 for s in steps if re.search(r'[.:;!?]\s+\S', s)), sum(1 for s in steps if re.search(r'[.!?]\s+\S', s)))"`
    /// → `1767 495 381` at `9ae00161`, after this branch's one hop onto a `main` three pack
    /// branches had grown under it. The figure reads the shipped pack resources only, which no commit
    /// on this branch touches. (The glob is written as two joined strings for the reason
    /// `CLAUDE.md` gives: a slash-star in a line comment opens a block-comment span that
    /// `MacAgentSource.read` never closes, and everything below it vanishes from every source scan in
    /// the tree. Writing the number with its command is what put it there, which is the trap that
    /// rule keeps setting; `LineCommentMayNotOpenABlockTests` is what caught it, in the full suite
    /// and not in this file's own.) Four of those steps already place one of `privacyObjects`
    /// immediately after a boundary, none of them beside a credential word — which is what the array
    /// is for rather than a defect anybody has shipped.
    let joinedToPrevious: [Bool]

    init(_ text: String) {
        folded = SearchText.normalized(text)
        let cut = Self.cutRecordingGaps(folded)
        words = cut.words
        joinedToPrevious = cut.joinedToPrevious
        casedWords = Self.cut(text)
        singularForms = words.map(Self.singularCandidates(of:))
    }

    static func cut(_ text: String) -> [String] {
        text.split { !($0.isLetter || $0.isNumber) }.map(String.init)
    }

    /// `cut`, plus whether each word is joined to the one before it by spaces alone.
    ///
    /// A tab counts as a space, because the whitespace fold above already treats one as a separator
    /// and a step written with one is the same sentence. A line break does not, and neither does any
    /// punctuation — including a hyphen, which means "board-secret" is read as two words that are not
    /// beside each other and is therefore refused. That is the fail-closed direction and it costs a
    /// spelling no page in the catalogue uses.
    static func cutRecordingGaps(_ text: String) -> (words: [String], joinedToPrevious: [Bool]) {
        var words: [String] = []
        var joinedToPrevious: [Bool] = []
        var current = ""
        var gapIsSpaceOnly = true
        for character in text {
            if character.isLetter || character.isNumber {
                if current.isEmpty {
                    joinedToPrevious.append(words.isEmpty ? false : gapIsSpaceOnly)
                }
                current.append(character)
            } else {
                if !current.isEmpty {
                    words.append(current)
                    current = ""
                    gapIsSpaceOnly = true
                }
                if character != " " && character != "\t" {
                    gapIsSpaceOnly = false
                }
            }
        }
        if !current.isEmpty {
            words.append(current)
        }
        return (words, joinedToPrevious)
    }

    /// `word` and every singular it might be: `-ies` → `-y`, `-es` dropped, or `-s` dropped (not
    /// `-ss`). Every candidate is kept, since English does not say which is right, so a wrong one
    /// ("codes" → "cod") can only add a match, never lose one.
    ///
    /// **The one copy of this rule** (PR #241's second scoped round). The money rule reads the plural
    /// of every word on its three noun lists through it — money objects, contextual objects and money
    /// context words (SONNY-479) — and `SkillPackTests.isOrdinary` reads a trigger word's through it,
    /// so the readings cannot drift apart.
    static func singularCandidates(of word: String) -> [String] {
        var candidates = [word]
        if word.hasSuffix("ies"), word.count > 4 { candidates.append(String(word.dropLast(3)) + "y") }
        if word.hasSuffix("es"), word.count > 3 { candidates.append(String(word.dropLast(2))) }
        if word.hasSuffix("s"), !word.hasSuffix("ss"), word.count > 2 { candidates.append(String(word.dropLast())) }
        return candidates
    }

    /// Whether the phrase's words appear here as a run of whole words. With `readingPlurals`, a word
    /// here also matches a phrase word that is one of its singular forms, so "account numbers" and
    /// "cards on file" match the phrases "account number" and "card on file". Only this side is read
    /// that way: a phrase listed in the plural ("payment details") is not matched by its singular.
    func contains(_ phrase: [String], readingPlurals: Bool = false) -> Bool {
        guard !phrase.isEmpty, phrase.count <= words.count else { return false }
        for start in 0...(words.count - phrase.count) {
            let matched = phrase.indices.allSatisfy { offset in
                readingPlurals
                    ? singularForms[start + offset].contains(phrase[offset])
                    : words[start + offset] == phrase[offset]
            }
            if matched { return true }
        }
        return false
    }
}

/// A list of phrases, each cut into words once rather than on every text it is compared against.
struct SkillPhraseList {
    let phrases: [(spelling: String, words: [String])]

    init(_ spellings: [String]) {
        phrases = spellings.map { ($0, SkillWords.cut(SearchText.normalized($0))) }
    }

    func first(in texts: [SkillWords], readingPlurals: Bool = false) -> String? {
        phrases.first { phrase in texts.contains { $0.contains(phrase.words, readingPlurals: readingPlurals) } }?.spelling
    }
}

/// **No flow moves money, in any pack, whatever its category** (founders, 2026-09-13 on SONNY-452),
/// read off a pack's wording as well as a first-party check can.
///
/// **What it reads.** A flow's title and steps together, the pack's summary, and each of its
/// sections, because all of them reach the planner. A flow is read as one unit, since its money act
/// is often split between a title ("Create a payout") and a step ("Click Confirm").
///
/// **How it decides — four tests, any of which refuses:**
/// 1. **A verb or act that can only mean money**, alone: `pay`, `refund`, `reimburse`, `withdraw`,
///    `top up`, `wire`, `remit`, `disburse`, `cash out`, `get paid`, and the old list's
///    `make a transfer`, `send a transfer` and `make a deposit` (restored in PR #241's delta round,
///    after the first version of this rule let them load as single steps).
/// 2. **An action verb with a money object.** Action verbs change something: add, change, update,
///    replace, send, create, submit, confirm, initiate, run, approve, capture, charge, move,
///    transfer, remove, connect, request, settle, split, tip and the rest of `actionVerbs`. Money objects are things money moves
///    through or to: money, funds, a payment, a payout, payroll, a bill, a beneficiary, a payee, an
///    IBAN, a wire, ACH, SEPA, a bank account, a card on file, payment details, a currency amount.
///    A few objects are ordinary words elsewhere — a *recipient* in an email tool, a *card* on a
///    Trello board, an *account*, a *balance*, an *amount* — and count only when the same unit also
///    names money: a bank, billing, an IBAN, a transfer, a wire, a payment, a payout, money, funds, a
///    currency, an invoice, or a currency amount.
/// 3. **A purchase act**, alone: `buy`, `purchase`, `place an order`, `proceed to checkout` — and
///    those four spellings only, since every other one this list was drafted with is already reached
///    by an earlier test, which `purchaseActs`' own comment names. Buying is money leaving the user,
///    and tests 1 and 2 were built for money *movement* — transfers, payouts, refunds, payees — so
///    what reached a purchase before SONNY-506 was whatever a money verb happened to cover (`pay`,
///    `top up`) and nothing else:
///    `git grep -cE '"(buy|purchase|checkout|postage)"' 981c6e56 -- Sources/MacAgentCore/SkillPackContentRules.swift`
///    → exit 1, no output. A purchase act refuses on its own rather than beside an action verb,
///    because the verb in a purchase step is *click*: "Click Buy Postage" holds no listed action
///    verb and never will.
/// 4. **A purchase control beside a price.** `subscribe`, `upgrade`, `renew` and `checkout` — the
///    last spelled as one word or two — are each a free action on one site and a charge on the next:
///    YouTube's Subscribe, a Workspace edition called "Teaching and Learning Upgrade". So each counts
///    only when the same unit also names what is being paid: a plan, a price, pricing, a cost,
///    billing, a subscription, a payment, a card, a trial, a seat, per month, per year, paid. This
///    test asks for no action verb either, for test 3's reason. "Pick the Business plan and click
///    Upgrade to see the price." is refused; "Click Subscribe." on a channel loads.
///
/// **Every word on those three lists — money objects, contextual objects, money context words — is
/// read in the plural too, and the lists hold singulars**, as do test 4's two (`purchaseControls`
/// and `pricedWords`). `purchaseActs` is the one list that does not, because its entries are verbs
/// and acts whose forms are spelled out. Each word of the text is tried with its
/// singular forms, through `SkillWords.singularCandidates(of:)`, so "Add the IBANs", "Update the
/// cards on file", "Update the account at the banks." and "Update the balance in two currencies." are
/// refused exactly as their singulars are. Money objects have read plurals since PR #241's second
/// scoped round. The other two lists have since SONNY-479: they spelled their plurals out, and the
/// context list missed four of them — banks, IBANs, wires and currencies — while this comment said
/// both lists spelled theirs out. A word listed in the plural has no singular on its list (`funds`,
/// `refunds`, the `… details` phrases), so its singular is not matched — "Update the bank detail."
/// loads — but it is read in the plural like every listed word: "Update the banks details." is
/// refused as `bank details`, and "Move the fundses." as `funds`.
///
/// **An object is refused only beside a listed action verb.** The verb and the object need not be
/// joined: any listed action verb anywhere in the unit is enough, so a money act whose own verb is
/// unlisted is refused when the unit holds a listed one elsewhere ("Open Payouts, then push the
/// funds to the vendor and confirm"). Reading verbs — open, view, find, filter, download, review,
/// export — are not action verbs, so "Filter the payouts and payments by date" and "Download a
/// statement" load. The cost is false refusals ("Run the payments report", "View the charge", "Find
/// the wire"), and a wrong singular adds a few more, since it can only add a match: "Add aches to the
/// log." is refused as `add + ach` (accepted rather than guarded, SONNY-479: no catalogue category
/// writes about aches, and the refusal is loud). Every false refusal surfaces in
/// `everyShippedPackLoadsAndEveryOneIsARowOfTheCommittedCatalogue` before a pack ships.
///
/// **Nouns alone are allowed on purpose.** The phrase list this replaced refused "payee", "payment
/// details" or "refunds" anywhere; this rule refuses them only beside an action verb, so that a flow
/// may read them, which the founders allow.
///
/// **What this cannot guarantee, said plainly.** It is a guard on first-party data that this
/// repository writes and reviews, not a proof that a pack cannot lead Sonny to move money. It does
/// not catch:
/// - **a listed money object whose only verb is unlisted** — "Push the funds to the vendor." and
///   "Allocate the funds to the project." load, because neither verb is listed and nothing else in
///   the flow is;
/// - **a contextual object with no money word beside it** — "Move the balance to savings." loads,
///   because *balance* counts as money only beside one;
/// - **a plural the three suffix rules do not reach** — "Transfer the monies." loads, since no
///   candidate of "monies" is "money" — **and a phrase listed only in the plural, written in the
///   singular** — "Update the bank detail." loads, since only the text's words are read for
///   plurals;
/// - **a money act in words neither list names at all**;
/// - **a flow that reaches a money page through steps that name nothing about money**;
/// - **spellings outside first-party writing** — a zero-width space inside a word, or a Cyrillic
///   letter standing in for a Latin one. **What stands between Sonny and a payment is still the
/// consequence rule**, which asks before an external or destructive action whatever a pack says,
/// and screen control's own per-action classification; a pack can make nothing ask less.
enum SkillPackMoneyRule {
    static let moneyVerbs = SkillPhraseList([
        "pay", "pays", "paying", "refund", "refunding", "reimburse", "reimburses", "reimbursing",
        "withdraw", "withdraws", "withdrawing", "top up", "tops up", "topping up",
        "wire", "wiring", "remit", "remits", "remitting", "disburse", "disburses", "disbursing",
        "cash out", "cashing out", "get paid", "getting paid",
        "wire money", "wire funds", "make a transfer", "send a transfer", "make a deposit"
    ])

    /// Base and "-ing" forms only. The third-person "-s" forms are left out on purpose: most of them
    /// are also plural nouns a reading flow uses ("changes", "updates", "transfers", "charges",
    /// "schedules", "deposits", "links", "funds"), and pack steps are written as instructions.
    static let actionVerbs = SkillPhraseList([
        "add", "adding", "change", "changing", "update", "updating", "replace", "replacing", "edit",
        "editing", "set up", "setting up", "send", "sending", "create", "creating", "submit",
        "submitting", "confirm", "confirming", "initiate", "initiating", "run", "running", "approve",
        "approving", "capture", "capturing", "charge", "charging", "schedule", "scheduling", "make",
        "making", "issue", "issuing", "process", "processing", "execute", "executing", "authorize",
        "authorise", "authorizing", "authorising", "release", "releasing", "fund", "funding", "move",
        "moving", "transfer", "transferring", "remove", "removing", "delete", "deleting", "connect",
        "connecting", "link", "linking", "save", "saving", "deposit", "depositing", "request",
        "requesting", "settle", "settling", "split", "splitting", "tip", "tipping", "forward",
        "forwarding"
    ])

    /// Singulars, each read in the plural too (`violation(in:)`). A plural here is a word with no
    /// singular on the list.
    static let moneyObjects = SkillPhraseList([
        "money", "funds", "payment", "payout", "payroll", "bill", "refunds", "reimbursement",
        "beneficiary", "payee", "iban", "swift code", "bic", "wire", "wire transfer", "ach", "sepa",
        "bank transfer", "bank account", "bank details", "account number", "routing number",
        "sort code", "direct deposit", "card on file", "credit card", "debit card", "payment card",
        "card number", "card details", "billing details", "billing information", "payment method",
        "payment details", "payout account", "payout method", "payout details", "charge",
        // SONNY-506. Both are money objects wherever they appear: postage is bought and never
        // granted, and a billing change is a change to what the user is charged — Dialpad's
        // add-a-user page ends at "Confirm any billing changes and add the user(s)", which held no
        // money object at all before these two.
        "postage", "billing change"
    ])

    /// Ordinary words elsewhere, money objects only beside a money word in the same unit. Singulars,
    /// read in the plural too.
    static let contextualObjects = SkillPhraseList([
        "recipient", "card", "account", "balance", "amount"
    ])

    /// Singulars, read in the plural too — the four this list once left out were banks, IBANs, wires
    /// and currencies (SONNY-479).
    static let moneyContext = SkillPhraseList([
        "bank", "billing", "iban", "transfer", "wire", "payment", "payout", "money", "funds", "currency",
        "invoice"
    ])

    /// Buying, which tests 1 and 2 could not see because both were built for money *movement*
    /// (SONNY-506). These refuse alone, like the money verbs, because a purchase step's own verb is
    /// *click*: "Click Buy Postage" carries no `actionVerbs` entry and a faithful step never will.
    ///
    /// **Every purchase control an earlier test already reaches is deliberately absent**, because a
    /// list entry that can never fire is one a later reader trusts for no reason. "Confirm and pay"
    /// and "Top up" are test 1's, on `pay` and `top up`; "Buy postage" and "Complete the purchase"
    /// are this list's own, on `buy` and `purchase`; "Add funds" is test 2's, as `add + funds`.
    /// `aFlowThatEndsInAPurchaseDoesNotLoad` carries a row for each of the five, which is what keeps
    /// that a measurement rather than an assumption — and what will say so if one stops holding.
    static let purchaseActs = SkillPhraseList([
        "buy", "buys", "buying", "purchase", "purchases", "purchasing",
        "place an order", "place the order", "place your order", "placing an order",
        "proceed to checkout", "go to checkout", "complete checkout"
    ])

    /// Controls that charge on one site and cost nothing on the next, so each counts only beside
    /// `pricedWords` in the same unit. Read in the plural too, like every other noun list here.
    static let purchaseControls = SkillPhraseList([
        "subscribe", "subscribes", "subscribing", "upgrade", "upgrades", "upgrading",
        "renew", "renews", "renewing", "checkout", "check out"
    ])

    /// What names the thing being paid for. A `purchaseControls` word beside one of these is a
    /// purchase; without one it is YouTube's Subscribe button or a Workspace edition called
    /// "Teaching and Learning Upgrade". Deliberately holds neither `checkout` nor `cart`, which are
    /// `purchaseControls` entries and product names — pairing a word with itself would refuse the two
    /// shipped summaries that read "Checkout pages and online sales platform." and "Shopping cart and
    /// checkout pages."
    /// Read in the plural too, so "Compare the plans" names a plan.
    static let pricedWords = SkillPhraseList([
        "plan", "price", "pricing", "cost", "billing", "subscription", "payment", "card", "trial",
        "seat", "per month", "per year", "paid"
    ])

    /// A currency amount — "$500", "€ 20", "500 USD", "20 euros" — which is a money object on its own.
    static let currencyAmount = try! NSRegularExpression(
        pattern: #"[$€£¥₹]\s*\d|\d[\d,.]*\s*(usd|eur|gbp|inr|jpy|cad|aud|chf|dollars?|euros?|pounds?|rupees?)(?![a-z])"#
    )

    /// What in `texts` moves or spends money — a money verb, a purchase act, "verb + object", or a
    /// purchase control beside a price — or `nil` when nothing does.
    ///
    /// The order is the order the doc comment states, and it is what keeps a refusal's wording
    /// stable: a unit that was refused before SONNY-506 is refused by the same test, in the same
    /// words, because tests 3 and 4 can only add a refusal to a unit that had none.
    static func violation(in texts: [String]) -> String? {
        let units = texts.map(SkillWords.init)
        if let verb = moneyVerbs.first(in: units) {
            return verb
        }
        if let action = actionVerbs.first(in: units) {
            if let object = moneyObjects.first(in: units, readingPlurals: true) {
                return "\(action) + \(object)"
            }
            if units.contains(where: hasCurrencyAmount) {
                return "\(action) + an amount"
            }
            if let object = contextualObjects.first(in: units, readingPlurals: true),
               moneyContext.first(in: units, readingPlurals: true) != nil || units.contains(where: hasCurrencyAmount) {
                return "\(action) + \(object)"
            }
        }
        if let act = purchaseActs.first(in: units) {
            return act
        }
        if let control = purchaseControls.first(in: units, readingPlurals: true),
           let priced = pricedWords.first(in: units, readingPlurals: true) {
            return "\(control) + \(priced)"
        }
        return nil
    }

    private static func hasCurrencyAmount(_ unit: SkillWords) -> Bool {
        currencyAmount.firstMatch(in: unit.folded, range: NSRange(unit.folded.startIndex..., in: unit.folded)) != nil
    }
}

/// **No pack carries, asks for or types a credential** (SONNY-452's "Must not change"). Read over
/// every text field of every pack, as whole words, folded — with one case-sensitive word, `PIN`,
/// because the lowercase word is how chat tools say they keep a message at the top.
///
/// **One word reads its neighbours, and only one: `secret`** (SONNY-508). Pinterest's board privacy
/// toggle is named "Keep board secret", so the rule refused a flow for naming a real control, and the
/// pack dropped the clause rather than inventing a label nobody could find. `secret` and `secrets`
/// are therefore excused when — and only when — the word sits **immediately** beside one of
/// `privacyObjects`, the things a site makes private. Everything else about the rule is unchanged,
/// and the shape is fail-closed three times over:
/// - **every** occurrence in the text must be excused, or the word refuses. "Keep the board secret
///   and paste the API secret." is refused on the second one.
/// - **immediately** beside, with spaces alone between the two words. Not merely in the same
///   sentence — "Paste the secret into the chat." is refused, though it names a chat — and **not
///   across a boundary either**: "Copy the client ID and the secret. Boards are listed on the left."
///   is refused, because the full stop means `boards` is not beside anything.
/// - **only `secret`.** The other collision-capable words — `passcode`, `2fa`, `mfa`, the cased
///   `PIN` — keep refusing outright until a lane measures a real control named by one, which is
///   **SONNY-514** and opens with nothing to do until somebody does (founders, 2026-09-17).
///   Widening a rule for a collision nobody has hit is how it stops meaning anything.
///
/// This is SONNY-492's answer to the same question in the trigger check, where everyday words the
/// system word list lacked — box, podia, expo, grok, luma — were taught to the check rather than
/// avoided by the packs. A flow that names a control the user cannot find is worse than no flow.
///
/// **What this cannot guarantee.** Like the money rule, it is a guard on first-party wording: a step
/// can lead to a sign-in page without naming a credential. What refuses to type one is the planner
/// prompt's own rule, which `SkillGuidance.header` restates above every pack.
enum SkillPackCredentialRule {
    static let phrases = SkillPhraseList([
        "password", "passwords", "passcode", "passcodes", "passphrase", "passphrases", "credential",
        "credentials", "login details", "pin code", "pin number", "api key", "api keys", "api token",
        "api tokens", "access token", "access tokens", "auth token", "auth tokens", "bearer token",
        // `secret` and `secrets` are not here: `secretViolation(in:)` reads them, because whether
        // they are a credential depends on the word beside them (SONNY-508). They are checked first,
        // so a credential step is still refused on the same word it was before.
        "refresh token", "secret key", "secret keys", "client secret",
        "private key", "private keys", "verification code", "verification codes", "one time code",
        "one time codes", "one time password", "one time passwords", "otp", "otps", "two factor code",
        "two factor codes", "2fa", "mfa", "authentication code", "authentication codes",
        "security code", "security codes", "recovery code", "recovery codes", "backup code",
        "backup codes",
        // PR #241's delta round: a password by another name, a bare token that is yours, and the
        // code a sign-in sends you.
        "login and pass", "username and pass", "user name and pass", "email and pass",
        "your token", "the token", "a token", "code we emailed", "code we sent", "code we texted",
        "code sent to your", "code from your email", "code from the email", "code from your phone",
        "authenticator app", "authenticator code", "6 digit code", "six digit code", "4 digit code"
    ])

    static let casedWords: Set<String> = ["PIN", "PINs"]

    /// URL query and fragment names that carry a credential.
    static let urlNames: Set<String> = [
        "token", "access_token", "id_token", "refresh_token", "api_key", "apikey", "key", "password",
        "pass", "secret", "client_secret", "code", "otp", "auth", "sig", "signature"
    ]

    /// The things a site makes private, which is the only company `secret` may keep (SONNY-508).
    /// Pinterest's "Keep board secret" is the measured one; the rest are the same control on sites
    /// this repository has not written a pack for yet.
    static let privacyObjects: Set<String> = [
        "board", "boards", "group", "groups", "chat", "chats", "conversation", "conversations",
        "gist", "gists", "album", "albums"
    ]

    static func violation(in text: String) -> String? {
        let unit = SkillWords(text)
        if let secret = secretViolation(in: unit) {
            return secret
        }
        if let phrase = phrases.first(in: [unit]) {
            return phrase
        }
        return unit.casedWords.first { casedWords.contains($0) }
    }

    /// `secret` or `secrets` when it is a credential here, `nil` when every occurrence of both names
    /// a thing a site makes private.
    ///
    /// Read before `phrases` so that a credential step is refused on the word it has always been
    /// refused on — "Paste the client secret." still answers `secret`, not `client secret`.
    private static func secretViolation(in unit: SkillWords) -> String? {
        for spelling in ["secret", "secrets"] {
            let occurrences = unit.words.indices.filter { unit.words[$0] == spelling }
            guard !occurrences.isEmpty else { continue }
            let everyOneNamesAThing = occurrences.allSatisfy { index in
                namesAThing(before: index, in: unit) || namesAThing(after: index, in: unit)
            }
            if !everyOneNamesAThing {
                return spelling
            }
        }
        return nil
    }

    /// Whether the word before `index` is one of `privacyObjects` **and** is joined to it by spaces
    /// alone. The second half is what stops a full stop from supplying the excuse (review-268's F1).
    private static func namesAThing(before index: Int, in unit: SkillWords) -> Bool {
        guard index > 0, unit.joinedToPrevious[index] else { return false }
        return privacyObjects.contains(unit.words[index - 1])
    }

    /// The same, for the word after `index`: it must be joined to *it*, which is the same array read
    /// one place along.
    private static func namesAThing(after index: Int, in unit: SkillWords) -> Bool {
        let next = index + 1
        guard next < unit.words.count, unit.joinedToPrevious[next] else { return false }
        return privacyObjects.contains(unit.words[next])
    }

    /// Whether a URL names a credential in its query or its fragment. A fragment is read as
    /// `name=value` pairs separated by `&`, which is how an implicit-grant sign-in hands a token
    /// back (`#access_token=…`), and it is the half of a URL a query-only check never sees.
    static func urlCarriesCredential(_ components: URLComponents) -> Bool {
        let queryNames = (components.queryItems ?? []).map(\.name)
        let fragmentNames = (components.fragment ?? "")
            .split(separator: "&")
            .compactMap { pair in pair.split(separator: "=", maxSplits: 1).first.map(String.init) }
        return (queryNames + fragmentNames).contains { urlNames.contains($0.lowercased()) }
    }
}
