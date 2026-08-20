# Phase 10 — Offline Audio Caching

## Goal
Avoid re-synthesizing audio every time a chapter is reopened — generate once,
persist, and reuse, while keeping storage usage sane. Audio files live in
the `AudioCache/` folder defined in Phase 1 (inside the App Group
container), one `.m4a` per document, named by `Document.id`.

## Tasks

1. **Cache-aware synthesis trigger**
   - Before calling `KokoroTTSService.synthesize` (Phase 4), check whether
     `Document.audioFileURL` already points to a valid, existing file on
     disk. If so, skip regeneration entirely and play directly.
   - Only regenerate if the audio file is missing (e.g. after a "Clear
     cached audio" action from Phase 8) or if the underlying `bodyText` has
     somehow changed (edge case — flag but don't over-build for this unless
     it's actually reachable given the rest of the app).

2. **Storage-conscious defaults**
   - Store generated audio in a reasonably compressed format (e.g. AAC via
     `.m4a`) rather than uncompressed PCM, to keep per-chapter storage
     reasonable (a typical chapter's audio shouldn't need to be more than a
     few MB).

3. **Cache invalidation / cleanup**
   - Wire up Phase 8's "Clear all cached audio" action to actually delete
     the audio files and null out `Document.audioFileURL` +
     `Document.wordTimestamps` (timestamps are tied to the audio, so they
     should be cleared together) while leaving `bodyText` intact so it can
     be regenerated later.
   - Optional: an automatic cleanup policy for very old, rarely-opened
     chapters' audio (e.g. keep text forever, but offer to purge audio for
     chapters untouched in 60+ days) — nice to have, not required for this
     phase's acceptance.

4. **Storage reporting accuracy**
   - Make sure Phase 8's storage usage number reflects reality after this
     phase's changes (compressed file sizes, correct accounting after
     cache clears).

## Acceptance criteria
- Reopening a previously-played chapter plays back immediately without
  re-running synthesis (verify via timing/logs — should be near-instant vs.
  the multi-second-plus generation time from Phase 4).
- Audio files use a compressed format and reasonable per-chapter file sizes.
- Clearing cached audio via Settings actually frees disk space and forces
  correct regeneration the next time that chapter is opened.
- No stale `audioFileURL` references pointing to deleted files anywhere in
  the app (should gracefully fall back to "needs generation" state).
