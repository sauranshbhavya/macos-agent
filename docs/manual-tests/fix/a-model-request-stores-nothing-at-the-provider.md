### The provider is asked to store nothing (new 2026-09-17, SONNY-513)

Server-side only, and **nothing in the app changes** — no new surface, no new copy, no behaviour a
user can see. A screen-control session and an ordinary command work exactly as before, which is the
whole point: the change is one field in the request this gateway sends to the model provider.

The one row below is **founder-owned because it needs a real provider credential**, which no session
has. It is the half of SONNY-513's probe that could not be run from a lane: whether the upstream in
front of us honours the field. Everything this branch controls — that the field goes on the wire, on
all three affected routes — is pinned by tests that fail when it is dropped or flipped, so this row
is about the provider's side of the boundary rather than ours.

Skip this row if no `VISION_API_KEY` is configured anywhere; it cannot be run without one, and that
is a gap rather than a pass.

- [ ] **With a real `VISION_API_KEY` and the gateway pointed at the route that ships**, run one
      screen-control session end to end (widget → a command that needs the screen → let it take at
      least one look). Then, from a terminal, ask the provider for that response back by id:
      `curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $VISION_API_KEY"
      "$VISION_BASE_URL/responses/<id>"`, using any `id` the provider returned. **What would be a
      finding:** a `200` — that means the reply was stored despite `store: false`, and the thirty-day
      window SONNY-513 exists to close is still open, which is a finding to put on that ticket rather
      than a reason to change anything in the app. A `404` or `400` is the expected, wanted answer.
      **Also a finding:** the session failing, or the command erroring, where it worked before — that
      would mean the provider rejects the `store` field rather than honouring it, and the same ticket
      wants to know.
