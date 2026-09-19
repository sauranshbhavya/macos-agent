### Branch: feature/deep-packs-sales-and-crm
Status: complete
Date: 2026-09-19
Tickets: **SONNY-518** — all 22 of group 9's sales and CRM sites are accounted for.
- **Deep (14):** `pipedrive`, `copper`, `nutshell`, `dubsado`, `kommo`, `insightly`, `clay`, `honeybook`, `contactout`, `rocketreach`, `hubspot`, `gong`, `outreach`, `linkedin_sales_navigator`.
- **Held (8), each for a start-page reason named below:** `freshsales`, `odoo`, `twenty`, `attio`, `highlevel`, `bitrix24`, `microsoft_dynamics_365`, `streak`.

The work took two passes in one session. The coordinator's reply between them ruled on HubSpot and asked for Gong's third check. **SONNY-526**, one row only — `contactout`'s guessed sign-in address was opened and is right. Wave 13, cut from `main` at `8f3d1d02`, independent of every other lane — no stack.
Reviewed by: the coordinator measured HubSpot's start page independently between the two passes and ruled that it passes (SONNY-510). The fresh-session review has not run yet.

Spec sections covered: none directly. This is Skills pack data: fourteen resource files and fourteen rows of the catalogue.
Files changed:
- `Sources/MacAgent/Resources/SkillPacks/` `pipedrive`, `copper`, `nutshell`, `dubsado`, `kommo`, `insightly`, `clay`, `honeybook`, `contactout`, `rocketreach`, `hubspot`, `gong`, `outreach`, `linkedin_sales_navigator` (`.skillpack.json`):
  - Each goes from `shallow` to `deep` and gains its flows and one start-page record: 27 flows, 120 steps and 14 records. Gong has one flow and the others two each.
  - Field by field against `8f3d1d02`, only `depth`, `flows` and `startPages` moved, on all fourteen and on no other pack. The command is a Python comparison of `git show 8f3d1d02:<file>` against `git show b02d1cd6:<file>` for each of the fourteen. It prints `fields that moved on the 14: ['depth', 'flows', 'startPages']`, `flows 27 steps 120 start-page records 14` and `changed pack files == the 14: True`.
  - The files were re-serialised with two-space indentation, so each `triggers` array now shows one entry per line. That changes no value.
- `docs/sonny-skill-sites.tsv`: the `doc_url_1` to `doc_url_3` cells of those fourteen rows, and nothing else: 35 cells. Each row now names exactly the pages its flows cite, in flow order, with blanks after them, which is the convention the last wave's lanes used (Contentful, Kajabi). The eight held rows are unchanged.
- This entry and `docs/manual-tests/feature/deep-packs-sales-and-crm.md`.
- `git diff --name-only 8f3d1d02 b02d1cd6` lists the fourteen pack files, the catalogue and these two record files, and nothing else. The record files moved in that range because the first pass committed them at `2cbfa1a3`.

Tests: all at `b02d1cd6`, the last pack commit, unless a line says otherwise.
- **Deep and shallow counts.** `git grep -l '"depth": "deep"' <sha> -- Sources/MacAgent/Resources/SkillPacks | wc -l` gives 160 at `8f3d1d02` and 174 at `b02d1cd6`. The `"depth": "shallow"` twin gives 313 and 299. The control, `"depth": "medium"`, gives 0 at both. No catalogue row moved between `deep` and `site`, so the two tally numerals in `SkillPackTests.swift` are untouched and no Swift file changed.
- **The catalogue, cell by cell.** A scratch script compares `git show 8f3d1d02:docs/sonny-skill-sites.tsv` against the file at `b02d1cd6`, cell by cell. It fails on any change outside the `doc_url_1`–`doc_url_3` cells of this group's 22 rows, or outside `contactout`'s `sign_in_url`, which SONNY-526 hands this lane. It also fails on any change to the header, the row set or order, a column count, or the trailing newline.
  - Result: `changed cells: 35 outside scope: 0`, exit 0, and all 35 cells are on the fourteen deep rows. No `sign_in_url` cell is among them.
  - The control copies the file with one real value changed, Affinity's `category` from `sales_crm` to `sales_CRM`. It prints `BAD affinity.category: 'sales_crm' -> 'sales_CRM'` and exits 1.
- **The Skills suites under `--filter 'SkillPack|Skill'`**, over the working tree whose packs and catalogue were then committed unchanged as `b02d1cd6`: `Test run with 74 tests in 5 suites passed after 8.960 seconds.`, exit 0. No line read `skipped`, and none read `recorded an issue` or `failed after`. The same filter gave the same count line at `63093311`, `4d2d49ad` and the first pass's full-suite tree.
- **The full flagged suite**: exit 0, `Test run with 3475 tests in 251 suites passed after 154.806 seconds with 8 known issues.` It started at 04:15:05Z with 0 Swift compiler or test processes on the machine, at a load of 11.23. The count came from `ps -axww -o command | grep -cE '(^| )/[^ ]*(swift-frontend|swift-driver|swiftpm-testing-helper|xctest)'` → 0, beside the control `(zsh|launchd)` → 14. It ran over `b02d1cd6` with only this entry and the manual-test file uncommitted, and no test reads either of them.
  - 0 lines read `failed after` or `recorded an issue at`.
  - The five catalogue completeness tests each printed exactly one `started` and one `passed` line (`grep -cE "Test <name>\(\) started"` and the same for `passed`, each → 1): `everyShippedPackLoadsAndEveryOneIsARowOfTheCommittedCatalogue`, `everyCatalogueRowHasExactlyOnePack`, `theCommittedCatalogueIsTheListTheFoundersDecided`, `everyShippedDeepPackRecordsWhereItsStartPagesLanded` and `everyShippedTriggerIsDistinctiveOrAnchoredToItsSite`.
  - Its 7 `skipped` lines are environment gates: the live-gateway suite and its four tests, the capture-corpus measurement, and a window test. None is Skill-related.
  - The first pass's run at `a3e3af70` gave the same count line (3475 tests in 251 suites) and is superseded by this one.
- `npm run check:secrets` from the repository root, `scripts/no-attribution tree` and `scripts/changelog-order`: run over the tree committed with this entry, each exit read with nothing between it and `$?`.
  - `server/scripts/check-secrets.sh`: exit 0, `check-secrets: clean (1306 tracked files scanned, 12 patterns, 8 baselined fixtures)`.
  - `scripts/no-attribution tree`: exit 0, `0 of 1302 tracked file(s) carry an attribution (4 excluded by path)`.
  - `scripts/changelog-order`: exit 0, reading `main at 8f3d1d02` and 19 entry files under each directory.
  - No Postgres was started and nothing under `server/` changed.
- **Ancestry.** Every SHA this entry cites exits 0 under `git merge-base --is-ancestor <sha> HEAD`, read with nothing between it and `$?`: `8f3d1d02`, `63093311`, `4d2d49ad`, `a3e3af70`, `2cbfa1a3` and `b02d1cd6`. The control, SONNY-510's pre-hop head `91ecb5aa`, resolves and exits 1.
Mutation plan: none. This branch is data only and adds no behaviour a mutant could remove. The ticket says so: "Data only: no mutation plan".

Behavior added:
- **The browser was confirmed signed out before any reading, and again after each pause** (SONNY-527). All times are UTC on 2026-09-19. Local time, which the records' `read` dates use, is four hours behind, so readings before 04:00Z are dated 2026-09-18 and later ones 2026-09-19.
  - 00:13:46Z: `accounts.google.com` landed on `/v3/signin/identifier`, with no account listed.
  - 00:13:52Z: `github.com` showed its sign-in link and no `user-login`.
  - 00:14:05Z: `www.linkedin.com/feed/` went to `/login/`.
  - 00:14:20Z: `login.microsoftonline.com` showed "Sign in / No account? Create one!" and no account tile.
  - The Google and GitHub checks were repeated at 03:07:40Z and 03:07:44Z, and again at 03:52:17Z and 03:52:23Z, with the same results.

  Every recorded start page was read twice, through its own start URL, and judged under the single rule and the founders' rulings of 2026-09-18. No deep pack's start page lands off its own site, so `SkillPackStartPageRule.identityHosts` is unchanged. None binds biometric or recording consent to its sign-in control.
- **Every empty heading means "no visible heading of any kind."** Today's ruling on SONNY-510 counts a visible `role="heading"` element as a heading. The first pass read headings against h1 and h2 only, so each empty heading was read again, twice, between 03:53Z and 03:57Z, against h1, h2 and `role="heading"`. None has one:
  - Pipedrive's only heading element is an h3, "Log in". The ruling names h1, h2 and `role="heading"`, as Payoneer's record did with its h3.
  - Copper's "Welcome back!" is a `div`.
  - Nutshell's "Sign in" is a `div`.
  - Insightly's "Log in to continue" is a `div`.
  - HoneyBook's "Welcome back" is a `span`.
  - RocketReach's only heading elements are the hidden cookie centre's.
  - HubSpot and Gong have no heading elements at all.

  The second pass read every page against all three from the start.
- **Pipedrive** — `app.pipedrive.com/auth/login` stays put, titled "Log in". "Try it free" and "Don't have an account?" both link to `/register`. Flows: add a stage to a pipeline, and import from a spreadsheet through the five steps.
- **Copper** — `app.copper.com/users/sign_in`, titled "Copper", reading "Welcome back!". "Create an account?" links to `/users/sign_up`. Flows: add a task to an opportunity, and focus the Feed.
- **Nutshell** — `app.nutshell.com/` lands on `/auth`, titled "Nutshell | Log in to Nutshell". "Sign up" links to `/signup`. Flows: import from a CSV, and share a synced email with the team. The second uses only the article's inbox-sharing section; the rest of that page connects email by signing in and giving an SMTP password.
- **Dubsado** — the row's `www.dubsado.com/login` is a chooser between "Login to legacy 2.0" and "Login to beta 3.0", with no form.
  - Both articles are Dubsado 2.0's: the lead-capture article's breadcrumb reads "Legacy Dubsado Articles (Dubsado 2.0) > Lead Capture", and the URL article's title ends "in 2.0".
  - So the flows start at the 2.0 login, `hello.dubsado.com/user/login`. It is titled "Dubsado CRM For Creatives", with the h2 "Log in to Dubsado", and "Sign up" links to `/user/signup`. The pack's `signInURL` still matches the row.
  - Flows: share a lead capture form, and map a custom URL. For the second, the page's CNAME record is a precondition at the domain host, and the flow says Dubsado cannot create it.
- **Kommo** — `www.kommo.com/login/`, titled "Log in — Kommo", with the h2 "Log in". "Sign up" in the header opens a different, hidden "Create your account" form. The row's page, `connect-instagram-to-kommo`, walks through an Instagram sign-in with a username and password, so the flows come from two other Kommo docs: add or rename stages, and change leads in bulk.
- **Insightly** — `login.insightly.com/User/Login`, titled "Insightly", reading "Log in to continue". "Create an account" links to `/User/Signup`. The help centre is Zendesk, so each article was verified by its landed title. Flows: add a Finish Action, and the trigger-condition section of the AppConnect recipes page.
- **Clay** — `app.clay.com/login`, with the h1 "Welcome back!". "Sign up" links to `/signup`. Flows: build a table with Find Companies, and set up a Signal. The Find Companies page lists revenue brackets in dollars, and the flow leaves them out on purpose: a currency amount beside "Add" is a refusal under the money rule.
- **HoneyBook** — `app.honeybook.com/app/login`, reading "Welcome back". "Don't have a business account? Create one" is a separate control.
  - **Its title races, so the record carries both.** The 03:11Z arrival settled on "Login | HoneyBook". Two fresh arrivals at 03:55Z and 03:56Z settled on an empty title, with no `<title>` element in the document, on a fully rendered form (four reads over 30 seconds, then two more). The record's `title` is `""`, and `otherTitles` holds "Login | HoneyBook".
  - The row cited a password page and a login-email page behind two-factor verification, neither of which can be a flow. The flows are create a project, and import leads and clients from a spreadsheet, both from pages found through HoneyBook's own help search.
- **ContactOut** — `contactout.com/login` stays put, titled "Login - Contactout", with the h1 "Login". "Sign up" links to `/register`. So SONNY-526's guess for this row is right, and the cell stays. The help centre is Freshdesk, and each article was verified by its landed title. Flows: build and export a list in the Search Portal, and create an email campaign.
- **RocketReach** — `app.rocketreach.co/login` lands on `rocketreach.co/login`, titled "Log in to your RocketReach.co account". "Sign up!" links to `/signup`. The two Zendesk articles disagree on where the Actions button sits, upper right or upper left, so the flow names neither. Flows: export contacts to CSV, and filter My Contacts.
- **HubSpot, a boundary case that passes** — `app.hubspot.com/login` stays on its own site, titled "HubSpot Login and Sign in".
  - What the page shows: no visible heading of any kind (no h1, no h2 and no `role="heading"`; read again at 03:57:20Z). One email input, no password field and no provider button. The form's entire text is "Email Continue".
  - Above the form, outside it, the page reads, verbatim, **"Sign in or create an account"**. In that phrase, "create an account" is a link (measured `inForm: false`) to a separate page at a distinct path, `app.hubspot.com/signup-hubspot/crm`.
  - The coordinator measured the page independently and ruled that it passes. Luma, Manus and Twenty were held because one form did both jobs and the page said so; HubSpot's form signs in, and account creation is a different page reached by a link beside it.
  - The wording is recorded verbatim so that a later reader re-judges from what the page says rather than from this verdict. It is on SONNY-510 as the second boundary case, beside Plaud.
  - The row's subscription page is billing, and a guessed URL returned HubSpot's 404. The flows came from links on `knowledge.hubspot.com/crm`: create a task, and edit a property value on a contact.
- **Gong, which passes under the founders' decision A** — `app.gong.io/` lands on `/welcome/sign-in`, titled "Gong | Welcome". It offers single sign-on and an email field, with "Don't have an account? Request a demo" and no registration control. It passes on the same three checks Optimizely set this wave:
  - **Calls to action:** www.gong.io offers only Pricing, Book a demo and Talk to sales (03:18:36Z).
  - **Plans page:** `/pricing` is a form asking for "a customized proposal", with no free, trial or dollar-price text (03:18:46Z).
  - **A direct sign-up URL:** `www.gong.io/signup` answers "Page Not Found", with the h1 "OOPS! PAGE NOT FOUND" (03:52:33Z). `app.gong.io/signup` sends you back to `/welcome/sign-in`, the same "Request a demo" page (03:52:49Z and 03:52:51Z).

  The workspace guide is mostly description, so Gong has one flow, from its collaboration-panel section.
- **Outreach, which passes under decision A on the same three checks** — `web.outreach.io/` lands on `login.outreach.io/`, titled "Outreach". Its h2 is "Sign in", with one email field and Continue, and its only links are Status, Terms and Privacy.
  - **Calls to action:** www.outreach.io now redirects to www.outreach.ai, which offers only Pricing, Get a demo, Request a demo and Contact us (04:02:11Z).
  - **Plans page:** `www.outreach.ai/pricing` ("AI Agent Platform Pricing for Revenue Teams") has no free, trial, sign-up or price text, and offers only demo requests and contact (04:02:33Z).
  - **A direct sign-up URL:** `www.outreach.ai/signup` is a 404, "Page Not Found" (04:02:42Z).

  Flows: create a sequence from scratch, and turn on a sequence step. They come from Outreach's Freshdesk portal, verified by title. The row's other page, forecast risk signals (beta), is not used.
- **LinkedIn Sales Navigator** — `www.linkedin.com/sales/home` lands on `/sales/login`, titled "Sales Navigator".
  - The form sits in a same-origin frame (`www.linkedin.com/uas/login`), so the top document's body reads empty. The record's heading, "Sign in to Sales Navigator", is the frame's visible h1, read inside the frame (04:07:13Z and 04:07:15Z) and seen in a screenshot (04:07:00Z).
  - The form takes an email and a password, and "New to LinkedIn? Join now" links to the separate `/signup/cold-join`. This is LinkedIn's separate route, the one the founders' ruling already passes for LinkedIn Ads.
  - Flows: save a lead or account search, and send an InMail to a lead.
- **Held: Freshsales, whose start page cannot be read.** `login.freshworks.com/email-login/` is the row's sign-in URL and where www.freshworks.com's own Login link points.
  - It showed a spinner and nothing else (title "Freshworks", empty body, no inputs) at three readings under heavy load, and at three more after the load fell, the last after an 18-second wait.
  - `login.freshworks.com/` shows "We're sorry!", and `www.freshworks.com/login/` goes to the marketing page `/products/`.
  - A page that never renders is unreadable, not empty, so it was not recorded as offering nothing.
- **Held: Odoo, whose start page cannot reach the flows.** `www.odoo.com/web/login` is a sign-in page with a separate `/web/signup`. But it signs in to odoo.com's account portal ("Access and manage your documents and databases from odoo.com"), not to a CRM.
  - Each customer's CRM runs in its own database: `<name>.odoo.com`, Odoo.sh or self-hosted.
  - So a flow's first step cannot be reached from that page for a self-hosted user, and the loader cannot tell which kind of user it has. This is Mattermost's shape (SONNY-510).
- **Held: Twenty, re-read rather than inherited.** `app.twenty.com` lands on `/welcome`, titled "Sign in or Create an account", reading "Welcome to Twenty". It offers Continue with Google, Microsoft or Email, and no separate route (03:59:03Z and 03:59:14Z). twenty.com's "LOG IN" and "GET STARTED" both point at that same page (03:59:32Z). One page does both jobs and its title says so, the shape Luma and Manus were held for.
- **Held: Attio, re-read rather than inherited.** `app.attio.com/` lands on `/auth/sign-in`, titled "Attio", reading "Sign in", with Google or email Continue and no registration control (03:59:58Z and 04:00:01Z).
  - attio.com's "Start for free" points at `app.attio.com/welcome/sign-in`. That page offers the same "Sign in with Google" and email "Continue", with a marketing-consent line (04:00:33Z and 04:00:35Z).
  - Self-serve sign-up exists and runs through the same controls, and the sign-in page hides it. That is tl;dv's shape, which decision A names as held.
- **Held: HighLevel.** `app.gohighlevel.com/` has the h2 "Sign into your account", with email and password and Google, and no registration control (04:01:06Z and 04:01:08Z). www.gohighlevel.com offers "Start 14-day trial" and "14 DAY FREE TRIAL" (04:01:24Z). Self-serve sign-up exists and the sign-in page shows no route to it, so the page is held.
- **Held: Bitrix24, which lands off its own site.** `www.bitrix24.com/auth.php` lands on `www.bitrix24.net/authorization/`, "Log in to Bitrix24" (read twice, in two tabs, about 04:09Z and 04:11Z).
  - `www.bitrix24.net` is neither the pack's `bitrix24.com` nor a listed identity host, so the loader would refuse the landing.
  - Pairing it is an edit to `SkillPackStartPages.swift`, which this ticket's never-touch list forbids.
  - Customer portals also live on per-customer subdomains, which is Odoo's shape.
- **Held: Microsoft Dynamics 365, which has no start page on its own site.** `dynamics.microsoft.com/` redirects to `www.microsoft.com/en-us/dynamics-365/`, a marketing page (04:11:37Z). The Sales app runs at `<org>.crm.dynamics.com`. Both are off the pack's `dynamics.microsoft.com`.
- **Held: Streak, whose product lives inside Gmail.** www.streak.com ("The Gmail CRM") offers "Add Streak to Chrome", app-store links and a demo (04:12:01Z). The product is an extension running in `mail.google.com`, the pack's `signInURL` is null, and no page on streak.com reaches the product. This is n8n's shape.

Behavior preserved (required, no blanket claims):
- The other 459 packs are untouched: `git diff --name-only 8f3d1d02 b02d1cd6` names only the fourteen pack files, the catalogue and this branch's two record files.
- The fourteen packs' names, domains, categories, summaries, `signInURL`s, triggers and sections are unchanged, per the field-by-field comparison above. So the trigger check reads the same words it passed before.
- The eight held packs are byte-identical to `8f3d1d02`, and their rows are unchanged.
- Every other catalogue row and every other column is unchanged, per the cell check and its control above. That includes `contactout`'s `sign_in_url`.
- No Swift source or test file changed. `SkillPackStartPages.swift` and its identity-host list, `SkillPackContentRules.swift`, `SkillPackTests.swift` and its tally numerals are all as they were.

Architectural decisions / pitfalls discovered (required, write "none" if true):
- **A loaded machine makes the browser's evidence unreliable rather than slow.** The load was another lane deliberately running CPU burners to measure behaviour under load.
  - The one-minute load averages from `uptime`, beside the readings:
    - 42.65 at 00:29Z, 73.08 at 00:35Z and 90.13 at 00:46Z;
    - 5.37 at 03:07Z and 14.36 at 03:19Z;
    - 25.76 at 03:51Z, 16.41 at 03:57Z and 17.34 at 04:00Z;
    - 47.55 at 04:04Z, 20.96 at 04:06Z, 24.41 at 04:08Z and 33.07 at 04:12Z.
  - Before 00:29Z no load was recorded. Every reading from then is two agreeing reads of a rendered page.
  - At the high readings, three things failed:
    - Script evaluation timed out at 45 seconds, on HoneyBook, Kommo, Clay, Bitrix24 and once on example.com.
    - The extension's tab group vanished once.
    - Single-page sign-in forms rendered empty bodies, and at 04:04Z a read returned the previous page because the navigation had not happened.
  - An empty body under load reads exactly like a page that offers nothing, so **no blank or stale read entered a record**. Those reads were discarded, and the page was read again after the load fell below 25. HoneyBook and Clay then rendered normally, and Freshworks did not, which is why Freshsales is held on the low-load readings and not the loaded ones.
  - Kommo's first reading, at a load of about 42, was a rendered form. It was read again at 16.4 (03:58:01Z and 03:58:13Z), with the same title, heading and Sign up button.
  - `get_page_text` kept answering when `javascript_tool` froze.
- **A row's cited help page can itself be a credential flow.** Three of this group's rows pointed at one: Kommo's Instagram connection, and HoneyBook's password and login-email pages. So a lane reads a row's pages before assuming they give flows, and finds replacements on the same help centre.
- **Two help pages from one site can disagree on a control's position** (RocketReach's Actions button). A flow that names a position either page contradicts is wrong for one reader, so the flow names the control and not the position.
- **A money-rule refusal can hide in a filter list.** Clay's Find Companies page lists revenue brackets in dollars. A step copying that list beside "Add" would be refused as `add + an amount`, so the flow leaves the list out rather than rewording it.
- **A sign-in form in a same-origin frame reads as an empty page** (Sales Navigator). The frame's own document holds the heading and the controls, and a reader that stops at the top document records nothing. This is a different case from JustCall's cross-origin frame (SONNY-510), which needed a screenshot.

Known limitations / deferred scope:
- **Gong has one flow**; the rest of its guide page is description.
- **The eight held sites stay shallow.** Each could come back:
  - Freshsales, if a signed-out reading of its sign-in page renders a form.
  - Bitrix24, if the founders pair `www.bitrix24.net` with `bitrix24.com` in `SkillPackStartPageRule.identityHosts`, which is a Swift change outside this ticket.
  - Twenty, Attio and HighLevel, if a separate sign-up route appears at their sign-in pages.
  - Odoo, Dynamics 365 and Streak have no start page on their own site that reaches the product, and nothing in this repository can change that.

Open questions (required, write "none" if true):
- None. HubSpot, raised here as close to the line, was measured by the coordinator and ruled a pass. It is recorded on SONNY-510 as a boundary case beside Plaud, with its wording verbatim.

Next branch: none named; the coordinator assigns wave 13's next work.
