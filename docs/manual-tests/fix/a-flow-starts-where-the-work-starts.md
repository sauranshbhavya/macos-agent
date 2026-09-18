### `fix/a-flow-starts-where-the-work-starts` (SONNY-510, 2026-09-18)

The Skills page shows no depth, flows or start pages, so nothing on it changes. What changes is where
Sonny goes when a command names one of these packs:
- 38 start pages moved to the site's sign-in page.
- 15 packs name a different sign-in page.
- 29 packs have no task steps any more.
- Perplexity lost two flows, and eBay one.
- OneDrive starts at its own sign-in page.
- The 25 packs other wave-12 lanes made deep now carry the record, and all 25 keep their task steps.

Run each row with the packaged app, with the named skill added on the Skills page, in a browser
**signed out** of the site in question.

- [ ] **SONNY-510 — a start page that used to be account creation now opens sign-in.** Ask Sonny to
  do a Miro task, for example "create a Miro board". It opens `miro.com/login/` ("Sign in to Miro"),
  not `miro.com/signup/`. Before this branch the flow started at `miro.com/app/dashboard/`, which sends
  a signed-out visitor to Miro's account-creation page.
- [ ] **SONNY-510 — a bare origin that used to land on marketing now opens sign-in.** Ask Sonny for a
  Slack task, for example "in Slack, create a channel". It opens Slack's email sign-in page ("Enter your
  email address to sign in"), not the slack.com marketing homepage.
- [ ] **SONNY-510 — shape 2, the landed host.** Ask Sonny for a Google Ads task. It starts at Google's
  sign-in (`accounts.google.com`, "Google Ads - Sign in", heading "Sign in"), not at
  `business.google.com`'s marketing page.
- [ ] **SONNY-510 — a pack with no admissible start page has no task steps.** Ask Sonny to do an n8n
  task. It does not open `n8n.io`'s marketing homepage and try to follow numbered steps from there. The
  pack still tells Sonny what n8n is and where its sign-in page is. The same is true of Claude,
  GrowthBook, Microsoft 365, Zoho Desk, Greenhouse, Midjourney, Pinterest and ShipStation.
- [ ] **SONNY-510 — a start page whose form also creates the account has no task steps.** Ask Sonny
  for a Canva task, for example "make a Canva poster". It does not open Canva's "Log in or sign up in
  seconds" page and follow numbered steps from there. The same is true of Airtable, Amplitude, Attio,
  Dropbox, Fireflies, Framer, HeyGen, Manus, Microsoft Copilot, Synthesia, Twenty and v0.
- [ ] **SONNY-510 — a start page that asks to scan faces has no task steps.** Ask Sonny for a Runway
  task. It does not open Runway's log-in page, whose Continue and Log in agree that faces may be
  scanned and voiceprints captured, and follow numbered steps from there.
- [ ] **SONNY-510 — a product nobody signs themselves up for keeps its task steps.** Ask Sonny for a
  Lever task. It opens Lever's "Sign in to Lever" page. Lever offers no self-serve sign-up anywhere,
  because an employer creates its accounts. The same is true of Affinity, Ashby, Birdeye and Pylon.
  BambooHR is the opposite case and has no task steps: its sign-in page shows no sign-up either, but
  `bamboohr.com/signup/` offers a self-serve free trial.
- [ ] **SONNY-510 — a pack another lane made deep opens its recorded start page.** Ask Sonny for a
  Kajabi task. It opens `id.kajabi.com/u/login` ("Sign in to your account"), where "Sign up here" is a
  separate link. The same goes for the other 24 packs wave 12 added, among them Circle, Skool, Otter and
  TikTok Ads.
- [ ] **SONNY-510 — a marketplace starts on the product itself.** Ask Sonny to save an eBay search, for
  example "save an eBay search for vintage cameras". It opens `www.ebay.com/` and searches there,
  signed out, rather than going to a sign-in page first. Asking Sonny to tidy your eBay Watchlist
  gets no numbered steps, because signed out that flow's first step, My eBay, led to a bot check.
- [ ] **SONNY-510 — a product page whose first step needs an account has no task steps.** Ask Sonny
  for a ChatGPT task, for example "set my ChatGPT custom instructions". It does not open `chatgpt.com`
  and follow numbered steps from there: signed out, ChatGPT's Settings has no Personalization, and its
  "Log in" opens one form for both logging in and signing up. The same is true of Bolt, Mistral,
  Product Hunt and Luma, whose `luma.com/create` asks you to "sign in or sign up below" as it loads.
- [ ] **SONNY-510 — Perplexity keeps its question flow only.** Ask Sonny a question in Perplexity. It
  opens `www.perplexity.ai/` and asks in the "Ask anything" box, signed out. Asking Sonny to make a
  Perplexity skill gets no numbered steps, because signed out there is no Skills page to start from.
- [ ] **SONNY-510 — OneDrive starts at its own sign-in.** Ask Sonny to upload a file to OneDrive. It
  opens `onedrive.live.com/login/`, which shows Microsoft's "Sign in" with "No account? Create one!"
  as a separate link, and follows its steps from there.
- [ ] **SONNY-510 — signed in, a moved start page still reaches the product.** Signed **in** to Miro
  in the browser, ask Sonny for a Miro task. `miro.com/login` should forward a signed-in user into the
  product. This branch read every start page signed out only, so this row is the one reading of the
  signed-in case. If it stops on a sign-in form, record which pack and page it was.
