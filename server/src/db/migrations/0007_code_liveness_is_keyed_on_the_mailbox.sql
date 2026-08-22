-- 0007 — a sign-in code's lifecycle is keyed on the MAILBOX, not on the identity address
-- (SONNY-127, PR #87 third round, F4).
--
-- **This repository has two email normalisations on purpose, and this table was using the wrong
-- one.** `normalizeEmail` lowercases and trims and deliberately keeps plus-tags, because it is the
-- *identity* key and merging two addresses merges two accounts. `rateLimitEmailKey` folds plus-tags
-- away, because it is the *mailbox* key and `a@x`, `a+1@x` and `a+2@x` all land in one inbox. Both
-- are right. `sign_in_code_issue` keyed every one of its operations — issue, invalidate, consume,
-- classify — on the identity one.
--
-- The consequence, reproduced against a real database: three simultaneous `email/start` calls for
-- `victim@x`, `victim+1@x` and `victim+2@x` share a single rate-limit bucket, so all three are
-- allowed, and then each writes its own issuance row and invalidates only its own. **Three live,
-- independently guessable codes arrive in one inbox**, against a guarantee this branch states in
-- three places as a single-live-code guarantee, reachable by anyone who knows the address and can
-- type a plus sign.
--
-- **Two corrections to how this was first written** (PR #87 fifth round, F7). It said "3× guessing
-- surface": the per-mailbox verify ceiling bounds an attacker to five trials per fifteen minutes
-- whether one code is live or three, so the trials are the ceiling and the codes are not. And the
-- guarantee this restores is "at most one code can be REDEEMED", not "only the newest works" — the
-- send still uses the identity address, so Supabase keys an OTP per literal spelling and three real
-- codes still arrive in one inbox. What the fold fixes is that only one of them can complete.
--
-- **The column is renamed rather than just re-populated**, because the name is what made the defect
-- read as correct. `email_norm` beside a function called `normalizeEmail` looks like the two belong
-- together; `mailbox_key` beside `rateLimitEmailKey` reads as the mismatch it would be. A comment
-- saying "this holds a different normalisation than its name suggests" is a comment somebody skips.

ALTER TABLE sonny.sign_in_code_issue RENAME COLUMN email_norm TO mailbox_key;

COMMENT ON COLUMN sonny.sign_in_code_issue.mailbox_key IS
  'The MAILBOX this code was sent to, from rateLimitEmailKey() — plus-tags folded, lowercased. '
  'Deliberately NOT normalizeEmail(), which is the identity key and keeps plus-tags apart: two '
  'addresses that are different identities can be one inbox, and a code lives in an inbox. Keyed '
  'the other way, plus-tag variants each held their own live code (PR #87 third round, F4).';

-- **Existing rows are folded onto the new key**, so the single-live-code rule holds across the
-- migration rather than from the next issuance onwards. Written as SQL rather than deferred to the
-- application because the application never reads a row it did not key correctly in the first place,
-- so nothing else would ever repair these.
--
-- `split_part` on `+` reproduces `rateLimitEmailKey`'s fold: local part up to the first plus, then
-- the domain. The address is already lowercased and trimmed by the old key, so only the plus-fold is
-- outstanding. Rows with no `@` are left alone, matching that function's own refusal to invent
-- structure in a malformed value.
UPDATE sonny.sign_in_code_issue
   SET mailbox_key = split_part(split_part(mailbox_key, '@', 1), '+', 1)
                     || '@' || split_part(mailbox_key, '@', 2)
 WHERE position('@' in mailbox_key) > 1
   AND position('+' in split_part(mailbox_key, '@', 1)) > 0;

-- **Folding can create duplicates among rows that were separate before**, and the newest of them is
-- the one the rule says survives. Everything older is marked consumed, which is exactly what an
-- `email/start` for any of those variants would have done had the key been right at the time.
UPDATE sonny.sign_in_code_issue older
   SET consumed_at = now()
  FROM sonny.sign_in_code_issue newer
 WHERE older.mailbox_key = newer.mailbox_key
   AND older.consumed_at IS NULL
   AND newer.consumed_at IS NULL
   AND (newer.issued_at, newer.id) > (older.issued_at, older.id);

-- @rollback
-- The name goes back. The FOLD does not, and cannot: `victim+1@x` was rewritten to `victim@x` and
-- the tag it carried is not recoverable from the row. Stated rather than pretended — a rollback that
-- silently leaves data in the new shape under the old name is worse than one that says so. The
-- practical effect of rolling back is that those rows classify as belonging to the untagged address,
-- which costs a user one extra code request.
ALTER TABLE sonny.sign_in_code_issue RENAME COLUMN mailbox_key TO email_norm;
