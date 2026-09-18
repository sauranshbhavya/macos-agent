### Branch: fix/a-flow-starts-where-the-work-starts
Status: complete — on `main` at `1832956e` with the full review's round pushed, holding for a scoped delta pass on that round (it merges last in wave 12)
Date: 2026-09-18
Tickets: SONNY-510. A flow's start page is now recorded where it lands for a signed-out visitor, and the loader refuses a pack whose record is missing, lands off the site (except on a named identity host paired with that site), names account creation, or says the page was anything but a sign-in page or the product itself.
- All 181 distinct start URLs were read in a browser in the first round.
- In the second, every sign-in record was judged again under the founders' final rule, including their three decisions of 2026-09-18.
- At the hop, the 25 packs other wave-12 lanes had made deep were read under the same rule, and all 25 pass.
- After the full review, every record that says `product` was judged again too, which round two had not done.

SONNY-524 keeps one question, which is now about provenance only.
Reviewed by: review-272 on PR #272, a fresh session's deep adversarial pass at `6dbe1250` (post-hop `cb24fbff`).
- **Two blocking findings:** the branch's definition of `sign-in` contradicted the founders' ruling, and the eleven Google records described a page a fresh profile never sees.
- **Three cheap ones:** the sign-in host admitted any `offers` word; the declared URL's query was never read; and the bare-origin sentence claimed more than its command measured.
- **Corrections to this entry.**

All are resolved in the second round, as are the founders' three decisions on the questions that round raised.

Then a fresh session ran a full pass at `e7b7e944`, not a delta. It found:
- **One blocking finding:** round two re-judged the 155 `sign-in` records and never the ones saying `product`, and three product pages led into the forms other packs were removed for.
- **Four more for the same round:** OneDrive's start page, a population test that built its expected answer from the list it checked, the Google pack's own-site identity host skipping the sign-in-only check, and a stale PR description.

The figures, the gates, 22 of 22 mutants and all four rulings held up. Everything is resolved below, and SONNY-529 holds what that review routed elsewhere. A scoped delta pass on this round only is owed.

Spec sections covered: none directly. This is the skills catalogue's evidence rule (SONNY-461, SONNY-463), not a spec surface.
Files changed:
- `Sources/MacAgentCore/SkillPackStartPages.swift`: new. `SkillPackStartPage`, `SkillPackStartPageOffer` and `SkillPackStartPageRule`, with the rule stated once in the first type's doc comment and the identity-host list stated at the list.
- `Sources/MacAgentCore/SkillPack.swift`: `startPages` on the struct, eight load errors, the decoder (including the optional `otherTitles`), and `isOnSite(host:domain:)` extracted so the declared-start check and the landing check share one definition. The declared check's behaviour is unchanged.
- `Tests/MacAgentCoreTests/SkillPackTests.swift`: nine new tests, and two existing controls given a matching record. Eight arrived in the first round. The second round added its cases inside three of them and wrote the list's population test. The full review's round replaced that test with `theIdentityHostListIsExactlyTheLandingsTheShippedPacksMake`, still nine.
- `Tests/MacAgentTestSupport/SkillPackFixtures.swift`: a deep fixture pack carries a matching record, plus `startPage(…)`.
- `Sources/MacAgent/Resources/SkillPacks/*.skillpack.json`: every deep pack. That is the 164 deep at `0d645464` and the 25 made deep on `main` since.
- `mutation/plans/fix/a-flow-starts-where-the-work-starts.txt`.
Tests: the flagged `swift test` command from `CLAUDE.md` → exit 0, `Test run with 3475 tests in 251 suites passed after 102.791 seconds with 8 known issues` at `a7bd61fe`, clean tree. It started at 21:59:29Z with no Swift compiler or test process running anywhere on the machine and a one-minute load of 5.05, and no other worktree was building when it ended. Every one of the nine new tests prints one `started` and one `passed` line in that log; its 7 skip lines are environment gates, none Skill-related. `scripts/warnings` → exit 0, `measured at : a7bd61fe (clean)`, `0 warnings`. The Skills suites under `--filter 'SkillPack|Skill'` → exit 0, `Test run with 74 tests in 5 suites passed after 7.546 seconds`, over the tree committed as `a7bd61fe`. The server half did not move in the full review's round, so its figures are carried from `38c7f731` with a tree-identity proof. `git rev-parse --verify --quiet "${rev}:server"` prints `98ab28c009c065c035d8a3b32efefcdccb71e403` at both `38c7f731` and `a7bd61fe` (IDENTICAL). The same check reads `Sources` as MOVED, and a path that resolves nowhere exits 1 on both sides (REFUSED), which shows the check can give all three answers. The carried figures were owed by the hop's range (`git diff --name-only 0d645464 1832956e` → 105 files, 42 under `server/`), all run at `38c7f731`: `npm run build` exit 0; `npm run typecheck` exit 0; `npm test` exit 0, `Test Files 34 passed | 28 skipped (62)` and `Tests 951 passed | 503 skipped (1454)`, the database tests skipping without `DATABASE_URL`; and `npm run test:db` → exit 0, `Test Files 62 passed (62)` and `Tests 1454 passed (1454)`. That last one ran against a Postgres named `sonny-gw-db-lane-510` on the free host port Docker gave it (32778), after `pg_isready` and the init log's second "ready to accept connections"; the container was removed afterwards. The hop round's own Swift figures, at `38c7f731`, were 3475 tests in 251 suites, 0 warnings and 74 Skills tests, and they are history now.
Mutation plan: mutation/plans/fix/a-flow-starts-where-the-work-starts.txt (founder-triggered, not run on this branch). It has 24 mutants.
- M1 returns the check to the own-domain test alone, and M2 accepts a landing on another host.
- M3–M12 narrow each of the rule's other parts, or widen the one refusal every Google pack depends on.
- M13–M15 undo the second round's three checks.
- K3, K4, K5 and D1 are review-272's own probes. K4 has the parser read the declared URL as the landing. D1 is a data mutant that moves the shipped `google_ads` landing to `business.google.com`.
- I1–I3 hold the identity-host list: a host that forgets which sites it signs in for, a host nobody read (review-272's `business.google.com`), and a host the sweep found, dropped.
- M2, M3, M13 and K5 were re-anchored at the hop, when the landing check split into its two errors.
- I4 is the full review's own widening mutant, which pairs Google's sign-in host with every `.com` site. I5 narrows the sign-in-only check back to off-site landings.
- **The repaired population test was shown to produce its own negative**, through `scripts/mutate` at `e3baddf6`, with a scratch plan and the Skills filter as the suite. The baseline passed 74 tests. The widening mutant W1 was **KILLED by 2 tests**: the repaired test and the new Figma-on-Google's-host case. A control C1, the same two sites written in the other order, which a `Set` does not see, **SURVIVED**, as it should.
- **What a plan of this shape cannot do.** Every mutant deletes or narrows a guard that exists, so none can find a guard that was never written. Review-272's F3 and F4 were absent code, and only probing the rule from outside found them. The plan's header says so.

Behavior added:
- **Every deep pack carries `startPages`.** There is one record per distinct start URL, holding:
  - the landed URL, with no query, no query inside its fragment, and no per-visit path segment;
  - the title, once it has settled, and in `otherTitles` any other title a racing page was read reporting;
  - the first heading a visitor can see;
  - `offers`, which is `sign-in` or `product`;
  - the date read.
  A pack with flows that leaves it out gets `missingField("startPages")`. A shallow pack owes none.
- **The loader refuses:**
  - a flow whose start URL has no record, a record no flow uses, and two records for one URL;
  - a landed URL with a query, including one inside its fragment (`#/login?redirect=/`);
  - a landing off the pack's own site on a host `identityHosts` does not pair with that site, as `landedOnUnpairedHost(url:host:site:)` (shape 2, `ads.google.com/` → `business.google.com`, whatever the pack's `signInURL` says);
  - a `product` record on any listed identity host, on the pack's own site or off it, as `identityHostLandingIsNotSignIn(url:host:)` (the Google pack's domain is `google.com`, so `accounts.google.com` is its own site);
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
    The hop's 25 landings are all on their own sites, so the list is unchanged.
  - The deciding property is the failure direction. A landing on an unlisted host refuses the pack, and somebody sees it. The old allowance read the pack's own `signInURL`, which its author writes in the same file, so a wrong value admitted a bad landing silently, which is how review-272 loaded a Google Ads pack naming `business.google.com`.
  - Each host is paired with its sites, so Google's sign-in host admits a Google pack and not Notion's. The refusal names the missing pairing, the landed host and the pack's own site, because the list is now kept one pairing at a time: a host already listed for another site is still refused, and the fix a reader looks for is that pairing.
  - `theIdentityHostListIsExactlyTheLandingsTheShippedPacksMake` holds the list to exactly the population that uses it. It reads the shipped pack files as raw JSON and pairs each off-site landed host with the registrable site of every pack that lands there, never consulting the list. Its first version read each host's sites out of the list inside its own loop, compared the list with itself, and let the full review's widening mutant through. The doc comment says how a real new pairing is added.
- **The sign-in rule, as the founders settled it on 2026-09-18.** A start page is acceptable when the form on it signs in an account that already exists and the site has a separate route for creating one. It is not acceptable when that same form is also how an account gets created, whatever words sit beside it. A terms line is evidence, not the test, and a cookie notice is never relevant. The separate route is read at the page, and a page that shows none is held. There are two further grounds, both in the doc comment with their reasoning:
  - **Decision A: a product with no self-serve sign-up anywhere passes**, because an admin or a sales team creates every account. The visible route was a proxy for "this form cannot create an account", and on such a product the proxy reads backwards. So the check is of the site, not the sign-in page: self-serve sign-up anywhere, hidden by the sign-in page, is tl;dv's shape and holds it.
  - **Decision B: a biometric or recording consent bound to the sign-in control holds the page**, whatever its sign-up route. It is narrow, biometric and recording consent only, because it is a separate ground the account-creation rule is blind to.
  - A record's heading is the first one a visitor can see, not the first in the document (the ticket, 17:23Z).
- **The first round's sweep, over the whole population the rule governed at its base.** That was 181 distinct start URLs used by 427 flows in 164 deep packs at `0d645464`, of which 300 flows across 116 packs started at a bare origin. Each was read signed out. The outcome:
  - 132 were kept: they landed on a sign-in page (120) or on the product itself (12).
  - 38 were replaced by the catalogue row's `sign_in_url` or an on-site sign-in path, and every replacement was read too.
  - 15 packs had `signInURL` corrected to the identity host their start page lands on. Those are five Google products, four Microsoft ones, Carrd, Cursor, Notion, Postman, v0 and Google Ads.
  - 11 start URLs had no admissible start page, so ten packs went shallow: claude, growthbook, microsoft, onedrive, zoho_desk, greenhouse, midjourney, n8n, pinterest and shipstation. OneDrive came back in the full review's round (below). Microsoft 365, Zoho Desk and Midjourney each need a new pairing or a judgement, and they are on SONNY-529.
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
- **Decision B, checked across the population.** All 119 distinct landings of the 139 sign-in records were scanned signed out for text naming biometric capture or recording: the 134 passes, plus the five restored. The scan read each text node and whether it was visible. Runway's is the only one.
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
- **The hop: the 25 packs wave 12 made deep, read and recorded on 2026-09-18.** First the profile was confirmed empty, at 20:03:28Z: `accounts.google.com` landed on `/v3/signin/identifier` with no account listed, and `github.com` showed "Sign in" and no signed-in user. Each start page was then read signed out, through its own start URL, twice, under the final rule. **All 25 pass.** No landing is off its pack's site, and none carries a biometric or recording consent. The records:
  - **Sign-in pages with a separate route on the page** (21):
    - CallRail, "Get a free trial".
    - Chatwork, "Sign Up (Free)".
    - Circle, "Sign up".
    - ClickFunnels, "Sign Up".
    - Contentful, "Sign up".
    - Ecwid, "Create new Ecwid account", a different form.
    - Fathom, "New to Fathom? Sign up".
    - JustCall, "Start free trial".
    - Kajabi, "Sign up here".
    - Krisp, "Sign up".
    - LinkedIn Ads, "Join now", the same page as LinkedIn's record.
    - Otter, "Create account".
    - Plaud, "Sign up".
    - Quo, "Sign up for free".
    - Read AI, a separate "Create account" control.
    - SamCart, "Sign Up".
    - Skool, "Sign up for free".
    - Squarespace, "Create Account".
    - ThriveCart, "Don't have an account", which goes to `thrivecart.com/`, where an account is bought.
    - TikTok Ads, "Sign up now".
    - Unbounce, "Create an account".
  - **Sign-in behind a control on the landing** (3), each pressed and judged by what it opens, as the ticket's 16:57Z method asks:
    - Aircall's "Sign in to Aircall" opens `auth.aircall.io/login`, which offers email and password, Google, SSO and a separate "Sign up". The landing also offers "Start a free trial".
    - Webex's "Sign in" opens `web.webex.com/sign-in/enter-email`, and "Sign up" is a separate control on the landing.
    - Etsy's "Sign in" opens the "Special starts on Etsy" dialog, with "New to Etsy? Create an account" separate. Etsy's flows begin signed in, so it is `sign-in`, not `product`.
  - **The product itself** (1): eBay. `www.ebay.com/` is the marketplace, usable signed out, and its "Search for anything" box is the first flow's first step. Its heading is the day's promotion, recorded as read.
  - **Terms lines, evidence only:** Fathom, Krisp, Otter, Quo and Read AI each carry an "agree to the Terms" line. None is biometric or recording consent, though all five record meetings or calls. Plaud's "I agree to register my account in United States" is a data-region acceptance of the same kind.
  - **Otter's title races**, as the ticket found. In the full review's round, two runs through its own start URL, `otter.ai/home`, each landed on `/signin` and held one title to the end of a watch of ten seconds or more. The first read "Otter.ai - Access real-time and shareable meeting notes" from 3.8 seconds, and the second read "Sign In: Otter Voice Meeting Notes - Otter.ai" from 3.0 seconds. The record carries both: the second as `title`, as SONNY-502's record orders them, and the first in `otherTitles`. SONNY-502's comment of 17:33Z already records both, so it needed no update.
  - **JustCall's sign-in form is a cross-origin frame** (`ui-vercel.justcall.io`). No script or accessibility read reaches it, so the form was read from a screenshot: "Sign in to your account", Google, Microsoft, email and password, SSO, and "Don't have an account? Start free trial". The landed document itself has no heading.
- **The dates.** 170 of the 171 records say `2026-09-18`. The one that keeps `2026-09-17` is Outlook Calendar's, which records no heading, so the heading re-read did not reach it, and was judged from the same Microsoft page as Outlook's.
- **The full review's round: every `product` record judged again, on 2026-09-18.** First the profile was confirmed empty at 21:42:16Z: Google's identifier page with no account listed, and GitHub signed out. A `product` record has to mean the product is usable signed out at each flow's first step. So all 13 were read twice, signed out, through their own start URLs, and each flow's first step was looked for on the page. Where that step was gated, the record takes the sign-in rule: the site's own sign-in control was pressed and what opened was judged. Provider buttons were never pressed, and nothing was typed.
  - **Held, and the pack goes shallow** (5):
    - **Luma**'s `/create` raises "Welcome to Luma. Please sign in or sign up below." over the page on load. That is the combined form Luma's own `/signin` flow was removed for in round two, and it was Luma's last flow.
    - **ChatGPT**'s first flow starts in Settings, then Personalization. Signed out, Settings holds only Appearance, Language and Data controls. The other two flows need saved conversations, and its "Log in" opens a dialog headed "Log in or sign up". That is the combined shape Canva, Dropbox and Amplitude were removed for.
    - **Bolt**'s three flows start inside "your Bolt project". Its "Sign in" opens a dialog reading "To use Bolt you must log into an existing account or create one using one of the options below": one form for both.
    - **Mistral**'s page raises a "Vibe Terms of Service" dialog on load, and no Work or Code mode exists signed out. Its "Sign in" opens `v2.auth.mistral.ai/login`, "Let's start building. Login or signup below": one form for both. The terms dialog was not accepted.
    - **Product Hunt** shows no "Post" button signed out, and the flow starts there. Its "Sign in" opens "Sign up on Product Hunt" with LinkedIn, GitHub, X, Google, Facebook and Apple and nothing else. It is single sign-on under a sign-up heading, Fireflies' shape.
  - **One flow held, the record kept** (1): **Perplexity**'s "Make a skill" starts on a Skills page no signed-out control reaches. Its "Sign In" opens "Sign up below to unlock the full potential of Perplexity", the form its `/library` flow was removed for. The question flow keeps its `product` record, because the "Ask anything…" box is the product, usable signed out.
  - **Now `sign-in`, and passing** (2):
    - **DeepL**'s "Translate files", the flows' first step, says "To translate files, create a DeepL account" signed out. Its "Log in" opens `auth.deepl.com/login`, "Log in to your account", with a separate "Sign up".
    - **Gemini**'s flows need Activity, and signed out its Settings menu has none. Its "Sign in" opens Google's identifier page, with "Create account" separate.
  - **Still `product`** (5 records across 4 packs):
    - **eBay**'s search box is its first flow's first step.
    - **Grok** has "Ask Grok anything" with Submit on its question page, and the same box on `/imagine`.
    - **OpenRouter**'s catalogue renders 50 model links and a search box.
    - **Zoom**'s join page asks for a meeting ID.
    - eBay's heading is the day's rotating promotion and is re-recorded as read. Its "My eBay" and `signin.ebay.com` both led to a bot check ("Please verify yourself to continue"), which a session may not complete. So the sign-in page behind the Watchlist flow was not read this round.
  - **OneDrive comes back** (the full review's F2). `onedrive.live.com/login/` stays on OneDrive's own site and frames Microsoft's "Sign in" with "No account? Create one!", read from a screenshot because the frame is another site's. Its three flows now start there and are otherwise as they stood at `0d645464`. The landed document has no heading of its own.
  - **DeepL's title races too.** It showed "DeepL Translate: The world's most accurate translator" once before settling, so its record now carries that title in `otherTitles`.
- **This branch removes packs, deliberately, and that is the rule working, not damage and not a regression.**
  - `main` at the hop, `1832956e`, has **189 deep packs and 473 flows**. With this branch it has **160 deep packs and 400 flows**: **29 packs and 73 flows removed**.
  - Every removed pack is one whose start page a flow may not start on, named above with its reason. The first round removed 10 packs and 24 flows, and the second removed 15 packs and 41 flows. The full review's round removed 5 packs and 11 flows and restored OneDrive's 1 pack and 3 flows. None of the 25 packs the hop brought in is removed.
  - Every one of the 29 keeps its name, domain, triggers, sections and sign-in page, and loses only its task steps.
  - A reader in six months meets 160 where the wave's headline said 189. That difference is this rule refusing pages that were wrong.
- **Where the population stands**, at `a7bd61fe`:
  - 160 deep packs, 400 flows and 171 records (165 `sign-in`, 6 `product`).
  - 188 flows across 77 packs start at a bare origin. Of those, 183 land on a page recorded `sign-in` and 5 on one recorded `product`, the 5 being across 4 packs: ebay, grok, perplexity and zoom.
  - The commands, run from the repository root:
    - `python3 -c "import json,glob;from urllib.parse import urlsplit as u;P=[json.load(open(p)) for p in glob.glob('Sources/MacAgent/Resources/SkillPacks/'+'*.skillpack.json')];B=[(d['id'],f) for d in P for f in d['flows'] if u(f['startURL']).path in ('','/') and not u(f['startURL']).query and not u(f['startURL']).fragment];print(len(B),len({i for i,_ in B}),sum(len(d['flows']) for d in P),sum(d['depth']=='deep' for d in P))"` prints `300 116 427 164` over a `git archive 0d645464` of the packs folder, `320 127 473 189` over `1832956e`'s and `188 77 400 160` over `a7bd61fe`'s.
    - The join, `python3 -c "import json,glob;from urllib.parse import urlsplit as u;from collections import Counter;P=[json.load(open(p)) for p in glob.glob('Sources/MacAgent/Resources/SkillPacks/'+'*.skillpack.json')];O={(d['id'],s['url']):s['offers'] for d in P for s in d.get('startPages',[])};B=[O[(d['id'],f['startURL'])] for d in P for f in d['flows'] if u(f['startURL']).path in ('','/') and not u(f['startURL']).query and not u(f['startURL']).fragment];print(len(B),dict(Counter(B)),dict(Counter(O.values())),len(O))"`, prints `188 {'sign-in': 183, 'product': 5} {'sign-in': 165, 'product': 6} 171` over `a7bd61fe`'s.
  - Shallow packs carry no flows, so the scan finding none in them is a real answer.
- **The hop-round figures are history too.** At `38c7f731` the first command printed `198 81 408 164`, and the join showed 13 `product` records, before the full review's round.
- **The pre-hop figures are history.** They were measured at heads the rebase replaced, and they describe the branch before `main`'s 25 packs arrived:
  - The first round's head, `6dbe1250` (post-hop `cb24fbff`), read `197 77 403 154` by the first command. By the join it read `197 {'sign-in': 181, 'product': 16}`, where this entry once said all 197 landed on a sign-in page (F5).
  - The decisions round's data head, `1781b665` (post-hop `6de0084f`), read `178 70 362 139`.
  - Nothing in this entry rests on them now. The rest of the map is at the end.

Behavior preserved (required, no blanket claims):
- **The own-domain check on a declared `startURL`** is byte-for-byte the same rule. It moved into `isOnSite(host:domain:)`, and `aFlowWhoseStartPageIsOnAnotherSiteDoesNotLoad` still holds both directions: `evil.example.org` and `notnotion.so` are refused, the domain and a subdomain load.
- **`signInURL` is still decoded, still optional and still rendered into guidance** as "Sign-in page: …". Only the start-page host rule stopped reading it.
- **The money and credential rules** read the same texts as before. `startPages` is not in `guidance`, so what reaches the planner is unchanged except where a start URL or a `signInURL` changed, and where a pack went shallow and lost its flows.
- **The guidance byte ceiling** is unaffected, because the records are not guidance. Every pack still loads under 6,000 bytes: `everyShippedPackLoads…` passes at `a7bd61fe`.
- **Against `main` at `1832956e`**, compared field by field over `git archive`s of both packs folders:
  - 284 packs are untouched, and they are exactly `main`'s 284 shallow packs.
  - The other 189 are the deep ones. The 160 still deep carry `startPages`, and 29 went shallow. `signInURL` changed on 15, and `flows` changed on 59 (the 29 made shallow, Perplexity, OneDrive's moved start URL, and the start URLs the first round replaced).
  - No flow's title, steps or source changed.
  - `docs/sonny-skill-sites.tsv` is as `main` has it: `git diff --quiet 1832956e a7bd61fe -- docs/sonny-skill-sites.tsv` exits 0.
- **The five packs restored under decision A** are identical to the first round's versions except their `read` date and Birdeye's heading.
- **`SkillPackFixtures.catalogue()`** still builds Docusign, Linear and Notion through the real loader. The Command Center Skills tests pass unchanged.

Architectural decisions / pitfalls discovered (required, write "none" if true):
- **The record lives in the pack, and the loader checks it.** A shared file of landings would be one file that every pack lane appends to, which is the coupling SONNY-500 removed. The catalogue TSV was ruled out for the same reason and because three wave-12 lanes hold its rows. The reasoning is on SONNY-510's first implementing comment, posted before any code was written.
- **The host rule names identity hosts in code, and the 15 `signInURL` corrections no longer matter to it.**
  - The first round corrected 15 packs' `signInURL` to the identity host their start page lands on. That put them at odds with their catalogue rows: `python3 -c "import json,glob,csv;R={r['id']:r['sign_in_url'] or None for r in csv.DictReader(open('docs/sonny-skill-sites.tsv'),delimiter='\t')};print(sum((json.load(open(p))['signInURL'] or None)!=R[json.load(open(p))['id']] for p in glob.glob('Sources/MacAgent/Resources/SkillPacks/'+'*.skillpack.json')))"` prints `0` over `1832956e`'s packs and catalogue, and `15` at `a7bd61fe`.
  - Since decision C, nothing in the loader reads `signInURL` for that rule. So which value is right is a provenance question only, and it is SONNY-524's.
- **A rule applied to one class of record and not the other is not applied.** Round two re-judged every `sign-in` record against the final rule and left the `product` records as the first round wrote them. Five of the thirteen gated their flows behind exactly the forms the rule removes elsewhere, and two more were sign-in pages under the wrong word. The full review found it by asking what `product` must mean, which is usable signed out at the flow's first step. That question is now the test for every product record.
- **A population test that reads its expected answer from the thing it checks passes whatever that thing says.** The list's first population test fetched each host's sites from the list inside its own loop. The full review's mutant widened Google's sign-in host to every `.com` site, passed the whole Skills suite, and let a Figma pack land there: SONNY-388's held-sample trap, inside the code written to close review-272's hole. The expected answer now comes from the raw pack files, and the fix was shown to kill that mutant while a harmless control survived.
- **A hop that adds packs is a reading, not a rebase.** The rebase itself was clean. But the loader refuses any deep pack without records, so the hop owed a signed-out reading of every start page `main` had added, under the rule as it now stands. A later branch that makes packs deep owes the same record, and the loader will say so.
- **The browser this lane had is not a clean profile, and each reading says what it was.**
  - The Chrome extension holds a claude.ai session of its own: `claude.ai/login` lands on `/new`, checked at about 17:45Z on 2026-09-18, reading the path only.
  - In the first round the profile also remembered a signed-out Google account. Google sign-ins landed on `/v3/signin/accountchooser`, and the first entry wrongly called that "the same sign-in page". It is not: the chooser lists a remembered identity, and the identifier page does not.
  - Before the second round read anything, before its heading re-read, at 20:03:28Z before the hop's readings, and at 21:42:16Z before the full review's round, `accounts.google.com` landed on `/v3/signin/identifier` with no account listed, and `github.com` showed a "Sign in" link and no signed-in user.
- **A heading has to be read for visibility, and the obvious tests are wrong in both directions:**
  - The window was not on screen throughout (`document.visibilityState` was `hidden`). So a card that fades in, by CSS animation (Clerk) or by script (Discord's `animatedDiv`), sat at opacity 0, and an opacity test called both headings hidden. Opacity is therefore not read.
  - A screen-reader-only heading has rendered area, so the coordinator's three conditions (area, `display`, `visibility`) count it as visible. The clip is checked too: Crunchbase's `rect(0,0,0,0)`, and DeepL's and OpenRouter's 1×1 `inset(50%)`.
  - Salesforce's first `h1` is empty, so the heading is the first visible one that carries text.
  - The first round's reader cut headings at 50 characters, and two records carried the cut.
- **Browser-reading pitfalls, each measured here:**
  - The extension's output filter replaces any JavaScript result containing a query string with `[BLOCKED: Cookie/query string data]`, so read `origin + pathname`, plus the fragment up to its `?`.
  - `browser_batch` has a wall-clock ceiling of roughly 30 seconds, and a slow navigation inside it times out the whole call. The extension also disconnected several times mid-call, and the lost reads were redone.
  - A redirect that lands after a read began kills it with "Inspected target navigated". The answer is to re-read the page, not to trust the half-read. The consent scan waited for the tab to reach the recorded landing before reading anything, which also rules out the stale read below.
  - A sign-in form in a cross-origin frame (JustCall, OneDrive) is invisible to scripts and to the accessibility tree alike. Only a screenshot shows it.
  - Some sites put a bot check in front of sign-in (eBay). A session does not complete one, so that sign-in page goes unread and the record says so.
  - Three agents sharing one Chrome made every tab a background tab, which produced 45-second renderer freezes. One tab read about five times faster.
  - The stale-read trap happened: Pylon's delayed redirect surfaced in the next page's read. Apollo's second hash route, opened straight from its first, stayed on `#/sequences` with nothing rendered, because a hash change is not a load; leaving the site and coming back read it. And Ashby's first consent read ran before its redirect to `/signin`.
  - The catalogue's `sign_in_url` can be dead: Midjourney's answers a 404 page.
- **The rule's own time cost.** The first round ran well past the ninety-minute stop without stopping to report at a green point. The second ran past it too: at about three hours, with two clarifications newly posted on the ticket, the lane stopped and asked, and the founder chose to apply both then. The founders' three decisions came after that round was pushed and were applied before the hop. All of it is recorded on SONNY-510.

Known limitations / deferred scope:
- **What `offers` means is a person's judgement.** The loader holds only the two words it may be written in. A site that changes after its reading is not noticed, and `read` says how old each record is.
- **Whether a single sign-on button creates an account the first time an unknown identity presses it cannot be seen from outside.** Every judgement here rests on the visible route, on what the site offers, and on what the page says. None was tested by pressing a provider button or typing anything. Only a site's own controls were pressed: its "Sign in" on Aircall, Webex, Etsy, Perplexity, ChatGPT, Bolt, Mistral, Product Hunt, DeepL and Gemini, eBay's "My eBay", and the settings menus of ChatGPT and Gemini, to look for a flow's first step. No dialog asking for agreement was accepted.
- **The consent scan reads words, not meaning.** It looks for biometric and recording terms in the page's own document. Text inside a cross-origin frame or a shadow root is not read, and a consent worded outside those terms needs a person's reading. It found Runway's, the one case already known, which is the control that it can find one. JustCall's framed form was read from a screenshot instead.
- **A racing title is recorded with every title it was read reporting**, in `otherTitles`. A reading can still miss a title the page reports at another moment, and no refusal reads either field.
- **eBay's sign-in page was not read this round**, because a bot check stands in front of it. The Watchlist flow's first step, "My eBay", is on the product page, and what lies behind it rests on earlier rounds.
- **SONNY-529 holds what the full review routed elsewhere:** Microsoft 365, Zoho Desk and Midjourney; the short account-creation word list; Pylon's weak `/signup` evidence; the date field accepting `2026-13-45`; the "unpaired host" wording; and the eBay-versus-Etsy labelling.
- **Signed-in landings were not read.** Where a flow was already correct signed out, its start URL was kept rather than swapped, so a signed-in user's landing does not move for no measured reason. The manual-test file's last row is the one reading of the signed-in case.
- **The 29 packs made shallow** are named above and on SONNY-510 with the reason. Restoring any of them means a pack lane reading a start page that passes the rule.

Open questions (required, write "none" if true):
- **Should a pack's `signInURL` equal its catalogue row's `sign_in_url`?** 15 differ. After decision C the answer changes no loader behaviour, so it is a provenance question only. It is SONNY-524's.

The hop's SHA map. The rebase onto `1832956e` replaced every commit on this branch. Each pre-hop SHA below still resolves on this Mac and is no longer an ancestor, so it is a timestamp on the branch before the hop:

| Pre-hop | Post-hop | What it was |
|---|---|---|
| `91ecb5aa` | `233504c9` | the first round's code |
| `6dbe1250` | `cb24fbff` | the first round's entry, the head review-272 read |
| `2099b2b7` | `b9fc2391` | the second round's re-judgement |
| `db12984d` | `45cf9ae6` | Manychat re-read |
| `797086d4` | `2268f2a2` | the at-the-page route and the visible headings |
| `e9eaa310` | `59de4fec` | the second round's entry |
| `9925cc88` | `c82b4345` | decision C, the identity hosts |
| `1781b665` | `6de0084f` | decisions A and B, the pack data |
| `6507ce74` | `2d0332a2` | the decisions round's entry |

Since the hop, `1aee8496` is the hop round's records for the 25 packs, `38c7f731` its refusal naming the missing pairing, `e7b7e944` its entry, `e3baddf6` the full review's code and `a7bd61fe` its data. All five are ancestors of this branch.

Every figure this entry states as current is measured at `a7bd61fe` or at `1832956e`, except the server half's, which is measured at `38c7f731` and carried by the tree-identity proof on the Tests line. `0d645464` is the branch's base and an ancestor of `main`.

Next branch: none named. SONNY-507's open half, whether a catalogue cell is checked for a bad seed, is the neighbouring question.
