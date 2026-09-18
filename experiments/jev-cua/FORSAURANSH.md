# FORSAURANSH.md — the Jev + cua experiment, explained

This folder is an experiment (SONNY-517), not part of Sonny. It asks one question: **if you split
"thinking" from "doing" — a slow reasoning model that plans, and a fast picking model that acts —
how well does that pair drive a real Mac?** This document explains what got built, why it looks
the way it does, and what you can learn from it.

## The idea in one picture

Think of a pilot and a co-pilot. The pilot (the **coordinator**, an OpenAI model) looks at the
instruments, decides "we're descending to 3,000 feet", and says so in one sentence. The co-pilot
(the **action model**, TypeSafe's Jev) doesn't philosophise about the sentence — it looks at the
panel of switches in front of it and picks *which switch to flip next*, over and over, until the
sentence is satisfied. Then the pilot looks again and gives the next sentence.

The trick that makes the co-pilot fast is that it **never writes**. It only *chooses*. Every
step, the code hands it a numbered list of things on screen — "[12] button: Search", "[30]
textfield: Where to?" — and asks two questions in one network call:

1. Which *operation* next? (CLICK, TYPE_TEXT, PRESS_RETURN, SCROLL_DOWN, WAIT, DONE, BLOCKED…)
2. If it were CLICK, which number? If it were TYPE_TEXT, which number?

Question 2 is asked *speculatively* for every operation at once, before knowing the answer to
question 1. That is jev-ultrafast's whole design: one round trip instead of two, and the code
reads only the target answer that the chosen operation needs. The other answers are thrown away
unread, which is why a garbage answer on an unused head can never cause an action (there's a test
pinning exactly that).

Text is generated only in one place: when the operation is TYPE_TEXT, a small model is asked
"what goes in this field, given the goal?" and must answer `{"text": "..."}` or `{"text": null}`.
`null` means "the goal doesn't say" and nothing gets typed. The executor never guesses.

## The cast, file by file

```
experiments/jev-cua/
├── scripts/fetch-cua-driver.sh   downloads ONE pinned cua-driver release, checks its SHA-256
├── src/
│   ├── config.ts                 every env var, validated once with Zod, keys never logged
│   ├── driver/
│   │   ├── types.ts              Zod schemas for the slice of cua-driver's JSON we read
│   │   ├── driver.ts             the Driver interface — the seam tests replace
│   │   ├── mcpClient.ts          talks MCP over stdio to `cua-driver mcp`
│   │   └── mcpDriver.ts          the real Driver: one tool call per method
│   ├── actionSpace.ts            screen elements → numbered candidates per operation
│   ├── actionModel/
│   │   ├── questions.ts          the rules text Jev is given (adapted from jev-ultrafast)
│   │   ├── jev.ts                builds the one-request question set, validates the answers
│   │   └── textHelper.ts         the only place text is generated
│   ├── ladder.ts                 cua's escalation policy as pure functions
│   ├── executor.ts               runs ONE instruction: observe → choose → act → observe
│   ├── coordinator.ts            the reasoning model: plan, then judge after each instruction
│   ├── agent.ts                  the whole run: launch app → plan → loop → report
│   ├── tasks.ts                  the five benchmark tasks
│   ├── cli.ts                    `npm run task -- <id>`; writes runs/<id>-<time>.json
│   └── testSupport/fakes.ts      scripted driver / action model / text helper for tests
```

Data flows top to bottom and never sideways: `agent` calls `coordinator` and `executor`;
`executor` calls `actionModel`, `textHelper` and `driver`; nobody reaches around. That is what
lets every layer be tested with a fake below it.

## Why these decisions

**Why not let one big model do everything?** Because a screenshot-reading model that also writes
its next action is slow (seconds per step) and its output has to be parsed and trusted. A model
that only *selects from a list* returns a key and a probability distribution. There is nothing to
parse and the code stays in control: it can refuse an answer whose numbers don't add up (they
must sum to 1, the choice must be the argmax, every offered key must be present — see
`validateChoice`). TypeSafe's phrase for this is "typed output guarantees the interface, not
truth", so the checking still happens.

**Why cua-driver and not our own accessibility code?** Because it already does the two hard
things: it gives every actionable element a stable index inside a snapshot (an index from an old
snapshot is refused rather than clicking the wrong thing), and every action reports how sure it
is that it worked — `effect: "confirmed" | "unverifiable" | "suspected_noop"` plus a hint about
what to try next. That second part is what turns cua's "action-selection policy" doc into
~60 lines of code in `ladder.ts` instead of a judgment call by a model.

**The ladder, in plain words.** Try the polite way first: an accessibility action delivered in
the background, so the user's frontmost app and mouse are untouched. If the driver says
"confirmed", done. If it says "I couldn't verify" and the screen didn't change, climb one rung:
click by pixel at the element's centre. Still nothing? Bring the window to the front for one
action and try again. Each rung is more intrusive than the last, so you climb only on evidence.
The one rung we skipped is "page" (driving a browser tab through its DOM) — it maps to foreground
for now and the report says so when it happens.

**Why the coordinator only sees text.** The coordinator gets "App: Safari / Window: Flights /
Controls: [3] button: Search … / Visible text: …". No screenshot. This keeps each coordinator call
cheap and makes the experiment honest about what the accessibility tree alone can support. If a
task fails *because* the tree was blind to something, that is a finding, and the report's
`degraded_reason` field will say so.

**Why Safari for the browser tasks, not Chrome.** WebKit exposes page content through the Mac
accessibility tree without any setup. Chrome needs its CDP route (cua's `browser_*` tools), which
is a different rung and a second experiment.

**Why TypeScript.** Node 22 was already installed, it matches the rest of your stack, TypeSafe
has a JS SDK, and the MCP SDK speaks stdio to the driver. The Python reference was ported rather
than depended on; the logic is ~300 lines and the port is where the understanding lives.

## Things that went wrong, and what they teach

**npm crashed with `Cannot read properties of null (reading 'edgesOut')`.** Not a package
problem: npm 10.9.8's peer-dependency resolver falls over on vitest's optional `@vitejs/devtools`
peers. The `server/` half never sees it because its lockfile pins a tree that already resolved.
Isolating it took two scratch folders: runtime deps alone installed fine, vitest alone crashed.
`legacy-peer-deps=true` in `.npmrc` skips that resolver. *Lesson:* when a tool crashes, bisect the
inputs before reading its source; two installs told more than the stack trace.

**`cua-driver mcp` exited instantly.** Its stderr said it was trying to launch
`/Applications/CuaDriver.app` through LaunchServices so macOS attributes permissions to the app's
identity, not to whichever terminal spawned it. We'd unpacked the app into the worktree instead.
`open -n -g <path>/CuaDriver.app --args serve` launches that copy through LaunchServices by path,
so nothing gets installed in `/Applications`. *Lesson:* macOS permissions are keyed to a signed
bundle identity, which is also why Sonny's own packaging script signs with a real certificate —
ad-hoc signatures lose their grants on every rebuild.

**Then every tool call answered `permissions_pending`.** Accessibility and Screen Recording are
grants only a human can give, and the driver refuses everything until both land. A session cannot
click that dialog. *Lesson:* build against the documented shapes with a fake driver while you
wait, and treat the real payloads as things to verify, not assume — `types.ts` is deliberately
lenient (`passthrough`, optional fields) so a field name we guessed wrong fails at the boundary
with the tool's name in the message.

**Two tests failed for a reason that looked like a logic bug and wasn't.** `runTask` passed its
`queue` and `history` arrays *by reference* into the coordinator and executor. The fakes stored
the reference; by the time the test asserted, later turns had mutated it. The fix — copy on
hand-off — is also the right design: a callee should get a snapshot, not a live view of the
caller's state. *Lesson:* a test that fails on a shared reference is usually pointing at real
aliasing, not at the test.

**A design bug caught by writing the test first.** `valueReflects` originally tried to read the
typed text back off the driver's result object, which never carries it. Writing the test made it
obvious the executor has to pass the expected value down itself. The fix threaded
`expectedValue` through the ladder climb. *Lesson:* if a function needs data that "should be
there", check who actually holds it.

## How to run it

```bash
cd experiments/jev-cua
./scripts/fetch-cua-driver.sh                 # once; verifies the pinned checksum
open -n -g .cua-driver/unpacked/*/CuaDriver.app --args serve   # start the daemon; grant the two permissions
cp .env.example .env                          # then paste TYPESAFE_API_KEY and OPENAI_API_KEY
npm run task -- calculator                    # or textedit | settings | wikipedia | flights | all
npm test                                      # 83 unit tests, no keys and no driver needed
```

Each run writes `runs/<task>-<timestamp>.json` with the tree SHA it ran at, every coordinator
instruction, every Jev decision with its confidence and top alternatives, every ladder attempt
with its rung and the driver's `effect`, and per-component timings. The console prints a one-line
summary per run.

## What to look at in the reports

- **`totals.rungs`** — how often the polite rung was enough. If `foreground` is common, the
  accessibility route is failing on that surface.
- **`totals.exhausted`** — actions where every rung failed. Each one is a surface cua couldn't
  drive, and the step's `attempts` say what it tried.
- **`confidence` per step** — Jev's certainty about the *operation*. Below the floor
  (`MIN_OPERATION_CONFIDENCE`, 0.35) the executor stops and asks the coordinator instead of
  acting. Watch whether the floor fires on genuinely ambiguous screens or just on busy ones.
- **`truncated`** — snapshots where more than 250 clickable things were on screen and the rest
  were cut. A truncated snapshot on a failed step is a likely cause.
- **`coordinatorMs` vs `jevMs`** — the whole bet is that the reasoning model is called a few
  times and the picking model many times. If the ratio inverts, the plan step is doing too little.

## Ideas worth trying next

- Give the coordinator the screenshot too, and see which failures disappear.
- Build the page rung with cua's `browser_*` tools and compare Chrome against Safari.
- Feed the same tasks through Sonny's production planner and compare wall time and success.
- Let Jev's target confidence gate the *pixel* rung: a low-confidence target shouldn't be clicked
  by coordinates at all.
