# Focused player polish

Branch: `experiment/ios27-ui-ux`; minimum iOS 26. This implements the seven corrections requested after `d6bfbaa`. Main and `checkpoint/antigravity-complete` remain at `2709f20`. No merge occurred. The earlier [restoration report](UI_PLAYER_RESTORATION.md) is historical; this report supersedes its caption sizing, material veil, header edge, and timeline layout.

## Changes

1. **Compact return pill.** Centered, 220 points wide at the default text size, with a stationary return icon and a minimum 44-point height. Dynamic Type scales its dimensions; width is bounded by the available screen. One-line captions truncate without changing the pill's position or width. The accessibility name remains “Return to Current Word,” with the full current token as its value. No announcement or caption animation was added.
2. **No fallback flicker after a valid word.** `ReaderWordDisplay` retains the last valid token across nil, empty, whitespace, punctuation-only, and rejected multiword updates, playing or paused. The old implementation explicitly cleared its presentation value for rejected playing updates; focused contracts reproduce and cover that cause. Paragraph boundaries were not established as the source of the live callback gaps, so this change handles rejected updates independently of their origin.
3. **Saved-position initialization.** An empty restored marker resolves a lexical word from the document at the same UTF-16 character offset used by the reader highlight. The saved document offset is an initialization fallback when no marker is available. It never replaces an advanced live caption during a temporary gap. Chapter changes clear remembered words and initialization state; playback ownership is checked before consuming a marker. Tests cover composed characters, surrogate offsets, internal apostrophes/hyphens, interword positions, trailing punctuation, and invalid positions.
4. **Neutral progressive foreground blur.** Removed the reading transition's system material and theme-colored fade. A passive transparent `UITextView` shares the original `NSTextStorage` and renders through public SwiftUI `.blur(radius: 4)`. Complementary gradient masks blend sharp text into blurred text over 72 points above the measured dock top, then retain blurred line structure through the bottom of the screen. Only the text pixels are softened; the theme background stays solid. The source remains the sole interactive and accessible reader. The mirror has independent layout, receives synchronized scroll offsets, and shares attributes/highlights without transcript copies on every word. Its viewport is limited to the lower transition area. The dock keeps its separate dark adaptive surface and a lighter shadow.
5. **Softer header boundary.** The transparent navigation presentation and native glass controls remain. The reader's native top scroll edge explicitly uses `.soft` rather than automatic styling. No additional rectangular header overlay was introduced. Native bottom-edge treatment stays disabled to avoid stacking it with the foreground blur.
6. **Timeline follows the upper rim.** Track, buffer, and progress use the same continuous 24-point rounded contour as the dock, stroked inward and masked to its upper edge. The prior one-point vertical inset is removed. The restrained thumb appears while dragging. The invisible touch shape includes the top strip and a central 44-point-deep region, excluding the queue/X button targets. Seeking callbacks and accessible adjustment retain their existing behavior.
7. **Less vertical bulk.** Top padding drops from 44 to 8 points and bottom padding from 16 to 10, reducing default dock height from 160 to 118 points. Existing comfortable button dimensions remain. Horizontal dock margins remain 16 points.

Sources: [PlayerView.swift](Plume/Plume/PlayerView.swift), [PlayableTextView.swift](Plume/Plume/PlayableTextView.swift), [ReaderWordDisplay.swift](Plume/Plume/ReaderWordDisplay.swift). Typography, theme definitions, rosewood accent, X stop/release action, minimize action, playback engine, seeking implementation, routing, and follow-timer policy are unchanged. Manual browsing, immediate Return, three-second inactivity/reset behavior, and pause/sheet/background/VoiceOver suspension retain their existing contracts.

## Integration and visual review

The initial public material candidate still reproduced Basic's gray wash and Warm's darker band. Changing material strength would retain trait-dependent background tint, so the focused investigation replaced backdrop compositing with foreground-only blur. Empty background samples above and below the final dock match the source PNG channel values: Basic `#000000`, Warm `#DDD5CD`, Muted `#2E2E2E`.

An initial direct mask on the hosting controller's view emitted a UIKit warning. The final implementation masks plain UIView containers around the source and blurred host; that warning is absent from the final theme run. There are no private filters, blur animators, snapshot loops, or duplicate accessible reader elements. Reduce Transparency removes the blurred mirror and restores sharp text; controls use opaque surfaces. Reduce Motion keeps the existing immediate scrolling branch. The extra text layout/compositing pass has not yet been profiled on the physical phone.

Final screenshots were reviewed in Basic, Warm, and Muted, including landscape, accessibility5 text, and forced reduced-effects rendering. The [39-second scrolling recording](ui-evidence/player-polish/ios27-scroll-and-return.mp4) shows all three themes, actual reader scrolling, the compact caption, header blending, and text becoming sharp above the dock. These are paused fixture interactions, not evidence of speech synthesis or active playback on this revision.

## Verification

| Check | Result | Evidence / limits |
|---|---|---|
| Reader contracts | Passed: 15 Swift Testing functions, including 51 parameterized cases | `/tmp/plume-player-polish-host.log`; word gaps, paused retention, saved positions, chapter resets, font migration, and follow timing. |
| iOS 27, iPhone 17 simulator | Passed: 5 UI tests | Theme/paused Return run `test_sim_2026-10-15T02-10-03-770Z_pid72904_766c796e.xcresult`; remaining four `test_sim_2026-10-15T02-13-05-920Z_pid72904_396cdc14.xcresult`. |
| iOS 26.5, iPhone 17 Pro simulator | Passed: 5 UI tests | `test_sim_2026-10-15T02-16-56-316Z_pid72904_afb43419.xcresult`. |
| Saved position before Play | Passed in all three themes on both simulators | Empty marker at Paragraph 8 resolves “Morning”; paused Play state asserted, caption centered and compact, manual Return succeeds without starting playback. |
| Larger text, landscape, sheets | Passed and screenshots reviewed | accessibility5 pill remains within the screen; Appearance/Speed controls remain reachable. |
| Reduced effects | Rendering branches passed in all themes on both simulators | Fixture flags force the same policy branches; this does not certify actual OS setting propagation or VoiceOver behavior. |
| Physical iPhone | Build succeeded; test could not bootstrap | `test_device_2026-10-15T02-11-43-456Z_pid72904_2cefaece.xcresult`: “Unlock Saumya to Continue,” followed by lost testmanagerd connection. User chose to continue with simulator evidence. |
| Screenshots / scrolling | 44 screenshots and one reviewed recording | [Evidence index](ui-evidence/player-polish/README.md). Only final implementation captures are included. |

The five UI tests cover themes/paused Return, saved-position captions, reduced effects, landscape/sheets, and larger text. The updated physical test includes the curved-rim drag, active word changes with a stable pill frame, immediate/automatic Return, pause, two background round trips, minimize/reopen, and X release. **That updated physical test has not run successfully on this revision.** Earlier device passes at `d6bfbaa` establish a baseline, not a pass for these layout/blur changes. Actual VoiceOver focus, adjustment and non-announcement behavior, OS Reduce Transparency/Reduce Motion, current playback/scrubber/highlight/routing/background handoff, and physical scroll performance remain open gates.

Result bundles/logs remain outside git under `~/Library/Developer/XcodeBuildMCP/workspaces/Plume-ccf85facdece/`. Simulator MLX uses the existing disposable DerivedData weak-link workaround and does not verify MLX synthesis; device dependencies are unmodified. Existing Swift 5-mode concurrency, audio-session activation, and simulator priority-inversion warnings remain outside this focused scope. Fixture models and appearance/cache/queue storage are isolated from the user's library.

## Model usage

| Work | Model / reasoning | Actual use |
|---|---|---|
| Supervision, integration, routine review, fixtures, builds, evidence | GPT-6.1 Sol / medium | Default workflow. Root owns shared integration and builds. |
| Fresh-context player polish and word contracts | GPT-6.1 Sol / medium | One worker in an isolated worktree; exclusive reader/player/contract/test files. |
| Reproduced material-tint integration problem | GPT-6.1 Sol / high | One narrowly scoped investigation after the medium candidate visibly failed; implemented neutral foreground blur. |
| Precisely scoped copy/report updates | GPT-6 Luna / low | Available in the agreed workflow; not used in this follow-up. Root completed the report. |
| Astra | Disabled by default | Not used. |

The two workers ran sequentially, below the two-worker limit. Each batch followed implement → focused check → review → integrate. Tested worktree source and final experiment source were compared byte-for-byte. No broad audit, unrelated feature work, or repeated passing test batches were added.
