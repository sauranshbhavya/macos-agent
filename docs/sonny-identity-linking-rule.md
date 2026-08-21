# The identity-linking rule

SONNY-127. Decided 2026-08-21, pinned by tests in `server/test/linking.test.ts`.

This is the rule that keeps one person on one account when they sign in three different ways. It is
decided on this branch even though Google and Apple ship on the next one, because getting it wrong
produces a user with two accounts and one subscription, and retrofitting it once real accounts exist
is the expensive path.

---

## 1. The rule

**The identity key is `(provider, subject)`. It is never the email address.**

An identity is one row per `(provider, subject)`. `subject` is the provider's own stable identifier:
the provider's subject claim for Google and Apple, and the normalised address for `email`, where
possession of the mailbox is what was proven and nothing more stable exists.

A sign-in resolves to an account in this order, and stops at the first match:

| # | Condition | Result | `link_method` |
|---|---|---|---|
| 1 | `(provider, subject)` already exists | that identity's account | — |
| 2 | the provider asserts a **verified**, **non-relay** email that matches an existing identity's verified, non-relay `email_hint` | link to that account | `verified_email_match` |
| 3 | anything else | a **new** account | `primary` |
| 4 | user is signed in on account A and completes a sign-in with method B | B joins A | `explicit` |

Rule 4 is the only path that joins two *existing* accounts, and it requires an authenticated session
**on the target account specifically** — not on "one of them", which is what an earlier version of
this line said and is a weaker claim than the code now makes. `linkExplicitly` takes the
authenticated account id and refuses unless it equals the target, so a session on the *source*
account is not sufficient. **Nothing merges two accounts on the strength of an email address alone.**

**That check did not exist when this document first claimed it** (PR #87 F7). The function took no
session at all, and this paragraph plus its docstring described a guarantee nothing performed —
which SONNY-129 would have routed the primitive while reading. It is implemented now, and the
parameter is required rather than optional so that omitting it is a type error rather than a
judgment call.

---

## 2. Why not "match on email", which is the obvious rule and also Supabase's

Supabase Auth's documented default is: *"Supabase Auth automatically links identities with the same
email address to a single user"*, gated on the address being verified. The ticket required
establishing what the platform actually does rather than assuming in either direction, so: that is
what it does, it is on by default, and the verified-email gate is a real safeguard against the
takeover direction.

**It is still not sufficient, and it fails in the direction that costs money.**

Sign in with Apple can return `abc123@privaterelay.appleid.com` instead of the real address. That
address matches nothing. Under match-on-email the person who already has an email account gets a
**second** account, with a second subscription, and neither they nor we notice until they ask why
they are paying twice. Rule 1 is what prevents it: Apple's `sub` is stable across sign-ins whether or
not the address is hidden, so the second press of the Apple button lands on the first one's account.

The takeover direction matters too, and rule 2 is deliberately narrow because of it. Joining two
accounts because two providers reported the same email is a known account-takeover pattern; it is
safe only when the asserting provider has *verified* the address, which is why rule 2 requires
`email_verified` and is the reason an unverified assertion falls through to rule 3.

---

## 3. Where this diverges from the platform, and what that costs

Supabase's automatic linking operates on `auth.users`. Ours operates on `sonny.account`, which is a
different row. Both run:

- **Two providers, same verified address.** Supabase links them into one `auth.users`; our rule 1
  then finds the existing identity, or rule 2 links them. Same answer by two routes. No conflict.
- **Apple with a relay address.** Supabase creates a second `auth.users`, because nothing matches.
  Our rule 1 matches on Apple's `sub` if that identity has been seen, and otherwise rule 3 creates a
  new account. **Two `auth.users` rows can therefore point at one `sonny.account`, and that is the
  case the separation exists to express.**

The cost is one join and one table. The alternative — making the account *be* the Supabase user —
cannot represent that case at all, which is why it was rejected rather than deferred.

**Supabase's behaviour is accepted rather than overridden**, because with the account separated it
can no longer produce the wrong answer: at worst it creates an extra `auth.users` row that our
identity table resolves to the right account.

---

## 4. The case this rule deliberately does not solve silently

A person with an existing email account who presses Apple **for the first time** with Hide My Email
on presents: an unknown `sub`, and a relay address matching nothing. Rules 1 and 2 both miss, so
rule 3 creates a new account.

**That is not the ticket's "silently creates a second one", and the difference is the word
silently.** The relay case is detected — `email_is_relay` is stored at write time — and the sign-in
response carries a `link_hint` saying an existing account may belong to this person and can be joined
by rule 4. What the server must never do is guess: it cannot know that
`abc123@privaterelay.appleid.com` is the same human as `real@example.com`, and inventing a link on a
guess is the takeover pattern with extra steps.

So the second account is created, flagged, and offered a link. **Surfacing that hint is
SONNY-128's and SONNY-129's**; this ticket owns the detection, the flag and the field, and pins them
with tests.

---

## 5. Email normalisation, and one thing deliberately not normalised

`subject` for the `email` provider is the address lowercased and trimmed. **Plus-tags are not
stripped**: `a+work@example.com` stays distinct from `a@example.com`. Stripping them would merge two
addresses the user may have chosen precisely to keep apart, and merging accounts is the failure this
whole document exists to prevent — so where normalisation is a judgment call, it errs toward *not*
merging. Domain-specific rules (Gmail ignoring dots) are not applied for the same reason and because
they would encode one provider's policy into our identity key.

---

## 6. What is pinned by tests

`server/test/linking.test.ts`, all against a real Postgres:

- the same verified address by two methods lands on **one** account (rule 2)
- the same `(provider, subject)` twice lands on one account and does not duplicate (rule 1)
- an **unverified** email assertion does **not** link, and creates its own account (rule 2's gate)
- an Apple **relay** address for a user who already has an email account does not link, is **flagged**
  `email_is_relay`, and carries a link hint — the ticket's "does not silently create a second one"
- Apple twice with a relay address lands on one account, because `sub` is stable (the Hide My Email case)
- an explicit link joins two accounts and moves the identity (rule 4)
- an explicit link **refuses when the caller's session is not on the target account**
- an explicit link **refuses** to join an account that is deleted
- two identities on one account may carry two different `supabase_user_id`s — the case the separation exists for
