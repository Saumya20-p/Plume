# Phase 9 — Multi-Chapter Queue & Auto-Advance

## Goal
Support the realistic web-novel-binging use case: sharing several chapters
in a row from Safari and having Plume play through them in order without
manual intervention each time.

## Tasks

1. **Queue model**
   - Introduce a lightweight `PlaybackQueue` concept: an ordered list of
     `Document` references currently queued for sequential playback,
     separate from the full Library list.
   - Sharing multiple chapters from the same source/series in sequence
     should append to the queue rather than requiring the user to manually
     re-open the app each time (build on the Phase 2/3 pending-share pickup
     flow — each new share becomes a queue candidate).

2. **Auto-advance**
   - When a chapter finishes playing, automatically begin generating (if not
     already cached — see Phase 10) and playing the next item in the queue,
     with a brief on-screen indication of the transition (e.g. a toast/label
     showing the next chapter's title).
   - Respect user pause/stop — auto-advance shouldn't override an explicit
     stop action.

3. **"Up Next" UI**
   - Surface the current queue somewhere reachable from the player (e.g. a
     small "Up Next" section or sheet), showing upcoming queued chapters
     with the ability to reorder or remove items.

4. **Manual queue management**
   - Allow adding any Library document to the queue manually (not just
     freshly-shared ones), and reordering/removing queue items.

## Acceptance criteria
- Sharing 3 chapters from Safari in sequence and opening Plume once
  results in all 3 appearing in the queue in the order they were shared.
- Playing through a queued chapter automatically advances to the next one
  without user interaction, including triggering audio generation for it if
  it hasn't been synthesized yet.
- Explicitly pausing/stopping playback does not trigger auto-advance.
- Reordering and removing queue items works and is reflected immediately in
  the "Up Next" UI.
