### The provider is asked to store nothing (new 2026-09-17, SONNY-513)

Server-side only, and **nothing in the app changes** — no new surface, no new copy, no behaviour a
user can see. A screen-control session and an ordinary command work exactly as before, which is the
point: the change is one field in the request this gateway sends to the model provider.

The row below is **founder-owned because it needs a real provider credential**, which no session
has. It is the half of SONNY-513's probe that could not be run from a lane: whether the upstream in
front of us *honours* the field. Everything this branch controls — that the field goes on the wire,
on all three affected routes — is pinned by tests that fail when it is dropped or flipped.

**It does not go through the app, and that is deliberate.** A screen-control session never surfaces
the provider's response id: the adapter reads the reply's text and drops the rest, and the content
store's `response_body` is this gateway's own reply assembled in an `onSend` hook, not the
provider's. So there is no id to retrieve with, and a row phrased as "run a session, then look it
up" cannot be run at all. Two direct calls supply their own ids instead.

**Both calls are needed, and the second is the control.** A `404` on the first proves nothing on its
own — a proxy that does not implement retrieval answers `404` to everything, which is
indistinguishable from "it stored nothing". The second call asks for storage explicitly; if *it*
cannot be retrieved either, this route does not support retrieval and the pair says nothing about
`store` at all. Only `404`-then-`200` is evidence.

Needs **three** variables for the route that ships — `VISION_API_KEY`, `VISION_BASE_URL` and
`VISION_MODEL`. The first line of the script requires all three and fails loudly if any is unset,
which is not ceremony: an unset `VISION_MODEL` would send `"model":""`, the provider would reject
the body, and the row would land on its own most urgent finding — a missing prerequisite
manufacturing the alarm the row exists to raise. Skip the row if you cannot supply all three; that
is a gap, not a pass.

- [ ] **Run both calls below, in order.** Each sends a one-word prompt and no image, so neither
      costs anything meaningful and neither involves your screen.

      ```
      # 0. All three required, and the base normalised the way the gateway normalises it:
      #    `endpoint()` in vision.ts strips one trailing slash, so a base ending in `/` would
      #    otherwise make these calls hit `//responses` rather than the path the server uses.
      : "${VISION_API_KEY:?set it}" "${VISION_MODEL:?set it}" "${VISION_BASE_URL:?set it}"
      BASE="${VISION_BASE_URL%/}"
      # 1. store:false — what this branch now sends.
      curl -s -H "Authorization: Bearer $VISION_API_KEY" -H "content-type: application/json" \
        -d '{"model":"'"$VISION_MODEL"'","store":false,"input":"ping"}' \
        "$BASE/responses" | tee /tmp/off.json | head -c 300; echo
      # 2. store:true — the control.
      curl -s -H "Authorization: Bearer $VISION_API_KEY" -H "content-type: application/json" \
        -d '{"model":"'"$VISION_MODEL"'","store":true,"input":"ping"}' \
        "$BASE/responses" | tee /tmp/on.json | head -c 300; echo
      # 3. Retrieve each by its own id.
      for f in /tmp/off.json /tmp/on.json; do
        id=$(python3 -c "import json;print(json.load(open('$f')).get('id',''))")
        printf '%s id=%s -> ' "$f" "$id"
        curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $VISION_API_KEY" \
          "$BASE/responses/$id"
      done
      ```

      **The wanted result is `off.json` → `404` (or `400`) and `on.json` → `200`.** That is the
      provider honouring `store`, and it is the only outcome that establishes it.
      **What would be a finding, each meaning something different — put whichever you get on
      SONNY-513:**
      *both `200`* — the field is ignored and the thirty-day window is still open, which is the
      finding this row exists to catch;
      *both `404`* — this route does not implement retrieval, so the check is inconclusive rather
      than passing, and whether `store` is honoured stays unknown;
      *either call erroring or returning no `id`* — the provider rejects the `store` field or the
      body shape, which would mean the field we now send is not merely ignored but harmful, and is
      the most urgent of the three.
