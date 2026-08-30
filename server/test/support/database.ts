/**
 * Where every test in this suite gets its database URL (SONNY-352).
 *
 * **One knob, and it used to be three.** `npm run test:db` sets `DATABASE_URL`, falling back to
 * `localhost:55433` when nothing else set it — which is a fallback for a lone session and is no
 * longer what any document tells you to start (SONNY-355; the constant below says what is).
 * Two test files ignored the variable and named that port as a literal —
 * `authdeps.test.ts` and `entitlement.test.ts` — so the variable was configurable for most of the
 * suite and inert for those two. That only shows up with two lanes running at once, which is why it
 * survived: a second lane that finds 55433 busy and starts a container on another port gets what
 * looks like a working setup, while two files still name the first lane's port. Observed on
 * 2026-08-29 with `sonny-gw-db` on 55433 and `sonny-gw-db-341` on 55444 up together.
 *
 * **What the collision actually was, corrected from the ticket** (SONNY-352 says those two files
 * "quietly connect to the first lane's database"): neither of them opens a socket. `authdeps`
 * constructs a lazy `pg.Pool` and never queries it — its own doc comment says so — and
 * `entitlement`'s literal is an env map handed to `loadConfig`. So the strings were fixtures, and
 * the live collision that prompted the ticket came from the shared container NAME: one lane
 * recreated `sonny-gw-db` while the other was mid-run against it, which reads as a suite-wide
 * failure with a fresh `initdb` in the container log and nothing in the test output pointing at it.
 * The knob is still worth being one knob, and the guard below is the part that pays: the next file
 * to name a connection string may well be one that connects.
 */
/**
 * What `npm run test:db` falls back to when `DATABASE_URL` is unset — one lane, one machine, no
 * choices made. It is NOT what the documentation tells you to start any more: `CLAUDE.md`'s server
 * half, `server/README.md` and the banner `global-setup.ts` prints all now derive a container name
 * from the worktree and let Docker pick the host port, because a fixed name and a fixed port are
 * both machine-wide and lanes here run in parallel (SONNY-355). This line stays because a session
 * that sets nothing still has to land somewhere, and somewhere is better named here than guessed.
 *
 * **This file is the only place under `server/test/` allowed to name that port**, and
 * `database-url.test.ts` is what enforces it. The guard is narrow on purpose: several tests name a
 * connection string legitimately — `pool.test.ts` uses port 1 because it must not connect,
 * `errors.test.ts` plants one inside a fake error to prove it is redacted, `health.test.ts` names
 * 5432 — so a blanket ban on `postgres://` would need an exemption list, and an exemption list is
 * the thing that rots. What is never legitimate is a second file naming the port the runner exists
 * to choose.
 */
export const FALLBACK_DATABASE_URL = "postgres://postgres:postgres@localhost:55433/postgres";

export function testDatabaseUrl(): string {
  return process.env["DATABASE_URL"] ?? FALLBACK_DATABASE_URL;
}
