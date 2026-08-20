# Phase 5 — Player UI, Word Highlighting, Background Audio

## Goal
Build the actual reading/listening experience: playback controls, real-time
word highlighting driven by Phase 4's timestamps, and background/lock-screen
audio support.

## Tasks

1. **Audio playback engine**
   - Use `AVAudioPlayer` or `AVAudioEngine` to play the `audioFileURL` from a
     `Document`.
   - Support: play, pause, seek, skip forward/back (±10s or ±15s, pick one
     and be consistent), and a variable playback speed control (e.g. 0.75x–
     3.0x) using pitch-preserving time-stretching (`AVAudioUnitTimePitch` if
     using `AVAudioEngine`, or the appropriate player API).

2. **Word highlighting**
   - Drive a `currentWordIndex` (or timestamp cursor) off the audio player's
     current playback time, checked against `Document.wordTimestamps`.
   - Render the chapter text with the currently-spoken word visually
     highlighted (background highlight, consistent with the accent color at
     reduced opacity — see Phase 1's design tokens).
   - Auto-scroll the text view to keep the highlighted word in view as
     playback progresses.
   - Tapping a word in the text should seek playback to that word's
     timestamp.

3. **Full player screen**
   - Shows the chapter text (using whatever appearance settings are active —
     real theming arrives in Phase 7, use sensible defaults for now: Basic
     theme, Georgia font).
   - Playback controls docked at the bottom: play/pause, skip back/forward,
     speed control, progress scrubber showing elapsed/remaining time.

4. **Mini-player**
   - A persistent compact player bar (title, tiny progress indicator,
     play/pause) that can dock at the bottom of other screens (e.g. Library)
     when a chapter is loaded but the full player isn't showing. Full
     integration with Library happens in Phase 6 — just build the component
     here.

5. **Background audio + lock screen**
   - Confirm the Background Modes → Audio capability from Phase 1 is active
     and playback continues when the app is backgrounded or the device is
     locked.
   - Implement `MPNowPlayingInfoCenter` updates (title, elapsed time,
     duration) and `MPRemoteCommandCenter` handlers (play, pause, skip
     forward/back, scrubbing) so lock screen and Control Center controls
     work correctly.

6. **Progress persistence**
   - Update `Document.progress` as playback advances (e.g. periodically, and
     on pause/backgrounding) so the Library (Phase 6) can show accurate
     progress percentages, matching the reference Speechify screenshots.

7. **Listening-session tracking**
   - Write `ListeningSession` rows (defined in Phase 3) as playback happens —
     flush a row when playback pauses, finishes a chapter, or the app
     backgrounds, capturing `secondsListened`, `wordsListened` (derived from
     `wordTimestamps` and how far playback advanced), and the
     `playbackSpeed` active during that stretch. If the user changes speed
     mid-session, close out the current row and start a new one at the new
     speed, so Phase 8's "average speed" and "time saved" math stays
     accurate rather than being skewed by a single session spanning
     multiple speeds.

## Acceptance criteria
- Playing a generated chapter shows correct word-by-word highlighting that
  visibly tracks the audio in real time, not just approximately.
- Tapping a word seeks playback accurately to that word.
- Playback continues uninterrupted when the app is backgrounded and when the
  device is locked.
- Lock screen shows correct title/progress and all remote commands (play,
  pause, skip) work.
- Speed control changes playback rate without pitch distortion ("chipmunk"
  effect).
- `Document.progress` updates and persists correctly across app relaunches.
- `ListeningSession` rows are created during playback with accurate
  duration, word count, and speed — verify by listening for a known
  stretch of time and checking the resulting row(s) directly.
