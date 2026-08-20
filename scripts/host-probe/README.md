# host-probe — a measurement tool, not product code

Built for SONNY-125 to answer one question with observations instead of documentation: does a
real Sonny vision request survive the trip to a candidate backend host, and does the platform
let the request sit for as long as a vision call actually takes?

**Nothing here is the beginning of `server/`.** The endpoints it deploys are throwaway echo and
sleep handlers with no auth, no state and no product logic. `server/` belongs to
`feature/row-12-server-foundation`; this directory exists so the numbers in
`docs/sonny-row-12-host-decision.md` can be re-derived rather than trusted.

## What it measures

| route | question |
|---|---|
| `POST …/echo` | Does a body of size N arrive, and does the platform inflate `Content-Encoding: gzip` before the handler sees it? |
| `GET …/slow?ms=N` | Does the platform cut a request off that produces no bytes for N ms? |
| `GET …/up?ms=N` | The same, but waiting on a real outbound `fetch` — the shape a gateway actually has. |
| `GET …/drip?ms=N` | The same, but streaming from the first byte. Answers whether streaming evades a cut-off. |

`spendcap/` is separate: it demonstrates what two requests from one user do when they race the
per-user spend cap, against a real Postgres.

## Running it

```sh
# 1. one control arm, no host involved -- proves the harness and the uplink are not the bottleneck
PORT=8788 deno run --allow-net --allow-env server.ts &                        # slow upstream
PORT=8787 UPSTREAM_URL=http://127.0.0.1:8788/slow deno run --allow-net --allow-env server.ts &
MODE=sizes ./probe.sh http://127.0.0.1:8787 local-deno

# 2. against a host you have deployed (see below)
MODE=sizes                        ./probe.sh <base-url> <label>
MODE=times TIMES="1000 105000"    ./probe.sh <base-url> <label>
MODE=up    TIMES="105000"         ./probe.sh <base-url> <label>
MODE=drip  TIMES="200000"         ./probe.sh <base-url> <label>
CEIL_FROM=4200000 CEIL_CAP=67108864 MODE=ceiling ./probe.sh <base-url> <label>
```

**One run per label at a time.** `probe.sh` takes a lock at `results/.<label>.lock` and refuses a
second concurrent run against the same label, because two runs appending to one log through
`tee -a` produce a file whose runs interleave — SONNY-125 did exactly that and ended up with a
ceiling ladder it could not attribute to a command it had issued. Remove the lock directory by hand
if a killed run left it behind.

Every run appends to `results/<label>.txt`, and the log records the literal curl command before
each measurement, then that request's status, wall-clock, upload size and response body. One
curl per measurement — body and metrics always come from the same request, so a figure can never
be paired with a different request's outcome.

## Deploying the probe endpoints

Both need an account you own. **No credential belongs in this repository** — log in with the
vendor CLI so the token lands in your home directory, and pass identifiers on the command line.

**Run the Supabase deploy from this directory, not from `supabase/`.** The CLI resolves
`supabase/functions/<name>/index.ts` relative to the working directory, so `scripts/host-probe/` is
the right place to stand; from `supabase/` it looks for `supabase/supabase/functions/...` and fails.

```sh
cd scripts/host-probe
supabase functions deploy probe --project-ref <ref> --no-verify-jwt
(cd cloudflare && wrangler deploy)                              # the probe
(cd cloudflare && wrangler deploy -c wrangler-upstream.toml)    # the slow upstream
```

**The tree deploys as-is — all three entry points import the single `handler.js` at the root of this
directory by relative path**, and that is checked rather than assumed: a deploy from the committed
tree logs `Uploading asset (probe): handler.js` beside `index.ts`, so the bundler really does follow
the import out of the function directory. It did not always: the first committed version had every
entry point importing `./handler.js` from a directory that had no copy of it, so none of the three
would have deployed at all (PR #82 cycle 1, F4).

**One wrinkle worth knowing when a deploy dies with `exit 137`.** That is a SIGKILL, not a code
error: with Docker running, the CLI bundles inside a container that can be OOM-killed. With Docker
stopped it bundles through the API instead and succeeds. If you see 137, stopping Docker is a
reasonable first move rather than a puzzling one.

`wrangler.toml`'s `UPSTREAM_URL` and Supabase's `UPSTREAM_URL` secret must point at **each
other's** host, not at a second Worker on the same account: a Worker fetching another Worker on
the same zone returns Cloudflare error 1042, which SONNY-125 hit and recorded.

## The spend-cap demonstration

```sh
docker run -d --name sonny-cap-probe -e POSTGRES_PASSWORD=probe -p 55432:5432 postgres:17
docker exec -i sonny-cap-probe psql -U postgres -q -f - < spendcap/schema.sql
./spendcap/race.sh        # the mechanism
./spendcap/control.sh     # the control -- the naive version, which must fail
```

`control.sh` exists because the first version of `race.sh`'s inline control asserted an outcome
it never showed, and its own final state contradicted it. Run both: a race test with no control
passes whether or not the property holds.

## What this does and does not prevent

- **It measures one account on one plan from one machine.** A limit that differs by plan, region
  or account age is invisible here. `docs/sonny-row-12-host-decision.md` records which plan each
  number came from.
- **Wall-clock includes the uplink.** A 4.2 MB upload took about 4 s on the machine that produced
  the recorded numbers; that is the connection, not the platform. `time_connect` and
  `time_starttransfer` are logged so the two can be separated.
- **`actual_ms` in an echo response is handler wall-clock, not CPU time.** It bounds CPU from
  above; it does not measure it. Neither platform exposes a per-request CPU figure to the handler.
- **The lock is per label, not per host.** Two labels pointed at the same endpoint still run
  concurrently, and their wall-clock figures will contend for the same uplink.
- **It cannot answer a billing question.** Whether an outbound `fetch` from a function meters as
  egress is a question for the vendor's invoice, not for this harness.

## The three deployed endpoints, and which may be torn down

- **`probe` (Supabase Edge Function)** and **`sonny-host-probe` (Worker)** are the two measured
  hosts. Teardown-eligible once nobody needs to re-check a row.
- **`sonny-slow-upstream` (Worker) is load-bearing, not spare.** It is the upstream the Supabase
  function's `up` route fetches — Supabase's `UPSTREAM_URL` secret points at it. Deleting it does not
  degrade that arm, it breaks it: `up` answers `502` with an `upstream_error`. Tear it down only
  together with the other two.

The cross-wiring is deliberate and is not a matter of taste — a Worker fetching another Worker on
the **same** zone returns Cloudflare error 1042, reproduced in
`results/cloudflare-1042-same-zone.txt` with a cross-zone control beside it.

## Two naming details that are deliberate

- **Logs are `results/<label>.txt`, not `.log`.** The repository's `.gitignore` ignores `*.log`
  everywhere, so a log written under that extension is silently untracked — which would leave
  `docs/sonny-row-12-host-decision.md` citing evidence files that are not in the repository. It did,
  briefly, during SONNY-125. Do not "fix" the extension back.
- **`payloads/` is ignored by this directory's own `.gitignore`.** The bodies run to tens of
  megabytes and `make_payload.py <bytes> <path>` reproduces any of them byte-for-byte in shape from
  its size alone, so storing them buys nothing.
