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

### The nine new packs' start pages are sign-in pages or a shop front, not sign-up pages (new 2026-09-18, SONNY-504)

No app needed — a browser signed out of everything, which is what Sonny meets on a fresh Mac. Each was measured once on this branch; if a page has moved, note what it now shows.

- [ ] `https://be.contentful.com/login/` — "Log in to your Contentful account", email and password.
- [ ] `https://app.unbounce.com/users/sign_in` — "Sign into your Unbounce account", Create an account a link.
- [ ] `https://account.squarespace.com/` — goes to login.squarespace.com, "Log into Squarespace", Create Account demoted.
- [ ] `https://id.kajabi.com/u/login` — "Sign in to your account", Sign up here a link.
- [ ] `https://app.samcart.com/auth/login` — "Login | SamCart", Sign Up a link to the pricing page.
- [ ] `https://www.ebay.com/` — the homepage: a search box, Sign in and register as links, a My eBay menu.
- [ ] `https://www.etsy.com/` — the shop homepage with its search box and Sign in. A cookie notice may show at the bottom right; leave it alone. It is the one agreement text on the page, and it was ruled not to be a terms acceptance bound to a flow's control.
- [ ] `https://app.clickfunnels.com/users/sign_in` — "ClickFunnels - Login", Sign Up a link, no agreement text.
- [ ] `https://thrivecart.com/signin/` — email, password and Sign In, no sign-up form.
- [ ] For contrast, the held ones should still show what held them: `https://www.appsheet.com/Template/Apps` ("By signing in, you agree…" under its provider buttons), `https://my.ecwid.com/` ("By continuing, you agree…"), `https://www.linkedin.com/login` (the same, under Continue with Google), `https://app.bubble.io/login` (a sign-up form), and `https://creator.zoho.com/` (a www.zoho.com sign-up form).

### This group's remaining sites still carrying facts alone is not a finding (new 2026-09-18, SONNY-503, SONNY-504)

- [ ] appsheet, ecwid, bubble, glide, zoho_creator, linkedin_ads, metricool and tiktok_ads are still shallow packs after this branch — each named on SONNY-503 or SONNY-504 with the start-page or flow reason. Skip them when checking deep flows.
