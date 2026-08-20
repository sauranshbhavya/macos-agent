# Row 12 — where Sonny's backend runs: the measurements, and the decision they support

SONNY-125. Branch `docs/row-12-host-decision`. All host measurements taken **2026-08-20 (UTC)**.

Every figure in the results tables was observed against a live endpoint. **None is quoted from a
host's documentation.** Where a documented figure appears it is labelled as one and placed beside
the measurement that tested it, because comparing the two is the point of the ticket.

Repository figures — payload sizes, iteration counts — are stamped at `87199ff`, the branch point.

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

**Nothing here is a recommendation to change the decision.** The recommendation in §12 is to keep
Supabase and to record two consequences that the measurements make concrete.

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

**The control arm ran first, on `localhost`, before any host number was attributed to anything.**
Same handler, same runtime family Supabase Edge Functions use (Deno 2.7.12), nothing in between:

| arm | result |
|---|---|
| all four sizes, raw and gzip | `200`, 5–30 ms |
| `slow?ms=105000` | `200` at **105.005 s** |
| `up?ms=105000` (real outbound fetch) | `200` at **105.015 s** |
| body ladder | `200` at 16,800,000; no limit in the runtime itself |

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
| 150 s | `slow` | `546` | 150.16 s |
| 200 s | `slow` | `546` | 150.65 s |
| 400 s | `slow` | `546` | 150.27 s |
| **105 s** | **`up`** (real outbound `fetch`) | **`200`** | **105.72 s** |
| 200 s | `up` | `546` | 150.36 s |

**The cliff is 150 seconds, and it is a hard one** — 150 s, 200 s and 400 s all terminate within
0.5 s of the same wall-clock. The contract needs 105. The refusal body is:

```json
{"code":"WORKER_RESOURCE_LIMIT","message":"Function failed due to not having enough compute resources (please check logs)"}
```

**That message is misleading and a future session should not believe it.** The function was
*sleeping* — it consumed no CPU and allocated nothing. The trigger was wall clock, and the error
names compute resources. Anyone debugging a real occurrence would go looking for a CPU or memory
problem that is not there.

The 150 s figure is the **Free plan's**. Supabase documents 400 s for paid plans; that is a
documentation figure, it was not measured here, and it is only ever more headroom than what was
measured. **The number that decides the row was taken on the tighter of the two plans**, which
makes it the conservative one — the decision holds on Free, so it holds on Pro.

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
one. The non-streaming path fails cleanly with `546` and a parseable error object.

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
`error code: 1042` in the body. Two Workers on one `workers.dev` subdomain are the same zone. The
`up` arms were therefore cross-wired — Cloudflare's probe fetches Supabase's `slow`, Supabase's
fetches Cloudflare's — which is recorded here because it also bounds the measurement: Cloudflare's
`up` arm cannot be pushed past Supabase's own 150 s ceiling, so it was tested at 105 s only. The
in-handler `slow` arm carries the 400-second result.

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
  from a `546` into a silent truncation the client cannot detect.
- **`546` needs a home in the error taxonomy.** Contract §7's taxonomy has no entry for it, and
  §12 promises the client sees a typed `504 provider.timeout` rather than a transport error. A raw
  `546` with a body about "compute resources" satisfies neither. **This is SONNY-136's** (backend
  unreachable, error copy) **and SONNY-131's** (vision mid-loop failure), and it is named on both
  by the ticket comment recorded alongside this document rather than left to be discovered.
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

A reservation whose request the platform kills between reserve and settle leaks cap until swept.
**That is not theoretical here** — §4.3 measured exactly the event that produces those orphans, at
150 seconds. Hence the expiry column and `sweep()`, both demonstrated above. **Choosing the expiry
window and scheduling the sweep is SONNY-135's**, which the contract already names as the owner of
the spend-cap mechanism; this document supplies the shape and the evidence it works, not the values.

---

## 10. Cost

Two environments plus local, per the founder's 2026-08-16 decision.

### 10.1 The monthly floor

| configuration | monthly | what it buys |
|---|---|---|
| Supabase **Free**, two projects | **$0** | 500 MB database, 5 GB egress, 500K function invocations, **150 s wall clock (measured)**. Free projects **pause after 1 week of inactivity** — which a staging environment reaches easily. |
| Supabase **Pro**, two projects | **$35** | Supabase's own worked example: "$25 (plan) + $10 (project 1) + $10 (project 2) − $10 (credits) = $35/month". 8 GB disk per project, 250 GB egress, 2M invocations, 100,000 MAUs, documented 400 s wall clock. |
| Cloudflare Workers, if the gateway ever moves | **$0** or **$5** | Free: 100K requests/day, 10 ms CPU. Paid: $5/month minimum. |

**The realistic floor for a shipping product is $35/month.** The pause-after-a-week behaviour rules
Free out for a staging environment that is used intermittently, which is what staging is.

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

## 12. The recommendation — the founder's decision, not this session's

**Keep Supabase. Everything the ticket put at risk survived its own test.** The two limits that
could have invalidated the row are 16× and 1.43× clear of what the contract needs, the atomic spend
cap the hybrid shape could not answer is a single Postgres statement, and the fallback is a measured
number rather than a documentation quote.

Three things to decide, all of which are the founder's:

1. **Free or Pro, and when.** Free measured 150 s and costs nothing, but pauses a project after a
   week of inactivity, which makes it wrong for staging. $35/month is the realistic floor.
2. **Whether the 45-second margin is comfortable.** It is real margin on a limit that is documented
   to be 400 s on Pro — but that 400 is unmeasured, and §8's three consequences hold either way.
3. **Whether to settle the egress question before or after the first Pro invoice** (§10.3).

Nothing here needs a decision to *proceed*: SONNY-126 and the rest of row 12 can start against
Supabase on the strength of these measurements.

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
CEIL_FROM=4200000 CEIL_CAP=67108864 MODE=ceiling ./scripts/host-probe/probe.sh <base-url> <label>
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
  orders of magnitude in what a Pro plan buys. Settleable by measurement against the usage page.
- **`546 WORKER_RESOURCE_LIMIT` has no home in the error taxonomy** (§8) — contract §7 has no entry
  and §12 promises the client a typed `504 provider.timeout`. Named on SONNY-131 and SONNY-136 in
  this ticket's closing comment.
