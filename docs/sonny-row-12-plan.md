# Row 12 — hosted agent runtime backend: plan

Planning output for SONNY-16, written 2026-08-16 against `main` at `9a84e3b`. Every measurement and
every file:line below was taken at that SHA; the tree will move, so re-verify before relying on one.

This document is the durable plan. The decisions in it are recorded on the Plane tickets they belong
to as well, per the founder's 2026-08-16 directive that Plane is where context lives — this file is
the place they are assembled into one shape, not the only place they exist.

Founder decisions of 2026-08-16 (Sauransh Bhardwaj) are attributed inline. Everything not attributed
to him is the planning session's own reasoning and is open to correction.

---

## 1. Why this row exists

Sonny works on one machine in the world. Every provider key is read from a process environment
variable, and a `.app` launched from Finder inherits no shell environment — so a stranger who
double-clicks Sonny gets an app that cannot plan, transcribe, search or see. That is the single
largest gap between the current build and something anyone else can use, and it is this row's to
close (SONNY-106 section E).

Sitting on top of it: billing (row 13), the paid-only entitlement gate (row 18), account memory,
enterprise accounts (row 19), and the pricing numbers themselves — which cannot be set until this
row's metering can see what a screen-control session actually costs.

---

## 2. What is true today, verified at `9a84e3b`

### 2.1 The network surface

**Nine files in `Sources/` send an HTTP request**, across 11 send sites. Enumerated by grepping the
whole tree for `session.data(` / `session.bytes(`, then reading each hit:

| File | Send site | Needs a provider credential? |
|---|---|---|
| `OpenAIPlanner.swift` | `:68` | yes — `OPENAI_API_KEY` |
| `CerebrasPlanner.swift` | `:81` | yes — `CEREBRAS_API_KEY` |
| `OpenAITranscriber.swift` | `:74` | yes — `OPENAI_API_KEY` |
| `VisionModelClient.swift` | `:117` | yes — `OPENCODE_API_KEY` |
| `WebResearchSynthesizer.swift` | `:345` | yes — `OPENAI_API_KEY` |
| `TavilySearchProvider.swift` | `:65` | yes — `TAVILY_API_KEY` |
| `HackerNewsService.swift` | `:46`, `:55` | no |
| `MediaPlaybackService.swift` | `:652` | no |
| `WebResearchService.swift` | `:275`, `:309` | no |

**`AgentViewModel.swift` is not one of them.** Its only three `URLSession`-adjacent mentions are a
doc comment at `:778-779` and a `URLError(.cancelled)` comparison at `:784`. It makes no requests.
It still has to change in this row — the readiness check at `:424`, provider construction at
`:2027`, `:2070`, `:2071`, `:2167`, and two duplicated error literals at `:1377` and `:2090` — but
not because it is a network call site.

> **Spec correction to carry forward.** §16.5's migration note (`docs/sonny-major-release-spec.md`
> line 2153) names "every existing call site (`OpenAIPlanner`, `OpenAITranscriber`, `AgentViewModel`)"
> as needing re-pointing. That list is both stale and incomplete: `AgentViewModel` is not a call
> site, and the real set is the six credential-bearing files above. A later session reading only the
> spec will get this wrong.

### 2.2 The environment variables

21 `ProcessInfo.processInfo.environment` reads exist across 11 enclosing declarations in 11 files.
A plain single-line grep finds only 19 — two reads wrap across lines (`AgentViewModel.swift:378-379`,
`CerebrasPlanner.swift:57-58`) and are missed unless the grep tolerates the wrap.

Four are provider credentials: `OPENAI_API_KEY`, `CEREBRAS_API_KEY`, `TAVILY_API_KEY`,
`OPENCODE_API_KEY`. The rest are model names and behaviour flags (`OPENAI_MODEL`,
`OPENAI_TRANSCRIBE_MODEL`, `CEREBRAS_MODEL`, `SONNY_VISION_MODEL`, `SONNY_CEREBRAS_STRUCTURED`,
`SONNY_PLANNER`), a Word-automation mock (`MAC_AGENT_MOCK_DOCX`), and three test-harness flags.

`KeychainSecretStore` exists (`Sources/MacAgentCore/KeychainSecretStore.swift`, 80 lines) with
exactly one production caller — `LocalStorageEncryptionKeyManager`, storing one 32-byte AES-GCM key.
No API key, token or credential has ever been written to it.

### 2.3 Screen control records no usage at all

`AIUsageCallKind` (`Sources/MacAgentCore/TaskUsage.swift:3-6`) has exactly three cases: `planner`,
`webResearchSynthesis`, `transcription`. Grepping all five vision-path files
(`VisionModelClient.swift`, `VisionSession*.swift`, `AgentViewModel+VisionSession.swift`,
`ScreenCaptureService.swift`, `LocalRedactionService.swift`) for `usageRecorder`, `AIUsageRecord` or
`TaskUsageRecording` returns zero matches.

So the per-session screen-control cost that SONNY-17's pricing is waiting on cannot be derived from
anything the product records today. Building it is this row's, and it is the reason the metering
exists.

### 2.4 No shared HTTP anything

There is no shared HTTP client, no retry helper, no backoff, no error-mapping utility anywhere in
`Sources/`. Each of the nine files above builds its own `URLRequest`, does its own
`(200..<300).contains(statusCode)` check, and declares its own error enum. No explicit timeout is set
anywhere in the vision path — `URLSession.shared` runs on Foundation's stock defaults, which nothing
in this codebase chose.

A backend client that needs token refresh, 401-triggered re-auth, timeouts and retry is greenfield.

### 2.5 First run — corrected

An earlier draft of this plan said there is no first-run flow anywhere in the app. **That was wrong**,
stated from one inspected path, and it changes the design. What exists at `9a84e3b`:

- `ScreenAccessOnboardingModel` (`Sources/MacAgent/ScreenAccessOnboarding.swift:39`) and
  `ScreenAccessOnboardingView` (`:109`) — a real Screen Recording and Accessibility setup flow,
  presented from `CommandCenterView.swift:3849`, gated on `isScreenAccessSetupPresented` (`:3722`).
- `firstRunApprovalExplainerLines` (`Sources/MacAgent/AgentActivityPresentation.swift:148`), rendered
  at `FloatingWidgetView.swift:645` — first-time-only copy on the approval panel, and the one
  founder-approved exception (2026-07-24) to the no-explanatory-copy rule.

**The constraint this exposes.** `ScreenAccessOnboardingModel.relaunchNow()` (`:100`) and
`DefaultAppRelauncher` (`:12`) exist because macOS requires an app relaunch after a Screen Recording
grant. The app restarts partway through first run. A session held only in view state is lost at
exactly that moment, so the token must be written to the Keychain before any step that can relaunch.

### 2.6 Instant utilities survive offline

`InstantCommandResolver` (`Sources/MacAgentCore/InstantCommandResolver.swift`) makes no network call
of any kind and returns `.plan(AgentPlan)` directly from local stores. §16.3's requirement that free
local capabilities keep working when the network is unreachable therefore holds under this row's
architecture. Verified rather than assumed, because the whole scope decision leans on it.

---

## 3. The payload, measured

The ticket required this against a real redacted-screenshot payload rather than a documentation
figure. Method: real screen content captured at point resolution (the app sets
`configuration.captureResolution = .nominal`, `ScreenCaptureService.swift:302-303`), pushed through
the product's own encoders — `CGImageDestination` PNG (`ScreenCaptureService.swift:318-328`), then
`RedactionImageRenderer.fillRegions`' `CGContext` re-encode (`LocalRedactionService.swift:246-305`),
then the literal JSON body `OpenCodeVisionModelClient.decide` builds (`VisionModelClient.swift:95-115`).

All figures at `9a84e3b`, measured 2026-08-17 (UTC):

| case | captured px | redacted PNG (what is sent) | JSON body | body gzipped |
|---|---|---|---|---|
| small window | 570×462 | 164,422 | 228,843 | 167,434 |
| half-screen window | 864×1000 | 545,765 | 746,634 | 556,692 |
| large window | 1400×900 | 847,939 | 1,157,717 | 865,127 |
| maximized window | 1728×1080 | 1,341,223 | **1,828,535** | 1,368,775 |
| dense content, maximized | 1728×1080 | 1,937,090 | 2,667,217 | 1,996,867 |
| dense content, 5K display | 2560×1440 | 3,833,633 | 5,277,217 | 3,952,294 |

The product's own ceiling is `OpenCodeVisionModelClient.maximumImageBytes = 9_000_000`
(`VisionModelClient.swift:59`), applied to the raw PNG before base64. **The largest payload the app
will accept therefore produces a JSON body of ~12,005,000 bytes (11.45 MiB).**

A second measurement asked whether that ceiling is reachable. Pure incompressible content at point
resolution, RGBA8 through the same encoder:

| display (point resolution) | PNG of pure noise | over the 9,000,000 ceiling? |
|---|---|---|
| MacBook Pro 14/16in, 1728×1117 | 6,759,208 | no — body would be 9,017,280 |
| 27in 5K, 2560×1440 | 12,864,298 | **yes — the app refuses to send it** |
| Pro Display XDR, 3008×1692 | 17,754,831 | **yes — the app refuses to send it** |

So SONNY-114's reliability claim is real: on a large display a capture can exceed the cap, and when
it does the vision session fails the iteration rather than degrading. The user asked Sonny to do
something and it stopped, because of their monitor.

**One session sends up to 12 of these.** `VisionSessionLimits.default.maximumIterations = 12`
(`VisionSessionContainment.swift:205-211`), and `VisionSessionRunner.runLoop()` captures a fresh full
screenshot at the top of every pass (`:196-198`) — including for `wait`, `delegate`, `done` and
`stuck`. There is no diffing and no image state carried between iterations.

### 3.1 What this rules out, and what it does not

| host | documented request-body ceiling | verdict against a 12,005,000-byte body |
|---|---|---|
| Cloudflare Workers | 100 MB (Free/Pro account plans) | fits |
| Google Cloud Run | 32 MiB (HTTP/1) | fits |
| Railway | no byte ceiling documented; 5-minute upload window | fits |
| Fly.io / Render | none published either way | unknown — would need testing |
| Supabase Edge Functions | **not published at all** | unknown |
| AWS Lambda (any front door) | 6 MB synchronous invocation | **fails** |
| AWS API Gateway | 10 MB, not raisable | **fails** |
| Vercel Functions | 4.5 MB | **fails** |

Vercel is the founder's default stack. A Sonny backend on Vercel would work on his laptop — the
typical 1.8 MB body fits easily — and fail for a customer on a large monitor. That specific failure
is the reason the ticket demanded a measurement instead of a docs figure.

### 3.2 The honest limit of this measurement

The payload half is measured. **The host half is not, and cannot be until an account exists.** No
figure above for any host was observed; every one is quoted from that host's documentation. Proving
that a body of this size actually lands, with the timing it actually takes, on the host that is
chosen, is a hard gate on the first server ticket — before anything is built on top of it.

### 3.3 The payload is an accident, not a design (SONNY-114)

There is no downscale, resize, `compressionQuality`, JPEG or HEIC encode anywhere in `Sources/` or
`Tests/`. Grepping for all of them returns only window-resize *detection* code in
`ScreenActionSynthesizer.swift` and `VisionSessionRunner.swift`. ScreenCaptureKit's output is what
gets sent, at full point resolution, losslessly.

Re-encoding the same maximized-window capture measured above:

| encoding | image bytes | JSON body | vs PNG |
|---|---|---|---|
| PNG lossless (ships today) | 1,343,781 | 1,796,708 | 1.00× |
| JPEG q80 | 442,450 | 594,936 | 0.33× |
| HEIC q80 | 243,362 | 329,484 | 0.18× |

On the 5K case, PNG's 3,601,744-byte body becomes 988,636 at JPEG q80.

**This is why the host decision is held.** A shortlist built around 12 MB requests is a shortlist
built around a number we are about to change. SONNY-114 owns the change, and it is not a compression
tweak — the model returns coordinates that get scaled back to real screen positions, so downscaling
puts rounding error into click accuracy, and JPEG artifacting around small text affects what the
model can read. Both need evidence.

Two constraints this plan hands SONNY-114:
- Any resampling happens **after** redaction, never before. A downscale that ran first could smear a
  redacted region's edges. `RedactedPayload`'s initializer is `fileprivate` to
  `LocalRedactionService.swift`, which makes the ordering enforceable rather than conventional.
- `maximumImageBytes` gets re-derived from whatever encoding is chosen. Leaving a number sized for
  uncompressed PNG behind a compressed payload is a cap that no longer means anything.

---

## 4. The decisions

### 4.1 Scope — what runs on the server (founder, 2026-08-16)

**The server holds provider credentials, authenticates the user, checks entitlement, meters usage,
retains content, and forwards to the model providers. Sonny's agent loop stays on the Mac.**

The boundary is **anything that needs a provider credential**, not "model calls" — six of the nine
network files (§2.1). The three keyless routes stay local: `HackerNewsService`,
`MediaPlaybackService`, and `WebResearchService`'s page fetcher and robots.txt checker.

> **Recorded decision, with its tradeoff named.** Leaving the three keyless routes local means the
> user's own IP address reaches Hacker News, iTunes, and whatever page their command names. Proxying
> them would hide both the IP and what is being fetched. That is a privacy question rather than a
> billing one, and the decision is to leave them local — recorded here so it reads as a choice and
> not as an omission.

**This is not a deviation from §16.5 — it is §16.5.** That section's requirements are exactly this
architecture: provider credentials never ship to client, model routing controlled server-side,
provider-specific retention/training configuration, failover where appropriate. §9.1's "Sequencing
implication (added v1.2)" (spec line 1340) says in the spec's own words that moving off
direct-to-OpenAI to a backend proxy is a separate milestone from the local capability and risk-engine
work.

**What is a deviation is not building §9's server-side agent loop.** §9.1 assigns the hosted runtime
task orchestration, planning, risk classification, tool selection, trace generation and policy
pre-checks. v1 ships §16.5 plus §16.1/§16.3/§16.4's auth, entitlements and billing, and consciously
does not ship §9's orchestration. Three grounds, none of which is effort:

1. **The safety gate stays local and structural.** The consequence rule, the risk engine and the
   terminal refusal are local code that cannot be talked out of an answer. `AgentRunner.swift`,
   `RiskApproval.swift` and `ToolRegistry.swift` contain no network call of any kind — verified.
   Server-side risk classification would make a network hiccup a participant in deciding whether an
   action is destructive.
2. **§9.2's agent state model holds observations and trace events server-side.** For screen control
   those observations are screen-derived content, so the §9 architecture forces screens into server
   task state as a structural requirement rather than a bounded, disclosed choice.
3. **§16.3 requires free local capabilities to keep working when the network is unreachable.**
   Instant utilities resolve locally with no planner (§2.6), so they survive offline under this
   architecture. Under §9, creating a task at all needs the server, and that guarantee becomes false.

### 4.2 Retention — what the backend keeps (founder, 2026-08-16)

**Full request and response content is retained for a bounded period of 30–90 days**, disclosed on
the website's terms and privacy pages. Three named purposes, all chosen deliberately: debugging and
support, product analytics, and training or fine-tuning a model.

The planning session recommended metadata-only and set out the case against retention. The founder
decided otherwise with that case in front of him. It is his decision, not a default. The full record,
including the four consequences below, is SONNY-16's comment of 2026-08-16.

**This is a deviation from §16.5.** That section requires "Request logging excludes sensitive content
by default" (spec line 2145). The decision is that the backend does keep it. §16.5's other four
requirements are met in full; this one is consciously not, and it is recorded as a dated deviation on
the same footing as §9.

**It is not a reversal of the 2026-08-14 transparency posture.** Those decisions governed what the
*product says* — no data-sent-to-AI copy, no how-it-works sentences, disclosure confined to Safe mode
and the website. They did not govern what a server keeps, because there was no server. The Mac app
still says nothing and disclosure still lives on the website.

**What is stored is the redacted content.** SONNY-89's redaction runs before anything leaves the
device and `RedactedPayload`'s `fileprivate` initializer makes it structurally non-bypassable. That
is a real mitigation and it raises the stakes on redaction quality: today a miss is a transient
exposure to a provider; under retention plus training a miss is durable and can propagate into a
trained model.

Four consequences the design must handle, none optional:

1. **Training consent lives on the website, not in the app.** Training on personal data is a
   materially different promise from storing it to debug, and generally needs its own explicit basis.
   An in-app toggle would have to explain itself and would collide head-on with the 2026-08-14
   no-explanatory-copy rule. Consent is captured in the website signup flow. This is the one place
   the decision hands work back to product, and it is founder-owned.
2. **The corpus will contain third parties' personal data that no user consented on behalf of.** A
   screenshot can hold someone else's messages, medical information, another person's documents.
   Redaction catches secret-shaped strings; it cannot catch "a photo of someone else's private
   correspondence." This belongs in the founders' terms and legal work explicitly.
3. **Deletion must be able to reach the training set.** Training reads from documented snapshots with
   recorded lineage, never directly from the live store, so a deletion request can be traced to which
   snapshots it touched. This cannot be retrofitted once data has been trained on.
4. **Two retention clocks, not one.** Raw content on the short end of the range (30 days); derived
   metrics and usage indefinitely, since they are what compound in value; training snapshots on their
   own separately-consented lifecycle. Recommended split, for the founder to confirm.

Carried unchanged from the same decision: **voice audio is part of "the content"** and must be named
explicitly in what is stored and what is disclosed — it is the most personally sensitive of the four
and the one most likely to be overlooked. **Provider error bodies** route into the same store and the
same clock rather than an unclassified log, because an error body echoing input is content arriving
in a field nobody classified. **Provider request IDs** are kept for correlation.

**Two requirements arrived from row D's planning (SONNY-14) after this decision, and both land here.**
Recorded on SONNY-16 by that session on 2026-08-16; folded into ticket 11 rather than left on another
row's ticket. Both are about what the backend must be able to *not keep*, and to *un-keep* — a
retention design that only answers "what do we store and for how long" satisfies neither.

1. **Deleting a task deletes the server's copy too.** The founder decided delete means deleted
   everywhere. That needs a delete-by-task path reachable from the app, not an internal admin
   operation, and it must reach training snapshots — making consequence 3 above's snapshot lineage
   its first concrete consumer rather than a theoretical safeguard. The same path serves a user's
   data-deletion request, so it is needed twice over.
2. **An incognito run is never retained server-side.** Metered for billing, never stored: no
   debugging copy, no analytics, never in a training snapshot. Two design constraints follow.
   **Enforced server-side, not client-trusted** — a flag the client sets and the server is trusted to
   honour is a request, not a guarantee; enforce it where the storing happens. And **structurally
   excluded from training snapshots, not filtered by a query** — if an incognito run can reach a
   snapshot because someone dropped a `WHERE` clause, the guarantee is not one. Pin it with a test.
   Metering still runs; incognito affects what is stored, never what is billed. Accepted cost,
   recorded so it is not later read as a defect: a user reporting that an incognito run misbehaved
   cannot be diagnosed from stored data. That is the feature working.

**SONNY-110's justification is amended, not its work.** The zero-retention provider move is no longer
argued from "screen content should not sit in a retention window." The position is that the content
is ours and not a third party's. The provider requirement widened accordingly: **no retention AND no
training rights over our data** — a route that retains nothing but reserves training rights would
satisfy the old wording and defeat the new purpose. No closing comment or changelog entry may claim
this system does not retain screen content. It does. It just does not let the provider do it too.

### 4.3 Sign-in (founder, 2026-08-16)

**v1 ships three methods: email code, Sign in with Google, Sign in with Apple.** Email code is built
first. That is build order, not scope — under the 2026-08-16 directive that nothing is left for
later, all three are v1 and none is deferred. §16.3 sanctions both email and OAuth, so none of this
is a spec deviation.

> **A pricing rule this produced, general beyond this question.** The email-only option was priced
> with "adding a Google button later doesn't change any of this." There is no later on this project.
> Whenever an option's cost is "we can add it in a later phase," re-price it as "we add it in v1 too"
> *before* comparing options. Here that flipped the answer from one method to three.

Four things the three-method set obliges:

1. **Identity linking, designed now.** A user who signs up with email and later signs in with Google
   on the same address must land on one account. With three methods shipping together this is a
   first-release correctness requirement — getting it wrong produces a user with two accounts and one
   subscription. Decide the rule, record it, pin it with tests.
2. **Hide My Email defeats the obvious linking rule.** Sign in with Apple can hand over a
   `@privaterelay.appleid.com` address instead of the real one, so the same person appears under two
   addresses depending on which button they pressed. Email is not a stable identity key. Second
   consequence: relayed mail only forwards while the sending domain is registered with Apple and in
   good standing, so transactional email to those users depends on founder-owned setup.
3. **Verify the Apple mechanism rather than assuming it.** Establish which Sign in with Apple flow
   actually works for a Developer-ID-signed, non-App-Store Mac app — the native capability with its
   own provisioning requirements, versus a web OAuth flow of the kind Google uses. It affects
   entitlements and provisioning, so settle it before writing the contract.
4. **First run is one sequence, not a sign-in screen.** A new user on a clean Mac faces sign-in,
   Screen Recording, Accessibility, the relaunch of §2.5, and website training consent. That ordering
   has an owner in this plan's ticket set. SONNY-106 section E carries "first run works from a clean
   machine" as a v1 condition.

Apple is in the set because Apple's rule requiring Sign in with Apple alongside other third-party
sign-ins binds App Store distribution, not direct Developer-ID distribution. It does not bind Sonny
now, but it would the moment Sonny went on the Mac App Store. Including it keeps that door open
rather than closing it by accident, and the marginal cost is small given Developer Program enrolment
is already in flight for notarization. **Recorded so a later reader does not assume it was mandatory.**

Enterprise SSO is deliberately not in the set. It waits on SONNY-107's row-19 planning to say whether
v1 delivers real team accounts. The dependency runs both ways and is noted on both tickets.

On copy: `firstRunApprovalExplainerLines` is the one place the product explains itself, and it is a
founder-approved exception from 2026-07-24, not evidence that the no-explanatory-copy rule is soft.
A sign-in screen's copy is functional labels, not explanation.

### 4.4 Providers behind the router (founder, 2026-08-16)

**OpenAI and Anthropic both ship in v1, behind the provider-agnostic router, with Cerebras kept as a
server-side option.** This matches §16.5 literally ("Anthropic added second, both behind a
provider-agnostic router interface designed in from day one") and gives real failover — one provider
having a bad hour currently takes Sonny down for every user at once, which is a cost already accepted
and written down for this backend.

Cerebras costs nothing to keep: `CerebrasPlanner` already exists and is already registered with
`PlannerProviderRegistry` (`Sources/MacAgentCore/PlannerProviderRegistry.swift:154-163`). Under
server-side routing it stops being the `SONNY_PLANNER=cerebras` environment variable and becomes a
server configuration entry.

`PlannerProviderRegistry`'s `resolve(selection:)` logic is pure and stateless and moves server-side
essentially as-is. The thing that resists is usage recording: `TaskUsageRecording` is threaded through
each provider's `construct` closure and the `usageRecorder.record(...)` calls sit interleaved with
response parsing inside each `Planning` conformance's own method body (`OpenAIPlanner.swift:82-90`,
`CerebrasPlanner.swift:97-105`). Moving provider selection server-side cannot cleanly extract the
closures without relocating metering at the same time. The ticket set keeps them together for that
reason.

### 4.5 Where the backend lives (founder, 2026-08-16)

**Same repo, a new top-level `server/` directory.** One pull request shows both halves of a change,
which matters because this row repoints six client seams at an API being written at the same time.
WORKFLOW.md, Plane and the changelog keep working unchanged.

Three consequences the tickets must carry:

1. **`CLAUDE.md`'s Commands section becomes wrong the moment `server/` exists.** `swift build` and
   the flagged test command stop being *the* verification. The backend's own build, test and deploy
   commands go there in the same explicit style, saying plainly which command covers which half. A
   session that runs only `swift build` and reports green would be honestly wrong.
2. **`.gitignore` is Swift-only today.** It needs the server's equivalents — `node_modules`, build
   output, and above all local env files — **before** the first server file lands, not after.
3. **No secrets in the repo.** Provider keys are the entire reason the backend exists. Config lives
   in the platform's environment settings, never a committed file, and the review criteria check for
   it. This repo already forbids secrets in Plane content; this is the first time it has had
   somewhere tempting to put them in the tree.

### 4.6 Environments (founder, 2026-08-16)

**Two: staging and production**, plus local development — three places code runs, and each ticket
says which command targets which.

1. **Staging never holds real user data.** Not a copy of production, not a subset. Under §4.2 the
   backend keeps screenshots, command text and voice audio; a staging database seeded from production
   would put real users' screen contents in a second, less-guarded place. Seeded with synthetic data,
   stated in the ticket.
2. **How the app points at staging, without contradicting SONNY-106.** That checklist carries "no
   environment variable is required for anything" as a v1 condition, and an environment pointer is
   exactly that. The resolution: **a staging pointer exists in debug builds only, and the release
   build has no such switch.** Stated that way explicitly so the two records do not read as
   conflicting.

### 4.7 Row boundaries — 12 versus 13 versus 18 versus 109

The roadmap table gives §16.3 and §16.4 to both row 12 and row 13 by name
(`docs/sonny-v1-implementation-changelog.md:55-56`). The resolution, founder-decided 2026-08-16:

- **Row 12 builds the machinery.** Sign-in, tokens, sessions, the entitlement check, metering, spend
  and rate limits, the model gateway, the retention store.
- **Row 13 builds screens that do not exist.** The account page, plan badge, usage screen, billing
  portal link, memory.
- **SONNY-109's whole-product UI/UX pass polishes screens that do exist.** After row 12, sign-in
  exists and is functional, so **its design belongs to SONNY-109, not row 13** — otherwise the same
  screen gets designed three times.
- **Row 18 (SONNY-23) owns the §6.5 paid-only entitlement gate itself.** Under the pricing shape
  decided 2026-08-16, screen control *is* the paid line, which makes that gate the mechanism the
  whole ladder rests on. Row 12 builds the entitlement check and the signed entitlement token; row 18
  decides and builds what is gated on it. Named explicitly here so it is not discovered later with
  two rows each assuming the other has it.

**One thing pinned in row 12's contract, because it is the kind of default that gets inverted by
accident:** §16.3's entitlement cache **fails closed only for paid or gated features**. Free local
capabilities keep working when the network is unreachable. Getting that backwards breaks the offline
behaviour instant utilities depend on (§2.6).

### 4.8 Host — deliberately not decided yet

The host choice is **held**, on the founder's instruction, and is downstream of SONNY-114 (§3.3).
Everything else in this plan is host-agnostic: the API contract, the auth model, the metering shape,
the entitlement design and the client seam swap do not depend on where this runs.

Two things to carry into that decision when it is made:

- **State the Supabase objection accurately.** Its 2-second CPU limit is not a 2-second wall-clock
  limit, and a proxy is I/O-bound — it waits on the provider rather than computing. The real
  objection is the **unpublished request-body ceiling**, and that is precisely the objection SONNY-114
  may dissolve.
- **Per-user spend caps need an atomic answer.** A hybrid shape — accounts in one place, the AI path
  in another — means the gateway reads and writes the account store on every call: latency, plus a
  race window on concurrent requests from the same user. A leaked token billing the founder is an
  accepted cost already recorded on SONNY-16, which makes an atomic spend cap a requirement of the
  design rather than later hardening. Whichever host wins, the decision says how the cap is enforced
  and what happens on a race.

---

## 5. Failure modes this row must answer

Named here so none of them is discovered during implementation. Each has a home in the ticket set.

- **Backend unreachable.** One outage takes Sonny down for every user at once. Free local
  capabilities keep working (§4.7); everything else needs a stated, non-raw user-facing behaviour.
- **Token expiry mid-session.** A screen-control session makes up to 12 sequential requests with no
  server-side session ID — continuity lives client-side in `history`. An access token expiring
  between iteration 4 and 5 needs defined refresh-and-retry behaviour.
- **Backend 5xx mid-loop.** Retry, or abort with partial `history`, or a new typed error alongside
  `VisionModelClientError`'s existing five cases (`VisionModelClient.swift:27-36`). Decide, do not
  discover.
- **Clock skew.** Offline entitlement rests on a signed token with a hard expiry. A Mac with a wrong
  clock falsely rejects a valid token or accepts an expired one. Needs a tolerance window or a
  server-time reference.
- **Corporate proxies and captive portals.** Every one of the nine networking files uses
  `URLSession.shared` with no configuration override. This row inherits that gap and should not
  compound it.
- **Free-tier abuse.** Scripted hammering of the vision loop drains founder-funded spend. Per-user
  rate and spend caps, enforced atomically (§4.8).
- **A leaked or stolen token.** Detection, device binding, revocation.
- **An old app version pinned to a removed API shape.** The versioning rule and how an old client
  detects a breaking change.
- **Provider key rotation.** Zero-downtime rotation of the backend's own OpenAI, Anthropic, Cerebras,
  Tavily and vision credentials, once a backend sits between every user and every AI call.
- **Account deletion's server-side reach.** `LocalDataDeletionService` wipes eight local stores and is
  client-only. Deleting an account must also reach server-held content, usage history and training
  snapshot lineage (§4.2, consequence 3).
- **Support without violating the retention classification.** A founder needs to look up a user's
  entitlement state and recent usage. That capability is a deliverable, not an afterthought.

---

## 6. Founder-owned dependencies

Flagged, not designed around, per the 2026-08-16 directive. Each blocks something specific.

| Dependency | Blocks |
|---|---|
| Host account (whichever is chosen) | every server ticket, and the payload measurement of §3.2 |
| Production email sending domain with SPF, DKIM, DMARC (Resend or Loops) | email-code sign-in. Supabase's built-in sending is rate-limited and not for production. Deliverability is the primary failure mode of email codes, and this has real lead time |
| Google Cloud OAuth client | Sign in with Google |
| Sign in with Apple service identifier and key, on the Developer Program account | Sign in with Apple, plus the sending-domain registration Hide My Email relaying depends on |
| Apple Developer enrolment | signing and notarization (row 20, SONNY-108) — already in flight |
| Payment provider account | row 13's billing implementation (SONNY-17) |
| Zero-retention, no-training vision provider purchase | SONNY-110, a named release blocker |
| Terms and privacy pages covering what is retained, for how long, the three purposes including training, and the deletion path | launch |
| Training consent captured in the website signup flow | §4.2 consequence 1 — the one piece of product work this hands back |

---

## 7. Open question for the founder, deliberately left open

Nothing in this row is blocked on it, but it should not go unasked. SONNY-110's triage comment of
2026-08-16 enumerated the other egress routes: the default planner sends the user's typed or spoken
command text on **every ordinary command**, the transcriber sends raw voice audio, the synthesizer
sends fetched page content, and Tavily receives search queries. A zero-retention, no-training
requirement applied only to the vision route leaves all of those where they are, on routes that fire
far more often than screen control does. Worth a sentence from the founder either way, so the answer
is on record rather than implied.

---

## 8. The ticket set

Fourteen tickets. Dependency order below; disjointness for parallel running is recorded on each
ticket at creation, per WORKFLOW.md step 3.

**Gate, before any server ticket starts:** SONNY-114 triaged and settled (payload encoding), and the
host account opened.

Created 2026-08-16 after founder approval of the batch, and attached to the
"12 — hosted agent runtime backend" module. Numbers read back from the API, never predicted.

| Ticket | Title | Branch | Depends on |
|---|---|---|---|
| SONNY-124 | Backend API contract and versioning rule (docs only) | `docs/row-12-api-contract` | — |
| SONNY-125 | Choose the host, and prove a real payload lands on it | `docs/row-12-host-decision` | SONNY-114, host account |
| SONNY-126 | Server foundation: `server/`, config, secrets, three environments, deploy, key rotation | `feature/row-12-server-foundation` | 124, 125 |
| SONNY-127 | Accounts, email-code sign-in, sessions, identity-linking rule (server) | `feature/row-12-accounts-email` | 126 |
| SONNY-128 | Client sign-in, Keychain token, shared backend HTTP client | `feature/row-12-client-signin` | 124, 127 |
| SONNY-129 | Sign in with Google and Sign in with Apple | `feature/row-12-social-signin` | 127, 128 |
| SONNY-130 | Gateway: planner, web-research synthesis, transcription, search — end to end | `feature/row-12-gateway-text` | 126, 127, 128 |
| SONNY-131 | Gateway: the vision route — end to end | `feature/row-12-gateway-vision` | 130, SONNY-114 |
| SONNY-132 | Server-side provider routing: OpenAI, Anthropic, Cerebras, with failover | `feature/row-12-provider-router` | 130 |
| SONNY-133 | Metering, including the screen-control cost that records nothing today | `feature/row-12-metering` | 130, 131 |
| SONNY-134 | Retention: two clocks, delete-by-task, never-store for incognito, snapshot lineage, support lookup | `feature/row-12-retention` | 126, 133 |
| SONNY-135 | Entitlements: signed token, offline grace, fail-closed-for-paid-only, atomic caps | `feature/row-12-entitlements` | 127, 133 |
| SONNY-136 | Backend-unreachable behaviour, mid-session token expiry, env-var removal sweep | `feature/row-12-degradation` | 130, 131 |
| SONNY-137 | First run as one sequence: sign in, Screen Recording, Accessibility, relaunch, back signed in | `feature/row-12-first-run` | 128, 136 |

### 8.1 Review depth

**SONNY-127, SONNY-128 and SONNY-135 carry an adversarial security review before merge** — a fresh
session briefed to break the thing rather than validate it — and **the founder reads those three
diffs himself** rather than delegating the read. Everything else takes the ordinary fresh-session
review of WORKFLOW.md step 7.

The reasoning, recorded because the obvious alternative was rejected: the founder's stated
willingness to hand-write the hardest parts stands, but **authorship is not the control that matters
here — review depth is.** His bottleneck is review capacity, not typing, so putting him at the
keyboard would spend the scarce resource to buy the plentiful one. The bespoke risk in this row is
not sign-in, which is platform primitives and configuration; it is Keychain token handling across the
relaunch (SONNY-128), and entitlement-token signing plus spend-cap atomicity under concurrent
requests (SONNY-135). Those get the hostile reviewer.

### 8.2 Disjointness, per WORKFLOW.md step 3

Recorded now rather than improvised later. **Absence of a note here means serial.**

- **SONNY-124 runs alone and first.** Everything else is written against the contract it produces.
- **SONNY-127 and SONNY-128 may run in parallel once SONNY-124 and SONNY-126 are merged.** SONNY-127
  touches only `server/`; SONNY-128 touches only `Sources/` and `Tests/`. Their shared assumption is
  the API contract, which is fixed by then. SONNY-128 needs a live server to sign in against, so it
  can build in parallel but cannot close before SONNY-127 merges.
- **SONNY-132 and SONNY-133 may run in parallel after SONNY-130.** Disjoint on the server; SONNY-132
  touches `PlannerProviderRegistry.swift` and `CerebrasPlanner.swift` on the client, SONNY-133 at
  most `TaskUsage.swift`.
- **SONNY-134 and SONNY-135 may run in parallel after SONNY-133.** Both read the metering shape;
  neither redefines it. SONNY-134 is server-only, SONNY-135 spans both.
- **Serial, explicitly:** SONNY-130 → SONNY-131 (SONNY-131 follows the gateway pattern SONNY-130
  establishes); SONNY-136 after both gateways (it removes what they make dead); SONNY-137 after
  SONNY-136 (first run must not walk a user through states SONNY-136 is still rewriting).
- **The known cross-row collision:** SONNY-129 and SONNY-137 touch Settings and the first-run
  surface, and SONNY-104's per-app control work lands a revocation list in the same Settings family.
  Neither has been designed. Recorded here rather than discovered at implementation; both arrive in
  SONNY-109's pass as functional-but-unpolished surfaces.

Ticket 13 is where "no environment variable is required for anything" (SONNY-106 section E) actually
becomes true, and where the ~10 independent "export a variable" strings get rewritten. They are
separate literals at separate call sites (`OpenAIPlanner.swift:22`, `OpenAITranscriber.swift:12`,
`TavilySearchProvider.swift:10`, `CerebrasPlanner.swift:11`, `VisionModelClient.swift:27-28`,
`PermissionReadinessService.swift:50`, and duplicated verbatim at `AgentViewModel.swift:1377` and
`:2090`), not one shared string.

`PermissionReadinessService.currentStatus` checks only `OPENAI_API_KEY` today and has no readiness
entry for Tavily, Cerebras or the vision route — the mental model a "signed in and entitled" item
replaces is already incomplete for the current four-provider reality. That is ticket 13's too.
