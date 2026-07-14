# Sonny Founder Design Decisions

Source: meeting transcript, Sauransh Bhardwaj + Bhavya Singh (design), 2026-07-05. This captures product/design decisions made verbally that are not fully reflected in `docs/sonny-major-release-spec.md`, `docs/sonny-design-system-reference.md`, or the wireframe exports. Treat this as authoritative over a naive reading of the wireframe SVGs where they conflict — the wireframes are a static snapshot of a design conversation, this transcript carries reasoning the static files don't.

## Notifications
Native macOS notifications for v1, not a custom overlay. Rationale: native respects Do Not Disturb and other system-expected behavior; a custom overlay would look wrong when it collides with/covers other apps' notifications. Explicitly open to revisiting later, not a permanent decision. Error-state notification: step-level failure is orange with a retry button; total task failure offers retry or start a new task.

## Tasks <-> Workspaces association
The Linear-style wireframe's "project" tag on each task row maps directly to **which workspace that task belongs to/ran in**. This is a real intended association, not wireframe-template leftover. Sonny's task history data model does not currently capture this — adding it is a real scope item, not optional polish, and it's also the prerequisite for the Insights "Breakdown by Workspace" feature (see below).

## Routines
- Routines have real intended scheduling: a defined run time and an enabled/disabled state ("what time does it run and is it enabled or disabled"), grouped by cadence (daily/weekly/monthly) same as the home/Tasks screen's status grouping. This is a real feature, not decorative wireframe grouping — it implies an actual scheduler/execution-trigger component that does not exist in the current build (routines today are manually triggered only).
- Clicking into a routine should open a **detail view styled like the floating widget (liquid glass material)**, but embedded inside the main app window, not the literal floating widget window. It closes when the app closes. Explicit intent: give the user one consistent "how I watch Sonny work" experience regardless of which surface (menu-bar widget vs. main app) they're looking from, rather than two different UIs for the same concept. This is a real, previously-undocumented System-B-inside-System-A UI requirement — not covered by the current System A / System B split in the design-system reference doc, which treats them as fully separate surfaces.

## Insights
- Layout should be an **asymmetric bento grid** (uneven tile sizes, Apple-keynote style), explicitly *not* a uniform/symmetrical grid. The wireframe export's actual layout (stat cards + full-width chart + full-width sections, stacked) does not reflect this stated intent — the verbal description is more authoritative here than the static SVG.
- Deliberately do **not** show usage/quota-consumption metrics (e.g. "you've used X% of your plan") on this page. Reasoning is explicit product strategy, not an oversight: it creates subscription-cancellation anxiety in heavy users and "am I getting my money's worth" doubt in light users. Take inspiration from Whisper Flow's insights instead — positive, non-anxiety-inducing stats like most-used app, most common action taken.
- A Spotify-Wrapped/"top 1%" style celebratory personal-usage insight is a deliberate v2/v3 idea, not v1 scope (needs a real user base first for the comparison to mean anything).
- A "Data Sent to AI" inspector — showing exactly what content/artifacts get sent to the external LLM provider — is an explicit, named competitive differentiator versus Clicky, which does not surface this anywhere in-product (only in a privacy policy page). Framing matters: must read as transparency, not as "we're just an API wrapper" — messaging needs care.

## Workspaces
- Card fields, confirmed real: workspace name, who's in it (solo vs. team — "team" ties to a future Enterprise tier, not v1's primary solo-user case, but the field/UI pattern should still exist), task count, and the apps in the workspace shown as an overlapping icon stack.
- Liquid glass material was tried for workspace cards and explicitly reverted — it was too visually distracting from the card content. Flat/opaque cards for Workspaces are a deliberate choice, not a corner cut.

## Floating widget — which main-app pages show it
Explicit, page-by-page decision, not "show it everywhere" or "show it on the homepage only":
- Tasks: yes.
- Routines: yes (creating/invoking routines via the widget is a real flow).
- Insights: no.
- Settings: no.
- Workspaces: ambiguous in the conversation — creating a workspace via the widget makes sense as a flow, but the page itself doesn't need the persistent widget affordance shown. Lean no unless a later decision says otherwise.

## Settings
Content was explicitly open/exploratory at design time ("I don't know what we're going to have in settings... this is a basic layout, Claude/Codex can add more on top of it"). The current build's simpler nav is not necessarily wrong against original intent — it just hasn't been elaborated. Treat Settings' final structure as still open for the UI/UX research phase to propose, not a fixed target to hit.

## Memory / history retrieval (relevant to branch 11, not immediate UI work)
Explicit architecture decision: persistent "memory" storage is for **user preferences only**. Anything fetchable live (calendar events, etc.) should be fetched fresh via the relevant API first. Only fall back to searching Sonny's own past conversation/task history (searched by date proximity to whatever date the user mentions, e.g. "the meeting on July 1st" searches roughly June 28-July 3) when a live API fetch isn't possible or doesn't apply. Conversations should be tagged with any dates mentioned in them so date-based search surfaces them later even if the conversation itself happened on a different date. This is not a new "memory" feature to build — it's a decision about what memory is *for* (preferences) versus what should just be live search over existing history.
