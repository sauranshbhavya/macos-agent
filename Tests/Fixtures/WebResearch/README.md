# Web-research fixtures

Three real pages, saved verbatim, that `RestrictedContentDetectorTests` runs the wall check over.

They exist because the tests that were here before **could not have caught SONNY-245**. A
hand-written `"<html>…captcha…</html>"` behaves identically under the rule that shipped the bug and
under the rule that fixes it — both refuse it. Only a real page separates them, because the thing
that separates them is where in a real page the word actually sits: in a script blob, in an
attribute, or in a sentence addressed to the reader.

All three were fetched on 2026-08-23 with the headers `URLSessionWebPageFetcher` sends —
`User-Agent: Sonny/1.0`, `Accept: text/html,application/xhtml+xml` — so they are what Sonny itself
would receive, not what a browser would.

| File | Source | HTTP | Bytes | What it is |
| --- | --- | --- | --- | --- |
| `wikipedia-machine-learning.html` | `https://en.wikipedia.org/wiki/Machine_learning` | 200 | 1 146 835 | The reported defect. An encyclopedia article, refused by the old rule. |
| `zillow-perimeterx-block.html` | `https://www.zillow.com/` | 403 | 5 776 | A genuine bot wall (PerimeterX). Its message is drawn by JavaScript, so it says nothing at all to a reader who does not run scripts. |
| `sciencedirect-captcha-challenge.html` | `https://www.sciencedirect.com/science/article/pii/S0004370221000862` | 403 | 1 207 697 | A genuine CAPTCHA gate that *does* speak: "Are you a robot? Please confirm you are a human by completing the captcha challenge below." |

## Why these three

The Wikipedia article matches the old rule twice and is guarded by nothing: `captcha` appears inside
a `<script>` config naming Wikipedia's own edit-form CAPTCHA, and `subscription required` inside the
`title=` attribute of the lock icon its citation templates print beside a paywalled reference.
Neither is text a reader sees.

The two block pages are the two shapes a real wall comes in, and they need different evidence to
catch, which is why both are here rather than one. Zillow's shows 0 characters of text — the only
trace in what the server sent is `captcha` in a script. ScienceDirect's shows 526 characters, and
they are the message itself. A rule that reads only markup refuses Wikipedia; a rule that reads only
visible text lets Zillow through. `RestrictedContentDetector` reads both and corroborates each
against how much the page has to say.

The ScienceDirect page is also the pair the whole fix turns on: **1.2 MB of markup that is a wall,
beside 1.1 MB of markup that is an article.** Page size decides nothing; what the page shows a
reader decides everything.

## The one edit

`sciencedirect-captcha-challenge.html` had the fetching machine's own public IP printed in it, in
the gate's "IP Address:" line. It is replaced by `203.0.113.42`, from RFC 5737's documentation
range — three characters shorter than the original, which is the whole difference between this file
and the 1 207 700 bytes that arrived. Nothing else in any of the three files is altered.

## Refreshing them

Don't, unless a test needs a property the live page no longer has. These are frozen inputs: the
suite asserts exact character counts against them, and a re-fetch of a live page changes those for
reasons that have nothing to do with the code under test. If one is ever replaced, re-measure the
counts and say in the ticket which page changed and why.
