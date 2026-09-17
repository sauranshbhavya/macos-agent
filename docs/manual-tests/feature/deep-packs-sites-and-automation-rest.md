### Sonny follows a Thinkific flow it now knows (new 2026-09-17, SONNY-504)

Packaged app (`./scripts/package-app.sh`, then `open .build/arm64-apple-macosx/debug/MacAgent.app`).
Sign in to Thinkific yourself first, in the browser Sonny drives — no flow asks Sonny to sign in.

- [ ] Ask Sonny, in the floating widget, to create a course on Thinkific. It names Thinkific rather than asking which site you mean.
- [ ] The steps it proposes go through Products, then Courses, then + New Course, rather than a general-purpose guess at a web form.
- [ ] Ask it to publish a draft course on Thinkific. It goes to Products, Courses, the draft course, and the Publish button — it does not offer to change a price or a plan anywhere.

### Sonny follows a Duda flow it now knows (new 2026-09-17, SONNY-504)

Same packaged app. Sign in to Duda yourself first.

- [ ] Ask Sonny to duplicate a site on Duda. Its first step says the Site creation permission is needed, rather than sending you at a menu that will not be there.
- [ ] The steps name the three-dots menu next to the site and the Copy button, in that order.
- [ ] Ask it to export your Duda site list. It goes to the three horizontal dots next to Create New Site and Export CSV, and it tells you the file arrives by email rather than claiming it downloaded one.

### The four new packs' start pages are sign-in pages, not sign-up pages (new 2026-09-17, SONNY-504)

No app needed — a browser signed out of everything, which is what Sonny meets on a fresh Mac.

- [ ] `https://sso.teachable.com/secure/teachable_accounts/sign_in` — a security check may hold it for a few seconds; when it clears the page says "Log in to Teachable" and offers Sign Up only as a link underneath.
- [ ] `https://app.podia.com/login` — "Login to Podia", one email box, Sign up a link.
- [ ] `https://courses.thinkific.com/onboarding/signin` — "Sign In", email and password, Create an account a link.
- [ ] `https://www.duda.co/login` — "Welcome back!", Log in is the button, Sign up here is a link.
- [ ] For contrast, and the reason Bubble was left out: `https://app.bubble.io/login` sends you to `https://bubble.io/login`, whose panel reads "Sign up and start building" and binds the Terms to its Start building button.
