### `chore/the-skills-follow-ups` (SONNY-529, SONNY-526, SONNY-524, 2026-09-18)

The Skills page shows no sign-in address, depth or flows, so nothing on it changes. What changes is
where Sonny goes when a command names one of these sites. Two packs have task steps again, and seven
packs name a different sign-in page.

Run each row with the packaged app, with the named skill added on the Skills page, in a browser
**signed out** of the site in question.

- [ ] **SONNY-529 — Microsoft 365 has task steps again, and they start at sign-in.** Ask Sonny to "add
  a user in the Microsoft 365 admin center". It opens `www.microsoft365.com/login`, which lands on
  Microsoft's "Sign in to your account" page. Before this branch the pack had no steps, and before
  SONNY-510 its flows started at a marketing page on another domain.
- [ ] **SONNY-529 — Zoho Desk has task steps again, and they start at sign-in.** Ask Sonny to "merge
  duplicate tickets in Zoho Desk". It opens `desk.zoho.com/agent`, which lands on Zoho's sign-in page
  reading "Sign in to access Desk", with "Sign up now" beside it and not in place of it.
- [ ] **SONNY-526 — Instagram's sign-in page is Instagram's, not a missing profile.** Ask Sonny to
  "open the Instagram sign-in page". It opens `www.instagram.com/accounts/login/`, with a password
  field. The old address, `instagram.com/login`, shows "Profile isn't available", because Instagram
  reads `/login` as a user name.
- [ ] **SONNY-524 — Outlook's sign-in page returns to Outlook.** Ask Sonny to "open the Outlook sign-in
  page". It opens `outlook.office365.com`, which lands on Microsoft's sign-in page. This is the one row
  that needs a signed-in account: after signing in there, you land in Outlook, not on office.com.
