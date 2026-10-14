# Player UI restoration evidence ledger

This ledger records the five UI corrections and the evidence available for this draft. The implementation under review is in `Plume/Plume/PlayerView.swift`; this report does not treat pending checks as passed.

## Corrections and evidence

1. **Reader header and safe areas.** The reader extends behind both safe areas. The active theme supplies the full presentation background and native Liquid Glass toolbar appearance, avoiding a solid black strip. The host reader contract suite passed 11 tests plus 32 parameterized cases (`/tmp/plume-reader-restoration-host.log`). The current implementation was also inspected in `PlayerView.swift`.

2. **Minimize control.** The leading toolbar control uses a down chevron and the accessibility label “Minimize Player.” Activating it dismisses the player while preserving the audio label; it does not use an X/stop-and-release action. Source inspection only; interaction verification remains pending.

3. **Timeline hit area.** The timeline retains a 3 pt visible upper rim and an exclusive 44 pt hit band. Source inspection only; device hit testing remains pending.

4. **Dock veil.** The public implementation uses one masked `UIVisualEffectView` with `.systemUltraThinMaterial`. Its mask ramps from 0 to 0.90 over 72 pt, reaches the measured dock top, then holds a 0.90 plateau below. Theme fade is capped at 0.25 and the dock uses a 55% adaptive fill. It does not stack native blurs or use a Core Animation filter. The first iOS 27 run passed three UI tests but exposed a too-sharp veil. An unmasked Sol-high diagnostic reproduced that the blur itself works; after lengthening the mask ramp, a manual iOS 27 warm-theme scroll check showed the header text underneath and a softer veil. iOS 26/27 final UI verification remains pending.

5. **Return to current word.** `ReaderWordDisplay` retains the actual spoken word while paused and falls back to nil/invalid or per-document changes. The return control has the prior “Return to Current Word” accessibility label and action hint, exposes the word as its value, and keeps a stable fixed-width, two-line caption layout. It adds no announcements and does not change timing. Host reader contract tests passed as recorded above. Live playback and return behavior still need manual verification.

## Verification status

| Gate | Status | Evidence / remaining work |
| --- | --- | --- |
| Host reader contracts | **Passed** | 11 tests and 32 parameterized cases; `/tmp/plume-reader-restoration-host.log`. |
| Initial iOS 27 UI run | **Passed, with issue found** | Three UI tests passed; review found the veil edge too sharp, leading to the mask-ramp correction. This is not final verification of the revised veil. |
| Revised warm-theme veil | **Partial** | Manual iOS 27 scroll check confirmed header text underneath and softer transition after the longer ramp. |
| iOS 27 final UI suite | **Pending** | Run against the final implementation. |
| iOS 26 UI suite | **Pending** | Run against the final implementation. |
| Physical playback and live-word return | **Pending** | Check spoken-word tracking, pause retention, manual return, and automatic return during playback. |
| VoiceOver announcement gate | **Pending — exact open gate** | With VoiceOver enabled, verify the Return to Current Word control exposes its stable label, action hint, and current word value without emitting an announcement or changing playback timing. |

No pending gate above is represented as passed.
