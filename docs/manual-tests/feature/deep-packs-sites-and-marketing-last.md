### Sonny follows a Contentful flow it now knows (new 2026-09-17, SONNY-504)

Packaged app (`./scripts/package-app.sh`, then `open .build/arm64-apple-macosx/debug/MacAgent.app`).
Sign in to Contentful yourself first, in the browser Sonny drives — no flow asks Sonny to sign in.

- [ ] Ask Sonny, in the floating widget, to create a content type in Contentful. It names Contentful rather than asking which site you mean.
- [ ] The steps go through the Content model tab and + Add content type, then Name, Create, + Add field and Save — in that order.
- [ ] Ask it to schedule an entry to publish tomorrow in Contentful. It goes to the Content tab, the entry, the drop-down arrow on the Publish button and Set schedule, and it mentions the timezone defaults to your computer's.

### Sonny follows a Kajabi flow it now knows (new 2026-09-17, SONNY-504)

Same packaged app. Sign in to Kajabi yourself first.

- [ ] Ask Sonny to filter your Kajabi contacts by a tag and save that as a segment. It goes to the Contacts tab, Filters, a Category / Conditional / Value, Apply Filters, then Save as Segment above the list.
- [ ] Ask it to add a tag to one contact in Kajabi. It opens the contact from the Contacts tab and uses Add Tag, then Save.
- [ ] Nothing in either proposal touches Offers, payments or a purchase.

### Sonny follows an eBay flow it now knows (new 2026-09-18, SONNY-504)

Same packaged app. Sign in to eBay yourself first.

- [ ] Ask Sonny to save an eBay search for something you look for often. It searches, then selects Save this search at the top of the results — it does not open a listing or offer to bid or buy.
- [ ] Ask it to tidy your eBay Watchlist. It goes to My eBay → Watching, and offers Sort, the Status dropdown, and tick-and-Delete.

### The twelve new packs' start pages sign in an existing account, with account creation a separate route (new 2026-09-18, SONNY-503, SONNY-504)

No app needed — a browser signed out of everything, which is what Sonny meets on a fresh Mac. Each was measured once on this branch; if a page has moved, note what it now shows.

- [ ] `https://be.contentful.com/login/` — "Log in to your Contentful account", email and password.
- [ ] `https://app.unbounce.com/users/sign_in` — "Sign into your Unbounce account", Create an account a link.
- [ ] `https://account.squarespace.com/` — goes to login.squarespace.com, "Log into Squarespace", Create Account demoted.
- [ ] `https://id.kajabi.com/u/login` — "Sign in to your account", Sign up here a link.
- [ ] `https://app.samcart.com/auth/login` — "Login | SamCart", Sign Up a link to the pricing page.
- [ ] `https://www.ebay.com/` — the homepage: a search box, Sign in and register as links, a My eBay menu.
- [ ] `https://www.etsy.com/` — the shop homepage with its search box and Sign in. A cookie notice may show at the bottom right; leave it alone. A cookie notice is never relevant to a start page (founders, 2026-09-18). Signed out, this page shows only "Sign in", with no Shop Manager and no Your account. That is expected: both flows begin in the signed-in product. Press Sign in, type nothing, and judge what opens: a sign-in dialog whose account creation is a separate route. This lane saw "Special starts on Etsy" with "New to Etsy? Create an account" linking to `/join` (2026-09-18). The coordinator saw a version with "Sign in" and "Register" tabs. Either passes. Note which one you see, then press Escape.
- [ ] `https://app.clickfunnels.com/users/sign_in` — "ClickFunnels - Login", Sign Up a link, no agreement text.
- [ ] `https://thrivecart.com/signin/` — email, password and Sign In, no sign-up form.
- [ ] `https://ads.tiktok.com/i18n/login` — "TikTok Ads: Log In", "Log in to your TikTok for Business account", Sign up now a link, no agreement text.
- [ ] `https://my.ecwid.com/` — goes to `/cp/`, "Sign in to your Ecwid account": email, password and Sign In. "Create new Ecwid account" switches to a different form ending "Next: Set up your Store". The "By continuing, you agree…" line is there and does not decide it.
- [ ] `https://www.linkedin.com/login` — "Sign in": email or phone, password and Sign in, with Join now a link to a separate sign-up page. The "By continuing, you agree…" line is there and does not decide it.
- [ ] For contrast, the held ones should still show what held them: `https://www.appsheet.com/Template/Apps` (seven single-sign-on provider buttons and no sign-up route at all, so the one set of buttons both signs in and would create an account), `https://app.bubble.io/login` (the visible form is "Sign up and start building"), and `https://creator.zoho.com/` (a www.zoho.com sign-up form).

### Sonny reads TikTok Ads results without touching an ad (new 2026-09-18, SONNY-503)

Same packaged app. Sign in to TikTok Ads Manager yourself first.

- [ ] Ask Sonny how your TikTok ads did this week. It goes to the Campaigns page, the Campaign / Ad group / Ad tabs and the column metrics, or to the Dashboard summary with its Calendar filter.
- [ ] Nothing it proposes creates, edits, turns on or pays for an ad.

### Sonny reads LinkedIn Ads lead results without touching an ad (new 2026-09-18, SONNY-503)

Same packaged app. Sign in to LinkedIn yourself first, with access to a Campaign Manager ad account.

- [ ] Ask Sonny to download the leads from one of your LinkedIn Lead Gen Forms. It goes to Campaign Manager → Content & Assets → Lead generation forms, ticks the form, sets the time range, then Download leads → Download.
- [ ] Nothing it proposes creates, edits, turns on or pays for an ad.

### This group's remaining sites still carrying facts alone is not a finding (new 2026-09-18, SONNY-503, SONNY-504)

- [ ] appsheet, bubble, glide, zoho_creator and metricool are still shallow packs after this branch — each named on SONNY-503 or SONNY-504 with the start-page reason. Skip them when checking deep flows.
