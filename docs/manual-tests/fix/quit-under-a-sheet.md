### Quitting with a sheet up, and Relaunch Sonny ending the copy it replaces (new 2026-09-18, SONNY-448)

**What changed:** any sheet on Command Center used to make Sonny ignore every way of quitting. That
included first run, Settings and every "are you sure" dialog, and it covered ⌘Q, both menus' **Quit
Sonny** and the Dock's **Quit**. Nothing happened and nothing said why. **Relaunch Sonny** only ever
appears inside a sheet, so it started the new copy and then could not end the old one. These rows
re-run your pass's **test 3** (failed: "doesn't let us quit on the login screen") and **test 77**
(the stale copy after Relaunch Sonny), plus the routes that were broken the same way and were not
in your report.

**What a test can and cannot see here.** The suite holds the setting that decides whether macOS may
quit the app, read off real windows. It also holds that first run records nothing when a quit takes
its sheet down, and that the next launch lands on the same step. **Whether the packaged app actually
quits is these rows and nothing else:** a test process cannot quit itself without ending the test
run. The same goes for Escape landing where it should in a live sheet, and for one Sonny being left
after a relaunch.

**Setup, for every row:** the packaged app, one copy only — `./scripts/package-app.sh`, then
`open .build/arm64-apple-macosx/debug/MacAgent.app`. Not `swift run`. To bring first run back, use
the archive's first-run reset (`scripts/changelog-order manual-tests | less`, then search for
*"The full reset is four things"*). Each row below names which parts of it (a)–(d) it needs. The
one-process check is `pgrep -lf MacAgent.app/Contents/MacOS/MacAgent` in Terminal: one line means
one Sonny.

- [ ] **⌘Q on the sign-in step — test 3's failure.** Reset **(a)** if you are signed in, then
      **(b)**. Launch; the sequence opens on sign in. Press **⌘Q once**. Sonny must quit: Command
      Center, the floating widget, the menu-bar icon and the Dock icon all go, and `pgrep` prints
      nothing. Open it again. It must come back **on sign in**, not on screen access and not
      on nothing. Quitting is not declining.
- [ ] **The menu-bar Quit, with the same sheet up.** Continuing from the row above (still on sign
      in): menu-bar icon → **Quit Sonny**. Same result, and it comes back on sign in again.
- [ ] **The Dock's Quit, with the same sheet up.** Right-click Sonny's Dock icon → **Quit**. Same
      result. This one was not in your report. It reached the same refusal by a route that never
      passes through Sonny's own Quit, which is why the fix is where it is.
- [ ] **Escape still declines, and does not just make the sheet go away.** Reset **(b)** and
      **(c)**, and **(a)** if signed in. **(c) is not optional here**: with both grants already held,
      the screen-access step counts as done, so declining sign-in correctly ends first run and the
      sheet goes away — which is exactly what this row treats as the failure. Launch, **click into
      the email field** so the cursor is in it, and press **Escape**. The sheet must move to the
      **screen-access** step. It must not disappear, and it must not stay on sign in. Press
      **Escape** again on screen access, without clicking anything first. The sheet goes away and
      first run is over. Quit and reopen: first run must **not** come back, because both steps were
      declined. (This row guards the one behaviour this fix had to move by hand: left to the sheet
      itself, Escape with a field focused is indistinguishable from a quit.)
- [ ] **Relaunch Sonny from first run ends the old copy — test 77.** Reset **(b)** and **(c)**
      (leave yourself signed out). Launch, press **Sign in later** to reach screen access, press
      **Request access** under Screen Recording, switch Sonny on in System Settings, and press
      **Relaunch Sonny**. Afterwards there must be **one** Sonny: `pgrep` prints one line, and the
      menu bar has one Sonny icon. The copy that came back must open **on the screen-access step with
      Screen Recording showing Granted**, still asking for Accessibility. If it opens on nothing, the
      relaunch recorded screen access as declined, and that is a failure of this row.
- [ ] **Relaunch Sonny from Settings ends the old copy too.** Reset **(c)**, then **(d)**: quit
      and reopen the packaged app, as the reset's last step says. If first run comes back, it is on
      the **screen-access** step only, because the row above recorded sign-in as declined; press
      **Set up later in Settings** to get it out of the way. Open **Settings → Security & Access**,
      and under **Screen Access** press **Set up**: that dialog is a sheet on top of the Settings
      sheet. Press **Request access**, grant Screen Recording in System Settings, and press
      **Relaunch Sonny**. `pgrep` must print one line.
- [ ] **⌘Q with Settings open.** Press **⌘,** to open Settings, then **⌘Q**. Sonny quits.
- [ ] **⌘Q with an "are you sure" dialog up does not do the thing it was asking about.** This needs
      at least one task in **Tasks**; if it is empty, run anything in the widget first (a
      calculation will do). Open a task in **Tasks**, choose **Delete task** from its actions, and
      while the delete confirmation is on screen press **⌘Q**. Sonny quits. Open it again: **the
      task must still be there**. Quitting closed the question; it did not answer it.
