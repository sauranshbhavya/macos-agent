### Branch: fix/a-flow-starts-where-the-work-starts
Status: complete — holding for its one hop onto `main` (it merges last in wave 12)
Date: 2026-09-18
Tickets: SONNY-510. A flow's start page is now recorded where it lands for a signed-out visitor, and the loader refuses a pack whose record is missing, off the site, names account creation, or says the page was anything but a sign-in page or the product itself. All 181 distinct start URLs were read in a browser in the first round, and in the second every sign-in record was judged again under the founders' reconciled rule. SONNY-524 holds the one open question.
Reviewed by: review-272 on PR #272, a fresh session's deep adversarial pass at `6dbe1250`. It raised two blocking findings: the branch's definition of `sign-in` contradicted the founders' ruling, and the eleven Google records described a page a fresh profile never sees. It raised three cheap ones: the sign-in host admitted any `offers` word, the declared URL's query was never read, and the bare-origin sentence claimed more than its command measured. It also raised corrections to this entry. All of them are resolved in the second round, below. A scoped delta pass is owed after the hop.

Spec sections covered: none directly. This is the skills catalogue's evidence rule (SONNY-461, SONNY-463), not a spec surface.
Files changed:
- `Sources/MacAgentCore/SkillPackStartPages.swift`: new. `SkillPackStartPage`, `SkillPackStartPageOffer` and `SkillPackStartPageRule`, with the rule stated once in the first type's doc comment.
- `Sources/MacAgentCore/SkillPack.swift`: `startPages` on the struct, seven load errors, the decoder, and `isOnSite(host:domain:)` extracted so the declared-start check and the landing check share one definition. The declared check's behaviour is unchanged.
- `Tests/MacAgentCoreTests/SkillPackTests.swift`: eight new tests, and two existing controls given a matching record. The second round added its cases inside three of the eight, and wrote no ninth.
- `Tests/MacAgentTestSupport/SkillPackFixtures.swift`: a deep fixture pack carries a matching record, plus `startPage(…)`.
- `Sources/MacAgent/Resources/SkillPacks/*.skillpack.json`: deep packs only, all 164 of them at `0d645464`.
- `mutation/plans/fix/a-flow-starts-where-the-work-starts.txt`.
Tests: the flagged `swift test` command from `CLAUDE.md` → exit 0, `Test run with 3454 tests in 250 suites passed after 96.578 seconds with 8 known issues` at `797086d4`, clean tree. It started at 18:39:57Z with no Swift compiler or test process running anywhere on the machine and a one-minute load of 9.51, and no other worktree was building when it ended. Every one of the eight new tests prints one `started` and one `passed` line in that log; its 7 skip lines are environment gates, none Skill-related. `scripts/warnings` → exit 0, `measured at : 797086d4 (clean)`, `0 warnings`. The Skills suites under `--filter 'SkillPack|Skill'` → exit 0, `Test run with 73 tests in 5 suites passed after 6.640 seconds`, over the tree committed as `797086d4`.
Mutation plan: mutation/plans/fix/a-flow-starts-where-the-work-starts.txt (founder-triggered, not run on this branch). It has 19 mutants.
- M1 returns the check to the own-domain test alone, and M2 accepts a landing on another host.
- M3–M12 narrow each of the rule's other parts, or widen the one refusal every Google pack depends on.
- M13–M15 undo the second round's three checks.
- K3, K4, K5 and D1 are review-272's own probes. K4 has the parser read the declared URL as the landing. D1 is a data mutant that moves the shipped `google_ads` landing to `business.google.com`.
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
  - a landing that is on neither the pack's own site nor, for a record that says `sign-in`, its `signInURL`'s host (shape 2, `ads.google.com/` → `business.google.com`, however `signInURL` is edited);
  - a declared or landed URL that names account creation in its path, fragment or query (shape 1, Ghost's `/signup`, and `?mode=signup` or Auth0's `?screen_hint=signup` on the declared URL);
  - any `offers` word but the two (shapes 3, 4 and 5).
- **The sign-in rule, as the founders reconciled it on 2026-09-18.** A start page is acceptable when the form on it signs in an account that already exists and the site has a separate route for creating one. It is not acceptable when that same form is also how an account gets created, whatever words sit beside it. A terms line is evidence, not the test, and a cookie notice is never relevant. Two clarifications were posted on SONNY-510 during this round, and both are applied here:
  - The separate route is read at the page: a visible registration control, a tab, a button or a link to a page of its own. A page that shows none is held.
  - A record's heading is the first one a visitor can see, not the first in the document.
- **The first round's sweep, over the whole population the rule governs.** That was 181 distinct start URLs used by 427 flows in 164 deep packs at `0d645464`, of which 300 flows across 116 packs started at a bare origin. Each was read signed out. The outcome:
  - 132 were kept: they landed on a sign-in page (120) or on the product itself (12).
  - 38 were replaced by the catalogue row's `sign_in_url` or an on-site sign-in path, and every replacement was read too.
  - 15 packs had `signInURL` corrected to the identity host their start page lands on. Those are five Google products, four Microsoft ones, Carrd, Cursor, Notion, Postman, v0 and Google Ads.
  - 11 start URLs had no admissible start page, so ten packs went shallow: claude, growthbook, microsoft, onedrive, zoho_desk, greenhouse, midjourney, n8n, pinterest and shipstation.
- **The second round's re-judgement: all 155 `sign-in` records at `6dbe1250`, read again signed out.** 134 pass and 21 are held. Each held record's pack goes shallow when it was the pack's only start page, which is 19 packs, and otherwise loses that flow, which is Luma and Perplexity. 53 flows went in all. The held records, each with the site and the reason:
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
    - Fireflies is single sign-on only, with no sign-up route and a consent to record the visitor's voice. It is the founders' named hold, tl;dv's shape.
    - Microsoft Copilot is single sign-on only (Microsoft, Apple, Google), with no sign-up route.
    - Perplexity's `/library` has one Continue for both and no sign-up route.
  - **No registration control on the page at all** (6): Affinity, Ashby, Birdeye, Lever, Pylon and BambooHR. Each account is created by an employer or through a sales team. The first pass of this round admitted them as sales-led. The 16:57Z clarification reads the route at the page, and on 2026-09-18 each page's visible controls held none: sign-in buttons, terms, marketing links, and BambooHR's domain box.
- **Records kept and changed in the second round:**
  - **The eleven Google records** (F2): gmail, google ×2, google_ads, google_business_profile, google_meet, google_search_console, googledocs, googledrive, googlesheets and youtube_studio. Each now lands on `accounts.google.com/v3/signin/identifier`, heading "Sign in", read in a profile confirmed to hold no remembered account.
  - **Two landings now carry their fragment route**: Zoom's `/signin` → `zoom.us/signin#/login`, and SurveyMonkey → `auth-us.surveymonkey.com/login#/login`.
  - **Seven headings changed under the visible definition:**
    - Cloudinary had OneTrust's hidden "Privacy Preference Center" and now records none.
    - Crunchbase's "Log In" is screen-reader-only (clip `rect(0,0,0,0)`), so it now records none.
    - OpenRouter's two "Models" headings are both screen-reader-only (1×1, `clip-path: inset(50%)`), so it now records none.
    - Perplexity's only heading is a hidden "Cookie Policy", so it now records none.
    - Gemini: "Conversation with Gemini" is hidden, and "Meet Gemini, your personal AI assistant" is what shows.
    - LinkedIn: "0 notifications" is hidden, and "Sign in" is what shows.
    - Shopify: "You are offline" is hidden, and "Log in" is what shows.
  - **Two headings the first reader had cut at 50 characters:**
    - Productboard's is now whole.
    - DeepL's first `h1` is screen-reader-only, so its heading is the next one down the page, "Trusted by over 200,000 businesses globally".
  - **DeepL's title is the one it settles on**: "DeepL Translator | World's Most Accurate Translator". Read six times about two seconds apart, it showed "DeepL Translate: The world's most accurate translator" once, at about three seconds, and the settled title on every other read.
  - **Product Hunt's heading** is its current promotion, "See what builders are making with GPT-6 Astra". The page changed since the first reading.
  - **Manychat** was re-read rather than judged from the first round's text. Its "Sign up" link opens `app.manychat.com/signup`, a page of its own.
- **The dates.** 143 of the 146 records say `2026-09-18`. The other three keep `2026-09-17`: Luma's `/create`, Mistral's product page and Outlook Calendar. Each records no heading, so the heading re-read did not reach them. Outlook Calendar was judged from the same Microsoft page as Outlook's.
- **Where the population stands now**, at `797086d4`:
  - 135 deep packs, 350 flows and 146 records (134 `sign-in`, 12 `product`).
  - 164 flows across 65 packs start at a bare origin. Of those, 148 land on a page recorded `sign-in` and 16 on one recorded `product`, the 16 being across 8 packs: bolt, chatgpt, gemini, grok, mistral_le_chat, perplexity, product_hunt and zoom.
  - At `6dbe1250` the same join gives 197 = 181 + 16, where this entry once said all 197 landed on a sign-in page (F5).
  - The commands, run from the repository root:
    - `python3 -c "import json,glob;from urllib.parse import urlsplit as u;P=[json.load(open(p)) for p in glob.glob('Sources/MacAgent/Resources/SkillPacks/'+'*.skillpack.json')];B=[(d['id'],f) for d in P for f in d['flows'] if u(f['startURL']).path in ('','/') and not u(f['startURL']).query and not u(f['startURL']).fragment];print(len(B),len({i for i,_ in B}),sum(len(d['flows']) for d in P),sum(d['depth']=='deep' for d in P))"` prints `300 116 427 164` over a `git archive 0d645464` of the packs folder, `197 77 403 154` over `6dbe1250`'s and `164 65 350 135` over `797086d4`'s.
    - The join, `python3 -c "import json,glob;from urllib.parse import urlsplit as u;from collections import Counter;P=[json.load(open(p)) for p in glob.glob('Sources/MacAgent/Resources/SkillPacks/'+'*.skillpack.json')];O={(d['id'],s['url']):s['offers'] for d in P for s in d.get('startPages',[])};B=[O[(d['id'],f['startURL'])] for d in P for f in d['flows'] if u(f['startURL']).path in ('','/') and not u(f['startURL']).query and not u(f['startURL']).fragment];print(len(B),dict(Counter(B)),dict(Counter(O.values())),len(O))"`, prints `197 {'sign-in': 181, 'product': 16} {'sign-in': 155, 'product': 12} 167` over `6dbe1250`'s and `164 {'sign-in': 148, 'product': 16} {'sign-in': 134, 'product': 12} 146` over `797086d4`'s.
  - Shallow packs carry no flows, so the scan finding none in them is a real answer.

Behavior preserved (required, no blanket claims):
- **The own-domain check on a declared `startURL`** is byte-for-byte the same rule. It moved into `isOnSite(host:domain:)`, and `aFlowWhoseStartPageIsOnAnotherSiteDoesNotLoad` still holds both directions: `evil.example.org` and `notnotion.so` are refused, the domain and a subdomain load.
- **The money and credential rules** read the same texts as before. `startPages` is not in `guidance`, so what reaches the planner is unchanged except where a start URL or a `signInURL` changed, and where a pack went shallow and lost its flows.
- **The guidance byte ceiling** is unaffected, because the records are not guidance. Every pack still loads under 6,000 bytes: `everyShippedPackLoads…` passes at `797086d4`.
- **Shallow packs**: all 309 that were shallow at `0d645464` are untouched. 338 are shallow at `797086d4`: those 309, the ten made shallow in the first round and the 19 in the second. Each of the 29 keeps its name, domain, triggers, sections and sign-in page. Measured by a `json.load` walk over a `git archive` of each head's packs folder, counting `depth == 'shallow'`. This corrects the first round's "none of the 319 shallow files changed", which counted the ten it had made shallow itself.
- **No flow's title, steps or source changed, and no pack field outside `flows`, `startPages` and `depth` changed in the second round.** That comes from a field-by-field comparison of every pack between the two heads' archives. `docs/sonny-skill-sites.tsv` is byte-identical to `0d645464`'s (`git diff --quiet 0d645464 797086d4 -- docs/sonny-skill-sites.tsv` exits 0).
- **`SkillPackFixtures.catalogue()`** still builds Docusign, Linear and Notion through the real loader. The Command Center Skills tests pass unchanged.

Architectural decisions / pitfalls discovered (required, write "none" if true):
- **The record lives in the pack, and the loader checks it.** A shared file of landings would be one file that every pack lane appends to, which is the coupling SONNY-500 removed. The catalogue TSV was ruled out for the same reason and because three wave-12 lanes hold its rows. The reasoning is on SONNY-510's first implementing comment, posted before any code was written.
- **The host rule needs the identity host named, and `signInURL` is where it is named.** A Google product lands on `accounts.google.com`; Outlook and Teams land on `login.microsoftonline.com`. Admitting "any host sharing the registrable domain" would admit `business.google.com` for Google Ads, which is the exact shape the rule exists for.
  - So a pack whose start page lands on an identity host names that host in `signInURL`, and the landing is the evidence.
  - Because `signInURL` sits in the same file as the record, the allowance admits only a record that says `sign-in` (F3). Every landing off its pack's own site already said so: 20 at `6dbe1250` and 19 at `797086d4`, all `sign-in`, from a walk joining each record's landed host to its pack's `domain`.
  - **That puts 15 packs' `signInURL` at odds with their catalogue row's `sign_in_url`.** Before this branch all 473 agreed. Measured with `python3 -c "import json,glob,csv;R={r['id']:r['sign_in_url'] or None for r in csv.DictReader(open('docs/sonny-skill-sites.tsv'),delimiter='\t')};print(sum((json.load(open(p))['signInURL'] or None)!=R[json.load(open(p))['id']] for p in glob.glob('Sources/MacAgent/Resources/SkillPacks/'+'*.skillpack.json')))"`, which prints `0` over `0d645464`'s packs and catalogue and `15` at `797086d4`.
  - Nothing tests that the two agree. `signInURL` is now load-bearing for the host rule, and that is on SONNY-524.
- **The browser this lane had is not a clean profile, and each reading says what it was.** The Chrome extension holds a claude.ai session of its own: `claude.ai/login` lands on `/new`, checked again at about 17:45Z on 2026-09-18, reading the path only. So claude.ai cannot be read signed out here, and that pack stays shallow for that reason alone.
  - In the first round the profile also remembered a signed-out Google account. Google sign-ins landed on `/v3/signin/accountchooser`, and the first entry wrongly called that "the same sign-in page". It is not: the chooser lists a remembered identity, and the identifier page does not.
  - Before the second round read anything, and again before its heading re-read began, `accounts.google.com` landed on `/v3/signin/identifier` with no account listed. `github.com` showed a "Sign in" link and no signed-in user.
- **A heading has to be read for visibility, and the obvious tests are wrong in both directions:**
  - The window was not on screen throughout (`document.visibilityState` was `hidden`). So a card that fades in, by CSS animation (Clerk) or by script (Discord's `animatedDiv`), sat at opacity 0, and an opacity test called both headings hidden. Opacity is therefore not read.
  - A screen-reader-only heading has rendered area, so the coordinator's three conditions (area, `display`, `visibility`) count it as visible. The clip is checked too: Crunchbase's `rect(0,0,0,0)`, and DeepL's and OpenRouter's 1×1 `inset(50%)`.
  - Salesforce's first `h1` is empty, so the heading is the first visible one that carries text.
  - The first round's reader cut headings at 50 characters, and two records carried the cut.
- **Browser-reading pitfalls, each measured here:**
  - The extension's output filter replaces any JavaScript result containing a query string with `[BLOCKED: Cookie/query string data]`, so read `origin + pathname`, plus the fragment up to its `?`.
  - `browser_batch` has a wall-clock ceiling of roughly 30 seconds, and a slow navigation inside it times out the whole call.
  - A redirect that lands after the read began kills the read with "Inspected target navigated". Re-reading the page, not trusting the half-read, is the answer; it happened on Close, Pylon, Postmark, Segment, SurveyMonkey and Twilio.
  - Three agents sharing one Chrome made every tab a background tab, which produced 45-second renderer freezes. One tab read about five times faster.
  - The stale-read trap happened: Pylon's delayed redirect surfaced in the next page's read. And Apollo's second hash route, opened straight from its first, stayed on `#/sequences` with nothing rendered, because a hash change is not a load; leaving the site and coming back read it.
  - The catalogue's `sign_in_url` can be dead: Midjourney's answers a 404 page.
- **The rule's own time cost.** The first round ran well past the ninety-minute stop without stopping to report at a green point. The second ran past it too: at about three hours, with the two clarifications above newly posted, the lane stopped and asked, and the founder chose to apply both in this round rather than leave them to the hop. Both are recorded on SONNY-510.

Known limitations / deferred scope:
- **What `offers` means is a person's judgement.** The loader holds only the two words it may be written in. A site that changes after its reading is not noticed, and `read` says how old each record is.
- **Whether a single sign-on button creates an account the first time an unknown identity presses it cannot be seen from outside.** Every judgement here rests on the visible route and on what the page says, as the ticket's 17:07Z comment states. None was tested by pressing anything.
- **Signed-in landings were not read.** Where a flow was already correct signed out, its start URL was kept rather than swapped, so a signed-in user's landing does not move for no measured reason. The manual-test file's last row is the one reading of the signed-in case.
- **The 29 packs made shallow** are named on SONNY-510 with the reason. Restoring any of them means a pack lane reading a start page that passes the rule.
  - For Claude, that is a reader with no claude.ai session.
  - The coordinator's own reading lists Continue with Google, Apple, email and SSO and no sign-up control. So a restoring reader looks for a visible registration route before anything else, because without one the page is held like Lever's.
- **Readings went stale at each hop.** Records for packs landed by other wave-12 lanes are owed at this branch's hop, because the loader refuses their flows until then, and they are read under the rule and the heading definition above. That is expected, and it is on the ticket.

Open questions (required, write "none" if true):
- **Should a pack's `signInURL` and its catalogue row's `sign_in_url` be held equal, or the identity hosts be named some other way?** 15 now differ, and the row is the older research value. This is SONNY-524's, and a founders' call.
- **Two passes sit close to the line, for the founders:**
  - Loom: "By signing up, you acknowledge…" sits under its log-in form, beside a separate `/signup` linked twice.
  - Runway: a consent to scan faces and capture voiceprints is bound to its "Log in", beside a separate sign-up step.
  Both pass the rule's two conditions. Runway's consent is the kind Fireflies carried.
- **Should an account an employer or a sales team creates count as a separate route?** The ticket's reading holds a page that shows no registration control, and six packs went shallow on that. Admitting them is a founders' decision, and they are named above.

Next branch: none named. SONNY-507's open half, whether a catalogue cell is checked for a bad seed, is the neighbouring question.
