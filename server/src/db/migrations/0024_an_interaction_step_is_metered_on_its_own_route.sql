-- @locks ACCESS EXCLUSIVE sonny.metering_event, ACCESS EXCLUSIVE sonny.retained_content
-- @scans sonny.metering_event, sonny.retained_content

-- 0024 — an interaction step is metered on its own route (SONNY-544, V2 plan Milestone A).
--
-- **What this is for.** `POST /v1/interact/step` is the call the Mac makes once per step while it
-- drafts inside another app through the Accessibility tree: a small text request that picks the next
-- element to act on. The founders decided on 2026-09-23 that it is metered on its own route name and
-- not charged. Metering it at all means a row in `sonny.metering_event`, whose `route` column carries
-- a CHECK admitting §11's five route names and nothing else, so the insert would fail without this.
--
-- **Why `sonny.retained_content` widens too, although nothing should ever land there.** The Mac
-- sends every step with `retention: "none"`, so `isStorable` refuses to deposit one. The table's own
-- CHECK names the same five routes, and a CHECK that refuses a route the gateway serves turns a
-- client that ever sent `standard` into a failed insert inside the request instead of a stored row
-- the deletion paths already cover. Keeping the two lists identical is the rule 0013 set when it
-- copied 0012's.
--
-- **Not charged, and nothing here decides that.** The screen-control figure reads `screen.analyze`
-- rows only (`metering/query.ts`), so a new route name is metered, audited and spend-capped like
-- every metered route and priced by nothing.
--
-- **The rollback deletes the rows this route wrote**, because a CHECK cannot be narrowed while rows
-- violate it. That loses the metering record of the interaction steps taken while this migration was
-- applied; rolling back also removes the route, so no new rows would arrive.

ALTER TABLE sonny.metering_event
  DROP CONSTRAINT metering_event_route_check;

ALTER TABLE sonny.metering_event
  ADD CONSTRAINT metering_event_route_check
  CHECK (route IN ('plan', 'research.synthesize', 'transcription', 'search', 'screen.analyze',
                   'interact.step'));

ALTER TABLE sonny.retained_content
  DROP CONSTRAINT retained_content_route_check;

ALTER TABLE sonny.retained_content
  ADD CONSTRAINT retained_content_route_check
  CHECK (route IN ('plan', 'research.synthesize', 'transcription', 'search', 'screen.analyze',
                   'interact.step'));

-- @rollback
-- @locks ACCESS EXCLUSIVE sonny.metering_event, ACCESS EXCLUSIVE sonny.retained_content
-- @scans sonny.metering_event, sonny.retained_content

DELETE FROM sonny.retained_content WHERE route = 'interact.step';

DELETE FROM sonny.metering_event WHERE route = 'interact.step';

ALTER TABLE sonny.retained_content
  DROP CONSTRAINT retained_content_route_check;

ALTER TABLE sonny.retained_content
  ADD CONSTRAINT retained_content_route_check
  CHECK (route IN ('plan', 'research.synthesize', 'transcription', 'search', 'screen.analyze'));

ALTER TABLE sonny.metering_event
  DROP CONSTRAINT metering_event_route_check;

ALTER TABLE sonny.metering_event
  ADD CONSTRAINT metering_event_route_check
  CHECK (route IN ('plan', 'research.synthesize', 'transcription', 'search', 'screen.analyze'));
