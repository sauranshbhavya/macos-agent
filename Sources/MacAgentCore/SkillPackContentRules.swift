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

    init(_ text: String) {
        folded = SearchText.normalized(text)
        words = Self.cut(folded)
        casedWords = Self.cut(text)
    }

    static func cut(_ text: String) -> [String] {
        text.split { !($0.isLetter || $0.isNumber) }.map(String.init)
    }

    func contains(_ phrase: [String]) -> Bool {
        guard !phrase.isEmpty, phrase.count <= words.count else { return false }
        for start in 0...(words.count - phrase.count) where Array(words[start..<start + phrase.count]) == phrase {
            return true
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

    func first(in texts: [SkillWords]) -> String? {
        phrases.first { phrase in texts.contains { $0.contains(phrase.words) } }?.spelling
    }
}

/// **No flow moves money, in any pack, whatever its category** (founders, 2026-09-13 on SONNY-452),
/// read off a pack's wording as well as a first-party check can.
///
/// **What it reads.** A flow's title and steps together, the pack's summary, and each of its
/// sections, because all of them reach the planner. A flow is read as one unit, since its money act
/// is often split between a title ("Create a payout") and a step ("Click Confirm").
///
/// **How it decides — two tests, either of which refuses:**
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
///    Trello board, an *account*, a *balance* — and count only when the same unit also names money
///    (bank, billing, payment, payout, transfer, IBAN, money, funds, an amount).
///
/// **It fails closed on the object only beside a listed action verb.** A money verb nobody listed is
/// refused once its object sits in the same unit as any listed action verb, and reading verbs — open,
/// view, find, filter, download, review, export — are not action verbs, so "Filter the payouts and
/// payments by date" and "Download a statement" load. The cost is false refusals ("Run the payments
/// report", "View the charge", "Find the wire"), which surface in
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

    static let moneyObjects = SkillPhraseList([
        "money", "funds", "payment", "payments", "payout", "payouts", "payroll", "bill", "bills",
        "refunds", "reimbursement", "reimbursements", "beneficiary", "beneficiaries", "payee", "payees",
        "iban", "swift code", "bic", "wire", "wires", "wire transfer", "ach", "sepa", "bank transfer",
        "bank transfers", "bank account", "bank accounts", "bank details", "account number",
        "routing number", "sort code", "direct deposit", "card on file", "credit card", "credit cards",
        "debit card", "debit cards", "payment card", "card number", "card details", "billing details",
        "billing information", "payment method", "payment methods", "payment details",
        "payout account", "payout method", "payout details", "charge", "charges"
    ])

    /// Ordinary words elsewhere, money objects only beside a money word in the same unit.
    static let contextualObjects = SkillPhraseList([
        "recipient", "recipients", "card", "cards", "account", "accounts", "balance", "balances",
        "amount", "amounts"
    ])

    static let moneyContext = SkillPhraseList([
        "bank", "billing", "iban", "transfer", "transfers", "wire", "payment", "payments", "payout",
        "payouts", "money", "funds", "currency", "invoice", "invoices"
    ])

    /// A currency amount — "$500", "€ 20", "500 USD", "20 euros" — which is a money object on its own.
    static let currencyAmount = try! NSRegularExpression(
        pattern: #"[$€£¥₹]\s*\d|\d[\d,.]*\s*(usd|eur|gbp|inr|jpy|cad|aud|chf|dollars?|euros?|pounds?|rupees?)(?![a-z])"#
    )

    /// What in `texts` moves money — a money verb, or "verb + object" — or `nil` when nothing does.
    static func violation(in texts: [String]) -> String? {
        let units = texts.map(SkillWords.init)
        if let verb = moneyVerbs.first(in: units) {
            return verb
        }
        guard let action = actionVerbs.first(in: units) else {
            return nil
        }
        if let object = moneyObjects.first(in: units) {
            return "\(action) + \(object)"
        }
        if units.contains(where: hasCurrencyAmount) {
            return "\(action) + an amount"
        }
        if let object = contextualObjects.first(in: units),
           moneyContext.first(in: units) != nil || units.contains(where: hasCurrencyAmount) {
            return "\(action) + \(object)"
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
/// **What this cannot guarantee.** Like the money rule, it is a guard on first-party wording: a step
/// can lead to a sign-in page without naming a credential. What refuses to type one is the planner
/// prompt's own rule, which `SkillGuidance.header` restates above every pack.
enum SkillPackCredentialRule {
    static let phrases = SkillPhraseList([
        "password", "passwords", "passcode", "passcodes", "passphrase", "passphrases", "credential",
        "credentials", "login details", "pin code", "pin number", "api key", "api keys", "api token",
        "api tokens", "access token", "access tokens", "auth token", "auth tokens", "bearer token",
        "refresh token", "secret", "secrets", "secret key", "secret keys", "client secret",
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

    static func violation(in text: String) -> String? {
        let unit = SkillWords(text)
        if let phrase = phrases.first(in: [unit]) {
            return phrase
        }
        return unit.casedWords.first { casedWords.contains($0) }
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
