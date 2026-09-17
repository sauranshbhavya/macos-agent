### Deep Skills packs for six communication sites (new 2026-09-17, SONNY-502)

Six sites gain deep packs: Discord, Dialpad, Google Meet, Loom, SimpleTexting and StreamYard.
What is being checked here is that a pack reaches the planner at all and that its steps are the
ones the site actually uses — not that Sonny completes the task on a live account. **Sign in to
nothing.** Every row below can be read from the plan Sonny shows before it acts.

Setup: the packaged app (`./scripts/package-app.sh`, then open
`.build/arm64-apple-macosx/debug/MacAgent.app`), because the floating widget is where a command
is typed.

- [ ] **A Discord command pulls in the Discord pack.** Ask the widget `search my discord messages
      for the release notes`. **Sonny's plan uses Discord's own search — the search bar at the top
      right, or the `from:`, `in:`, `mentions:` and `has:` filters — and starts on discord.com.**
      **What would be a finding:** a plan that opens some other site, that invents a Discord
      control the pack does not name, or that asks you to sign in as part of the task.
- [ ] **A Loom command pulls in the Loom pack.** Ask `share my latest loom video with the team by
      email`. **Sonny's plan uses Share, then the person's email address or name, and offers view
      or edit access** — the wording on Loom's own page. **What would be a finding:** a plan that
      pastes a link without going through Share, or that names a control Loom does not have.
- [ ] **No flow in these packs moves money.** In both commands above, read the whole plan.
      **Nothing asks to pay, refund, top up, change a card or confirm a billing change.** **What
      would be a finding:** any step that touches payment, billing or a card — that would be a
      defect in the pack, not in the planner. Dialpad is the one to watch if you try a Dialpad
      command: its add-a-user page ends at a billing confirmation and that path was deliberately
      left out of the pack.
- [ ] **A start page is somewhere the task can actually begin.** Ask `start a google meet`. **The
      plan's start page is `meet.google.com/landing`, and opening it signed out reaches Google's
      own sign-in, which returns to Meet.** **What would be a finding:** a plan starting at
      `meet.google.com/` — signed out that leaves the domain entirely for
      `workspace.google.com/products/meet/`, a marketing page with no New meeting button on it.
      This row exists because that is what shipped until review-258 caught it, and it read as
      healthy in a signed-in browser.
- [ ] **Mattermost is deliberately still shallow.** Ask `create a mattermost channel`. **Sonny has
      no step-by-step flow for it and says so, or plans from general knowledge rather than citing
      pack steps.** **What would be a finding:** Sonny confidently naming a start page for
      Mattermost. It is self-hosted, no URL on mattermost.com reaches a channel sidebar, and the
      pack stands down for that reason (SONNY-510).
