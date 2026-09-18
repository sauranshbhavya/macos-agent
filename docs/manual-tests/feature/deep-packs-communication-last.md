### Deep Skills packs for ten more communication sites (new 2026-09-17, SONNY-502 and SONNY-507)

Ten more sites in the communication group gain deep packs: Aircall, CallRail, Fathom, JustCall,
Krisp, Otter.ai, Quo, Read AI, Skool and Webex. What is being checked is that a pack reaches the
planner at all and that its steps are the ones the site actually uses — not that Sonny completes
the task on a live account. **Sign in to nothing.** Every row below can be read from the plan Sonny
shows before it acts.

Setup: the packaged app (`./scripts/package-app.sh`, then open
`.build/arm64-apple-macosx/debug/MacAgent.app`), because the floating widget is where a command is
typed.

- [ ] **A CallRail command pulls in the CallRail pack.** Ask the widget `rename my tracking number
      in callrail`. **Sonny's plan uses CallRail's own path — the Settings icon on the left, the
      company, Edit (the pencil) for the number, Edit in Number Options, then Number Name and Save —
      and starts on `app.callrail.com`.** **What would be a finding:** a plan that opens some other
      site, that names a CallRail control the pack does not, or that creates or buys a tracking
      number.
- [ ] **A Krisp command pulls in the Krisp pack, and starts at its sign-in rather than at sign-up.**
      Ask `create a meeting folder in krisp`. **The plan clicks New Folder (or + beside Private or
      Teamspace), names the folder, picks Private or Teamspace, and clicks Create; its start page is
      `app.krisp.ai/login`, which signed out reads "Sign in to your account" with "Sign up" as a
      link.** **What would be a finding:** a start page of `app.krisp.ai/` on its own — signed out,
      that one lands on Krisp's "Sign up for free" page.
- [ ] **No flow in these packs moves money.** Ask `call a contact with openphone`. **The plan dials
      from Quo's dialer and says that calls outside the US and Canada need credit on the account,
      which it does not add.** **What would be a finding:** any step, in this plan or the two above,
      that adds credit, pays, buys a number or changes a card. Quo's own calling page offers adding
      credit for international calls in a collapsed FAQ; the pack names it only to say it stops
      there.
- [ ] **Five sites of this group are deliberately still shallow.** Ask `upload a recording to
      tl;dv`, then `create a space in mighty networks`. **Sonny has no step-by-step flow for either
      and says so, or plans from general knowledge rather than citing pack steps.** **What would be a
      finding:** Sonny citing pack steps for tl;dv, Mighty Networks, Mattermost, Google Chat or Google
      Voice — none of those five shipped, each for a start-page reason this branch's changelog entry
      records.
