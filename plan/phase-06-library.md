# Phase 6 — Library

## Goal
Replace the Phase 3 debug list with the real Library screen: the home base
for all saved chapters, matching the general layout style referenced from
Speechify (title, source/date, progress %, quick actions).

## Tasks

1. **Library list UI**
   - List of all `Document`s, each row showing:
     - Title
     - Source (domain name from `sourceURL`, if available) + date added
     - Progress indicator (percentage complete, matching the
       reference screenshots' "97% · Dec 27, 2025 · web" style row)
     - A generation-state indicator: not yet generated / generating /
       ready to play (ties into Phase 4's synthesis trigger — this phase
       should replace the temporary debug button with a proper per-row
       action).
   - Tapping a row opens the Phase 5 full player for that document.
   - Swipe actions on each row, matching the reference screenshots' three-
     button pattern (Pin / Move / Delete):
     - **Pin**: toggles `Document.isPinned`. Pinned documents float to the
       top of the list, above the normal sort order.
     - **Move**: moves the document into a folder/collection if you're
       supporting folders (optional — skip this button entirely if Phase 6
       doesn't include folders; Pin + Delete alone is a reasonable v1).
     - **Delete**: does *not* hard-delete. Sets `Document.deletedAt = now`
       and removes the row from the main list. This feeds the "Recently
       Deleted" flow below — same soft-delete pattern Speechify/Apple's
       Files app use, so an accidental swipe isn't destructive.

2. **Recently Deleted (in Settings, not Library)**
   - A "Recently Deleted" screen, reachable from Settings (Phase 8), listing
     documents where `deletedAt != nil`, sorted by most recently deleted.
   - Each row supports **Restore** (sets `deletedAt = nil`, document
     reappears in the main Library) and **Delete Permanently** (hard-deletes
     the `Document` row and its cached audio file immediately).
   - Show how long until auto-purge (e.g. "Deletes automatically in 12
     days") next to each row, based on the 30-day window defined in Phase
     3's data model.
   - On app launch, run the purge check: any document with `deletedAt`
     older than 30 days gets hard-deleted automatically, same as the
     manual "Delete Permanently" path.

3. **Manual add entry point**
   - Add a "+" button/action in the Library (not just relying on the Safari
     share extension) that lets the user manually paste a URL or raw chapter
     text directly into the app. Reuse the Phase 3 extraction pipeline for
     pasted URLs, and Phase 12's manual-paste path for pasted text. This
     matters for cases where Safari's share sheet flow is inconvenient (e.g.
     the user already has text copied from somewhere else) and gives you a
     manual pipeline to test with during development without needing to
     actually go through Safari every time.

4. **Empty state**
   - A friendly empty state when there are no documents yet, briefly
     explaining the Safari share flow ("Share a chapter from Safari to get
     started").

5. **Sorting/filtering (basic)**
   - Default sort: most recently added first.
   - Optional simple filter/segmented control: All / In Progress / Finished
     (based on `progress` thresholds, e.g. finished = progress ≥ 0.95).

6. **Mini-player docking**
   - Integrate the Phase 5 mini-player component so it persists at the
     bottom of the Library screen whenever a document is loaded/playing,
     matching the reference screenshot's persistent bottom player bar.

7. **Pending shares surfaced correctly**
   - Confirm items captured via the Phase 2 share extension and processed by
     Phase 3's extractor appear here automatically the next time the app is
     opened/foregrounded, with no manual refresh needed.

## Acceptance criteria
- Library accurately lists all saved documents with correct title, date,
  and progress.
- Sharing a new chapter from Safari and reopening Plume shows it appear in
  the Library without any manual action beyond opening the app.
- Deleting a document removes it from the main Library list immediately but
  the underlying `Document` and audio file are only soft-deleted — it
  appears correctly in Recently Deleted and can be restored.
- Recently Deleted correctly restores a document back into the main Library,
  and "Delete Permanently" actually removes the row and audio file from
  disk (verify via storage inspection, not just UI disappearance).
- Pinning a document moves it above unpinned documents regardless of sort
  order.
- Mini-player appears/persists correctly across navigation within the app.
- Empty state renders correctly on a fresh install with zero documents.
- The manual "+" add flow successfully creates a working document from both
  a pasted URL and pasted raw text.
