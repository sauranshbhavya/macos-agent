### Branch: fix/a-flow-starts-where-the-work-starts
Status: complete — holding for its one hop onto `main` (it merges last in wave 12)
Date: 2026-09-18
Tickets: SONNY-510. A flow's start page is now recorded where it lands for a signed-out visitor, and the loader refuses a pack whose record is missing, off the site, names account creation, or says the page was anything but a sign-in page or the product itself. All 181 distinct start URLs were read in a browser and the flows fixed.
Reviewed by: pending. This is a boundary rule and gets a deep fresh-session review under `WORKFLOW.md` step 7.

Spec sections covered: none directly. This is the skills catalogue's evidence rule (SONNY-461, SONNY-463), not a spec surface.
Files changed:
- `Sources/MacAgentCore/SkillPackStartPages.swift`: new. `SkillPackStartPage`, `SkillPackStartPageOffer` and `SkillPackStartPageRule`, with the rule stated once in the first type's doc comment.
- `Sources/MacAgentCore/SkillPack.swift`: `startPages` on the struct, seven load errors, the decoder, and `isOnSite(host:domain:)` extracted so the declared-start check and the landing check share one definition. The declared check's behaviour is unchanged.
- `Tests/MacAgentCoreTests/SkillPackTests.swift`: seven new tests, and two existing controls given a matching record.
- `Tests/MacAgentTestSupport/SkillPackFixtures.swift`: a deep fixture pack carries a matching record, plus `startPage(…)`.
- `Sources/MacAgent/Resources/SkillPacks/*.skillpack.json`: all 164 deep packs at `0d645464`.
- `mutation/plans/fix/a-flow-starts-where-the-work-starts.txt`.
Tests: the flagged `swift test` command from `CLAUDE.md` → exit 0, `Test run with 3454 tests in 250 suites passed after 94.784 seconds with 8 known issues` at `91ecb5aa`. `scripts/warnings` → exit 0, `0 warnings`, stamped `91ecb5aa plus 2 uncommitted file(s)`. The two are this entry and the manual-test file, markdown that no compile reads. The Skills suites under `--filter 'SkillPack|Skill'` → `Test run with 73 tests in 5 suites passed` at `91ecb5aa`, and every one of the seven new tests is named `passed` in that log, none skipped.
Mutation plan: mutation/plans/fix/a-flow-starts-where-the-work-starts.txt (founder-triggered, not run on this branch). It has 12 mutants. M1 returns the check to the own-domain test alone, M2 accepts a landing on another host, and M3–M12 narrow each of the rule's other parts, or widen the one refusal every Google pack depends on.

Behavior added:
- **Every deep pack carries `startPages`**: one record per distinct start URL, holding the landed URL (no query, no per-visit path segment), the title, the first heading, `offers` (`sign-in` or `product`) and the date read. A pack with flows that leaves it out gets `missingField("startPages")`. A shallow pack owes none, so none of the 319 shallow files changed and no pack lane's file changes until its flows land.
- **The loader refuses** a flow whose start URL has no record, a record no flow uses, two records for one URL, a landed URL with a query, a landing that is on neither the pack's own site nor its `signInURL`'s host (shape 2, `ads.google.com/` → `business.google.com`), a landed or declared path naming account creation (shape 1, Ghost's `/signup`), and any `offers` word but the two (shapes 3, 4 and 5).
- **The sweep, over the whole population the rule governs.** That was 181 distinct start URLs used by 427 flows in 164 deep packs at `0d645464`, of which 300 flows across 116 packs started at a bare origin (the command is below). Each was read signed out. The outcome:
  - 132 were kept: they landed on a sign-in page (120) or on the product itself (12).
  - 38 were replaced by the catalogue row's `sign_in_url` or an on-site sign-in path, and every replacement was read too.
  - 15 packs had `signInURL` corrected to the identity host their start page lands on. Those are five Google products, four Microsoft ones, Carrd, Cursor, Notion, Postman, v0 and Google Ads.
  - 11 start URLs had no admissible start page, so ten packs went shallow: claude, growthbook, microsoft, onedrive, zoho_desk, greenhouse, midjourney, n8n, pinterest and shipstation. Each is named with what was tried on SONNY-510.
- **After**, at `91ecb5aa`: 154 deep packs, 403 flows, 167 records (155 `sign-in`, 12 `product`). 197 flows across 77 packs still start at a bare origin, and each of those origins was read and lands on a sign-in page. So a bare origin is not refused, and what it does is recorded. The command for both readings, run from the repository root:
  `python3 -c "import json,glob;from urllib.parse import urlsplit as u;P=[json.load(open(p)) for p in glob.glob('Sources/MacAgent/Resources/SkillPacks/'+'*.skillpack.json')];B=[(d['id'],f) for d in P for f in d['flows'] if u(f['startURL']).path in ('','/') and not u(f['startURL']).query and not u(f['startURL']).fragment];print(len(B),len({i for i,_ in B}),sum(len(d['flows']) for d in P),sum(d['depth']=='deep' for d in P))"`
  That prints `300 116 427 164` over a `git archive 0d645464` of the packs folder and `197 77 403 154` at `91ecb5aa`. The control that makes the shallow half's zero mean something: shallow packs carry no flows, so the scan finding none in them is a real answer.

Behavior preserved (required, no blanket claims):
- **The own-domain check on a declared `startURL`** is byte-for-byte the same rule. It moved into `isOnSite(host:domain:)`, and `aFlowWhoseStartPageIsOnAnotherSiteDoesNotLoad` still holds both directions: `evil.example.org` and `notnotion.so` are refused, the domain and a subdomain load.
- **The money and credential rules** read the same texts as before. `startPages` is not in `guidance`, so what reaches the planner is unchanged except where a start URL or a `signInURL` changed.
- **The guidance byte ceiling** is unaffected, because the records are not guidance. Every pack still loads under 6,000 bytes: `everyShippedPackLoads…` passes at `91ecb5aa`.
- **Shallow packs**: all 309 that were shallow at `0d645464` are untouched, and the ten made shallow keep their name, domain, triggers, sections and sign-in page.
- **`SkillPackFixtures.catalogue()`** still builds Docusign, Linear and Notion through the real loader. The Command Center Skills tests pass unchanged.

Architectural decisions / pitfalls discovered (required, write "none" if true):
- **The record lives in the pack, and the loader checks it.** A shared file of landings would be one file that every pack lane appends to, which is the coupling SONNY-500 removed. The catalogue TSV was ruled out for the same reason and because three wave-12 lanes hold its rows. The reasoning is on SONNY-510's first implementing comment, posted before any code was written.
- **The host rule needs the identity host named, and `signInURL` is where it is named.** A Google product lands on `accounts.google.com`; Outlook and Teams land on `login.microsoftonline.com`. Admitting "any host sharing the registrable domain" would admit `business.google.com` for Google Ads, which is the exact shape the rule exists for. So a pack whose start page lands on an identity host names that host in `signInURL`, and the landing is the evidence. **That puts 15 packs' `signInURL` at odds with their catalogue row's `sign_in_url`.** Before this branch all 473 agreed. Measured with `python3 -c "import json,glob,csv;R={r['id']:r['sign_in_url'] or None for r in csv.DictReader(open('docs/sonny-skill-sites.tsv'),delimiter='\t')};print(sum((json.load(open(p))['signInURL'] or None)!=R[json.load(open(p))['id']] for p in glob.glob('Sources/MacAgent/Resources/SkillPacks/'+'*.skillpack.json')))"`, which prints `0` over `0d645464`'s packs and catalogue and `15` at `91ecb5aa`. Nothing tests that they agree. The rows were left alone, because several are held by wave-12 lanes.
- **The browser this lane had is not a clean profile, and the record says so.** The Chrome extension holds a claude.ai session of its own, so claude.ai cannot be read signed out here, and that pack went shallow for that reason alone. The profile also remembers a signed-out Google account, so Google sign-ins land on `/v3/signin/accountchooser` where a fresh profile would land on `/v3/signin/identifier`. It is the same host and the same sign-in page, and the recorded path reflects this profile.
- **`sign-in` needed tightening from a first draft**, which said a terms line bound to the primary control made a page account creation. The sweep met "by continuing you agree" under ordinary sign-in forms across the population (Fireflies, Loom, Cloudflare, X's own log-in mode). What decides is which account the form reaches: an email or username that exists signs in.
- **Browser-reading pitfalls, each measured here:**
  - The extension's output filter replaces any JavaScript result containing a query string with `[BLOCKED: Cookie/query string data]`, so read `origin + pathname`.
  - `browser_batch` has a wall-clock ceiling of roughly 30 seconds, and a slow navigation inside it times out the whole call.
  - Three agents sharing one Chrome made every tab a background tab, which produced 45-second renderer freezes. One foreground tab read about five times faster.
  - The stale-read trap happened once: Pylon's delayed redirect surfaced in the next page's read.
  - The catalogue's `sign_in_url` can be dead: Midjourney's answers a 404 page.

Known limitations / deferred scope:
- **What `offers` means is a person's judgement.** The loader holds only the two words it may be written in. A site that changes after its reading is not noticed, and `read` says how old each record is.
- **Signed-in landings were not read.** Where a flow was already correct signed out, its start URL was kept rather than swapped, so a signed-in user's landing does not move for no measured reason. The 38 that moved are the manual-test file's last row.
- **The ten packs made shallow** are named on SONNY-510 with what was tried. Restoring any of them is a pack lane reading a start page that lands admissibly. For Claude, that means a founder or a lane with a browser that holds no claude.ai session.
- **Readings went stale at each hop.** Records for packs landed by other wave-12 lanes are owed at this branch's hop, because the loader refuses their flows until then. That is expected, and it is on the ticket.

Open questions (required, write "none" if true):
- Should a pack's `signInURL` and its catalogue row's `sign_in_url` be held equal? 15 now differ, and the row is the older research value. Founders' call. It is recorded on SONNY-510.

Next branch: none named. SONNY-507's open half, whether a catalogue cell is checked for a bad seed, is the neighbouring question.
