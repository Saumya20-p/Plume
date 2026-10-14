# Focused player restoration

Branch: `experiment/ios27-ui-ux`. Minimum OS: iOS 26. This follow-up implements only the five requested player corrections after the broader experiment at `de33af9`. Main and `checkpoint/antigravity-complete` remain at `2709f20`; no merge occurred.

## Five corrections

1. **Translucent chapter header.** The UIKit reading surface extends through both safe areas. The reader and its full-screen navigation presentation use the effective reading theme. Native toolbar glass surrounds the chevron and AA controls, with a transparent toolbar background and theme-colored title/controls. The initial text inset clears the header; scrolling content continues underneath it. Reduce Transparency uses an opaque theme background.
2. **X closes and releases playback.** The dock restores `xmark` while retaining `stopAndRelease()`, dismissal, and the accessibility name “Stop Playback and Close Player.” The top downward chevron still minimizes without releasing playback.
3. **Timeline on the upper edge.** A 3-point progress/buffer track sits 1 point from the dock top, clipped by the dock’s continuous rounded shape. Its exclusive 44-point gesture band is above all other buttons. Buffer and remaining track use different subdued opacities; the drag thumb appears during interaction. Existing seek callbacks, playback-position value, and 15-second accessible adjustment remain intact.
4. **Progressive material behind the player.** A single public `UIVisualEffectView` uses `.systemUltraThinMaterial` with a directly applied gradient view mask. The mask ramps from clear to 0.97 over 72 points above the measured dock top, then holds that plateau through the bottom of the reading surface. A separate theme fade reaches only 25% opacity, replacing the original 85–95% fade. The dock retains a dark control appearance across device color schemes, with a 55% adaptive fill instead of another blur. UIKit material appearance follows the reading theme. Text continues underneath and below the dock; moving upward blends it back to sharp text. Measured bottom inset still lets the last line scroll fully above the controls. Reduce Transparency hides the veil/fade and makes controls opaque.
5. **Return shows the spoken word.** `ReaderWordDisplay` consumes the existing playback highlight word. It validates one token, preserves the last valid word while paused, resets history on chapter changes, and uses the descriptive fallback when unavailable. The caption has fixed available width and a Dynamic Type-scaled fixed height, with a separate stationary icon. Accessibility retains “Return to Current Word” as its name and exposes the token as its value. There is no new speech process, word timer, announcement, or caption animation. Immediate Return and the existing three-second inactivity contract remain unchanged, including interaction resets and pause/background/sheet/VoiceOver suspension.

Sources: [PlayerView.swift](Plume/Plume/PlayerView.swift), [PlayableTextView.swift](Plume/Plume/PlayableTextView.swift), [ReaderWordDisplay.swift](Plume/Plume/ReaderWordDisplay.swift), and the presentation background in [MainTabView.swift](Plume/Plume/MainTabView.swift). Typography, reading theme definitions, rosewood accent, and playback/voice-routing code are unchanged.

## Integration decision

The prior native `.soft` edge did not produce the requested transition beneath and below the floating dock in the user’s screenshots. It is disabled for this reader; its element-container interaction is removed so it cannot overlap the new veil. The final public mask is a blend with a fixed material blur, not a private variable-radius filter.

A reproduced sharp-text residual prompted one Sol/high investigation. Unmasked inspection confirmed the public material itself worked. The final change completes the ramp at the dock top and limits the sharp residual to 3%. Public animator prototypes were rejected: holding them paused blocked XCTest idleness, and stopping them removed the intended blur. The shipped implementation has no blur animator, snapshot loop, private filter, or unfinished animation.

A Warm/reduced-effects Return tap failure also justified targeted investigation. Keeping gestures inside the unobscured passage ruled out settings overlap. Explicitly invalidating the hosted controls’ intrinsic size after root-view updates fixed the check across all themes; diagnostic inspection confirmed the UIKit frame expands by the Return row’s height. Temporary diagnostics were removed. The final iOS 26.5, iOS 27, and iPhone checks below cover that correction.

## Verification

| Check | Result | Evidence |
|---|---|---|
| Reader presentation/follow contracts | Passed: 11 Swift Testing test functions, including 32 parameterized cases | `/tmp/plume-reader-restoration-host.log`; font migration, follow timing, valid/invalid tokens, paused retention, and chapter reset. |
| iOS 26.5 final UI | Passed: 4 tests | `test_sim_2026-10-14T23-33-38-180Z_pid72904_7e2a0d8c.xcresult`; Basic/Warm/Muted, paused Return, landscape, accessibility5, expanded sheets, reduced-effects fallback. |
| iOS 27 final UI | Passed: all 4 focused tests | Themes/paused Return: `test_sim_2026-10-14T23-37-53-065Z_pid72904_1103276d.xcresult`; reduced effects: `test_sim_2026-10-14T23-31-51-658Z_pid72904_77f23702.xcresult`; landscape/accessibility5/sheets: `test_sim_2026-10-14T23-39-32-303Z_pid72904_601f2172.xcresult`. |
| Physical iPhone “Saumya,” iOS 27 | Passed: extended playback test | `test_device_2026-10-14T23-32-36-748Z_pid72904_2e37362d.xcresult`; play/highlight progression, skip, actual edge-slider drag, two background round trips, changing Return word with stable frame, immediate and automatic Return, paused word retention beyond three seconds, paused Return, appearance sheet, minimize/reopen, X release/close. |
| Screenshots and scrolling recordings | Saved and reviewed | [Evidence directory](ui-evidence/player-restoration/README.md). |
| Accessibility system behavior | Hands-on gate open | Reduced-effects fixture inputs verify the same rendering branches used by the OS settings. Actual VoiceOver focus/adjustment and absence of disruptive word-update announcements, plus physical OS Reduce Motion/Transparency confirmation, are not represented as passed. |

Fixture data and cache/queue/appearance storage are isolated. Simulator MLX uses the existing disposable DerivedData weak-link workaround; physical dependencies are unmodified. Result bundles and build output stay outside git. Failed/rejected prototypes are excluded from final evidence.

## Model usage and economical workflow

| Work | Model / reasoning | Use in this follow-up |
|---|---|---|
| Supervision, shared-file integration, routine review and builds | GPT-6.1 Sol / medium | Default workflow; root owns shared files and final builds. |
| Reader veil integration | GPT-6.1 Sol / medium | Initial reader worker in an isolated worktree. |
| Spoken-word presentation and focused contracts | GPT-6.1 Sol / medium | Separate worker, exclusive contract/test files. |
| Concrete UIKit integration failures | GPT-6.1 Sol / high | Reused for reproduced veil/animation-idleness problems and the hosted Return hit-boundary failure; root completed the boundary fix and verification. |
| Scoped report drafting | GPT-6 Luna / low | Initial evidence-ledger draft; final facts corrected during integration. |
| Astra | Disabled by default | Not used. |

At most two workers ran concurrently. Each received exclusive files and acceptance checks; batches followed implement → focused check → review → integrate. No broad audit or unrelated feature work was repeated. The existing cache, import, queue, voice routing, seeking, and background fixes were preserved.
