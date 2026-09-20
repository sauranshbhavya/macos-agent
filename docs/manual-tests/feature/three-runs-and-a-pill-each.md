### A "Task failed" notification's Retry re-runs the task it was about, or nothing (new 2026-09-19, SONNY-533)

**Before this branch**, pressing Retry on a "Task failed" notification re-ran whatever Sonny had
been asked most recently, not the task the notification was about. A notification can sit in
Notification Center for a long time, so by the time you pressed it that was often a different task.
**Now** each notification remembers its own failed task. Its Retry re-runs that task, once, and does
nothing at all once you have moved on to something else.

Setup: the packaged app (`./scripts/package-app.sh`, then open it). In Settings › Notifications,
"Task failed" is on. You need a task that fails on demand: **turn Wi-Fi off** and ask for anything
Sonny has to think about, for example `draft a short note about today's plan on my Desktop`. A
notification only posts while Sonny is not the app you are working in, so after each command press
Return and then click straight onto the Desktop or another app.

- [ ] Wi-Fi off. Type `draft a short note about today's plan on my Desktop`, press Return, click onto
      the Desktop. A "Task failed" notification arrives with a Retry button. **Leave it in
      Notification Center.**
- [ ] Wi-Fi on. Bring the widget back, type `draft a short note about lunch on my Desktop`, press
      Return. It finishes, and a note about lunch is on the Desktop. Delete that note.
- [ ] Open Notification Center and press **Retry on the old notification**, the one about today's
      plan. **Nothing happens**: no new note appears, about lunch or about today's plan, and the
      widget does not start working. (Before this branch, this press wrote the lunch note again.)
- [ ] The Retry that should work. Wi-Fi off, type `draft a short note about today's plan on my
      Desktop`, press Return, click onto the Desktop. The notification arrives. Turn Wi-Fi back on
      and press **Retry** on it. Sonny starts working, and the note about today's plan appears.
- [ ] Press Retry on that same notification again, if it is still in Notification Center. Nothing
      happens: one notification is one retry.

### A failure that is not a task offers no Retry (new 2026-09-19, SONNY-533)

Some "Task failed" notifications are not about a task at all, for example the microphone being
refused when you hold the push-to-talk shortcut. **Before this branch** they carried a Retry button
too, and pressing it re-ran whatever you had last asked Sonny, which had nothing to do with the
microphone. **Now** they carry no button. Clicking the notification still opens the widget.

This row needs the microphone turned off for Sonny, so skip it if you would rather not change
that: System Settings › Privacy & Security › Microphone, switch Sonny off, and relaunch Sonny.

- [ ] Run any task in Sonny first, so there is a last task it could wrongly repeat. Then switch to
      another app and hold ⌃⌥Space. If a "Task failed" notification arrives saying microphone
      permission was denied, **it has no Retry button**, and clicking it opens the widget, which
      shows the same sentence. If no notification arrives at all, that is because the shortcut
      brought the widget forward and Sonny counted as the app you were working in; write that down
      instead, because then this case cannot be reached by hand and the tests are what hold it.
- [ ] Switch the microphone back on for Sonny.

### The rest of this branch owes no rows yet, and why (SONNY-456)

Six more things changed on this branch, and none of them can be seen until two tasks can run at
once, which the rest of SONNY-456 delivers. Their rows arrive with it.

- **Stopping a screen-control task ends that task and no other.** The row to come: stop the task in
  the background while the widget shows a different one, and the stopped task's pill goes away.
- **What you say lands on the task you were looking at when you started speaking**, even if you
  click a different pill before the words arrive.
- **A fourth task is refused while three are running.** The widget says "Sonny is already working on
  three tasks. Try again when one finishes." and keeps what you typed.
- **⌃⌥⎋ stops every task**, not only the one the widget is showing.
- **Nothing is deleted under a running task, whichever task the widget shows.** Deleting all local
  data, the set-aside files, a Memory row, a routine or a workspace is refused while any task is
  running, with the same sentence as today.
- **A scheduled routine waits for every task to finish**, not only the one the widget shows, and
  then runs.

One thing you can check today, because it must not have changed:

- [ ] Start a screen-control task (for example `[s] open a new note in Notes`). While Sonny is
      controlling the app, press **⌃⌥⎋**. The task stops at once, exactly as it did before this
      branch, and the pill goes back to the widget.
