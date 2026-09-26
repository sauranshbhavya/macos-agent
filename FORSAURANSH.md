# Sonny, explained for Sauransh

This is the plain-language tour of Sonny: what it is, how the pieces fit, why it's built this way,
and what building it taught us, including the bugs. It describes V2, the architecture that landed on
`main` on 2026-09-26. README.md is the reference; this is the story behind it.

---

## 1. What Sonny is, in one breath

You tell your Mac what you want, typed or spoken: "zip the five biggest files in Downloads", "make
a note in Notes that says buy milk", "email the report to Sam". Sonny works out the steps and does
them. It opens apps, moves files, writes notes, clicks and types inside apps, reads the web, and
runs saved routines on a schedule.

The hard part isn't doing things. It's doing things **safely**: never sending an email you didn't
approve, never doing the same payment twice, never typing your password anywhere, and never letting
something a web page says talk it into anything.

---

## 2. The big idea of V2: a brain in the cloud, careful hands on the Mac

Think of a surgeon on a video call guiding a nurse in a remote clinic.

- **The surgeon (the gateway, in the cloud)** knows what to do next. They look at what the nurse
  shows them and say "now make the incision here".
- **The nurse (the Mac)** has the patient in front of them. They follow instructions, but they
  check every one against the rules of their own clinic. If the surgeon says something dangerous,
  the nurse stops and asks. The nurse is the only one who ever touches the patient.

That is V2. The **gateway** (a Node server) does all the reasoning: it runs the planner and the
screen agent, talks to the AI models, searches the web and reads pages. The **Mac** is the only
thing that acts, and it treats everything the gateway proposes as a suggestion to check, not an
order.

### Why we rewrote V1 into this

V1 did the thinking on the Mac. The Mac held the planner, the prompts, the research pipeline, the
skill packs, a vision loop, workspaces and more. That made three things hard:

1. **Updating the brain meant shipping an app.** A better prompt needed a new release.
2. **The Mac had too many jobs.** Deciding what to do and checking whether it's safe lived side by
   side, so every change risked the safety code.
3. **Billing and privacy were tangled with it.** Screen-control "runs" were counted on the Mac, and
   the privacy promises needed deletion machinery everywhere.

V2 splits it cleanly: reasoning on the gateway, execution and safety on the Mac. The founders took
the decisions on 2026-09-25 (they're in `docs/sonny-v2-implementation-plan.md`, section 1):

- **No backwards compatibility.** V2 starts with fresh stores. The first V2 launch removes V1's
  local data once.
- **One WebSocket per Mac.** It stays open, both sides talk over it, and every message names its
  task.
- **The model declares, the Mac can only raise.** The gateway says what an action does ("this sends
  an email"). The Mac can decide it's *more* serious than that, never less.
- **Credits are spent by tokens.** Every model call costs credits by what it used.
- **Planner plus screen agent.** Two separate AI agents: the planner owns the task, and the screen
  agent is its helper for working inside one app's window.

The work shipped in seven stacked PRs, #306 to #312, merged bottom-up.

---

## 3. One task's journey

Let's follow "make a note in Notes that says buy milk" from keypress to "Done".

### 3.1 On the Mac, before anything leaves

1. You type in the floating **widget** (`Sources/MacAgent/WidgetView.swift`). The widget is just
   presentation over `SonnyAppModel`.
2. `SonnyAppModel` hands the request to **`TaskDesk`** (`Kernel/TaskDesk.swift`). Every way a task
   can start goes through the desk: the composer, voice, a routine, a schedule, a follow-up, a
   watched page that changed.
3. The desk first asks the **instant path** (`Kernel/Instant/InstantPath.swift`): "can the Mac do
   this alone, with no AI at all?" Calculations, clipboard history, snippets, recent files and
   opening an app are answered in milliseconds without the network. A note in Notes isn't, so it
   goes on.
4. **`TaskController`** (`Kernel/TaskController.swift`) creates a **`TaskRuntime`** for the task,
   one actor per task, and makes sure the gateway connection is up. With no connection it fails at
   once with a plain sentence. Decision 13 says a model-backed task without the server is an
   immediate, honest error, not a spinner.

### 3.2 Over the wire

5. **`GatewayConnection`** (`Kernel/Transport/`) sends `task.start` over the WebSocket to
   `/v2/session`. Every message has the same envelope:

   ```text
   { v, type, id, task, seq, re, body }
   ```

   `seq` numbers each side's messages per task, and `re` says which message this one answers. That
   is how both sides notice a gap or a duplicate after a reconnect. The contract lives in
   `contracts/v2/`, as JSON Schema, with mirrors in Swift (`Kernel/Wire/`) and TypeScript
   (`server/src/agent/protocol.ts`). Both test suites decode the same fixture files, so the two can't
   drift apart quietly.

### 3.3 On the gateway

6. The session layer (`server/src/agent/session/`) checks the token and the rate limits, and hands
   the message to the **`TaskRunner`** (`server/src/agent/tasks/runner.ts`). The runner stores
   every message of the task (its transcript) in Postgres and runs the agent one turn at a time.
7. The **planner** (`server/src/agent/planner/planner.ts`) asks a model: given the goal, what's
   next? It can pick a typed operation ("open_app Notes"), hand a window to the screen agent,
   search, read a page, ask you a question, or finish.
8. Here it hands Notes to the **screen agent** (`server/src/agent/screen/`). The screen agent says
   "observe Notes": it wants to see the window.

### 3.4 Back on the Mac: looking and acting

9. The Mac's **`ScreenController`** (`Kernel/Screen/`) reads Notes' accessibility tree through
   **cua-driver**, a Rust library linked into the app, and sends back a tidied tree, plus a
   screenshot if asked. Secrets are masked before anything leaves: secure fields' values are never
   read out, and detected tokens and passwords are blanked.
10. The screen agent proposes "press New Note", then "type buy milk".
11. For each proposed action, the `TaskRuntime` runs the kernel's safety pipeline, which is the
    heart of the whole product:

    ```text
    validate → prepare → raise the effect → gate → (ask you?) → write the ledger → run → report
    ```

    - **Validate** (`ProposalValidator`): is this message for this task, in order, and a
      capability this Mac has?
    - **Prepare**: resolve it against the live Mac. Which window? Which element? What exactly will
      change?
    - **Raise** (`EffectRaiser`): the Mac's own facts can only make the declared effect more
      serious. Pressing Return in a window with a text field becomes "external", because Return
      there may send something to someone.
    - **Gate** (`Kernel/Gate/ActionGate.swift`): with this effect, this mode (Safe, Normal or Power)
      and this app's standing, does it run, ask, or get refused?
    - **Ask**: the `ApprovalBroker` shows you the exact effect and waits.
    - **Ledger** (`ExecutionLedger`): write "about to run" to disk **before** running it.
    - **Run**: the capability does the thing.
    - **Report**: send the outcome back.
12. The planner sees the note exists and sends `finish`. The widget shows "Done", and history
    remembers the task (unless it was private).

---

## 4. The safety ideas, one at a time

These are the ideas worth remembering long after the details change.

### "The model declares, the Mac can only raise"

Model output is untrusted, and so is everything the model read: web pages, screenshots,
accessibility text. So a model can never *lower* how careful the Mac is. Picture a bouncer with a
guest list, where the guest's own opinion of whether they're on it doesn't count.

### An approval covers exactly what you saw

When you click "Allow" on "Send email to sam@example.com", the approval is tied to a **digest**, a
fingerprint of the exact target and content. Just before running, the Mac **prepares the action
again**, and if the fingerprint changed at all (a different recipient, one word different), the
approval is void and the action doesn't run. This is how an approval can't be swapped for a
different action in the gap between clicking and doing.

### Exactly once, or honestly unknown

The ledger is written before every action runs. After a crash, each action is one of: known to have
run, known not to have run, or **unknown**. An unknown action that mattered (anything beyond
navigating) is **never retried**. The task pauses and asks you to check. Retrying "send payment"
because you're not sure it went is how people get charged twice.

### Fail closed

When the answer is unclear, choose the safe side:

- A gateway with no credit catalogue refuses to start, rather than guessing "unlimited" or "zero".
- A site whose robots.txt can't be fetched is treated as saying "don't read me".
- An app outside the built-in list asks before Sonny acts in it.
- Terminals and script editors are refused outright.

### Secrets stay on the Mac

Sonny never types into a password field, and secure fields' contents are never read out.
Screenshots are redacted on the Mac before they're sent.

---

## 5. Money: credits by tokens

Every model call costs credits by the tokens it used, at its tier's rate (fast, standard or strong).
The rates live in configuration (`CREDIT_PLANS`), never in code, because prices are a business
decision.

The clever bit is **hold, then settle**, like a hotel pre-authorising your card:

1. Before a model call, the gateway **holds** credits for the most that call could possibly cost.
2. After the call, it **settles** the hold down to what the call actually used.
3. If your balance can't cover the hold, the task stops *between* Mac actions, never in the middle
   of one.

Two calls for one account can't both spend the same last credits, because the balance check runs
under a Postgres advisory lock, a named lock keyed by the account.

Automatic top-up (buying a pack when you run out) has careful rules in `server/src/credit/topup.ts`:
consent is checked first, the provider's order id is written down before the card is charged, and
an order that was left unresolved is resolved before a new one is made. Tonight's PR #314 makes the
gateway trigger it when a task runs out.

---

## 6. The map: where things live

```text
Sources/
  MacAgentCore/            the Mac's engine, no UI
    Kernel/                V2's kernel: this is the part that matters most
      Wire/                the protocol types (mirror of contracts/v2)
      Transport/           GatewayConnection: the WebSocket, reconnects, hello/welcome
      Runtime/             TaskRuntime, ExecutionLedger, ApprovalBroker, ProposalValidator
      Gate/                ActionGate: run, ask or refuse
      Capabilities/        typed operations (open_app, write_file, compose_mail, …)
      Screen/              ScreenController over cua-driver, the foreground lease
      Instant/             the no-model instant path
      Stores/              KernelStores: every V2 file, encrypted, under Application Support/Sonny/V2
      TaskController.swift the one thing the UI talks to
      TaskDesk.swift       every entry point, history, routines, watchers
    *CapabilityAdapter.swift  V1's reviewed action bodies, kept and run behind typed operations
  MacAgent/                the app: widget, Command Center, settings, menu bar
server/                    the gateway (Node 22, Fastify, TypeScript, zod)
  src/agent/               V2: session, runner, planner, screen agent, model router, tools, skill packs
  src/credit/              credits, balance, top-up
  src/auth/, src/routes/   sign-in, accounts, billing, transcription
  src/db/migrations/       numbered SQL migrations, each with a rollback and a lock profile
  skill-packs/             473 skill packs for popular sites, matched to tasks on the gateway
  deploy/Caddyfile         the TLS proxy (phase H)
contracts/v2/              the wire contract, JSON Schema plus shared fixtures
docs/                      plans, decisions, history
```

### The technologies, and why each one

- **Swift 6.3 with actors.** Each `TaskRuntime` is an actor, so a task's state can only be touched
  one step at a time, and the compiler enforces it. Races that would be silent bugs elsewhere are
  compile errors here.
- **SwiftUI** for the widget and Command Center.
- **cua-driver**, a Rust library with a C interface, for reading and driving other apps' windows.
  Phase 0 read its source to confirm it sends no telemetry and that environment variables can't
  widen what it's allowed to do.
- **Node + Fastify + TypeScript + zod** on the gateway. zod checks every message at the boundary,
  so bad input is refused at the door instead of crashing something deeper.
- **Postgres** (via Supabase, which also does sign-in). Tasks, transcripts, credits and billing
  live here.
- **WebSocket** (the `ws` library) for the session. A socket lets the gateway ask the Mac for a
  look or propose an action whenever it needs to.
- **Caddy** in front of the gateway for TLS. It gets certificates itself and passes WebSockets
  through untouched.
- **Swift Testing and vitest** for tests, and **Docker** for a throwaway Postgres in tests.

---

## 7. War stories: bugs we hit and what they taught

Every one of these was real and found during the V2 build.

### The task that started twice

**What happened.** When the connection came up, tasks waiting for it were released *before* the
Mac had processed the gateway's `welcome`. A task could send `task.start`, and then the welcome
handling would send it again.

**Fix.** Handle the welcome first, then release the waiters.

**Lesson.** Order of operations at a connection handshake is a correctness property, not a detail.
Write down what must happen before what.

### The zombie that held the only slot

**What happened.** A task stopped while offline came back after a relaunch looking alive, and held
the one "running task" slot forever.

**Fix.** The ledger now records "ended here" (`endedLocally`), and a restored ended task holds no
slot.

**Lesson.** Anything you persist is a promise to your future self about what it means after a
crash. Write down *why* a record exists, not just *that* it does.

### "Remind me in 5 minutes" that voided its own approval

**What happened.** The Mac prepares an action again just before running it (section 4). But
"5 minutes from now" re-read a minute later is a different time, so the fingerprint changed and
every approval that took over a minute was voided as "changed".

**Fix.** `PreparePins` remembers the time chosen the first time an action is prepared.

**Lesson.** A safety check can be defeated by an innocent value that naturally moves. Pin anything
time-dependent at the moment the person saw it.

### The cleaner nobody called

**What happened.** A function to delete stored replies after 24 hours existed, was tested, and
was documented. And nothing had ever run it. Transcripts kept "for a day" were kept forever.

**Fix.** The task retention sweep now runs it every ten minutes.

**Lesson.** A tested function is not a running feature. When you see "X is cleaned up by Y", go
and find the line that calls Y.

### The recent-files list that never grew

**What happened.** In V2 nothing recorded the files Sonny made, because the V1 runner had been
the only caller. "Open recent" showed only what V1 had left behind.

**Lesson.** The same one as above. When you delete a big component, list everything it *did*, not
only what it *was*.

### How we deleted 65 files safely

**The problem.** Phase 7 had to delete V1 without breaking what V2 still used. Reading 400 files to
decide was hopeless.

**The trick.** Start from nothing: build only the kernel, the kept adapters and the app, and
restore a V1 file only when the compiler complains it's missing. The compiler becomes an oracle
for "what is actually needed".

**The catch.** That works at the level of whole files. A second pass had to remove V1-only code
*inside* kept files.

### A shell that quietly changed our command

**What happened.** In zsh, `$BASE:server` doesn't mean "the variable, then ':server'". `:s` is a
zsh modifier (substitute), so the command silently used the whole repository tree where it meant
only the `server` folder.

**Fix.** Write `${BASE}:server`.

**Lesson.** When a result looks impossible (1,349 changed files for a one-folder change), stop and
find out why before doing anything with it.

### Tests that hung because of a copied response

**What happened.** A test returned `response.clone()` from a fake. Cancelling one copy of a cloned
body waits until the *other* copy is read or cancelled too, and nothing ever did.

**Lesson.** When a test hangs, suspect the fake before the code. Real servers give a fresh
response every time, and the fake should too.

### The exit that happened before we listened

**What happened.** A test sent the gateway `SIGTERM` and then attached an "exit" listener. The
gateway drained and exited in 4 milliseconds, before the listener existed, so the test waited
forever.

**Fix.** Capture the exit promise at the moment the process starts.

### A harmless looseness that became dangerous

**What happened.** The Mac's robots.txt parser matched user agents by substring, so "s" counted as
naming Sonny. That was mostly harmless while a group naming Sonny *added* rules. Then we fixed it
to *replace* the `*` group, as the RFC says. Now a group for "s" could erase a site's "don't crawl"
rules for everyone.

**Lesson.** When you change what a match *does*, re-check how loosely you *match*.

### The rewrite quietly dropped things V1 did "on the side"

The night after V2 merged, an audit compared V1's runner and view model, line by line, with V2. It
asked one question: what did V1 do *as a side effect* that V2 does nowhere? It found a dozen things.
None of them was a feature anyone had listed. They were chores V1's big central classes did, and V2's
cleaner split had no obvious home for them:

- **A signed-out launch never connected again**, even after you signed in, and every failure said
  "check your internet".
- **A bad Keychain read made history look empty**, and the next save wrote the empty list over the
  real file.
- **The screen agent could read a terminal**, and a shell showing in any app, though Sonny refuses to
  *act* there.
- **Screen work kept clicking with the Mac locked.** The plan even said "keep the attention monitors",
  and they were never ported.
- **A private task left traces:** clipboard copies, recent files, Shortcut runs and notification
  text.
- **"Zip my downloads folder" and "run my morning routine" stopped working.**

**Lesson:** when you split a big class, list everything it *did*, not only what it *was*. A god
class's side effects are features nobody wrote down. The plan document can also say "keep X", and X
still gets lost, because deletion is fast and porting is slow. Check the plan's "keep" lines against
the code after the fact.

### When one bug becomes another

Fixing "signing in connects" created a new, worse path. Sign out of account A and into B without
quitting, and A's unfinished tasks were offered to B's session. The old bug (the connection never
restarting) had been hiding the flaw (tasks aren't tied to an account). The review of the fix caught
it. Now the app remembers which account the Mac's tasks belong to, and ends them before a different
one connects.

**Lesson:** when a fix makes a path reachable that wasn't before, review what lives on that path.

### Tests can go missing too

Phase 7 deleted test files along with the V1 code they were written for. A few of those files also
held the only tests of code that V2 still uses: the process runner's cancellation, and the routine
schedule line on the Routines page. Nothing failed. The tests were simply gone.

One restored test told a second story. It was meant to cover a cancel landing mid-launch, and it
passed even with the protecting line deleted. It never reached the case it was named for. The fix
was a small seam in the runner that only tests use, so the test can put its cancel exactly in that
gap.

**Lesson:** a test you haven't seen fail proves nothing. Delete the line it protects, and watch it go
red.

### A task-local for privacy

"Don't save this task" has to reach code deep inside adapters, such as the recent-files list and the
Shortcut history, without threading a parameter through every signature. Swift's `@TaskLocal` does
it: the runtime sets `TaskPrivacy.isPrivate` around each action, and anything that action awaits can
read it. The catch is that it doesn't cross `Task.detached`. So the review's first job was to walk
the path and make sure nothing detached sits between the two.

### Reviews earn their keep

Every PR tonight got an independent, adversarial review, and every review found something real:

- a slot-accounting edge case;
- Word stealing focus;
- a toggle that undid your choice;
- a cancel that waited 30 seconds;
- the robots.txt matching looseness above.

But reviews are wrong sometimes too. One called a temporary over-count "forever", and reading the
code showed it clears as soon as tasks end. **Verify the claim, then fix what's real.**

### "Merges cleanly" is not "works together"

Before calling a batch of PRs independent, every pair was checked with `git merge-tree`: no
conflicts anywhere. Then all 31 were merged on a throwaway branch and built together. Two pairs
didn't compile.

- **#313 and #325.** #313 made the private toggle changeable only through `togglePrivate()`. #325's
  test set it directly. Each branch was fine on its own. Together, the test couldn't compile.
- **#332 and #338.** #338 added a required argument to the Mail send capability, and a new field to
  the draft it reads back. #332's new tests built that capability the old way.

Git compares lines, not meaning. Two edits can sit a hundred lines apart and still break each other.

**Lesson:** "no conflicts" is a text check. The only check for "works together" is building and
testing together. Both pairs are now stacked, so they can only be merged in the order that works.

### The link that ate `node_modules`

To test a fix in a second worktree, I linked its `server/node_modules` to the main checkout's copy,
to save installing everything again. Then `git add -A` committed the link. The ignore rule said
`node_modules/`, and the trailing slash matches only a folder. A link is a file.

It got worse when I checked that branch out in the main checkout. Git treats files inside an
ignored folder as disposable, so it replaced the real `node_modules` folder with the link, which
now pointed at itself. The tests quietly stopped running. The repair was `npm ci`, a rewritten
commit, a note on the PR, and a one-character fix to `.gitignore` (#340).

**Lesson:** stage the files you mean (`git add path/to/file`), not everything. And remember that a
trailing slash in `.gitignore` means "folders only".

### A polite server that let tasks starve

When the gateway failed to store a message (usually the database, for a second), it sent the Mac an
`error` frame and kept the socket open. That seemed polite. But the Mac ignores error frames. It
only resends what the gateway hasn't acknowledged after a fresh welcome. So the message was never
handled, and both sides waited for each other until the 24-hour sweep.

The fix (#329) was to close the socket. The Mac already knows what to do when a socket closes:
reconnect, hear what the gateway has, and send the rest again.

**Lesson:** a signal the other side ignores is the same as silence. Use the one it already acts on.

### An id is only unique where it was made

`send_mail` was changed to send only drafts Sonny wrote itself, by remembering their ids. The review
spotted that Mail numbers its drafts from the start again every time Mail restarts. So after a Mail
restart, "Sonny's draft 42" could be the person's own half-written email. Now each remembered id
also records which Mail process made it (#338).

**Lesson:** an id from another program is unique only inside the session that issued it.

### Return comes in many shapes

The rule "pressing Return in a text field counts as sending" was checked by asking whether the typed
text ends in `\n`. Then the list of ways around it kept growing:

- `\r\n`, which in Swift doesn't end in `\n` (it's one character);
- a line break in the middle of the text;
- Return held with ⌘ in a key chord listed in the other order;
- typing that set_value falls back to;
- the Space key and ⌘V while a password field is showing.

The fix (#333) stopped listing the bad things and listed the safe ones instead: while a password
field is showing, only a short list of keys that can't type anything is allowed.

**Lesson:** a list of forbidden things leaks, because there's always one more. A list of allowed
things holds.

---

## 8. How good engineers think (what this project models)

- **Decide what's trusted, then enforce it at one boundary.** Here: the Mac trusts nothing it
  didn't check itself.
- **Make the dangerous thing impossible, not just unlikely.** The ledger-before-dispatch rule and
  the approval digest mean "run twice" and "approve one thing, run another" can't happen, rather
  than being careful not to.
- **Write the failing test first, and make sure it fails.** A test that passes before the fix
  proves nothing about the fix.
- **Small PRs, stacked.** Each phase was one PR on top of the last, reviewed and merged bottom-up.
  A reviewer can hold one PR in their head, not eight.
- **Name the decision and who owns it.** Prices, caps and anything that spends money are founder
  decisions. Code reads them from configuration, and PR descriptions spell out the options.
- **Delete with evidence.** Use the compiler, the grep, the test, not memory.

---

## 9. Pitfalls to watch for

- **Adding a capability that brings an app to the front?** Set `bringsAppForward`, or it can pull
  an app forward in the middle of another task's click (PR #313).
- **Adding anything that deletes or retains data?** Find the line that schedules it, and test that
  it runs.
- **Anything with a time in it inside an approval?** Pin it.
- **Changing an effect or the gate?** The raise rules only ever go up. Add a test that shows a
  model can't lower it.
- **Touching money?** Record before you charge, never retry a charge whose outcome is unknown, and
  keep purchases one at a time per account.
- **Docker can't read files on your Desktop** (macOS privacy). Copy config to `/tmp` to mount it.
- **Checked that two branches merge?** Build and test them together too. A clean merge is only a
  text check.
- **Working in a second worktree?** Run `npm ci` there. Don't link `node_modules`, and stage files by
  name.
- **Remembering an id from another app?** Remember which run of that app issued it.
- **Sending text to the gateway?** Its limits count UTF-16 units, and Swift counts characters. Cut
  with `clipped(toUTF16:)`, and mask secrets first with `maskedAndClipped(toUTF16:)`.

---

## 10. Words you'll see

| Word | Meaning |
|---|---|
| **Gateway** | the Node server. It reasons, and it never touches your Mac. |
| **Kernel** | the Mac's execution core in `Kernel/`. It validates, gates, approves, records and runs. |
| **Capability** | one typed thing the Mac can do, like `open_app` or `write_file`. |
| **Effect** | how serious an action is: observe < navigate < edit_local < create < unknown < destructive < external < financial < credential. "Unknown" asks rather than stops. |
| **Mode** | Safe, Normal or Power. How often Sonny asks. |
| **Ledger** | the per-task record, written before each action runs. |
| **Outcome unknown** | an action started and we can't tell whether it finished. Never retried. |
| **Foreground lease** | one app in front at a time, shared by every task. |
| **Hold / settle** | reserve credits for the worst case, then charge what was used. |
| **Instant path** | commands the Mac answers alone, with no model and no network. |
| **Skill pack** | site-specific guidance, matched to a task on the gateway. |
| **Drain** | on restart, the gateway tells each Mac "reconnect in a second" (close code 1012). |
