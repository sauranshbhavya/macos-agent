### The Jev + cua experiment runs its five tasks on a founder's Mac (new 2026-09-17, SONNY-517)

Not the packaged app. This is `experiments/jev-cua`, run from a terminal; it touches nothing in Sonny. Setup once: `cd experiments/jev-cua && ./scripts/fetch-cua-driver.sh`, start the daemon with `open -n -g .cua-driver/unpacked/*/CuaDriver.app --args serve`, grant CuaDriver both Accessibility and Screen Recording when macOS asks, and put a TypeSafe key and an OpenAI key in `.env` (copy `.env.example`). No sign-in is needed on any page below and the agent must never be asked for one; the flight task ends at the results list and nothing is ever selected, booked or paid for.

- [ ] `npm run task -- calculator` ends with `calculator: DONE` in the terminal and Calculator's display shows 1776. Nothing else on the Mac moved: the terminal stayed frontmost the whole run unless the report's `rungs.foreground` count is non-zero, in which case the window was fronted exactly that many times and put back.
- [ ] `npm run task -- textedit` leaves an untitled TextEdit document holding exactly "The quick brown fox jumps over the lazy dog." and nothing else, with no second document opened.
- [ ] `npm run task -- settings` leaves System Settings on the Displays pane.
- [ ] `npm run task -- wikipedia` leaves Safari on the English Wikipedia article titled "Eiffel Tower", reached through Wikipedia's own search box rather than by typing a URL.
- [ ] `npm run task -- flights` leaves Safari on Google Flights showing a one-way results list from Zurich to London for 20 October 2026, one adult, economy — and no flight is selected, no booking page is open, and no sign-in page was visited. If Google shows a consent or sign-in interstitial the run may end `FAILED` with the coordinator saying so; that is the correct outcome, not a defect.
- [ ] Every run wrote `runs/<task>-<time>.json`, and its `tree.sha` matches `git rev-parse --short HEAD` in the worktree the run came from, with `tree.dirty` false.
- [ ] Killing the daemon (`cua-driver stop`) and running a task again ends with an `ERROR` status naming the daemon, not a hang.
