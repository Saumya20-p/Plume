# Phase 8 — General Settings & Listening Statistics

## Goal
Build the app-wide Settings screen (distinct from Phase 7's reading-specific
appearance sheet) covering playback defaults, voice, storage, Recently
Deleted, a listening-statistics dashboard, and a heavily-guarded "delete
everything" option — all fully local/on-device, no accounts, no
subscription tiers, no upgrade prompts. Everything you track here (time
listened, words listened, speed, etc.) is derived entirely from the
`ListeningSession` rows defined in Phase 3 — this is your own data on your
own device, not a synced or gated feature.

## Tasks

1. **Playback defaults**
   - Default playback speed applied to newly opened chapters (e.g. a picker:
     0.75x–3.0x in reasonable increments).
   - Default skip interval if you want it configurable (10s/15s/30s) —
     optional, but nice to have given Phase 5 hardcoded a single value.

2. **Voice selection (forward-looking)**
   - Even though Kokoro is currently wired up with a single default voice
     (Phase 4), build this screen to support selecting from multiple voice
     styles if more are bundled later. If only one voice exists right now,
     show it as the sole selected option rather than building a dead-end UI —
     but structure the settings model so adding more voices later doesn't
     require rearchitecting.

3. **Storage management**
   - Show total space used by cached/generated audio (ties into Phase 10's
     caching).
   - "Clear all cached audio" action (with confirmation) that deletes
     generated audio files but keeps the underlying text/documents intact,
     so chapters can be regenerated on demand later.
   - Link to **Recently Deleted** (built in Phase 6) from here — a settings
     row showing the count of pending-deletion documents, opening into the
     restore/delete-permanently list.

4. **Listening statistics dashboard**
   - A dedicated stats screen, in the same spirit as the reference
     screenshots but entirely local and with no paywalled tiers or
     "upgrade" prompts anywhere in it:
     - **This week/month summary card**: total time listened, daily average,
       computed by summing `ListeningSession.secondsListened` grouped by
       day/week/month.
     - **Time Listened chart**: bar chart, toggleable between Week / Month /
       6 Months / Year, same shape as the reference screenshot — one bar per
       day (or aggregated per week/month at longer ranges).
     - **Words Listened chart**: same toggle pattern, summing
       `wordsListened` instead of `secondsListened`.
     - **Lifetime totals row**: total time listened, total words listened,
       total time saved (see below), average playback speed across all
       sessions.
     - **Time saved**: for each session, compute
       `secondsListened * (playbackSpeed - 1.0)` when speed > 1.0 and sum it
       — this is the "182h 18m Total Saved" style stat from the reference,
       representing time saved vs. listening at 1.0x.
     - **Month-over-month comparison**: a simple line like "You're listening
       X% more/less this month," comparing this month's daily average
       against last month's.
     - **Files/chapters listened count**: total number of distinct documents
       with at least one `ListeningSession`.
   - All of this reads from local SwiftData `ListeningSession` rows — no
     account, no server sync, no "Basic plan"/subscription gating anywhere.
     Skip the reference app's account/avatar/email header entirely; this
     screen opens straight into your own stats.

5. **About section**
   - App version.
   - Brief acknowledgment of Kokoro TTS (Apache 2.0 licensed) and any other
     open-source components, since this is good practice even for a personal
     build.

6. **Danger Zone — Delete All Data**
   - This is a full factory-reset action: permanently deletes every
     `Document` (text + cached audio, bypassing Recently Deleted entirely —
     not a soft delete), every `ListeningSession` row (wipes the stats
     dashboard back to zero), and the playback queue. It does **not** delete
     the bundled Kokoro model or reset app-wide settings like default speed
     or theme — only user content and history.
   - **Visual treatment — this needs to stand out as dangerous, not blend
     in with the rest of Settings:**
     - Place it in its own section at the very bottom of the Settings list,
       separated from everything else (About, Storage, etc.) by real
       spacing, not just a section header.
     - Section header reads "Danger Zone" (or similar), row itself in
       destructive red (`.foregroundStyle(.red)` / `role: .destructive`),
       with a warning-triangle icon (SF Symbol `exclamationmark.triangle.fill`)
       next to the label — don't reuse the app's ruby accent color here,
       since that's used for normal positive actions elsewhere and would
       undercut the "this is different" signal.
     - Row label should say exactly what it does, not something vague:
       "Delete All Data" rather than "Reset" or "Clear Everything."
   - **Confirmation flow — require two deliberate steps, not one tap:**
     - Step 1: tapping the row shows a confirmation alert/sheet stating
       plainly what will be lost (chapter count, total listening time —
       pull real numbers from the stats so it's concrete, e.g. "This will
       permanently delete 47 chapters and 12h 30m of listening history.
       This cannot be undone.") with a **destructive-styled** confirm
       button and a clearly-labeled cancel.
     - Step 2: after confirming Step 1, require the user to type the exact
       word **DELETE** into a text field before the final destructive
       button becomes enabled (mirrors the pattern used by GitHub's repo-
       deletion and similar irreversible actions elsewhere in iOS/macOS
       apps) — this specifically guards against a fast double-tap or
       muscle-memory confirming through a single alert without reading it.
     - Only after both steps does the actual deletion run. No keyboard
       shortcut, swipe gesture, or single-tap path should be able to reach
       full deletion.
   - **No silent/instant path anywhere else in the app should trigger this**
     — this action lives only behind this one row in Settings, not
     duplicated as a quick action, long-press menu, or shake gesture.

## Acceptance criteria
- Changing default playback speed affects newly opened chapters going
  forward (doesn't need to retroactively change chapters already in
  progress).
- Storage usage number roughly matches actual disk usage of cached audio
  files (spot-check against Files app or Xcode's container inspector).
- Clearing cached audio removes the files and Library rows correctly reflect
  "not yet generated" state afterward, without deleting the documents
  themselves.
- Listening statistics accurately reflect actual playback: listen to a
  chapter for a known duration at a known speed, and confirm the numbers
  on the stats screen update correctly (time listened increases by roughly
  that duration, words listened increases proportionally, time saved
  reflects the speed used).
- Time Listened and Words Listened charts correctly reflect activity across
  the Week/Month/6 Months/Year toggle.
- Recently Deleted is reachable from Settings and its restore/delete-
  permanently actions work as specified in Phase 6.
- No paywall, upgrade prompt, account screen, or subscription-tier UI
  appears anywhere in Settings or the stats dashboard.
- "Delete All Data" is visually distinct (red, warning icon, isolated
  section) from every other row in Settings — it should be impossible to
  mistake for a normal settings toggle at a glance.
- Tapping "Delete All Data" never deletes anything by itself — it always
  requires completing both the confirmation alert AND typing "DELETE"
  before anything is actually removed.
- Backing out at either confirmation step (cancel, dismissing the sheet, or
  leaving the text field empty/incorrect) leaves all data completely
  untouched.
- After a real confirmed deletion: Library is empty, stats dashboard reads
  zero across all metrics, Recently Deleted is empty, and the app is
  otherwise fully functional (can still share/add new chapters normally).
