### A notification's Allow answers only the question it was posted for (new 2026-09-18, SONNY-456)

One of the two things this branch changes that you can see (the other is the last section of this
file). **Before it**, pressing Allow on an "Approval needed" notification acted on whatever Sonny had
in front of it *at the moment you pressed it*, not on the question the notification was about. With
one task at a time that could already go wrong: an old notification left in Notification Center
approved a newer, different question; with nothing waiting it started whatever was typed in the
widget, or put "Enter a natural-language command first." on the widget. **Now** each notification
remembers its own question, and its Allow does nothing once that question has gone.

Setup: the packaged app (`./scripts/package-app.sh`, then open it). In Settings › Notifications,
"Approval needed" is on. Make a folder on the Desktop called `sonny-test` holding three empty text
files, `a.txt`, `c.txt` and `e.txt`. Any command that asks before acting will do in place of the renames
below; renames are what the founders use for "a command that asks first".

A notification only posts while Sonny is not the app you are working in, so after each command
press Return and then click straight onto the Desktop or another app.

- [ ] Type `rename a.txt in the sonny-test folder on my Desktop to b.txt`, press Return, click onto
      the Desktop. An "Approval needed" notification arrives. **Leave it in Notification Center.**
- [ ] Click the pill to bring the widget back, and press ✗ to deny that question. Nothing is
      renamed.
- [ ] Type `rename c.txt in the sonny-test folder on my Desktop to d.txt`, press Return, click onto
      the Desktop. A second "Approval needed" notification arrives.
- [ ] Open Notification Center and press **Allow on the first notification**, the one for
      `a.txt`. **Nothing happens**: `c.txt` is not renamed, and the pill still says Sonny needs
      you. (Before this branch, this press would have renamed `c.txt`.)
- [ ] Press **Allow on the second notification**, the one for `c.txt`. `c.txt` becomes `d.txt`.
- [ ] A stale notification with nothing waiting. Type `rename e.txt in the sonny-test folder on my
      Desktop to f.txt`, press Return, click onto the Desktop, and **leave the notification**. Bring
      the widget back and press ✗. Now type `hello` in the widget **without pressing Return**, click
      onto the Desktop, and press Allow on that notification. **Nothing starts**, `e.txt` is not
      renamed, and `hello` is still in the widget, unsent. (Before this branch, this press sent
      `hello` as a task.)
- [ ] Put the folder back (`a.txt`, `c.txt` and `e.txt`) if you want to run this again.

### Nothing else changed: the ordinary answers still work (new 2026-09-18, SONNY-456)

The rest of this branch moves how Sonny holds its one running task, without changing what it does.
These check the paths it moved.

Setup: the same packaged app and folder.

- [ ] One question, answered from its notification: type the `a.txt` rename, press Return, click
      away, and press Allow on the notification straight away. `a.txt` is renamed.
- [ ] One question, answered in the widget: run the rename again (back to `a.txt` first), click the
      pill, and press ✓. It is renamed. Run it once more and press ✗: nothing is renamed and the
      widget clears.
- [ ] One question, answered in Command Center: open Command Center, run the rename from the widget,
      and answer it with Allow on Command Center's attention panel. It is renamed.
- [ ] A command that fails while you are in another app still posts a "Task failed" notification,
      and the failure is still on the widget when you come back to it.
- [ ] The menu-bar icon still changes while a task runs, turns to the attention colour while a
      question waits, and to the failure colour after a failure.

### A shortcut that cannot be set up at launch no longer claims a task failed (new 2026-09-19, SONNY-456)

The second thing this branch changes, and it is on purpose (founder decision 2026-09-19). **Before
it**, when the push-to-talk shortcut (⌃⌥Space) could not be set up at launch, usually because
another app already holds it, Sonny posted a **"Task failed"** notification carrying the reason,
though no task had run. **Now** no notification posts; the reason still shows in the widget and in Settings, and the
menu-bar icon still turns red.
What is lost is the only signal that arrived unasked; SONNY-535 is where whether a launch-time
problem should push anything is decided. This row checks the new behaviour, not that ticket's.

Setup: the packaged app. In Settings › Notifications, "Task failed" is on. Give another app ⌃⌥Space
as its own shortcut — a launcher such as Raycast or Alfred lets you set one — so Sonny cannot take it.

- [ ] Quit Sonny, then launch it from Finder and leave it without opening the widget. **First, the
      menu-bar icon turns to its failure colour** — that is what says the other app really did take
      ⌃⌥Space; if it does not, the rows below prove nothing, so fix the setup first.
- [ ] **No "Task failed" notification arrives**, then or in the next minute.
- [ ] Open the widget. It says the shortcut could not be set up. Settings › Security & Access ›
      Permission Readiness says "Another app is using ⌃⌥Space." These two and the icon are where
      the failure still shows; what this branch removed is only the notification.
- [ ] Take ⌃⌥Space away from the other app and relaunch Sonny. Holding ⌃⌥Space starts a recording
      again.
