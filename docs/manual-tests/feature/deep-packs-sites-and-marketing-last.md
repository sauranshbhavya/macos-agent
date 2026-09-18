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

### The six new packs' start pages are sign-in pages, not sign-up pages (new 2026-09-17, SONNY-504)

No app needed — a browser signed out of everything, which is what Sonny meets on a fresh Mac. Each was measured once in this branch's session; if a page has moved, note what it now shows.

- [ ] `https://be.contentful.com/login/` — "Log in to your Contentful account", email and password, Sign up is not the form.
- [ ] `https://www.appsheet.com/Template/Apps` — redirects to AppSheet's "Sign in with:" page listing Google, Microsoft, Apple, Dropbox, Smartsheet, Box and Salesforce, under the line "By signing in, you agree to the terms of service and privacy policy". No account-creation form.
- [ ] `https://app.unbounce.com/users/sign_in` — "Sign into your Unbounce account", with Create an account as a link.
- [ ] `https://account.squarespace.com/` — sends you to login.squarespace.com, "Log into Squarespace", with Create Account demoted.
- [ ] `https://id.kajabi.com/u/login` — "Sign in to your account", with Sign up here as a link.
- [ ] `https://app.samcart.com/auth/login` — "Login | SamCart", email and password, Sign Up a link to the pricing page.
- [ ] For contrast, the reason Zoho Creator was left out: `https://creator.zoho.com/` sends a signed-out visitor to `https://www.zoho.com/creator/`, a marketing page carrying an account-creation form with a password box and an "I agree to the Terms of Service" checkbox.

### This group's other sites still carrying facts alone is not a finding (new 2026-09-17, SONNY-503, SONNY-504)

- [ ] linkedin_ads, tiktok_ads, metricool, ebay, etsy, ecwid, clickfunnels, thrivecart, bubble, glide and zoho_creator are still shallow packs after this branch — named on SONNY-503 and SONNY-504 with the reason for each. Skip them when checking deep flows.
