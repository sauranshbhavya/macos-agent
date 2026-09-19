### Deep Skills packs for the finance and billing group (new 2026-09-18, SONNY-519)

Twelve finance and billing sites gain deep packs so far: Stripe, Wise Business, Square, Toggl Track,
Clockify, Wave, GoCardless, Dext, Qonto, Lemon Squeezy, Airwallex and Ramp. What is being checked is that a pack
reaches the planner at all and that its steps are the ones the site actually uses — not that Sonny
completes the task on a live account. **Sign in to nothing.** Every row below can be read from the
plan Sonny shows before it acts.

Setup: the packaged app (`./scripts/package-app.sh`, then open
`.build/arm64-apple-macosx/debug/MacAgent.app`), because the floating widget is where a command is
typed.

- [ ] **A Clockify command pulls in the Clockify pack.** Ask the widget `start a timer in clockify
      for writing the report`. **Sonny's plan goes to the Time Tracker page, clicks the What are you
      working on? box, types a description, and clicks Start — and starts on `app.clockify.me`,
      which signed out lands on `app.clockify.me/login`, "Log in", with "Sign up" as a separate
      link.** **What would be a finding:** a plan that opens some other site, names a Clockify
      control the pack does not, or starts on a sign-up page.
- [ ] **A Stripe command pulls in the Stripe pack, and nothing in it touches money.** Ask `invite a
      teammate to my stripe.com dashboard`. **The plan goes to the Team tab, clicks Add member,
      adds the email address, picks the lowest role the person needs, and clicks Send invites; its
      start page is `dashboard.stripe.com/`, which signed out lands on the Stripe sign-in page with
      "Create account" as a separate link.** **What would be a finding:** any step that pays,
      refunds, creates a payout, or adds or changes a card or bank account.
