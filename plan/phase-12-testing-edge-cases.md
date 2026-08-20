# Phase 12 — Testing & Edge Cases

## Goal
Harden the app against the realistic failure modes of a share-extension +
on-device-AI pipeline, and add the manual-fallback path referenced back in
Phase 3.

## Tasks

1. **Extraction failure fallback**
   - When `Document.extractionFailed == true` (set back in Phase 3), surface
     a clear UI state in the Library/Player instead of showing broken/empty
     text: "Couldn't extract this chapter automatically" with a **manual
     paste** option — a text field/editor where the user can paste the
     chapter text themselves, which then populates `bodyText` and clears the
     failure flag.
   - Also handle the case where extraction "succeeds" but produces obvious
     garbage (e.g. mostly non-prose content) — reuse the same fallback UI
     rather than trying to auto-detect every possible bad case perfectly.

2. **Very long chapters**
   - Stress-test with an unusually long chapter (e.g. 10,000+ words) through
     the full pipeline: extraction → Kokoro chunked synthesis (Phase 4) →
     playback with highlighting (Phase 5). Confirm no memory spikes/crashes
     and that chunk-boundary stitching still sounds seamless at this length.

3. **Share extension network/handoff hiccups**
   - Handle the case where the extension captures a URL but HTML extraction
     via the JS preprocessor fails or times out (e.g. page still loading,
     or a site that blocks the technique) — fall back gracefully to storing
     just the URL, and have the main app attempt extraction from the URL
     directly if needed, rather than silently dropping the share.
   - Handle sharing while offline — extension should still capture and
     queue the item locally; extraction can proceed since HTML was already
     captured, or should clearly indicate "couldn't fetch, try again when
     online" if only a URL was captured and a live fetch is required.

4. **App Group sync / race conditions**
   - Test rapid sequential shares (e.g. share 3 chapters within a few
     seconds of each other) and confirm no pending items are lost or
     overwritten due to write races in the shared App Group storage.
   - Confirm the main app's "check for pending items" logic (Phase 2/3) is
     idempotent — relaunching the app repeatedly shouldn't create duplicate
     Documents from the same pending share.

5. **Low storage handling**
   - Simulate low available disk space (or mock the check) and confirm
     Kokoro synthesis (Phase 4) and audio caching (Phase 10) fail gracefully
     with a clear user-facing message rather than crashing mid-generation.

6. **Playback interruptions**
   - Test playback behavior when interrupted by a phone call, Siri, or
     another app's audio (e.g. a timer or another audio app) — playback
     should pause appropriately and either resume or clearly indicate it
     needs to be manually resumed, per standard `AVAudioSession` interruption
     handling. Also confirm correct behavior when a Bluetooth audio device
     disconnects mid-playback.

## Acceptance criteria
- A deliberately unextractable page results in a working manual-paste flow
  that produces a fully functional chapter afterward (extraction → TTS →
  playback all work on the manually-pasted text).
- A 10,000+ word chapter processes and plays back without crashing, memory
  warnings, or audible seams at chunk boundaries.
- Sharing while offline, and sharing several items in quick succession, both
  result in zero lost or duplicated Library entries.
- Low-storage and playback-interruption scenarios produce clear, non-crashy
  user-facing states rather than silent failures or hangs.
