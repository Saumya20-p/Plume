# Plume dual-engine playback: implementation plan

## Status and scope

This is a prospective implementation plan for a unified Kokoro / Apple Enhanced / Apple Premium picker and one logical listening session that can change audible engines safely. It is not a report that the feature exists, and no implementation, build, configuration, installation, or test changes are made by this document task.

The original Antigravity phase files are historical project planning material, not phases for this feature. This plan starts at Phase 3A because the following foundation work is already complete:

| Foundation | Evidence/status |
|---|---|
| Phase 0 reconnaissance | Complete by the prior team. The source audit below is the baseline for this plan. |
| Phase 1 voice identity/preferences/catalog | New Phase 1 test source files compile. The whole `PlumeTests` target fails/was never executed because the legacy test is stale and the shared scheme has no testables. `PlaybackVoiceID`, `VoicePreferencesStore`, and the English-only Apple catalog exist, but they are not yet the single runtime source of truth. |
| Phase 2 Kokoro identity/session safety | New Phase 2 test source files compile. The whole `PlumeTests` target fails/was never executed for the same harness reasons. The user separately completed Phase 2 physical-device checks; that is not a whole-test-target pass. |

The new Phase 1/2 test source files compile, but the whole test target fails/was never executed: legacy `PlumeTests.swift` uses a stale `generateSingleChunk` call, and the shared `Plume` scheme has an empty `<Testables>` section. This plan never treats compile-only evidence or the separate device checks as a whole-target pass.

## Product contract

- The picker shows Kokoro plus Apple Enhanced and Apple Premium. Apple default-quality voices are an emergency resolver choice only, never a selectable row. Current catalog scope remains English-only and excludes novelty and Personal Voice entries; disclose that scope in the picker/settings copy.
- The selected primary and the separate Apple fallback preference persist. A listening run snapshots both at start; changing the preference must not mutate the current run, delete caches, cancel/restart the reader, or silently jump the cursor. Resume, seek, fallback, and handback retain that snapshot; only an explicit new logical document session or the next explicitly queued document takes the latest persisted preferences. Runtime fallback resolution never overwrites the persisted fallback preference.
- Apple primary uses `AVSpeechSynthesizer`. It must not initialize Kokoro, Metal, or generation work. Apple preview is fixed sample text spoken directly by `AVSpeechSynthesizer`, without an artificial delay; “instant” or gapless startup is not a guarantee.
- A Kokoro fixed sample is generated on the first request, then cached and reused for later previews of that voice. Do not prefer or require a bundled Kokoro sample, and do not build a second preview pipeline.
- When Kokoro is primary, it may hand off one-way to the selected Apple fallback before the Kokoro buffer drains. When Kokoro becomes ready in the foreground, hand back at the next available existing sentence-chunk boundary. If it is not ready, remain on Apple. Re-backgrounding during preparation stays on Apple. Word/source continuity is the measured goal, not a guarantee of exact words, silence-free timing, or gapless switching.
- The run is one logical listening session. There is one audible producer and one control owner; an engine handoff is not a new user session or automatic document restart. Handoffs are hidden implementation details: controls and the source highlight remain stable, with no engine-toggle UI.
- Runtime operation is on-device/offline with no cloud TTS. OS voice downloads are managed separately in Settings; the app picker only reflects currently eligible installed voices.
- A legacy whole-document cache without verified voice metadata is preserved but never reused for selected-voice playback; only voice-qualified chunks or verified metadata may satisfy the active voice.
- “Desired play,” “actual engine activity,” and “generation/preparation activity” are separate state. Paused, interrupted, buffering/underrun, and failed/recoverable-pause states are explicit.

## Source audit baseline

- [`PlayerView.swift`](../Plume/Plume/PlayerView.swift#L448) still binds the picker to `@AppStorage("kokoroVoice")`. A selection cancels generation, clears memory, deletes the whole-document cache and every `.m4a` in the document directory, then seeks/regenerates. This directly violates snapshot continuity and cache preservation.
- [`PlaybackVoice.swift`](../Plume/Plume/PlaybackVoice.swift#L15) has a useful separate primary/fallback preference shape, but [`PlaybackGenerationIdentity.swift`](../Plume/Plume/PlaybackGenerationIdentity.swift#L135) still creates Kokoro sessions from the legacy `kokoroVoice` key. Runtime reads must converge on a session snapshot.
- [`AppleSpeechVoiceCatalog.swift`](../Plume/Plume/AppleSpeechVoiceCatalog.swift#L112) already filters English, excludes novelty/Personal Voice, and excludes default quality. Preserve that policy and communicate it; do not expand scope implicitly.
- [`AudioGenerationManager.swift`](../Plume/Plume/AudioGenerationManager.swift#L66) is Kokoro-specific, uses fixed media-second high/low watermarks, and auto-plays the first enqueued chunk at lines 184–187. A speculative foreground handback needs a preparation-only consumer so it cannot seize playback from Apple.
- [`AudioPlaybackEngine.swift`](../Plume/Plume/AudioPlaybackEngine.swift#L158) owns an `AVQueuePlayer`, while [`PlaybackCoordinator.swift`](../Plume/Plume/PlaybackCoordinator.swift#L20) auto-advances by checking `audioFileURL`. Queue advancement must route through the session/router, not an audio-file shortcut. End observation currently listens with `object: nil`, so unrelated player items can trigger it.
- [`AudioPlaybackEngine.swift`](../Plume/Plume/AudioPlaybackEngine.swift#L103) applies `playbackRate` directly to `AVPlayer`. Apple utterance speed is a per-utterance input, not a live AVPlayer multiplier; a rate change must apply to the next utterance/sentence or use an explicitly controlled restart from a safe cursor.
- [`AudioPlaybackEngine.swift`](../Plume/Plume/AudioPlaybackEngine.swift#L271) records statistics from `currentTime - currentSessionStartTime` and speed-estimated words. Seeks, handoffs, pauses, buffering, and preview audio make that delta unsuitable as the sole definition of actual listening.
- The current preview path in [`PlayerView.swift`](../Plume/Plume/PlayerView.swift#L547) calls `setCategory`/`setActive` itself. Preview teardown must restore the shared audio-session owner instead of competing with reader lifecycle.
- [`TextSegmenter.swift`](../Plume/Plume/TextSegmenter.swift#L24) already provides stable `NLTokenizer(.sentence)` chunks and UTF-16 ranges. Reuse it; do not introduce a generalized segmentation framework.
- Kokoro chunk files include voice in their names (`Document.chunkURL` and `AudioChunkGenerator`); legacy whole-document cache has no known voice metadata. It must not override a selected voice, and unrelated cache files must remain untouched.

## Architecture and invariants

1. **One session snapshot.** Introduce a small session record containing document ID, run ID/callback generation, primary voice, fallback Apple voice, source segment ordinal/UTF-16 cursor, desired play state, active producer, and lifecycle status. The session owns handoff decisions; the UI only issues intent.
2. **Two cursors and explicit Apple callback semantics.** Track an upcoming-word/display cursor for highlighting and a committed handoff cursor that only advances at an accepted source boundary. `willSpeak` is display-only; `didFinish` for the currently owned utterance commits its source boundary. `didCancel`, stale callbacks, and callbacks from a non-owned utterance never advance the cursor or queue. Only terminal logical-document completion advances the document queue, exactly once; handoffs and preparation completion never do so. Cursor monotonicity is required between intentional seeks.
3. **One source-position timeline.** Keep source position independently from engine time. Map Kokoro timestamps and Apple estimates onto the same document cursor. Existing skip/scrub remains source-position seeking; disclose that Apple position is estimated and cap any rate mapping rather than implying exact timing.
4. **One audible producer.** Apple synthesizer and Kokoro `AVQueuePlayer`/chunks are producers behind one router. Generation callbacks carry session and callback-generation IDs; stale speculative handback callbacks/results are rejected after a new session, intentional seek, source reset, interruption restart, document change, or re-background. Valid queued Kokoro playback audio survives an ordinary pause/background transition; those transitions cancel only speculative handback work/callbacks. A persisted preference change alone never invalidates the active snapshot.
5. **Resolver safety.** Resolve chosen eligible voice, then same-locale eligible voice, then a compatible system default only for emergency playback. If missing/repeatedly failing, enter an explicit recoverable pause with the saved cursor; do not retry forever.
6. **Audio session ownership.** Keep preview, Apple playback, and Kokoro playback under the shared app audio-session owner. Validate `AVSpeechSynthesizer.usesApplicationAudioSession = true` on device. Preview is one-at-a-time, cancelled on dismissal/background, and pauses the reader only under an explicit resume policy.
7. **Rate and buffering.** Set `AVSpeechUtterance.rate` before enqueue and bound the pending Apple queue to the current/next sentence so old rates do not outlive the next sentence boundary. A speed change affects the next sentence/utterance (or follows a documented safe-cursor restart); never assign a live AVPlayer multiplier to pretend Apple changed speed. Convert Kokoro media seconds to wall-time lookahead using actual playback rate and cap estimates.
8. **Diagnostics without content.** Log run/segment/engine IDs and monotonic timing for handoff decisions, failures, cancellation, and stale callback rejection. Never log private document text.
9. **Statistics compatibility.** Preserve existing `ListeningSession` rows and historical values. New actual-active wall time, if added, excludes preview audio, user pauses, interruptions, and buffering; words remain explicitly speed-estimated from the delivered source cursor rather than being silently redefined at handoff.

**Reusable per-phase gate (Astra, `gpt-6-astra`, reasoning `high`):** for every phase and every file-owning diff, the implementer reports changed files, tests attempted versus executed, and device evidence; an independent reviewer audits the diff; the implementer addresses findings without overlapping another writer; the reviewer re-reviews the fixes; only then does Astra decide whether the next user checkpoint is ready. A blocked, compile-only, or unexecuted result stays explicitly marked.

The gate note records: changed-file ownership, exact test/build status, device model and OS, installed voice IDs/quality, foreground/background/lock/interruption route, observed gap or skipped/repeated words, cache effects, and any blocked claim. This keeps physical evidence separate from source-level confidence and makes a later handoff auditable.

## Dispatch and collaboration rules

The root/orchestrator uses `gpt-6-astra` with reasoning `high` only for scope, architecture, assignments, and phase gates. Every hands-on implementer, researcher, test-runner, documenter, and independent reviewer uses `gpt-5.6-luna` with reasoning `xhigh`. A new agent spawn records `model=gpt-5.6-luna` and `reasoning_effort=xhigh`; follow-ups reuse a verified Luna/xhigh agent and never an old other-model reviewer. Dispatch records carry `model_reasoning_effort=xhigh`; ordinary file/tool calls do not need a model field. Maximum four active slots includes the root.

Every diff has a named implementer and a separate independent reviewer. No two writers work on the same files concurrently. After a reviewer requests fixes, the same reviewer (or a newly named independent reviewer) reviews the fixes again before the gate. Assign only existing relevant skills; do not install skills. Use `axiom-media` for AVFoundation/audio lifecycle, `swift-concurrency-pro` for actors/tasks/cancellation, `swift-testing-expert` for tests, `xcodebuildmcp` for build/device execution, `swiftui-expert-skill` and `mobile-ios-design` for UI/accessibility, and `swiftdata-pro` only if SwiftData/stat persistence is touched.

Work on one major phase/subphase at a time. Stop after each user checkpoint for simple iPhone checks before beginning the next phase. Do not add separate legal/store phases to this feature.

File ownership boundaries for the implementation (one writer per row at a time):

| Area | Primary files to own | Review focus |
|---|---|---|
| Session/cursors/contracts | `PlaybackGenerationIdentity.swift`, new small session/router types, pure tests | IDs, cursor invariants, actor isolation |
| Apple engine | new Apple producer type plus `AudioPlaybackEngine.swift` integration | AVSpeech lifecycle, rate, UTF-16 ranges, one producer |
| Kokoro preparation | `AudioGenerationManager.swift`, `KokoroTTSService.swift` integration | no auto-play in preparation, Metal lifecycle, cache identity |
| Picker/preferences/previews | `PlayerView.swift`, `PlaybackVoice.swift`, `AppleSpeechVoiceCatalog.swift` | selection snapshot, catalog scope, shared audio session, accessibility |
| Stats/routing | `ListeningSession.swift`, `PlaybackCoordinator.swift`, engine session hooks | historical compatibility, queue end ownership, actual-active semantics |
| Test evidence | `PlumeTests`, focused test files, scheme only when required for selection | executed versus compiled, device evidence, no false pass |

## Phase 3A — harness repair and shared contracts

**Scope and ownership:** test harness files/project scheme are owned by the harness implementer; playback identity/session/router contracts are owned by the playback-contract implementer. Preserve the working Kokoro pipeline and do not change picker behavior in this subphase.

- [ ] Repair only the minimum test-target/harness issues needed to make the relevant tests selectable and the stale legacy test either current or explicitly isolated; record compile, selected-test, and executed-test results separately --> [agent: harness implementer | model: gpt-5.6-luna | reasoning: xhigh] (skills: swift-testing-expert, xcodebuildmcp)
- [ ] Define host-testable pure contracts for session snapshot, desired/actual/generation states, source cursor, display cursor vs committed handoff cursor, callback generation, stale-result rejection, and resolver outcomes; keep ownership small and avoid a generalized framework --> [agent: playback-contract implementer | model: gpt-5.6-luna | reasoning: xhigh] (skills: swift-concurrency-pro, swift-testing-expert)
- [ ] Add focused tests for cursor monotonicity between intentional seeks, seek invalidation, pause/interruption transitions, resolver ordering, and one-audible-producer arbitration without invoking MLX or requiring cloud/runtime services --> [agent: contract test implementer | model: gpt-5.6-luna | reasoning: xhigh] (skills: swift-testing-expert)
- [ ] Run the phase-scoped deterministic tests and a baseline iPhone build, recording whether each result compiled, was selected, or actually executed before the user checkpoint --> [agent: Phase 3A test-runner | model: gpt-5.6-luna | reasoning: xhigh] (skills: swift-testing-expert, xcodebuildmcp)
- [ ] Independently review the harness and contracts for scope, actor isolation, stale callbacks, and truthful test reporting; review only the assigned files --> [agent: independent Phase 3A reviewer | model: gpt-5.6-luna | reasoning: xhigh] (skills: swift-concurrency-pro, swift-testing-expert)
- [ ] Re-review every fix requested by the independent reviewer and publish a gate note distinguishing compiled-only tests, executed host tests, simulator limitations, and physical-device evidence --> [agent: Phase 3A review-fix reviewer | model: gpt-5.6-luna | reasoning: xhigh] (skills: swift-testing-expert, xcodebuildmcp)

**Astra gate (gpt-6-astra, high):** contracts are narrow, Kokoro remains intact, and no phase is marked passed from compilation alone. If simulator MLX linking blocks tests, run the smallest host-testable pure target or stop for a user physical-device run.

Device checkpoint (before 3B):

1. Existing Kokoro playback starts, highlights text, pauses, resumes, and seeks without a new audible producer; expected: behavior matches the pre-feature baseline.
2. A seek followed by a delayed generation callback cannot move playback backward or reinsert stale audio; expected: cursor and audible source remain at/after the seek.

## Phase 3B — Apple-primary vertical slice

**Scope and ownership:** add Apple as a real primary source with controls/progress/stats behind an internal test seam that can select a voice in tests only. Consume `VoicePreferencesStore` for every new logical session now (including the fallback preference); Phase 4 may improve its UI but must not introduce a second runtime source of truth. Do not ship a debug menu or production test-selection UI.

- [ ] Implement the Apple producer/router path, shared audio-session ownership, bounded sentence-sized utterance scheduling, global UTF-16 range conversion, and explicit paused/buffering/failure states; `willSpeak` only updates display, owned-utterance `didFinish` commits a boundary, and `didCancel`/stale callbacks never advance state; Apple primary must not touch Kokoro or Metal --> [agent: Apple playback implementer | model: gpt-5.6-luna | reasoning: xhigh] (skills: axiom-media, swift-concurrency-pro)
- [ ] Route play/pause/skip/scrub, remote commands, interruptions, owned player-item completion, and queue auto-advance through the session/router; scope end observation to the owned item rather than `object: nil`, and advance exactly once only on terminal logical-document completion (never on handoff, preparation, cancel, or stale callback) --> [agent: command-and-queue implementer | model: gpt-5.6-luna | reasoning: xhigh] (skills: axiom-media, swift-concurrency-pro)
- [ ] Make Apple controls, progress, source-position skip/scrub, and existing stats rows consume the shared session/router contracts; document estimated Apple timing and speed-estimated word semantics without silently rewriting historical rows --> [agent: player integration implementer | model: gpt-5.6-luna | reasoning: xhigh] (skills: swiftui-expert-skill, mobile-ios-design, swiftdata-pro)
- [ ] Record elapsed monotonic actual-playing wall time for the logical session, excluding previews, user pauses, interruptions, buffering, and seek gaps; preserve historical `ListeningSession` rows and label speed-estimated words without silently redefining them --> [agent: stats implementer | model: gpt-5.6-luna | reasoning: xhigh] (skills: swiftdata-pro, swift-concurrency-pro)
- [ ] Keep unknown legacy whole-document audio preserved but bypassed for Apple or selected-voice playback unless verified voice metadata proves it matches; use only the new session/router path for voice-qualified playback --> [agent: legacy-cache implementer | model: gpt-5.6-luna | reasoning: xhigh] (skills: axiom-media, swift-concurrency-pro)
- [ ] Add an internal-only voice injection seam for deterministic tests; keep it out of production navigation and picker selection --> [agent: Apple test-seam implementer | model: gpt-5.6-luna | reasoning: xhigh] (skills: swift-testing-expert, axiom-media)
- [ ] Provide a debug-only launch argument or test injection that selects an installed Apple voice for the Phase 3B iPhone checkpoint, with simple Xcode handoff instructions; remove the argument/override when the Phase 4 picker lands and never persist it as a production setting --> [agent: Apple device-seam implementer | model: gpt-5.6-luna | reasoning: xhigh] (skills: xcodebuildmcp, swift-testing-expert)
- [ ] Run the phase-scoped deterministic tests and an iPhone build, recording selected versus executed tests and handing off the debug-only voice-selection steps for the user checkpoint --> [agent: Phase 3B test-runner | model: gpt-5.6-luna | reasoning: xhigh] (skills: swift-testing-expert, xcodebuildmcp)
- [ ] Independently review Apple session ownership, `willSpeak` semantics, UTF-16 ranges, utterance-rate timing, stats compatibility, and the no-Kokoro-on-Apple-primary invariant --> [agent: independent Phase 3B reviewer | model: gpt-5.6-luna | reasoning: xhigh] (skills: axiom-media, swift-concurrency-pro, swiftdata-pro)
- [ ] Re-review fixes and verify that preview/test seams cannot become a production voice-selection path --> [agent: Phase 3B review-fix reviewer | model: gpt-5.6-luna | reasoning: xhigh] (skills: swiftui-expert-skill, swift-testing-expert)

Apple planning references (constraints, not proof of device behavior): [usesApplicationAudioSession](https://developer.apple.com/documentation/avfaudio/avspeechsynthesizer/usesapplicationaudiosession), [AVSpeechUtterance.rate](https://developer.apple.com/documentation/avfaudio/avspeechutterance/rate), and [`speechSynthesizer(_:willSpeakRangeOfSpeechString:utterance:)`](https://developer.apple.com/documentation/avfaudio/avspeechsynthesizerdelegate/speechsynthesizer(_:willspeakrangeofspeechstring:utterance:)). The callback is generally an about-to-speak, word-sized signal, not audio completion. Physical verification remains required.

Device checkpoint (before Phase 4):

1. Apple Enhanced and Premium test voices speak the selected document while Kokoro/Metal remains uninitialized; expected: no Kokoro generation log or GPU work.
2. Highlighting advances from global UTF-16 ranges and does not jump on emoji/combining-mark text; expected: source highlight is monotonic between intentional seeks and aligned enough for the documented estimate.
3. Pause, interruption, route loss, and resume preserve one logical session; expected: no duplicate utterances, `didCancel`/stale callbacks do not advance the cursor, and no new stats row is created for an interruption alone.
4. Changing speed while Apple is speaking; expected: the pending rate applies to the next utterance/sentence (or the documented safe-cursor restart), never by mutating an AVPlayer rate.
5. Lock the device and use native background/lock-screen controls, then finish an item with another queued document; expected: Apple playback and owned-item completion remain live, only the intended next document advances, and no unverified timer guarantee is assumed.

## Phase 4 — unified picker, previews, preferences, and cache policy

**Scope and ownership:** replace only the current picker/preferences integration. Keep the current English-only catalog rules and existing Kokoro generation/cache pipeline.

- [ ] Build one accessible picker with a primary selector offering Kokoro plus eligible Apple voices and a separate fallback selector offering only the same eligible Apple Enhanced/Premium subset, with eligibility/loading/error states, scope disclosure, and no default-quality/novelty/Personal Voice rows --> [agent: picker implementer | model: gpt-5.6-luna | reasoning: xhigh] (skills: swiftui-expert-skill, mobile-ios-design)
- [ ] Route all preference reads/writes through the prospective primary plus independently persisted fallback store; preserve opaque Apple identifiers, refresh eligibility on the existing voice-change observation, migrate legacy `kokoroVoice` once, and never let a legacy whole-document cache choose the active voice --> [agent: preference/cache implementer | model: gpt-5.6-luna | reasoning: xhigh] (skills: swiftdata-pro, swift-concurrency-pro)
- [ ] Implement one-at-a-time previews: fixed sample text spoken by `AVSpeechSynthesizer` for Apple, generate the Kokoro fixed sample on first request then cache/reuse it, shared audio session, cancellation on dismissal/background, and explicit reader pause/resume policy with no surprise auto-resume --> [agent: preview implementer | model: gpt-5.6-luna | reasoning: xhigh] (skills: axiom-media, swiftui-expert-skill)
- [ ] Remove destructive selection behavior from the implementation path: do not delete unrelated cache files, cancel the current reader, restart the session, or seek merely because a preference changed --> [agent: cache-policy implementer | model: gpt-5.6-luna | reasoning: xhigh] (skills: swift-concurrency-pro, axiom-media)
- [ ] Verify primary/fallback independence and conservative cache behavior: changing either selector leaves the other preference untouched, a new session snapshots both, unknown voice-less whole-document audio is preserved but bypassed, and no selected-voice cache is deleted --> [agent: preference/cache test implementer | model: gpt-5.6-luna | reasoning: xhigh] (skills: swift-testing-expert, swiftdata-pro)
- [ ] Run focused picker/preference/preview tests and an iPhone build, recording catalog refresh, migration, cache-preservation, and preview audio-session results before the user checkpoint --> [agent: Phase 4 test-runner | model: gpt-5.6-luna | reasoning: xhigh] (skills: swift-testing-expert, xcodebuildmcp)
- [ ] Independently review picker eligibility, accessibility, migration, snapshot timing, preview audio-session restoration, cache preservation, and the explicit resume policy --> [agent: independent Phase 4 reviewer | model: gpt-5.6-luna | reasoning: xhigh] (skills: swiftui-expert-skill, mobile-ios-design, axiom-media)
- [ ] Re-review fixes, especially any change touching selection handlers or cache deletion, and confirm the current session is unchanged after preference edits --> [agent: Phase 4 review-fix reviewer | model: gpt-5.6-luna | reasoning: xhigh] (skills: swift-concurrency-pro, swift-testing-expert)

Device checkpoint (before Phase 5):

1. Open the picker during Kokoro playback and select a different primary; expected: current run continues from its snapshot, with no deletion, restart, or cursor jump.
2. Preview Apple, dismiss/background, then return; expected: preview is cancelled, the app audio session is restored, and the reader remains paused until the user taps Play.
3. Preview a Kokoro voice twice; expected: the first request generates and caches the fixed sample, the second reuses that cache, and no parallel Kokoro generation starts.
4. Remove or make the chosen Apple voice unavailable in Settings, then refresh the picker; expected: it is not selectable, resolver fallback is visible/recoverable, and default quality never appears as a row.

## Phase 5 — one-way background fallback

**Scope and ownership:** make Kokoro-primary playback hand off one-way to Apple before starvation while preserving a single session. Once Apple fallback starts in this phase, it remains audible through the rest of the document; foreground Kokoro preparation/handback is Phase 6. Background Metal safety remains; a lifecycle timer is not treated as guaranteed scheduling.

- [ ] Add lifecycle-aware lookahead using wall time (`buffered media seconds / actual playback rate`) and a bounded Apple fallback estimate, including measured cold Apple startup/scheduling jitter and lifecycle/item/rate events; verify trigger liveness while locked and do not rely on a background timer alone --> [agent: fallback implementer | model: gpt-5.6-luna | reasoning: xhigh] (skills: axiom-media, swift-concurrency-pro)
- [ ] Choose the last safe existing sentence boundary before runway expiry; if there is insufficient runway, use the next-unspoken UTF-16 cursor derived from the active Kokoro item time/timestamps, not stale UI highlighting, then stop the outgoing producer before starting Apple while preserving suffix/global offsets --> [agent: handoff-boundary implementer | model: gpt-5.6-luna | reasoning: xhigh] (skills: axiom-media, swift-concurrency-pro)
- [ ] Add diagnostic-only handoff IDs/timestamps and recoverable-pause behavior for missing/failing fallback voices; cap retries and save the source cursor --> [agent: reliability implementer | model: gpt-5.6-luna | reasoning: xhigh] (skills: swift-concurrency-pro, axiom-media)
- [ ] Run focused fallback/cursor tests and an iPhone build, then measure locked-screen behavior beyond the Kokoro buffer, skipped/repeated words, and audible gap; if trigger liveness fails, mark the phase blocked rather than accepting a “when device permits” result --> [agent: Phase 5 test-runner | model: gpt-5.6-luna | reasoning: xhigh] (skills: swift-testing-expert, xcodebuildmcp)
- [ ] Independently review lifecycle races, buffer math, boundary selection, stale callback rejection, failure recovery, and the absence of any instant/gapless guarantee --> [agent: independent Phase 5 reviewer | model: gpt-5.6-luna | reasoning: xhigh] (skills: axiom-media, swift-concurrency-pro)
- [ ] Re-review fixes on a device-oriented diff and confirm diagnostics contain IDs/timing only, not private text --> [agent: Phase 5 review-fix reviewer | model: gpt-5.6-luna | reasoning: xhigh] (skills: swift-testing-expert, xcodebuildmcp)

Device checkpoint (before Phase 6):

1. Start Kokoro with a short lookahead, lock the device, and wait beyond the buffer; expected: Apple begins before starvation, remains audible through document end, and no duplicate producer appears. If the supported device cannot meet the trigger, record the failure and block the phase.
2. Background while Kokoro generation is in flight near the fallback transition; expected: Apple remains audible and Kokoro does not start Metal work after the lifecycle pause.
3. Let Kokoro fail or remove the preferred fallback voice; expected: resolver tries same-locale eligible Apple, then compatible default, and pauses recoverably at a saved cursor only if all choices fail; retries are bounded.
4. Use headphones/route changes and an interruption around handoff; expected: no duplicate audio, incorrect auto-resume, unrelated queue advance, or hidden cursor regression.

## Phase 6 — foreground Kokoro handback

**Scope and ownership:** hand back only at an existing sentence boundary when the prepared Kokoro chunk is genuinely ready. Continue Apple if readiness misses the eligible boundary.

- [ ] Add a preparation-only Kokoro consumer/mode so speculative chunks cannot auto-play or take ownership while Apple is audible; if the eligible boundary passes first, discard the target and choose a future existing sentence boundary --> [agent: preparation-mode implementer | model: gpt-5.6-luna | reasoning: xhigh] (skills: swift-concurrency-pro, axiom-media)
- [ ] Prepare the next eligible Kokoro sentence without taking playback ownership, then atomically hand back at the committed boundary only when the session, document, voice, and callback generation still match; otherwise Apple continues --> [agent: handback implementer | model: gpt-5.6-luna | reasoning: xhigh] (skills: swift-concurrency-pro, axiom-media)
- [ ] Invalidate only speculative prepared audio/callbacks on a new session, intentional seek/source reset, interruption restart, re-background, or document change; ordinary pause/background preserves valid queued Kokoro playback audio, while pause may cancel speculative preparation only; clear existing audio only for intentional seek/new-session/source-reset transitions, and keep persisted preference changes out of the active snapshot --> [agent: handback invalidation implementer | model: gpt-5.6-luna | reasoning: xhigh] (skills: swift-concurrency-pro, swift-testing-expert)
- [ ] Preserve controls, stats, source position, and word highlighting across Apple-to-Kokoro handback without claiming exact word/gapless continuity --> [agent: continuity implementer | model: gpt-5.6-luna | reasoning: xhigh] (skills: axiom-media, swiftui-expert-skill, swiftdata-pro)
- [ ] Run focused handback/cancellation tests and an iPhone build, recording sentence-boundary readiness, seek/re-background invalidation, and Apple continuation when Kokoro is late --> [agent: Phase 6 test-runner | model: gpt-5.6-luna | reasoning: xhigh] (skills: swift-testing-expert, xcodebuildmcp)
- [ ] Independently review boundary selection, preparation-only mode, stale prepared-file rejection, Apple continuation when late, and one-session statistics --> [agent: independent Phase 6 reviewer | model: gpt-5.6-luna | reasoning: xhigh] (skills: swift-concurrency-pro, axiom-media)
- [ ] Re-review fixes and require device evidence for any continuity claim; downgrade language to a goal when timing is not directly observed --> [agent: Phase 6 review-fix reviewer | model: gpt-5.6-luna | reasoning: xhigh] (skills: xcodebuildmcp, swift-testing-expert)

Device checkpoint (before Phase 7):

1. Foreground after a successful Kokoro preparation; expected: handback occurs at the next existing sentence boundary, not mid-sentence.
2. Foreground after preparation misses its boundary; expected: Apple continues and no stale Kokoro chunk becomes audible later.
3. Seek while a handback is prepared, then background/foreground; expected: speculative audio/callbacks are invalidated, valid queued Kokoro audio survives an ordinary background, and playback follows the new source cursor after the intentional seek.
4. Change the persisted preference during an active handoff; expected: the current snapshot is unchanged and the next logical session uses the new preference.

## Phase 7 — focused regression, accessibility, performance, and release evidence

- [ ] Add focused pure tests for resolver fallback, session snapshots, rate scheduling, cursor mappings, stats transitions, cache key/preservation rules, and stale callback rejection; retain existing stats rows and document the meaning of new actual-active fields if added --> [agent: regression-test implementer | model: gpt-5.6-luna | reasoning: xhigh] (skills: swift-testing-expert, swiftdata-pro)
- [ ] Exercise picker VoiceOver labels, selected state, unavailable/download messaging, preview cancellation, pause/resume policy, dynamic type, and reduced-motion behavior --> [agent: accessibility implementer | model: gpt-5.6-luna | reasoning: xhigh] (skills: swiftui-expert-skill, mobile-ios-design)
- [ ] Profile generation, queue depth, AVSpeech scheduling, preview teardown, memory/Metal pressure, and main-actor stalls on representative physical devices; report observed results and limitations --> [agent: performance test-runner | model: gpt-5.6-luna | reasoning: xhigh] (skills: xcodebuildmcp, axiom-media, swift-concurrency-pro)
- [ ] Run the final deterministic test set and iPhone build, then hand off the final user manual checkpoint and evidence matrix; never report a selected-but-unexecuted test as passed --> [agent: Phase 7 test-runner | model: gpt-5.6-luna | reasoning: xhigh] (skills: swift-testing-expert, xcodebuildmcp)
- [ ] Independently review the final diff and evidence matrix against every invariant, including no runtime cloud, no Apple-primary Kokoro initialization, cache preservation, and honest wording about timing/continuity --> [agent: independent Phase 7 reviewer | model: gpt-5.6-luna | reasoning: xhigh] (skills: swift-testing-expert, xcodebuildmcp)
- [ ] Re-review final fixes and publish a concise device matrix with OS/device/voice/lifecycle result, failed or unexecuted tests, and any blocked acceptance claim --> [agent: Phase 7 review-fix reviewer | model: gpt-5.6-luna | reasoning: xhigh] (skills: xcodebuildmcp, swift-testing-expert)

Final user checkpoint:

1. Exercise one representative Kokoro voice plus installed Apple Enhanced and Premium voices when available; expected: controls stay stable, preview never leaves a second producer audible, and hidden handoffs do not change the UI source. Record any unavailable Apple tier as untested rather than inferring support.
2. Run Kokoro primary through lock-screen fallback and return to foreground; expected: Apple fallback is audible before starvation, handback is only at a valid sentence boundary when ready, and late preparation leaves Apple playing.
3. Change persisted primary/fallback preferences during playback and start a new document/session; expected: the current snapshot is unchanged and the new session uses the latest preferences without deleting unrelated caches.
4. Use the app offline with an uninstalled Apple voice; expected: no cloud request, Settings/download guidance for the OS voice, resolver repair/fallback, and recoverable pause only if all eligible choices fail.

**Astra final gate (gpt-6-astra, high):** accept only evidence-backed behavior. “No silence,” “instant,” “gapless,” “exact word continuity,” and “background timer guaranteed” remain non-claims unless directly demonstrated on the supported physical-device matrix. Keep blocked or unexecuted evidence visible rather than converting it to a pass.

## Stated defaults (not blockers)

1. Preview pauses reading and leaves it paused until the user taps Play. Dismissing a preview never auto-resumes the reader.
2. Apple speed changes apply to the next sentence/utterance. A safe-cursor restart is out of scope unless a later product decision explicitly accepts its boundary behavior.
3. A missing saved fallback is shown inline with Settings repair guidance. Runtime still tries the same-locale eligible voice and compatible system default silently; it pauses recoverably only when all choices fail, with bounded retries.
4. Preserve existing stats labels and rows. Identify actual-active wall time and speed-estimated words as estimates where applicable; do not silently reinterpret historical records or block the plan on optional wording polish.
