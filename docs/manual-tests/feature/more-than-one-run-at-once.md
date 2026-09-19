### A notification's Allow answers only the question it was posted for (new 2026-09-18, SONNY-456)

This is the one thing this branch changes that you can see. **Before it**, pressing Allow on an
"Approval needed" notification approved whatever question Sonny had waiting *at the moment you
pressed it*, not the question the notification was about. With one task at a time that could
already go wrong: an old notification left in Notification Center could approve a newer, different
question. **Now** each notification remembers its own question, and its Allow does nothing once
that question has gone.

Setup: the packaged app (`./scripts/package-app.sh`, then open it). In Settings › Notifications,
"Approval needed" is on. Make a folder on the Desktop called `sonny-test` holding two empty text
files, `a.txt` and `c.txt`. Any command that asks before acting will do in place of the renames
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
- [ ] Put the folder back (`b.txt` stays absent, `d.txt` back to `c.txt`) if you want to run this
      again.

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
