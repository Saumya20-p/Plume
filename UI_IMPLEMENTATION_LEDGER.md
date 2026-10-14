# UI implementation ledger

This ledger maps the recommendations in [UI_DESIGN_AUDIT.md](UI_DESIGN_AUDIT.md) to the current implementation. It does not replace or revise the audit. **Implemented** describes code present in the experiment; **runtime evidence** describes what has actually been exercised. Those are separate claims.

## Implementation map

| Finding | Implementation in this experiment | Status / limits |
|---|---|---|
| C1 Font Style | `Plume/Plume/ReaderFont.swift`, `AppearanceSettings.swift`, `AppearanceSettingsView.swift`, `PlayableTextView.swift`, `PlayerView.swift` | Implemented: selected reader font now reaches the rendered text. Host contract tests passed; reader UI behavior exercised in the iOS 27 focused run. |
| C2 Empty-folder import destination | `Plume/Plume/MainTabView.swift`, `FolderDetailView.swift`, `AddURLView.swift`, `ImportContracts.swift`, `ImportFileParser.swift`, `ContentExtractor.swift`, `EPUBParser.swift` | Implemented: folder-aware import destinations are carried through relevant import paths. Folder import succeeded in UI automation; its subsequent search assertion initially used an incorrect test label (`Search Chapters` vs `Search All Chapters`), was corrected, and is being rerun. |
| C3 Streamed audio cache accounting and clearing | `Plume/Plume/AudioCacheStore.swift`, `SettingsView.swift`, `Document.swift`, `AudioGenerationManager.swift`, `AudioPlaybackEngine+State.swift`, `KokoroTTSService.swift`, `StorageManager.swift` | Implemented: shared cache accounting/clear flow includes generated cache entries and protects active writers. Host contract tests passed, including concurrent clearing coverage added in the latest rerun (result pending). No MLX synthesis was simulated. |
| C4 Import failure and recovery | `Plume/Plume/AddURLView.swift`, `WebViewFetcher.swift`, `ImportContracts.swift`, `ImportFileParser.swift`, `ImportArtwork.swift`, `MainTabView.swift`, `ManualPasteView.swift` | Implemented: validation, visible failures, retry/manual routes, cancellation, and file-import error handling are present. Host import contracts passed; UI exercised invalid URL and import flows on iOS 27. Network timing and all external-site behaviors remain environment dependent. |
| C5 Accessible player timeline | `Plume/Plume/PlayerView.swift` | Implemented: timeline exposes playback position and duration plus adjustable accessibility actions. iOS 27 focused behavior tests passed; actual VoiceOver interaction on a device remains pending. |
| C6 Adaptable Appearance and Speed sheets | `Plume/Plume/AppearanceSettingsView.swift`, `SpeedSettingsView.swift` | Implemented: sheet content can expand/scroll to support larger text and compact layouts. iOS 27 UI checks covered expanded sheets and landscape. iOS 26.5 rendering/testing remains pending. |
| C7 Accessibility semantics for custom controls | `Plume/Plume/VoiceSettingsView.swift`, `AppearanceSettingsView.swift`, `PlayerView.swift`, `LibraryView.swift` | Implemented in source for named voice actions, selection state, theme state, sliders, and player controls. This is source evidence only; actual VoiceOver and Switch Control behavior remains unverified on device. |
| C8 Stats range consistency and short durations | `Plume/Plume/StatisticsRange.swift`, `ListeningStatisticsView.swift` | Implemented: summaries, chart filtering/domain, labels, and averages share a range definition; positive sub-minute durations have a distinct label. Host tests passed; iOS 27 Stats UI was exercised. |
| C9 Search/filter context and empty states | `Plume/Plume/LibrarySearchContracts.swift`, `LibraryView.swift` | Implemented: search spans folders, scope can be cleared, and empty search/filter states have contextual copy. Host search contract tests passed. UI continuation for folder import/search is rerunning after correcting the test label. |
| C10 Reader follow after manual browsing | `Plume/Plume/ReaderFollowContract.swift`, `PlayableTextView.swift`, `PlayerView.swift` | Implemented: manual browsing remains until explicit return to the current word; Reduce Motion is respected for reader follow and player animation. Reader UI and automatic-follow comparison were exercised on iOS 27. Physical-device motion/accessibility verification remains pending. |
| C11 Theme state with Match Device | `Plume/Plume/AppearanceSettings.swift`, `AppearanceSettingsView.swift` | Implemented: displayed selection reflects the applied theme while preserving the manual choice. Host contract tests and three-theme UI checks passed on iOS 27. |
| C12 Deletion wording and scope | `Plume/Plume/DocumentDeletion.swift`, `RecentlyDeletedView.swift`, `FolderDetailView.swift`, `LibraryView.swift`, `DeleteAllDataView.swift` | Implemented: permanent deletion is named distinctly, folder deletion explains its effect, and shared deletion handling coordinates related cleanup. Host tests passed; deletion confirmation behavior was exercised in focused UI checks. |
| Visual 1 Warm reading contrast | `Plume/Plume/AppearanceSettings.swift`, `PlayableTextView.swift` | Implemented: Warm uses a neutral dark reading color and subtler paragraph tint while retaining accent emphasis. Three-theme iOS 27 UI checks passed; rendered contrast at all text sizes and on physical displays remains pending. |
| Visual 2 Bottom reading veil | `Plume/Plume/PlayerView.swift`, `VariableBlurView.swift` | Implemented: veil transition was shortened and consolidated. iOS 27 reader rendering was exercised, including return behavior; iOS 26.5 comparison and physical-device rendering remain pending. |
| Visual 3 Distinguishable player exits | `Plume/Plume/PlayerView.swift` | Implemented: minimize and stop/close now have distinct labels and symbols. iOS 27 focused UI behavior passed; physical accessibility verification remains pending. |
| Visual 4 Add action placement / content clearance | `Plume/Plume/MainTabView.swift`, `LibraryView.swift`, `ListeningStatisticsView.swift` | Implemented: Add is library-scoped and content reserves room for the persistent dock. UI exercised on iOS 27; broad reachability at all text sizes/device sizes remains pending. |
| Visual 5 Chapter identity in lists | `Plume/Plume/LibraryView.swift`, `QueueSheetView.swift` | Implemented: browsing titles can wrap and imported items receive a truthful generic source label. Host and iOS 27 library checks passed; very large text and diverse real import metadata need device/content review. |
| Visual 6 Voice-setting copy | `Plume/Plume/VoiceSettingsView.swift` | Implemented: playback snapshot/fallback messaging was shortened and reframed around listening outcomes. Source/UI rendering evidence only; no dedicated copy comprehension study. |
| Visual 7 Short listening sessions in Stats | `Plume/Plume/StatisticsRange.swift`, `ListeningStatisticsView.swift` | Implemented: positive sub-minute time displays as `<1 min`, and charts include totals and accessible values. Host tests and iOS 27 Stats UI checks passed. |
| Visual 8 Library header hit targets | `Plume/Plume/LibraryView.swift` | **Not established as resolved.** Header actions now have explicit labels and remain in a compact row, but the experiment has no verified 44-point target/layout result across text sizes. Audit concern remains open pending rendered hit-region inspection. |

## Verification record

Evidence recorded for this experiment as of October 14, 2026:

- Host XCTest and Swift Testing: an earlier run after reader/import contract additions reported 63 XCTest and 20 Swift Testing tests passing. The latest host rerun has a Swift Testing failure in a 21-test run; investigation is pending, so the earlier counts do not represent final verification.
- iOS 27 simulator: initial focused run of 19 behavior tests passed; 3 of 4 UI tests passed in the initial run. UI checks exercised expanded sheets, landscape, invalid URL and Stats states, all three themes, paused Return-to-current-word, and folder import. The folder import/search continuation is rerunning after correcting its test query to the actual `Search All Chapters` accessibility label.
- iOS 26.5 simulator rendering/testing is pending.
- Simulator build/run requires `scripts/prepare-ui-simulator.py` to apply the exact upstream MLX #354 two-header weak-link fix to a **disposable** derived-data dependency checkout. Lockfile version 0.30.2 is unchanged. There is no clean, unpatched simulator success to report. The workaround only addresses simulator linking; it does not emulate or verify MLX synthesis.
- SwiftData schema is unchanged from baseline `2709f20` (`checkpoint/antigravity-complete`).
- Physical iPhone playback/background behavior, real VoiceOver interaction, Reduce Motion, transparency settings, and final recording gates remain pending. No finding should be marked device-verified from source inspection or simulator rendering alone.

## Repeatable checks

Use the `Plume` scheme and the applicable simulator destination for the focused unit/UI checks. Prepare only the disposable DerivedData checkout used by the simulator build:

```sh
python3 scripts/prepare-ui-simulator.py /tmp/plume-ui-build
```

Launch arguments for deterministic visual/behavior inspection:

```text
--ui-experiment-fixture       In-memory SwiftData fixture; does not open the user's persistent store
--ui-experiment-reader        Opens the fixture reader paused at a known word
--ui-experiment-large-text    Accessibility Dynamic Type and bold legibility fixture
--reader-edge-automatic      Comparison mode for automatic reader-follow behavior
```

The first three flags are implemented in `Plume/Plume/UIExperimentFixture.swift` and the reader UI tests. `--reader-edge-automatic` is a comparison launch argument used by the UI experiment. Do not treat fixture rendering as evidence of synthesis, background playback, physical accessibility behavior, or persistent-store migration.
