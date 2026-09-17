### Deep Skills packs for four more communication sites (new 2026-09-17, SONNY-502)

Four more sites in the communication group gain deep packs: ClickSend, Demio, Livestorm and
Textmagic. What is being checked is that a pack reaches the planner at all and that its steps are
the ones the site actually uses — not that Sonny completes the task on a live account. **Sign in to
nothing.** Every row below can be read from the plan Sonny shows before it acts.

Setup: the packaged app (`./scripts/package-app.sh`, then open
`.build/arm64-apple-macosx/debug/MacAgent.app`), because the floating widget is where a command is
typed.

- [ ] **A ClickSend command pulls in the ClickSend pack.** Ask the widget `send a quick sms with
      clicksend to my contact list`. **Sonny's plan uses ClickSend's own Quick SMS screen — the To
      field, the From field, Now or Later, then Preview and Confirm before Send — and starts on
      `dashboard.clicksend.com`.** **What would be a finding:** a plan that opens some other site,
      that invents a ClickSend control the pack does not name, or that asks you to sign in as part
      of the task.
- [ ] **A Textmagic command pulls in the Textmagic pack.** Ask `forward my textmagic number's
      incoming calls to messenger`. **Sonny's plan goes to the Numbers page, the More icon,
      Forwarding settings, then picks Textmagic Messenger under "Forward calls to" and clicks
      Continue** — the wording on Textmagic's own page. **What would be a finding:** a plan that
      names a control Textmagic does not have, or one that buys a number.
- [ ] **No flow in these packs moves money.** In both commands above, read the whole plan.
      **Nothing asks to pay, top up, buy a number, change a card or add credit.** **What would be a
      finding:** any step that touches payment, billing or a card — that would be a defect in the
      pack, not in the planner. ClickSend is the one to watch: its Quick SMS step says to check
      what the send will cost before sending, which is a preview screen and not a purchase.
- [ ] **A start page is somewhere the task can actually begin.** Ask `record my livestorm event`.
      **The plan's start page is `app.livestorm.co`, and opening it signed out reaches Livestorm's
      own sign-in — "Nice seeing you again", with signing up demoted to a link.** **What would be a
      finding:** a start page that lands on an account-creation form, or on a marketing page with
      no way into the product.
- [ ] **Google Chat and Google Voice are deliberately still shallow.** Ask `create a google chat
      space`. **Sonny has no step-by-step flow for it and says so, or plans from general knowledge
      rather than citing pack steps.** **What would be a finding:** Sonny citing pack steps for
      either. Both sites' flows were read in this session but their start pages could not be
      measured against a browser profile with no remembered Google account, so neither pack
      shipped (see this branch's changelog entry).
