# Row 12 — where Sonny's backend runs: the measurements, and the decision they support

SONNY-125. Branch `docs/row-12-host-decision`. All host measurements taken **2026-08-20 (UTC)**.

Every figure in the results tables was observed against a live endpoint. **None is quoted from a
host's documentation.** Where a documented figure appears it is labelled as one and placed beside
the measurement that tested it, because comparing the two is the point of the ticket.

Repository figures — payload sizes, iteration counts — were measured at `87199ff` and **re-verified
at `a44156f`**, this branch's head. **The branch point is `d71690f`, not `87199ff`**: the branch was
rebased after PR #79 merged, and an earlier draft of this line called `87199ff` the branch point
(PR #82 cycle 1, F5). That re-verification was not ceremonial — `git diff --stat 87199ff a44156f --
Sources/` is 4 files and 156 insertions, so the tree under those figures genuinely moved. All three
still hold: `maximumImageBytes: 3_000_000` (`RedactedCaptureEncoder.swift:92`),
`maximumIterations: 12` (`VisionSessionContainment.swift:239`), and the streaming sweep still
returns zero matches.

The harness, the probe sources and the raw logs live in `scripts/host-probe/`. §13 says how to
re-run any row below.

---

## 1. The short version

**Supabase Edge Functions carries the real workload, with margin on the axis that was in doubt and
a hard edge 45 seconds past the one the contract needs.** The founder's 2026-08-17 decision
survives its own test.

| what had to be true | needed | measured | verdict |
|---|---|---|---|
| a 4,200,000-byte body lands (contract §6.1) | 4,200,000 | `200`, and no refusal up to **67,200,000** | passes, 16× over |
| a request may sit on a slow upstream (contract §12) | 105 s | `200` at **105.19 s**; cut off at **150 s** | passes, 45 s margin |
| the same, waiting on a real outbound `fetch` | 105 s | `200` at **105.72 s** | passes |
| `Content-Encoding: gzip` survives (contract §6.4) | must arrive | arrives still compressed; inflates in **26 ms** | passes |
| a per-user spend cap that is atomic under a race | must exist | one statement; demonstrated against Postgres 17 | answered |

**The one number that would have killed it is the 150-second cliff, and it did not.** A vision
call gets 105 seconds by contract; the platform allows 150 on the plan measured. That is real
margin, not a rounding error, but it is also not generous — §8 says what to do with it.

**Read §12 before acting on any of this.** On **2026-08-21**, after these measurements were taken
and on the strength of them, the founder decided that **the gateway will run on a VM rather than on
Edge Functions** — staged deploymind → Oracle → AWS — while **Supabase keeps auth and Postgres**.
**The deploymind stage was then dropped on 2026-08-30** (founder decision, SONNY-373), leaving
**Oracle Cloud first and AWS for v1**; §12.4 is the live record and §12.2 is kept as what was
decided on 2026-08-21. So the Edge ceilings below stop binding on the shipping architecture: the
gateway will choose its own limits. What survives that decision intact is the spend-cap proof (§9),
which is Postgres's and so still live, the payload arithmetic (§2), and the gzip cost (§4.2). **The
measurements are kept in full because they are the evidence the decision was made against**, not
despite being superseded.

---

## 2. What the numbers had to be measured against

Both figures below are derived from Sonny's own code, not chosen for convenience.

**Payload.** SONNY-114 settled the encoding. `VisionCaptureEgressPolicy.default.maximumImageBytes`
is **3,000,000** bytes (`Sources/MacAgentCore/RedactedCaptureEncoder.swift:92`, verified at
`87199ff`). Base64 makes that exactly `ceil(3,000,000/3)×4 = 4,000,000` characters; plus SONNY-114's
measured 4,673-character prompt and about 120 bytes of JSON envelope, a request at the client's own
ceiling is **4,004,793** bytes. The contract sets the server limit at **4,200,000**
(`docs/sonny-backend-api-contract.md` §6.1), and §13 of that document names proving it lands as
this ticket's.

Four sizes were posted, each raw and gzipped:

| size | why this number |
|---|---|
| 664,000 | SONNY-114's densest *real* capture (display 1, 494,351 image bytes) as a request body |
| 3,512,879 | the largest body across all fifteen of SONNY-114's fixtures |
| 4,004,793 | the largest body the client can construct |
| 4,200,000 | the contract's server-side limit |

**Wall clock.** Contract §12 gives `POST /v1/screen/analyze` a 90 s upstream deadline and a
**105 s total deadline**. So 105 s is the number a platform has to allow a request to sit.

**Compression.** SONNY-146 merged; vision bodies can be gzip-encoded, and §6.4 obliges Sonny's own
gateway to accept `Content-Encoding: gzip` and apply size limits to the **decoded** body. Every
size was therefore posted both ways: the compressed body is what Sonny will send, the decoded one
is what a platform that rejects or transparently inflates gzip would see. Measuring one answers
half the question.

The probe payload is a JSON envelope of the same shape `OpenCodeVisionModelClient.decide` builds
(`Sources/MacAgentCore/VisionModelClient.swift:154-171`), carrying base64 of `os.urandom`. That is
deliberate: base64 of incompressible bytes deflates to about 6/8 = 0.75, because gzip recovers
base64's own overhead and nothing else. Observed across the four sizes: **0.7523, 0.7565, 0.7566,
0.7566** — within a thousandth of the **0.753** floor SONNY-146 measured on a seeded-noise capture.
So these bodies compress as badly as anything Sonny can actually produce, and the limits below were
tested against the worst gzip ratio rather than a flattering one.

---

## 3. Method, and the control that makes it readable

One handler, deployed unchanged to both hosts and run locally, so any difference in the numbers is
the platform rather than the probe. Routes: `echo` (read the body, report what arrived),
`slow?ms=N` (sleep N ms in-handler), `up?ms=N` (fetch a deliberately slow upstream and wait),
`drip?ms=N` (stream from the first byte). One `curl` per measurement, with the body and the metrics
taken from the same request.

A control arm ran on `localhost` before any host was touched: same handler, same runtime family
Supabase Edge Functions use (Deno 2.7.12), nothing in between. **The figures cited below are not
that first run.** They come from a clean re-run taken at 21:53–21:57 UTC — *after* the host runs of
21:20–21:46 — because the first run's log turned out to be unusable, for the reason two paragraphs
down. Said plainly rather than left to be inferred from timestamps: **the control that is quoted
here post-dates the measurements it is a control for.** What it establishes is unaffected — the
machine, the uplink, `curl` and the handler are the same in both windows, and the arm's purpose is
to show that none of them is a bottleneck — but a reader is entitled to know the order, and an
earlier draft of this section implied the opposite by opening "ran first" (PR #82 cycle 1, F10).

| arm | result |
|---|---|
| all four sizes, raw and gzip | `200`, 5–30 ms |
| `slow?ms=105000` | `200` at **105.005 s** |
| `up?ms=105000` (real outbound fetch) | `200` at **105.015 s** |
| body ladder | `200` at 16,800,000, where the ladder **stopped at its cap** rather than being refused |

So the machine, the uplink, `curl` and the probe code all hold a 105-second request and a 4.2 MB
body without complaint. **Anything that fails on a host below is the host.**

**Those control figures are a re-run, and the reason is worth recording.** The first control run
shared its log with a concurrent one: two `probe.sh` invocations under the same label appended to
one file through `tee -a`, and the result interleaved — the timing run lost its `=== finished`
line, a ceiling ladder was written inside it, and a second ladder ended up in the file with no
header naming the command that produced it. **A measurement whose provenance cannot be established
is not a measurement**, so nothing was cited from it; the control was re-run with nothing else
writing, and `results/local-control.txt` carries four strictly sequential runs verified by their own
timestamps. `probe.sh` now takes a per-label lock and refuses the second run outright, the same
shape as `scripts/mutate`'s. The contaminated file is kept as
`results/local-deno-INTERLEAVED-superseded.txt` with a header explaining it, rather than deleted.

**The host logs were checked the same way and are clean.** Every run in `supabase.txt` and
`cloudflare.txt` is strictly sequential with no overlap — on Supabase `sizes` 21:20:27→21:20:59,
`times` 21:22:11→21:31:29, `up` 21:31:29→21:35:45, `drip` 21:35:45→21:38:16, `ceiling`
21:42:19→21:43:27 then 21:43:47→21:45:35; on Cloudflare `times` 21:22:14→21:34:01, `up`
21:34:01→21:35:46, `sizes` 21:41:29→21:41:53, `ceiling` 21:45:35→21:46:38. **Every figure the
decision rests on comes from a run that owned its log.**

One thing the control also fixes: a 4.2 MB upload took about 4 s from this machine, and that is the
connection, not the platform. Across the 26 POSTs to the two hosts, `time_connect` ran 0.020 s to
0.290 s (median 0.037), and `time_starttransfer` never differed from `time_total` by more than
**0.0016 s** — the server answers only once the upload finishes, so the wall-clock in §4 and §5 is
upload time plus handler time. Nothing below reads a slow uplink as a slow host.

---

## 4. Supabase Edge Functions — the decided host

Project `zpyyljfsqrxulhmgkhfp` (`us-east-2`, Postgres 17.6.1.155), **Free plan**, deployed with
`--no-verify-jwt`. Endpoint `https://zpyyljfsqrxulhmgkhfp.supabase.co/functions/v1/probe`.

### 4.1 Request body — the objection that was never testable from documentation

| decoded bytes | wire bytes | encoding | status | wall clock | handler saw |
|---|---|---|---|---|---|
| 664,000 | 664,000 | raw | `200` | 0.76 s | 664,000 |
| 664,000 | 499,537 | gzip | `200` | 0.92 s | 499,537 → inflated 664,000 |
| 3,512,879 | 3,512,879 | raw | `200` | 4.92 s | 3,512,879 |
| 3,512,879 | 2,657,497 | gzip | `200` | 4.77 s | 2,657,497 → inflated 3,512,879 |
| 4,004,793 | 4,004,793 | raw | `200` | 5.25 s | 4,004,793 |
| 4,004,793 | 3,030,065 | gzip | `200` | 5.64 s | 3,030,065 → inflated 4,004,793 |
| **4,200,000** | **4,200,000** | **raw** | **`200`** | **4.38 s** | **4,200,000** |
| **4,200,000** | **3,177,921** | **gzip** | **`200`** | **4.43 s** | **3,177,921 → inflated 4,200,000** |

Ceiling ladder, raw: `200` at 4,200,000 → 8,400,000 → 16,800,000 → 33,600,000 → **67,200,000**. The
ladder was stopped there, not refused; §11 says why stopping was the right call.

**Supabase publishes no request-body limit at all, and the reason turns out to be that there is
nothing to publish in the range Sonny occupies.** The contract's figure clears by a factor of 16.

### 4.2 Compression — the platform does not inflate for you

At every size the handler received `still_gzipped: true` with the original `Content-Encoding: gzip`
header intact. **Supabase passes a gzip request body through untouched**, so the gateway inflates it
itself, which is exactly what §6.4 already requires. Inflating 3,177,921 → 4,200,000 cost **26 ms**
of handler wall-clock.

That matters more than it used to. Row 12's plan (§4.8) records the standing rebuttal to the
Supabase CPU objection: "a proxy is I/O-bound." **That reasoning predates the compression
requirement.** Inflating a 3.2 MB body and applying a limit to the decoded result is CPU, not I/O,
and Supabase caps CPU at 2 s separately from wall clock. So the objection is live again on a path
where it genuinely was not — and the measurement says it costs 26 ms, about 1.3% of that budget.
Stated precisely because it was raised precisely: `actual_ms` is handler *wall-clock*, which bounds
CPU from above rather than measuring it. Neither platform exposes a per-request CPU figure to the
handler. What can be said is that no request was terminated for a CPU reason at any size.

### 4.3 Execution time — the measurement the whole row rested on

| requested hold | route | status | wall clock |
|---|---|---|---|
| 1 s | `slow` | `200` | 1.19 s |
| **105 s** | **`slow`** | **`200`** | **105.19 s** |
| 150 s | `slow` | `546` † | 150.16 s |
| 200 s | `slow` | `546` † | 150.65 s |
| 400 s | `slow` | `546` † | 150.27 s |
| **105 s** | **`up`** (real outbound `fetch`) | **`200`** | **105.72 s** |
| 200 s | `up` | `546` † | 150.36 s |

† **The status varies run to run** — `546`, `504` and `503` have all been observed at this same
cliff. These four are what this battery returned; see below.

**The cliff is 150 seconds, and it is a hard one** — 150 s, 200 s and 400 s all terminate within
0.5 s of the same wall-clock. The contract needs 105.

**The status is not single-valued, and an earlier version of this document said it was** (PR #82
cycle 1, F1). It reported `546 WORKER_RESOURCE_LIMIT` as *the* outcome, because that is what all
four cut-off requests in the original battery returned. It is one of at least three. Across three
independent sittings against the same endpoint and the same `slow?ms=200000` request:

| sitting | observed |
|---|---|
| original battery, 2026-08-20 | 4 × `546 WORKER_RESOURCE_LIMIT` |
| cycle-1 reviewer, independently | 2 × `546`, 2 × `504 IDLE_TIMEOUT` |
| this session's six-run re-measurement, 2026-08-20 (`results/supabase-cutoff-statuses.txt`) | 5 × `504 IDLE_TIMEOUT`, 1 × `503` with an **empty body** |

So the same request, cut off at the same limit, answers `546`, `504` or `503` depending on nothing
the caller controls. The two bodies:

```json
{"code":"WORKER_RESOURCE_LIMIT","message":"Function failed due to not having enough compute resources (please check logs)"}
{"code":"IDLE_TIMEOUT","message":"Request idle timeout limit (150s) reached"}
```

and the `503` carried no body at all — so a client parsing the error object gets nothing to parse.

**Only one of those messages is misleading, and the original document blamed the wrong thing by
generalising from it.** `IDLE_TIMEOUT`'s text is accurate and even names the limit. The
`WORKER_RESOURCE_LIMIT` text is not: the function under test was *sleeping* — it consumed no CPU and
allocated nothing — and the message blames compute resources, so anyone debugging a real occurrence
from it would go looking for a CPU or memory problem that is not there. That warning stands for
`546`; it does not apply to `504`.

**Why the correction is worth more than the fact.** The original claim was not a guess — it was four
consistent observations, reported as a rule. Four runs of a non-deterministic behaviour that happen
to agree read exactly like a deterministic one, and nothing in the log said otherwise. The lesson is
the repository's own quantified-claim rule pointed at a status code: **a single-valued answer needs
a population, not a streak.**

**The 150 s figure is the Free plan's.** Supabase documents 400 s for paid plans; that is a
documentation figure, it was not measured here, and it is only ever more headroom. **The number that
decided the row was taken on the tighter of the two plans**, which makes it the conservative one.

### 4.4 Streaming — where the honest failure becomes a silent one

Not a named requirement of the ticket; the coordinator's 2026-08-17 comment asked for it to be
checked in the same sitting rather than discovered later. It was, and it found the worst behaviour
in this document.

| requested hold | route | status | wall clock | body |
|---|---|---|---|---|
| 200 s | `drip` (streams from the first byte) | **`200`** | 150.53 s | **truncated** |

Reproduced a second time live: `HTTP=200 time=150.24`, and the body fails to parse —
`json.decoder.JSONDecodeError: Unterminated string starting at: line 1 column 29`. `curl` reports
success.

**A streamed response that outruns the 150 s limit reaches the client as HTTP 200 with a truncated
body.** Streaming does not evade the cut-off; it converts a diagnosable failure into an undetectable
one. The non-streaming path fails with a real error status — `546`, `504` or `503` (§4.3) — and,
for the first two, a parseable error object.

This is a finding in the contract's favour rather than against it. Contract §4 defines no streaming
route, and the client streams nowhere: a sweep of `Sources/` and `Tests/` at `87199ff` for
`stream: true`, `"stream"`, `text/event-stream`, `AsyncBytes`, `.bytes(` and `chunked` returns
**zero matches**. (Widening it to `EventSource` case-insensitively returns two files —
`ScreenActionSynthesizer.swift` and `SystemSessionAttentionMonitor.swift` — and both are Core
Graphics' `CGEventSource`, which is an input-event source and has nothing to do with HTTP
streaming. Recorded because the wider sweep is the one that looks like a hit.) So the existing
design is now **measured** correct on this point rather than incidentally correct, and "the gateway
must not stream" has an evidenced reason behind it for whoever writes SONNY-131.

---

## 5. Cloudflare Workers — the fallback, measured so it is a number and not a hope

Free plan, `https://sonny-host-probe.sbhardwaj1418.workers.dev`. In the running because the founder's
own 2026-08-17 comment names the fallback shape: if a limit bites, auth and database stay on
Supabase and the gateway moves. A fallback quoted from a documentation page would repeat exactly
the mistake this ticket exists to prevent.

| arm | result |
|---|---|
| all four sizes, raw and gzip | `200`; 4,200,000 raw and 3,177,921 gzip both arrive intact |
| gzip handling | not inflated by the platform; handler inflates in **28 ms**; **no error 1102** at any size |
| ceiling ladder | `200` at 4,200,000 → 8,400,000 → 16,800,000 → **33,600,000**; stopped at cap, not refused |
| `slow?ms=105000` | `200` at 105.08 s |
| `slow?ms=200000` | `200` at 200.18 s |
| **`slow?ms=400000`** | **`200` at 400.11 s** |
| `up?ms=105000` | `200` at 105.30 s |

**No wall-clock cliff was found up to 400 seconds.** Cloudflare's documentation claims no hard
duration limit for HTTP-triggered Workers; that claim survived a 400-second test here.

The Free plan's 10 ms CPU allowance was the specific reason to measure rather than assume — a
3.2 MB gzip inflate is CPU, and 10 ms is not much of it. **No request returned error 1102** (the
CPU-exceeded code) at any size, raw or gzipped.

**One thing that cost time and will cost the next session time too:** a Worker fetching another
Worker **on the same zone** returns Cloudflare **error 1042**, surfacing as an upstream `404` with
`error code: 1042` in the body. Two Workers on one `workers.dev` subdomain are the same zone.

**Evidence: `results/cloudflare-1042-same-zone.txt`.** When this document was first written that
claim had none — it came from an interactive observation during setup that was never written to a
log, which made it the one assertion here resting on a session's memory rather than a file (PR #82
cycle 1, F7). It has since been reproduced deliberately: a throwaway Worker pointed at another
Worker on the same subdomain returned `error code: 1042` on **all three** runs, and the same code
reaching a **cross-zone** upstream returned `200` twice with the upstream genuinely waiting its
1000 ms. The control matters — without it the finding could equally have been a broken handler.

The `up` arms were therefore cross-wired — Cloudflare's probe fetches Supabase's `slow`, Supabase's
fetches Cloudflare's — which also bounds the measurement: Cloudflare's `up` arm cannot be pushed
past Supabase's own 150 s ceiling, so it was tested at 105 s only. The in-handler `slow` arm carries
the 400-second result.

---

## 6. What was not measured, and why — so no absence is read as an exclusion

**Vercel Functions — re-checked on paper, deliberately not measured, and no longer excluded.**
SONNY-125's own decisions-carried section says the hosts ruled out against a 12 MB body should be
*re-checked rather than inherited*. Doing that: Vercel's documented request-body limit is still
**4.5 MB**, and the settled contract figure of 4,200,000 now sits **under** it by about 300,000
bytes; Vercel's documented Hobby max duration is now **300 s**, comfortably past 105. So Vercel
moved from "fails" to "in range, on a ~7% margin." **Both of those are documentation figures and
neither satisfies this ticket.** The founder chose on 2026-08-20 not to spend an account on
measuring it, which is a reasonable call given the decision is Supabase. Recorded so that anyone
reading §3.1 of the plan does not carry forward an exclusion that the payload change dissolved.

**Google Cloud Run** — the escape from the serverless request model, i.e. the "move to a virtual
machine" the founder already accepted as a future-version option. Not measured: it needs a billing
account with a card, and Cloudflare already supplies a measured fallback.

**Fly.io** — dropped before the founder was asked. No free tier for new signups since 2024 and a
card required, so it costs money to answer a question Cloudflare answers free.

**Render** — dropped for a structural reason rather than a cost one: free web services deploy only
from a Git repository or a container image, so probing it would mean publishing a throwaway repo.

**Cloudflare's undocumented `--temporary` preview account** — `wrangler whoami` advertises it as a
way to deploy with no login. Not used. It is absent from `wrangler deploy --help`'s own option list,
and a number taken from an account whose plan cannot be named is a number that cannot be attributed
to "Cloudflare Workers, Free plan."

---

## 7. The Supabase objection, stated accurately

Required by the ticket, and the plan's §4.8 asks for the same thing. Three separate claims, only
one of which was ever the real objection:

1. **"The 2-second CPU limit kills it."** Wrong as stated, and it was wrong before this ticket: the
   limit is CPU, not wall clock, and a proxy waits on a provider rather than computing. The
   measurements confirm the shape — a 105-second request that consumes no CPU completes.
2. **"A proxy is I/O-bound, so CPU does not matter."** **Now only mostly true, and this document is
   where that changes.** §6.4 obliges the gateway to inflate a gzip body and apply limits to the
   decoded result, which is CPU work on a multi-megabyte body. Measured: 26 ms against a 2 s budget.
   Not a problem — but it is no longer a category that can be waved away, and if the payload ceiling
   ever rises it is the first thing to re-measure.
3. **"No request-body ceiling is published at all."** This was the real objection, correctly
   identified in the plan and in the ticket, and **it is now answered**: no refusal up to 67,200,000
   bytes, 16× the contract's limit.

The objection that actually deserved the worry was none of these. It was **wall clock**, which the
plan named as SONNY-125's second requirement and which the coordinator's comment ranked first. The
answer is 150 seconds against a 105-second need.

---

## 8. The 150-second cliff, and what row 12 should do with it

The founder's recorded decision of 2026-08-17 is that a bad measurement here is information, not a
blocker: mitigation is a future-version problem, the measurement is not. The measurement ran. This
section records what it found and stops there.

**The margin is 45 seconds, and it is not evenly distributed.** Contract §12 gives the upstream
90 s and the total 105 s. If a provider call runs long and the gateway's own overhead is small, the
request lands near 105 and the platform allows 150. But the same 150 s ceiling applies to
`/v1/research/synthesize`, which shares the 105 s budget.

Three things follow, none of which is a change to the plan:

- **The gateway must not stream** (§4.4). Not a preference — streaming is what turns the cut-off
  from a real error status into a silent truncation the client cannot detect.
- **The cut-off's status has no home in the error taxonomy — and it is not one status.** `546`,
  `504` and `503` have all been observed at the same cliff (§4.3). Contract §7's taxonomy has an
  entry for none of them, and §12 promises the client sees a typed `504 provider.timeout` rather
  than a transport error; a bare platform `504` that happens to share that number is not the same
  thing, and the `503` arrived with no body at all. **This was named on SONNY-136** (backend
  unreachable, error copy) **and SONNY-131** (vision mid-loop failure) when this document was
  written. **The 2026-08-21 VM decision (§12.2) makes that work moot for the shipping
  architecture** — the gateway sets its own timeouts and returns its own typed errors — and both
  comments have been corrected accordingly. Kept here because it is what a gateway on Edge Functions
  would have had to absorb, which is part of what the decision was taken against.
- **The Pro plan's documented 400 s is headroom nobody has measured.** If the 45 s ever looks tight,
  that is the first measurement to take, and it takes ten minutes with `scripts/host-probe/`.

---

## 9. The per-user spend cap, demonstrated rather than asserted

The ticket is explicit: *a design that cannot answer the race does not satisfy this ticket.* So it
is answered against a real Postgres — **17.11**, in a container, matching the engine version the
Supabase project reports (17.6.1.155). The property is Postgres's, not Supabase's hosting, and that
distinction is stated rather than blurred: **this was not run against the Supabase instance**, and
it did not need to be.

### 9.1 Where the counter lives

A row per user per billing period in Postgres — `usage_period(user_id, period_start, cap_credits,
spent, reserved)`, with `CHECK (spent + reserved <= cap_credits)`. Not in function memory and not in
a cache: Edge Functions are stateless with no shared memory between invocations, so a counter
outside the database has no consistency story at all. This is the argument the founder's decision
comment already made for putting everything on Supabase, and it holds up.

### 9.2 How the cap is enforced — reserve, then settle

Before the upstream call, **one statement**:

```sql
UPDATE usage_period
   SET reserved = reserved + p_amount
 WHERE user_id = p_user AND period_start = p_period
   AND spent + reserved + p_amount <= cap_credits
RETURNING reserved;
```

No rows returned means the cap is reached, and the request is refused **before any provider is
called**. After the call, `settle()` releases the hold and charges the actual cost in the same
transaction as the metering event, so a charge cannot exist without its audit row.

### 9.3 What happens when two requests from one user race

**One statement is the whole mechanism.** Under READ COMMITTED — Postgres's default and Supabase's
— an `UPDATE` that meets a row a concurrent transaction has just updated does not use the snapshot
it began with. It waits for that transaction, then **re-evaluates its own `WHERE` against the new
row version**. So the second racer tests `spent + reserved + amount <= cap` against a row that
already carries the first one's reservation, finds it does not fit, and is skipped. No advisory
lock, no `SELECT … FOR UPDATE`, no retry loop, and no read-then-write window to slip through.

Observed, 2026-08-20:

| test | result |
|---|---|
| two racers, cap fits one | `A=100`, `B=REFUSED`. B blocked **1.58 s** on A's row lock, then re-evaluated. Final `reserved` = 100 = cap. |
| 50 concurrent reservations, cap fits 10 | **10 wins, 40 refusals.** Final `reserved` = 1000 = cap exactly. |
| a request killed mid-flight | hold survives; a second request is correctly `REFUSED`; `sweep()` reclaims 1 expired hold; the second request then succeeds |
| `settle()` called twice | `spent` 400 both times — idempotent, so a retried settle charges once |

### 9.4 The control, which is the part worth reading

**The first version of this control was wrong, and it is recorded here because the way it was wrong
is the failure mode this repository keeps meeting.** It printed "both read 0 under their own
snapshots, both wrote" as narration, showed neither, and its own final state — `reserved` = 100, not
200 — contradicted it. What had actually stopped the second write was the `CHECK` constraint. The
control was demonstrating the constraint while claiming to demonstrate the race.

Rebuilt to separate the two, and run against the naive read-then-write implementation:

| variant | racer A | racer B | final `spent`/`reserved`/`cap` |
|---|---|---|---|
| naive, **no** `CHECK` | `read=0` | `read=0` | `0 / 200 / 100` — **an over-spend, reproduced** |
| naive, **with** `CHECK` | `read=0`, then `ERROR: new row for relation "naive" violates check constraint "never_over_cap"` | `read=0` | `0 / 100 / 100` |
| **single-statement reserve** | `100` | `REFUSED` | `0 / 100 / 100` |

So the constraint is a real backstop but a bad interface — it turns a cap hit into a constraint
violation, which is a `500`, not the `402` the contract wants. The single statement produces a clean
refusal *and* lands exactly on the cap. **A race test with no control passes whether or not the
property holds**, which is why both scripts are committed and why `control.sh` exists separately.

### 9.5 The residual, named rather than hidden

**Two residuals, and the first one shipped as a bug in this branch's own first draft.**

**One — orphaned holds, and the sweep that reclaims them.** A reservation whose request the platform
kills between reserve and settle leaks cap until swept. **That is not theoretical here** — §4.3
measured exactly the event that produces those orphans. Hence the expiry column and `sweep()`.

The first `sweep()` written here **was wrong, and wrong in the direction that loses money silently**
(PR #82 cycle 1, F2). It subtracted straight from the expired rows with `UPDATE … FROM`, which is a
join: when several source rows match one target row Postgres applies exactly one and discards the
rest. So it reclaimed a single hold per user-period while marking every one of them settled, and the
remainder became permanently unusable cap. Reproduced before fixing: three orphaned 300-credit holds
against a 1000 cap left **600 credits lost for good**, and the function reported success. The fix
sums per user-period first, so there is one source row per target row. **Its return value was
mislabelled too** — it counted `usage_period` rows and called them holds, so it answered `1` for
that three-hold case, a number that agreed with the bug instead of exposing it.

So this section can no longer say "the evidence it works" without qualification, and does not. What
is demonstrated is that the *fixed* sweep reclaims every expired hold across multiple holds and
multiple users — `sweep()` returns 4 for four orphans, both users return to zero reserved, and both
can re-reserve their full cap. `race.sh`'s TEST 3 now uses that multi-orphan shape deliberately,
because the single-orphan version it replaced **passed against the broken sweep**; `control.sh`
replays both implementations against it so that claim is evidenced rather than asserted.

**Two — `settle()` caps the charge at the reservation, and the excess vanishes.** It writes
`spent + LEAST(p_actual, r.amount)`, so a call that cost more than was held is charged the hold and
the difference is absorbed silently: reserve 100, spend 900, and **800 credits of real provider
spend never reach the cap**. Demonstrated in `race.sh` TEST 5. That is the direction this ticket
cares about — the failure is money the founder pays that the cap never sees, which is the exact hole
SONNY-16 recorded as an accepted cost and this mechanism exists to close. It is a residual rather
than a bug because the alternative is a decision, not a fix: charging the true cost can push a
period past its cap, and whether that is allowed, refused, or clamped is a pricing question.

**Both belong to SONNY-135**, which the contract already names as the owner of the spend-cap
mechanism — the expiry window, the sweep's schedule, and what an over-reservation settle should do.
This document supplies the shape, the demonstrated behaviour of the corrected code, and the two
residuals; not the values.

---

## 10. Cost

Two environments plus local, per the founder's 2026-08-16 decision.

### 10.1 The monthly floor

| configuration | monthly | what it buys |
|---|---|---|
| Supabase **Free**, two projects | **$0** | 500 MB database, 5 GB egress, 500K function invocations, **150 s wall clock (measured)**. Free projects **pause after 1 week of inactivity** — which a staging environment reaches easily. |
| Supabase **Pro**, two projects | **$35** | Supabase's own worked example: "$25 (plan) + $10 (project 1) + $10 (project 2) − $10 (credits) = $35/month". 8 GB disk per project, 250 GB egress, 2M invocations, 100,000 MAUs, documented 400 s wall clock. |
| Cloudflare Workers, if the gateway ever moves | **$0** or **$5** | Free: 100K requests/day, 10 ms CPU. Paid: $5/month minimum. |

**$35/month was the realistic floor for the architecture this document measured, and that
architecture is superseded** (§12.2). It prices Supabase carrying *everything* — auth, Postgres and
the gateway. After the 2026-08-21 decision Supabase carries **auth and Postgres only**, and the
gateway's hosting is a separate cost on Oracle, then AWS — that list read deploymind, then Oracle,
then AWS until 2026-08-30, when the founders dropped the deploymind stage (§12.4). **So $35 is
neither the floor nor a clean component of one**, and nobody has yet priced what the
auth-plus-Postgres footprint alone actually needs. That is the live version of the founder's
deferred Free-versus-Pro question.

One input survives the decision intact, because it is a property of Supabase *projects* rather than
of Edge Functions: **a Free project pauses after a week of inactivity**, and a staging environment is
precisely the thing that goes a week untouched. That is what ruled Free out before, and it still
does — so whatever the auth-plus-Postgres footprint costs, the shape of the answer is unlikely to be
"stay on Free".

(The reviewer flagged this same stale-costing error in `docs/sonny-row-12-plan.md` §4.8 and in the
changelog entry, and not here; it is the same error in a third document, corrected in the same
round rather than left to contradict the two that were named — PR #82 cycle 2, R2/R3.)

### 10.2 What meters

Supabase: **compute** (per project per hour — the $10/month Micro instance), **egress** (250 GB
included on Pro, then **$0.09/GB**), **database size** (8 GB included, then $0.125/GB), **Edge
Function invocations** (2M included, then $2/million), **monthly active users** (100,000 included),
and file storage (100 GB included). Cloudflare: requests ($0.30/million over) and CPU milliseconds
($0.02/million over) — and Cloudflare states plainly, "There are no additional charges for data
transfer (egress) or throughput (bandwidth)."

### 10.3 Egress, which is where a surprise bill would come from — and the one thing not settled

The images travel **inbound** to the gateway, and ingress is not metered. The exposure is the
**second leg**: the gateway forwarding that image onward to the model provider. A screen-control
session is up to 12 iterations (`VisionSessionLimits.default.maximumIterations = 12`, `VisionSessionContainment.swift:239`), each carrying
a fresh full capture.

| per session (×12 iterations) | body each | session total |
|---|---|---|
| mean of SONNY-114's five real captures | 331,793 | **3.98 MB** |
| its densest real capture | 663,929 | **7.97 MB** |
| at the client's own ceiling | 4,004,793 | **48.06 MB** |
| at the contract limit | 4,200,000 | **50.40 MB** |

**If** that outbound leg meters as egress:

| | Free, 5 GB | Pro, 250 GB | overage at $0.09/GB |
|---|---|---|---|
| at the real-capture mean | 1,255 sessions | 62,790 sessions | $0.00036/session |
| at the contract limit | 99 sessions | 4,960 sessions | $0.00454/session |

**And "if" is doing real work in that sentence.** Supabase's egress documentation defines the meter
as "the network data transmitted out of the system to a connected client" and names "Data sent to
the client when executing Edge Functions." **It says nothing about an Edge Function's outbound
`fetch` to a third-party API.** A model provider is not a connected client.

The two readings differ enormously. If the provider leg meters, Pro's 250 GB is roughly 4,960
worst-case sessions a month across all users. If it does not, Sonny's Supabase egress is close to
nothing, because the only thing going back to a client is a small JSON decision.

**This is the one cost question this ticket could not answer, and it is not answerable from a
documentation page or from this harness — it is answerable from an invoice.** How to settle it,
cheaply: send a known volume through an Edge Function's outbound `fetch`, wait for the usage page
to update, and read whether the egress meter moved. That is a measurement, it costs one afternoon
of elapsed time rather than one of attention, and it should happen before the first month on Pro
rather than after. Filed as a discovery ticket (§14).

---

## 11. What was stopped rather than found, said plainly

The ticket asks for "the ceiling at which it starts failing." On body size, **neither host was made
to fail.** The ladders stopped at 67,200,000 bytes on Supabase and 33,600,000 on Cloudflare, both
without a refusal, and the log records that as a stop rather than an absence:

```
ceiling: 67200000 passed and the ladder stopped at cap 134217728 without a refusal
```

Stopping was deliberate. Supabase's ladder was pushed to 16× the contract's limit precisely because
its ceiling is the unpublished one; past that, each rung costs about a minute of upload from this
connection and changes no decision anyone in row 12 has to make. **This is a bounded answer, not a
complete one**, and it is recorded that way so nobody later reads "no ceiling found" as "no ceiling
exists."

---

## 12. The recommendation this ticket made, and the decision the founder actually took

### 12.1 What this ticket recommended, 2026-08-20

**Keep Supabase, gateway included.** Everything the ticket put at risk survived its own test: the two
limits that could have invalidated the row are 16× and 1.43× clear of what the contract needs, the
atomic spend cap the hybrid shape could not answer is a single Postgres statement, and the fallback
is a measured number rather than a documentation quote.

### 12.2 What the founder decided, 2026-08-21 — and it supersedes the above

> **Superseded in part on 2026-08-30 (founder decision, SONNY-373): the deploymind stage was
> dropped, leaving Oracle Cloud first and AWS for v1. §12.4 is the live record.** Everything below
> is kept verbatim as what was decided on 2026-08-21, including the two things §12.4 replaces — the
> "first tries" hedge on deploymind as the development host, and the count of three in the derived
> constraint at the end of this section. Nothing else here moved.

Recorded on SONNY-125 by the coordinator; that comment is the source, this is the durable copy.

**The gateway runs on a VM, not on serverless functions.** Hosting is staged across the product's
life: development **first tries deploymind** (the cofounder Bhavya's deployment project),
**Oracle Cloud** for beta testing, **AWS** for the v1 release. **Supabase keeps auth and Postgres —
only the gateway moves.**

**"First tries" is the founder's own hedge and is preserved deliberately.** The VM decision is
settled; deploymind as the development host is not, and an earlier draft of this line stated it
flatly (PR #82 cycle 2, R5). Oracle and AWS are named without that qualifier because the source
names them without one. The distinction matters to SONNY-126, which should treat the development
host as the least fixed of the three — which costs it nothing, because the host-portability
constraint below already assumes none of them is load-bearing.

**What stops binding.** Every Edge-Function ceiling measured in this document — the 150-second wall
clock, the streaming truncation, the platform body limits, and Edge egress metering. The gateway now
chooses and enforces its own timeouts and limits instead of inheriting a platform's. **SONNY-188 was
cancelled as moot** on the same decision.

**What transfers, and it is the more valuable half.** The spend-cap race demonstration (§9) is a
property of Postgres, and the database stays on Supabase Postgres, so it holds unchanged — including
both residuals in §9.5, which are now fully live rather than conditional. The gzip inflation cost
(§4.2) is a CPU fact about the payload rather than about a host, so it transfers to whatever runs
the gateway. **Deferred:** the Supabase plan tier, Free versus Pro, which the founder will settle
with Bhavya before the v1 release.

**The derived constraint for SONNY-126:** three hosts across the product's life means the gateway
must be **host-portable from day one** — containerized, per-environment configuration, and a deploy
path not coupled to any single host.

### 12.3 Why the measurements still matter after being superseded

**They are the evidence base the decision was made against, and that is not a consolation.** A
platform whose request-body ceiling is unpublished and whose wall clock ends at 150 seconds is a
different thing to choose than one whose ceilings you set yourself, and that difference was only
visible once someone measured it. The 45-second margin in §8, the silent truncation in §4.4 and the
three-way status split in §4.3 are what a gateway on Edge Functions would actually have had to live
with. Deciding to leave was a decision taken with those numbers in hand rather than against a
documentation page — which is what SONNY-125 existed to make possible.

Three of them also outlive the platform outright: the **payload sizes** (§2) are the client's, the
**spend-cap mechanism** (§9) is Postgres's, and the **gzip cost** (§4.2) is the payload's. The
Cloudflare arm (§5) becomes what it always was — a measured comparison — rather than a fallback
anyone now needs.

### 12.4 What the founders decided, 2026-08-30 — deploymind is out of the plan

Recorded on SONNY-192 by the coordinator and filed as SONNY-373; that comment is the source, this is
the durable copy. It supersedes part of §12.2 and nothing else in this document.

**Deploymind is dropped from the hosting plan entirely** — verbatim: *"oracle cloud, completely drop
the idea of deploymind."* It is not a later stage, a fallback, or a maybe. **Oracle Cloud is the
first host and AWS is v1's**, so the staging §12.2 recorded is two hosts rather than three.

**Everything else in §12.2 stands, and the derived constraint stands unweakened.** The gateway still
runs on a VM rather than on serverless functions; Supabase still keeps auth and Postgres; every
Edge-Function ceiling this document measured still stops binding. Host-portability was never a
function of *how many* hosts there are — it is the requirement that no single one of them is
load-bearing — so dropping a stage leaves it exactly where §12.2 put it. What changes is the
sentence, not the obligation: "three hosts across the product's life" is now two.

**The "first tries" hedge dies with the stage it qualified.** §12.2 preserved it deliberately, and
recorded why (PR #82 cycle 2, R5): the VM decision was settled and deploymind as the development
host was not. With deploymind out there is nothing left for it to hedge, and Oracle and AWS were
always named without it.

**Development gets no remote host, and needs none.** `./scripts/deploy.sh local` builds the image
and runs it on the developer's own machine, which is what every session has actually used since
SONNY-126 — deploymind was never provisioned, so nothing changes in practice. What was dropped is a
plan for a development host, not a running one.

**Still owed, and unchanged by this:** `server/scripts/deploy.sh` refuses `staging` and `production`
with exit 3 because neither Oracle nor AWS is provisioned, and the first real remote deploy is
recorded on SONNY-126. The Supabase plan tier (§12.2, §10.1) is still the founders' deferred
question.

---

## 13. Reproducing this

Everything is in `scripts/host-probe/`, including its own README and the raw logs under
`results/`. Each log records the literal `curl` command before each measurement, then that
request's status, wall-clock, upload size and response body.

```sh
MODE=sizes                          ./scripts/host-probe/probe.sh <base-url> <label>
MODE=times TIMES="1000 105000 150000 200000 400000" ./scripts/host-probe/probe.sh <base-url> <label>
MODE=up    TIMES="105000"           ./scripts/host-probe/probe.sh <base-url> <label>
MODE=drip  TIMES="200000"           ./scripts/host-probe/probe.sh <base-url> <label>
# the ceiling ladder ran in two passes; the first alone cannot reach the headline figure,
# because its cap stops the ladder at 33,600,000 (PR #82 cycle 1, F8)
CEIL_FROM=4200000  CEIL_CAP=67108864  MODE=ceiling ./scripts/host-probe/probe.sh <base-url> <label>
CEIL_FROM=33600000 CEIL_CAP=134217728 MODE=ceiling ./scripts/host-probe/probe.sh <base-url> <label>
./scripts/host-probe/spendcap/race.sh && ./scripts/host-probe/spendcap/control.sh
```

**The probe endpoints deployed for this ticket were left running** so a reviewer can spot-check any
row rather than take the logs on trust. They are throwaway echo and sleep handlers with no auth, no
state and no product logic, and they cost nothing on either free tier. To remove them:

```sh
npx supabase functions delete probe --project-ref <ref>
npx wrangler delete --name sonny-host-probe
npx wrangler delete --name sonny-slow-upstream
docker rm -f sonny-cap-probe
```

### Secrets

**No credential of any kind is in this repository, and none passed through the session that took
these measurements.** Both CLIs were authenticated by the founder in his own terminal, which stores
tokens under his home directory (`~/Library/Preferences/.wrangler/config/default.toml` for
Cloudflare); the probe function was deployed with `--no-verify-jwt`, so no API key was needed to
call it, and the Postgres container used a throwaway local password. What is committed is
identifiers that already appear in public request URLs — a Supabase project ref and a `workers.dev`
subdomain — and nothing else.

That is the standing rule, not a courtesy of this ticket: provider keys are the entire reason the
backend exists (plan §4.5). Configuration lives in the platform's own environment settings and in
the operator's shell, never in a committed file.

---

## 14. Tickets this work spawned

- **The egress metering question** (§10.3) — whether an Edge Function's outbound `fetch` to a model
  provider counts against Supabase's egress meter. Undocumented, and the two answers differ by
  orders of magnitude in what a Pro plan buys. Filed as **SONNY-188**, and **cancelled as moot on
  2026-08-21** by the VM decision (§12.2): the gateway leaves Edge Functions, so no large outbound
  flow crosses Supabase's meter at all. Recorded rather than deleted, because the question was real
  when it was asked and the reason it stopped mattering is the decision, not an answer.
- **The cut-off status has no home in the error taxonomy** (§8) — and it is `546`, `504` *or* `503`
  depending on the run, not one status as this document first claimed. Named on SONNY-131 and
  SONNY-136 in this ticket's closing comment, and **corrected there on 2026-08-21**, in the same
  comments that record the VM decision making the taxonomy work moot for the shipping
  architecture.
