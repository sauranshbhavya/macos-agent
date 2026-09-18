### `fix/a-flow-starts-where-the-work-starts` (SONNY-510, 2026-09-18)

The Skills page shows no depth, flows or start pages, so nothing on it changes. What changes is where
Sonny goes when a command names one of these packs: 38 start pages moved to the site's sign-in page,
15 packs name a different sign-in page, and ten packs have no task steps any more. Run each row with
the packaged app, with the named skill added on the Skills page, in a browser **signed out** of the
site in question.

- [ ] **SONNY-510 — a start page that used to be account creation now opens sign-in.** Ask Sonny to
  do a Miro task, for example "open my Miro boards". It opens `miro.com/login/` ("Sign in to Miro"),
  not `miro.com/signup/`. Before this branch the flow started at `miro.com/app/dashboard/`, which sends
  a signed-out visitor to Miro's account-creation page.
- [ ] **SONNY-510 — a bare origin that used to land on marketing now opens sign-in.** Ask Sonny for a
  Slack task, for example "in Slack, create a channel". It opens Slack's email sign-in page ("Enter your
  email address to sign in"), not the slack.com marketing homepage.
- [ ] **SONNY-510 — shape 2, the landed host.** Ask Sonny for a Google Ads task. It starts at Google's
  sign-in (`accounts.google.com`, "Google Ads - Sign in"), not at `business.google.com`'s marketing page.
- [ ] **SONNY-510 — a pack with no admissible start page has no task steps.** Ask Sonny to do an n8n
  task. It does not open `n8n.io`'s marketing homepage and try to follow numbered steps from there. The
  pack still tells Sonny what n8n is and where its sign-in page is. The same is true of Claude,
  GrowthBook, Microsoft 365, OneDrive, Zoho Desk, Greenhouse, Midjourney, Pinterest and ShipStation.
- [ ] **SONNY-510 — signed in, the moved start page still reaches the product.** Signed **in** to
  Airtable in the browser, ask Sonny for an Airtable task. `airtable.com/login` should forward a
  signed-in user into the product. This branch read every start page signed out only, so this row is the
  one reading of the signed-in case. If it stops on a sign-in form, record which pack and page it was.
