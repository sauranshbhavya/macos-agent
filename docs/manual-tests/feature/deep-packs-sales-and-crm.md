### Sonny follows a Pipedrive flow it now knows (new 2026-09-18, SONNY-518)

Packaged app (`./scripts/package-app.sh`, then `open .build/arm64-apple-macosx/debug/MacAgent.app`).
Sign in to Pipedrive yourself first, in the browser Sonny drives — no flow asks Sonny to sign in.

- [ ] Ask Sonny, in the floating widget, to add a stage to your Pipedrive pipeline. It names Pipedrive rather than asking which site you mean.
- [ ] The steps go to the Deals tab, the pencil icon beside the pipeline dropdown, then the + icon between two stages, and name the stage's name, probability and rotting settings.
- [ ] Ask it to import a spreadsheet of contacts into Pipedrive. It goes through the account menu → Tools and apps → Import data → Import from spreadsheet, and walks the five steps in order, ending at Start import.

### Sonny follows a HubSpot flow it now knows (new 2026-09-18, SONNY-518)

Same packaged app. Sign in to HubSpot yourself first.

- [ ] Ask Sonny to create a task in HubSpot to call someone tomorrow. It goes to CRM → Tasks (through More if that menu is there), then Create task, and fills the panel: title, type, due date.
- [ ] Ask it to change a property on one of your HubSpot contacts. It opens CRM → Contacts, the contact's record, and the property on a card in the left sidebar or middle column. If the property is not shown, it uses Actions → View all properties.
- [ ] Nothing in either proposal touches billing, a subscription or a payment.

### The fourteen new packs' start pages sign in an existing account, with account creation a separate route or none at all (new 2026-09-18, SONNY-518)

No app needed — a browser signed out of everything, which is what Sonny meets on a fresh Mac. Read each with the window on screen and the tab in front: a tab Chrome is not drawing can show a spinner or a stale title, which is not what the page offers. Each was re-read with the window drawn on 2026-09-19. If a page has moved, note what it shows now. Type nothing and press no provider button.

- [ ] `https://app.pipedrive.com/auth/login` — the heading "Log in" (an h3): email and password, with "Try it free" and "Don't have an account?" linking to `/register`.
- [ ] `https://app.copper.com/users/sign_in` — "Welcome back!": email, Google and SSO, with "Create an account?" linking to `/users/sign_up`.
- [ ] `https://app.nutshell.com/` — goes to `/auth`, "Nutshell | Log in to Nutshell": Google, Microsoft or email, with "Don't have an account? Sign up" linking to `/signup`.
- [ ] `https://hello.dubsado.com/user/login` — "Log in to Dubsado" (Dubsado 2.0): Google, email and password, with "New to Dubsado? Sign up". The row's own `https://www.dubsado.com/login` is a chooser between 2.0 and 3.0 and is deliberately not a start page.
- [ ] `https://www.kommo.com/login/` — "Log in": email and password, Google and Facebook. "Sign up" in the header opens a different "Create your account" form.
- [ ] `https://login.insightly.com/User/Login` — "Log in to continue": Google, Microsoft or email, with "Create an account" linking to `/User/Signup`.
- [ ] `https://app.clay.com/login` — tab title "Clay | Login", heading "Welcome back!": Google or email, with "Don't have an account? Sign up" linking to `/signup`.
- [ ] `https://app.honeybook.com/app/login` — "Welcome back": email and password, Google and Apple, with "Don't have a business account? Create one". The page can take ten seconds or more to draw. The tab's title passes through "Workflow And Community To Grow And Manage Your Business | HoneyBook" and settles on "Login | HoneyBook" within about a second and a half; note if it settles on anything else.
- [ ] `https://contactout.com/login` — "Login": email and password, with "Sign up" linking to `/register`.
- [ ] `https://app.rocketreach.co/login` — goes to `rocketreach.co/login`, headed "LOGIN" with "Login to your account." under it: email and password, with "Don't have an account? Sign up!" linking to `/signup`.
- [ ] `https://app.hubspot.com/login` — the page reads, verbatim, "Sign in or create an account". The form itself is only "Email" and "Continue": no password field, no provider button, no heading. "create an account" is a link outside the form to a separate page, `/signup-hubspot/crm`. It passes as a boundary case (SONNY-510, beside Plaud); say whether the page still reads that way.
- [ ] `https://app.gong.io/` — goes to `/welcome/sign-in`: Google, Salesforce, Office 365 or email, with "Don't have an account? Request a demo" and no sign-up. It passes because Gong has no self-serve sign-up anywhere. www.gong.io offers Book a demo and Talk to sales, its pricing page is a form asking for a proposal, and `www.gong.io/signup` is "Page Not Found".
- [ ] `https://web.outreach.io/` — goes to `login.outreach.io`, "Sign in" over one email field, with no sign-up. It passes because Outreach has no self-serve sign-up anywhere: www.outreach.io now goes to www.outreach.ai, which offers only demo requests, pricing and contact; its pricing page has no free or trial offer; and `www.outreach.ai/signup` is a 404.
- [ ] `https://www.linkedin.com/sales/home` — goes to `/sales/login`, "Sign in to Sales Navigator": email or phone and password, with "New to LinkedIn? Join now" linking to a separate sign-up page. The form is drawn in a frame, so the page itself looks empty to a text reader; judge what you see.
