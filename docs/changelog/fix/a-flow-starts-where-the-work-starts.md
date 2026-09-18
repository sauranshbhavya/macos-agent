### Branch: fix/a-flow-starts-where-the-work-starts
Status: complete — holding for its one hop onto `main` (it merges last in wave 12)
Date: 2026-09-18
Tickets: SONNY-510. A flow's start page is now recorded where it lands for a signed-out visitor, and the loader refuses a pack whose record is missing, lands off the site (except on a named identity host), names account creation, or says the page was anything but a sign-in page or the product itself. All 181 distinct start URLs were read in a browser in the first round. In the second, every sign-in record was judged again under the founders' final rule, including their three decisions of 2026-09-18. SONNY-524 keeps one question, which is now about provenance only.
Reviewed by: review-272 on PR #272, a fresh session's deep adversarial pass at `6dbe1250`.
- **Two blocking findings:** the branch's definition of `sign-in` contradicted the founders' ruling, and the eleven Google records described a page a fresh profile never sees.
- **Three cheap ones:** the sign-in host admitted any `offers` word; the declared URL's query was never read; and the bare-origin sentence claimed more than its command measured.
- **Corrections to this entry.**

All are resolved in the second round, as are the founders' three decisions on the questions the first version of this round raised. A scoped delta pass is owed after the hop.

Spec sections covered: none directly. This is the skills catalogue's evidence rule (SONNY-461, SONNY-463), not a spec surface.
Files changed:
- `Sources/MacAgentCore/SkillPackStartPages.swift`: new. `SkillPackStartPage`, `SkillPackStartPageOffer` and `SkillPackStartPageRule`, with the rule stated once in the first type's doc comment and the identity-host list stated at the list.
- `Sources/MacAgentCore/SkillPack.swift`: `startPages` on the struct, seven load errors, the decoder, and `isOnSite(host:domain:)` extracted so the declared-start check and the landing check share one definition. The declared check's behaviour is unchanged.
- `Tests/MacAgentCoreTests/SkillPackTests.swift`: nine new tests, and two existing controls given a matching record. Eight arrived in the first round. The second round added its cases inside three of them and wrote one more, `everyIdentityHostIsOneAShippedStartPageLandsOn`.
- `Tests/MacAgentTestSupport/SkillPackFixtures.swift`: a deep fixture pack carries a matching record, plus `startPage(…)`.
- `Sources/MacAgent/Resources/SkillPacks/*.skillpack.json`: deep packs only, all 164 of them at `0d645464`.
- `mutation/plans/fix/a-flow-starts-where-the-work-starts.txt`.
Tests: the flagged `swift test` command from `CLAUDE.md` → exit 0, `Test run with 3455 tests in 250 suites passed after 96.369 seconds with 8 known issues` at `1781b665`, clean tree. It started at 19:42:16Z with no Swift compiler or test process running anywhere on the machine and a one-minute load of 3.47, and no other worktree was building when it ended. Every one of the nine new tests prints one `started` and one `passed` line in that log; its 7 skip lines are environment gates, none Skill-related. `scripts/warnings` → exit 0, `measured at : 1781b665 (clean)`, `0 warnings`. The Skills suites under `--filter 'SkillPack|Skill'` → exit 0, `Test run with 74 tests in 5 suites passed after 7.529 seconds`, over the tree committed as `1781b665`.
Mutation plan: mutation/plans/fix/a-flow-starts-where-the-work-starts.txt (founder-triggered, not run on this branch). It has 22 mutants.
- M1 returns the check to the own-domain test alone, and M2 accepts a landing on another host.
- M3–M12 narrow each of the rule's other parts, or widen the one refusal every Google pack depends on.
- M13–M15 undo the second round's three checks.
- K3, K4, K5 and D1 are review-272's own probes. K4 has the parser read the declared URL as the landing. D1 is a data mutant that moves the shipped `google_ads` landing to `business.google.com`.
- I1–I3 hold the identity-host list: a host that forgets which sites it signs in for, a host nobody read (review-272's `business.google.com`), and a host the sweep found, dropped.
- **What a plan of this shape cannot do.** Every mutant deletes or narrows a guard that exists, so none can find a guard that was never written. Review-272's F3 and F4 were absent code, and only probing the rule from outside found them. The plan's header says so.

Behavior added:
- **Every deep pack carries `startPages`.** There is one record per distinct start URL, holding:
  - the landed URL, with no query, no query inside its fragment, and no per-visit path segment;
  - the title, once it has settled;
  - the first heading a visitor can see;
  - `offers`, which is `sign-in` or `product`;
  - the date read.
  A pack with flows that leaves it out gets `missingField("startPages")`. A shallow pack owes none.
- **The loader refuses:**
  - a flow whose start URL has no record, a record no flow uses, and two records for one URL;
  - a landed URL with a query, including one inside its fragment (`#/login?redirect=/`);
  - a landing that is neither on the pack's own site nor, for a record that says `sign-in`, on a listed identity host that signs in for the pack's site (shape 2, `ads.google.com/` → `business.google.com`, whatever the pack's `signInURL` says);
  - a declared or landed URL that names account creation in its path, fragment or query (shape 1, Ghost's `/signup`, and `?mode=signup` or Auth0's `?screen_hint=signup` on the declared URL);
  - any `offers` word but the two (shapes 3, 4 and 5).
- **The identity hosts are named in code, and `signInURL` is not read by the rule at all** (the founders' decision C, SONNY-524's option 2).
  - `SkillPackStartPageRule.identityHosts` holds nine hosts, each with the sites it signs in for. It was built from the second round's sweep, which found 19 landings off their pack's own site, every one `sign-in`:
    - `accounts.google.com` for `google.com` and `youtube.com`;
    - `login.microsoftonline.com` for `office.com` and `microsoft.com`;
    - `login.live.com` for `live.com`;
    - `id.atlassian.com` for `trello.com`;
    - `app.frontapp.com` for `front.com`;
    - `app.notion.com` for `notion.so`;
    - `authenticator.cursor.sh` for `cursor.com`;
    - `identity.getpostman.com` for `postman.com`;
    - `carrd.com` for `carrd.co`.
  - The deciding property is the failure direction. A landing on an unlisted host refuses the pack, and somebody sees it. The old allowance read the pack's own `signInURL`, which its author writes in the same file, so a wrong value admitted a bad landing silently, which is how review-272 loaded a Google Ads pack naming `business.google.com`.
  - Each host is paired with its sites, so Google's sign-in host admits a Google pack and not Notion's. That is one step stricter than a flat list, and it is the same fail-closed direction.
  - `everyIdentityHostIsOneAShippedStartPageLandsOn` holds the list to exactly the population that uses it. The doc comment says how a real new identity host is added.
- **The sign-in rule, as the founders settled it on 2026-09-18.** A start page is acceptable when the form on it signs in an account that already exists and the site has a separate route for creating one. It is not acceptable when that same form is also how an account gets created, whatever words sit beside it. A terms line is evidence, not the test, and a cookie notice is never relevant. The separate route is read at the page, and a page that shows none is held. There are two further grounds, both in the doc comment with their reasoning:
  - **Decision A: a product with no self-serve sign-up anywhere passes**, because an admin or a sales team creates every account. The visible route was a proxy for "this form cannot create an account", and on such a product the proxy reads backwards. So the check is of the site, not the sign-in page: self-serve sign-up anywhere, hidden by the sign-in page, is tl;dv's shape and holds it.
  - **Decision B: a biometric or recording consent bound to the sign-in control holds the page**, whatever its sign-up route. It is narrow, biometric and recording consent only, because it is a separate ground the account-creation rule is blind to.
  - A record's heading is the first one a visitor can see, not the first in the document (the ticket, 17:23Z).
- **The first round's sweep, over the whole population the rule governs.** That was 181 distinct start URLs used by 427 flows in 164 deep packs at `0d645464`, of which 300 flows across 116 packs started at a bare origin. Each was read signed out. The outcome:
  - 132 were kept: they landed on a sign-in page (120) or on the product itself (12).
  - 38 were replaced by the catalogue row's `sign_in_url` or an on-site sign-in path, and every replacement was read too.
  - 15 packs had `signInURL` corrected to the identity host their start page lands on. Those are five Google products, four Microsoft ones, Carrd, Cursor, Notion, Postman, v0 and Google Ads.
  - 11 start URLs had no admissible start page, so ten packs went shallow: claude, growthbook, microsoft, onedrive, zoho_desk, greenhouse, midjourney, n8n, pinterest and shipstation.
- **The second round's re-judgement: all 155 `sign-in` records at `6dbe1250`, read again signed out, under the final rule.** 138 pass and 17 are held. Each held record's pack goes shallow when it was the pack's only start page, which is 15 packs, and otherwise loses that flow, which is Luma and Perplexity. 41 flows went in all. The held records, each with the site and the reason:
  - **One form for both, and the page says so** (6):
    - Amplitude, "Log in or Sign up".
    - Canva, "Log in or sign up in seconds".
    - Dropbox, "Log in or sign up for free".
    - Luma's `/signin`, "Please sign in or sign up below".
    - Manus, "Sign in or sign up".
    - Twenty, whose title is "Sign in or Create an account".
  - **The same form is how the account gets created** (9):
    - Airtable shows no sign-up route, and "By signing up, you agree" sits on this form.
    - Attio: every "Start for free" on attio.com points at this same sign-in page.
    - Framer: framer.com's "Sign up" lands on this same `/login/`.
    - HeyGen: every "Get started for free" on heygen.com points at `auth.heygen.com/`.
    - Synthesia shows no sign-up route, and its welcome form says "By signing up to the Synthesia platform".
    - v0's page says "By proceeding, you agree to creating a Vercel account".
    - Fireflies is single sign-on only, with no sign-up route and a consent to record the visitor's voice. It is the founders' named hold, and decision B holds it too.
    - Microsoft Copilot is single sign-on only (Microsoft, Apple, Google), with no sign-up route.
    - Perplexity's `/library` has one Continue for both and no sign-up route.
  - **No sign-up control on the page, and self-serve sign-up elsewhere on the site** (1): BambooHR. Its sign-in page asks only for a company domain, while `bamboohr.com/signup/` offers a free trial that creates an account ("Your account is ready", no credit card).
  - **Biometric consent bound to the sign-in control** (1): Runway. "By clicking “Continue” or “Log in”, you agree that we and our vendors may scan faces or capture voiceprints…"
- **Decision A, checked site by site, on 2026-09-18.** Every site was read signed out, homepage first, then its pricing page and any sign-up URL.
  - **Affinity passes.** The homepage offers "Contact us" and "Pricing". All three plans ($2,000 to $2,700 per user per year) say "Contact sales". `affinity.co/signup` redirects to `/request-demo`, and `app.affinity.co/signup` goes back to the sign-in page.
  - **Ashby passes.** It offers "Log in" and "Get in Touch", which goes to `/request-demo`. Its $400/month plan says "Get in Touch", and `app.ashbyhq.com/signup` does not load.
  - **Birdeye passes.** It offers "Watch Demo", "See Enterprise Pricing" and "Contact Us". The pricing page names no trial or free plan, and `birdeye.com/signup/` is a 404.
  - **Lever passes.** It offers "Request Demo", "Get a Demo", "Get My Price Quote" and "Contact Us", and `lever.co/signup` is a 404.
  - **Pylon passes.** It offers "Book a demo" and "Talk to Us" ("Register Now" is for a webinar). `/pricing` redirects to "Book a Demo", and `app.usepylon.com/signup` goes back to the sign-in page.
  - **BambooHR is held**, as above.
  - **The holds that rested on a missing route were confirmed against the same test**, since each would pass if its site offered no self-serve sign-up:
    - Airtable: "Sign up for free" goes to `airtable.com/signup`.
    - Synthesia: a Basic plan at "$0/mo, No credit card required", whose "Try for FREE" goes to the held page itself.
    - Fireflies: "Try Fireflies For Free" goes to the held page itself.
    - Microsoft Copilot: `login.live.com` offers "Create an account".
    - Perplexity: its homepage's "Sign In" opens "Sign up below to unlock the full potential of Perplexity".
  - **Claude stays shallow on its merits**, not because of the profile. `claude.com/pricing` offers a Free plan, "$0, Free for everyone", whose "Try Claude" goes to claude.ai's log-in page. And the coordinator's reading of that log-in page listed no sign-up control.
- **Decision B, checked across the population.** All 119 distinct landings of the 139 sign-in records (the 134 passes and the five restored) were scanned signed out for text naming biometric capture or recording. The scan read each text node and whether it was visible. Runway's is the only one.
  - Loom's only consent line is "By signing up, you acknowledge that you have read and understood, and agree to Atlassian's Terms and Privacy Policy", a terms line, so Loom passes.
- **Records kept and changed in the second round:**
  - **The eleven Google records** (F2): gmail, google ×2, google_ads, google_business_profile, google_meet, google_search_console, googledocs, googledrive, googlesheets and youtube_studio. Each now lands on `accounts.google.com/v3/signin/identifier`, heading "Sign in", read in a profile confirmed to hold no remembered account.
  - **Two landings now carry their fragment route**: Zoom's `/signin` → `zoom.us/signin#/login`, and SurveyMonkey → `auth-us.surveymonkey.com/login#/login`.
  - **Eight headings changed under the visible definition:**
    - Cloudinary had OneTrust's hidden "Privacy Preference Center" and now records none.
    - Crunchbase's "Log In" is screen-reader-only (clip `rect(0,0,0,0)`), so it now records none.
    - OpenRouter's two "Models" headings are both screen-reader-only (1×1, `clip-path: inset(50%)`), so it now records none.
    - Perplexity's only heading is a hidden "Cookie Policy", so it now records none.
    - Gemini: "Conversation with Gemini" is hidden, and "Meet Gemini, your personal AI assistant" is what shows.
    - LinkedIn: "0 notifications" is hidden, and "Sign in" is what shows.
    - Shopify: "You are offline" is hidden, and "Log in" is what shows.
    - Birdeye: both "Sign in easily" headings are hidden, and "AI Coworkers for Multi-location Brands" is what shows. It is recorded as the page's text reads, without the space.
  - **Two headings the first reader had cut at 50 characters:**
    - Productboard's is now whole.
    - DeepL's first `h1` is screen-reader-only, so its heading is the next one down the page, "Trusted by over 200,000 businesses globally".
  - **DeepL's title is the one it settles on**: "DeepL Translator | World's Most Accurate Translator". Read six times about two seconds apart, it showed "DeepL Translate: The world's most accurate translator" once, at about three seconds, and the settled title on every other read.
  - **Product Hunt's heading** is its current promotion, "See what builders are making with GPT-6 Astra". The page changed since the first reading.
  - **Manychat** was re-read rather than judged from the first round's text. Its "Sign up" link opens `app.manychat.com/signup`, a page of its own.
- **The dates.** 147 of the 150 records say `2026-09-18`. The other three keep `2026-09-17`: Luma's `/create`, Mistral's product page and Outlook Calendar. Each records no heading, so the heading re-read did not reach them, and Outlook Calendar was judged from the same Microsoft page as Outlook's.
- **This branch removes a lot, deliberately, and that is the rule working rather than damage.**
  - On its base, the tree goes from **164 deep packs to 139** and from **427 flows to 362**.
  - The first round is 10 packs and 24 flows of that. This round is 15 packs and 41 flows.
  - Every one of the 25 packs keeps its name, domain, triggers, sections and sign-in page, and loses only task steps that began on a page a flow may not start on. Each is named above or on SONNY-510 with its reason.
- **Where the population stands now**, at `1781b665`:
  - 139 deep packs, 362 flows and 150 records (138 `sign-in`, 12 `product`).
  - 178 flows across 70 packs start at a bare origin. Of those, 162 land on a page recorded `sign-in` and 16 on one recorded `product`, the 16 being across 8 packs: bolt, chatgpt, gemini, grok, mistral_le_chat, perplexity, product_hunt and zoom.
  - At `6dbe1250` the same join gives 197 = 181 + 16, where this entry once said all 197 landed on a sign-in page (F5).
  - The commands, run from the repository root:
    - `python3 -c "import json,glob;from urllib.parse import urlsplit as u;P=[json.load(open(p)) for p in glob.glob('Sources/MacAgent/Resources/SkillPacks/'+'*.skillpack.json')];B=[(d['id'],f) for d in P for f in d['flows'] if u(f['startURL']).path in ('','/') and not u(f['startURL']).query and not u(f['startURL']).fragment];print(len(B),len({i for i,_ in B}),sum(len(d['flows']) for d in P),sum(d['depth']=='deep' for d in P))"` prints `300 116 427 164` over a `git archive 0d645464` of the packs folder, `197 77 403 154` over `6dbe1250`'s and `178 70 362 139` over `1781b665`'s.
    - The join, `python3 -c "import json,glob;from urllib.parse import urlsplit as u;from collections import Counter;P=[json.load(open(p)) for p in glob.glob('Sources/MacAgent/Resources/SkillPacks/'+'*.skillpack.json')];O={(d['id'],s['url']):s['offers'] for d in P for s in d.get('startPages',[])};B=[O[(d['id'],f['startURL'])] for d in P for f in d['flows'] if u(f['startURL']).path in ('','/') and not u(f['startURL']).query and not u(f['startURL']).fragment];print(len(B),dict(Counter(B)),dict(Counter(O.values())),len(O))"`, prints `197 {'sign-in': 181, 'product': 16} {'sign-in': 155, 'product': 12} 167` over `6dbe1250`'s and `178 {'sign-in': 162, 'product': 16} {'sign-in': 138, 'product': 12} 150` over `1781b665`'s.
  - Shallow packs carry no flows, so the scan finding none in them is a real answer.

Behavior preserved (required, no blanket claims):
- **The own-domain check on a declared `startURL`** is byte-for-byte the same rule. It moved into `isOnSite(host:domain:)`, and `aFlowWhoseStartPageIsOnAnotherSiteDoesNotLoad` still holds both directions: `evil.example.org` and `notnotion.so` are refused, the domain and a subdomain load.
- **`signInURL` is still decoded, still optional and still rendered into guidance** as "Sign-in page: …". Only the start-page host rule stopped reading it.
- **The money and credential rules** read the same texts as before. `startPages` is not in `guidance`, so what reaches the planner is unchanged except where a start URL or a `signInURL` changed, and where a pack went shallow and lost its flows.
- **The guidance byte ceiling** is unaffected, because the records are not guidance. Every pack still loads under 6,000 bytes: `everyShippedPackLoads…` passes at `1781b665`.
- **Shallow packs**: all 309 that were shallow at `0d645464` are untouched. 334 are shallow at `1781b665`: those 309, the ten made shallow in the first round and the 15 in the second. Measured by a `json.load` walk over a `git archive` of each head's packs folder, counting `depth == 'shallow'`. This corrects the first round's "none of the 319 shallow files changed", which counted the ten it had made shallow itself.
- **The five packs restored under decision A** are byte-identical to `6dbe1250` except their `read` date and Birdeye's heading.
- **No flow's title, steps or source changed, and no pack field outside `flows`, `startPages` and `depth` changed in the second round.** That comes from a field-by-field comparison of every pack between the two heads' archives. `docs/sonny-skill-sites.tsv` is byte-identical to `0d645464`'s (`git diff --quiet 0d645464 1781b665 -- docs/sonny-skill-sites.tsv` exits 0).
- **`SkillPackFixtures.catalogue()`** still builds Docusign, Linear and Notion through the real loader. The Command Center Skills tests pass unchanged.

Architectural decisions / pitfalls discovered (required, write "none" if true):
- **The record lives in the pack, and the loader checks it.** A shared file of landings would be one file that every pack lane appends to, which is the coupling SONNY-500 removed. The catalogue TSV was ruled out for the same reason and because three wave-12 lanes hold its rows. The reasoning is on SONNY-510's first implementing comment, posted before any code was written.
- **The host rule names identity hosts in code, and the 15 `signInURL` corrections no longer matter to it.**
  - The first round corrected 15 packs' `signInURL` to the identity host their start page lands on. That put them at odds with their catalogue rows: `python3 -c "import json,glob,csv;R={r['id']:r['sign_in_url'] or None for r in csv.DictReader(open('docs/sonny-skill-sites.tsv'),delimiter='\t')};print(sum((json.load(open(p))['signInURL'] or None)!=R[json.load(open(p))['id']] for p in glob.glob('Sources/MacAgent/Resources/SkillPacks/'+'*.skillpack.json')))"` prints `0` over `0d645464`'s packs and catalogue, and `15` at `1781b665`.
  - Since decision C, nothing in the loader reads `signInURL` for that rule. So which value is right is a provenance question only, and it is SONNY-524's.
- **The browser this lane had is not a clean profile, and each reading says what it was.**
  - The Chrome extension holds a claude.ai session of its own: `claude.ai/login` lands on `/new`, checked again at about 17:45Z on 2026-09-18, reading the path only.
  - In the first round the profile also remembered a signed-out Google account. Google sign-ins landed on `/v3/signin/accountchooser`, and the first entry wrongly called that "the same sign-in page". It is not: the chooser lists a remembered identity, and the identifier page does not.
  - Before the second round read anything, and again before its heading re-read began, `accounts.google.com` landed on `/v3/signin/identifier` with no account listed, and `github.com` showed a "Sign in" link and no signed-in user.
- **A heading has to be read for visibility, and the obvious tests are wrong in both directions:**
  - The window was not on screen throughout (`document.visibilityState` was `hidden`). So a card that fades in, by CSS animation (Clerk) or by script (Discord's `animatedDiv`), sat at opacity 0, and an opacity test called both headings hidden. Opacity is therefore not read.
  - A screen-reader-only heading has rendered area, so the coordinator's three conditions (area, `display`, `visibility`) count it as visible. The clip is checked too: Crunchbase's `rect(0,0,0,0)`, and DeepL's and OpenRouter's 1×1 `inset(50%)`.
  - Salesforce's first `h1` is empty, so the heading is the first visible one that carries text.
  - The first round's reader cut headings at 50 characters, and two records carried the cut.
- **Browser-reading pitfalls, each measured here:**
  - The extension's output filter replaces any JavaScript result containing a query string with `[BLOCKED: Cookie/query string data]`, so read `origin + pathname`, plus the fragment up to its `?`.
  - `browser_batch` has a wall-clock ceiling of roughly 30 seconds, and a slow navigation inside it times out the whole call.
  - A redirect that lands after a read began kills it with "Inspected target navigated". The answer is to re-read the page, not to trust the half-read. The consent scan finally waited for the tab to reach the recorded landing before reading anything, which also rules out the stale read below.
  - Three agents sharing one Chrome made every tab a background tab, which produced 45-second renderer freezes. One tab read about five times faster.
  - The stale-read trap happened: Pylon's delayed redirect surfaced in the next page's read. Apollo's second hash route, opened straight from its first, stayed on `#/sequences` with nothing rendered, because a hash change is not a load; leaving the site and coming back read it. And Ashby's first consent read ran before its redirect to `/signin`.
  - The catalogue's `sign_in_url` can be dead: Midjourney's answers a 404 page.
- **The rule's own time cost.** The first round ran well past the ninety-minute stop without stopping to report at a green point. The second ran past it too: at about three hours, with two clarifications newly posted on the ticket, the lane stopped and asked, and the founder chose to apply both then. The founders' three decisions came after that round was pushed and were applied in the same branch before the hop. All of it is recorded on SONNY-510.

Known limitations / deferred scope:
- **What `offers` means is a person's judgement.** The loader holds only the two words it may be written in. A site that changes after its reading is not noticed, and `read` says how old each record is.
- **Whether a single sign-on button creates an account the first time an unknown identity presses it cannot be seen from outside.** Every judgement here rests on the visible route, on what the site offers, and on what the page says. None was tested by pressing anything.
- **The consent scan reads words, not meaning.** It looks for biometric and recording terms in the page's own document. Text inside a cross-origin frame or a shadow root is not read, and a consent worded outside those terms needs a person's reading. It found Runway's, the one case already known, which is the control that it can find one.
- **Signed-in landings were not read.** Where a flow was already correct signed out, its start URL was kept rather than swapped, so a signed-in user's landing does not move for no measured reason. The manual-test file's last row is the one reading of the signed-in case.
- **The 25 packs made shallow** are named above and on SONNY-510 with the reason. Restoring any of them means a pack lane reading a start page that passes the rule.
- **Readings go stale at each hop.** Records for packs landed by other wave-12 lanes are owed at this branch's hop, because the loader refuses their flows until then, and they are read under the final rule above. That is expected, and it is on the ticket.

Open questions (required, write "none" if true):
- **Should a pack's `signInURL` equal its catalogue row's `sign_in_url`?** 15 differ. After decision C the answer changes no loader behaviour, so it is a provenance question only. It is SONNY-524's.

Next branch: none named. SONNY-507's open half, whether a catalogue cell is checked for a bad seed, is the neighbouring question.
