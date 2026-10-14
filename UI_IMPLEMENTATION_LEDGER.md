# UI implementation ledger

Experiment: `experiment/ios27-ui-ux`. Baseline and `checkpoint/antigravity-complete`: `2709f20`. Minimum OS: iOS 26. Main remains at the baseline; no merge is authorized. SwiftData persisted fields and relationships are unchanged.

This records implementation separately from verification against [UI_DESIGN_AUDIT.md](UI_DESIGN_AUDIT.md). The subsequent five player corrections are recorded in [UI_PLAYER_RESTORATION.md](UI_PLAYER_RESTORATION.md); that report supersedes the earlier reader-edge and exit-icon choices below. The user's accepted plan overrides C10's original recommendation: automatic return remains, after three seconds of inactivity with suspension and stale-callback protection.

## Implementation map

| Audit finding | Result and primary source | Verification / remaining limit |
|---|---|---|
| C1 Font Style | [ReaderFont.swift](Plume/Plume/ReaderFont.swift), [PlayableTextView.swift](Plume/Plume/PlayableTextView.swift): real font families; migration preserves Georgia; app size/bold combines with Dynamic Type and system bold. | Migration contracts passed; normal and accessibility5 reader renders checked. |
| C2 Folder import destination | [ImportContracts.swift](Plume/Plume/ImportContracts.swift), [MainTabView.swift](Plume/Plume/MainTabView.swift): captured folder identity survives extraction, retry, and manual fallback. EPUB appends to a destination or creates a book folder from Library. Removed destinations fail visibly. | Destination/cancellation contracts and folder paste/search UI passed. External Files-provider and diverse EPUB content coverage is limited. |
| C3 Cache accounting and safe clear | [AudioCacheStore.swift](Plume/Plume/AudioCacheStore.swift): chunks and consolidated audio counted; current chapter and live writers protected, including canceled tasks until completion. Main-actor protection check and quarantine precede detached deletion; failed quarantine entries can be retried. [Document.swift](Plume/Plume/Document.swift) checks file availability anew. | Concurrent clear, canceled-writer, quarantine/new-writer, and retained-byte contracts passed. Consolidated synthesis also holds a writer lease. |
| C4 Import recovery | [AddURLView.swift](Plume/Plume/AddURLView.swift), [WebViewFetcher.swift](Plume/Plume/WebViewFetcher.swift), [ImportArtwork.swift](Plume/Plume/ImportArtwork.swift): visible errors/cancel/retry/manual recovery; 30-second end-to-end extraction deadline; file coordination/parsing off main; bounded optional artwork. | Deadline and cancellation return while CPU workers remain blocked; invalid-link/manual UI passed. No claim that every external site works. |
| C5 Timeline | [PlayerView.swift](Plume/Plume/PlayerView.swift): named position/duration, adjustable accessibility actions, 44-point gesture region. | UI element/value exercised; actual VoiceOver adjustment pending user hands-on check. |
| C6 Settings overflow | [AppearanceSettingsView.swift](Plume/Plume/AppearanceSettingsView.swift), [SpeedSettingsView.swift](Plume/Plume/SpeedSettingsView.swift): expandable, scrollable sheets, adaptive choices and wrapped labels. | iOS 26.5 and 27 landscape and accessibility5 reachability checked; final render fixes recorded below. |
| C7 Accessibility semantics | Theme/voice selected traits; separately named voice preview and selection; named player/header controls and slider values. | Source and accessibility hierarchy checked. Real VoiceOver, motion, and transparency gate remains open. |
| C8 Stats ranges | [StatisticsRange.swift](Plume/Plume/StatisticsRange.swift), [ListeningStatisticsView.swift](Plume/Plume/ListeningStatisticsView.swift): one range definition drives labels, chart domain/filtering, totals, and averages. | Host range tests and Stats UI passed. |
| C9 Search/context | [LibrarySearchContracts.swift](Plume/Plume/LibrarySearchContracts.swift), [LibraryView.swift](Plume/Plume/LibraryView.swift): all active chapters searchable across folders; visible filters, folder context, active counts and reset/empty states. | Host search contracts and folder import/search UI passed. |
| C10 Follow/browse | [ReaderFollowContract.swift](Plume/Plume/ReaderFollowContract.swift): Return appears on manual browsing; explicit Return works paused; three-second inactivity resets on interaction. Pause/background/sheets/VoiceOver suspend automatic return; revisions reject stale callbacks; Reduce Motion avoids animated scrolling. | Follow timing contracts and three-theme paused Return UI passed. Physical accessibility interaction pending. |
| C11 Effective theme | [AppearanceSettings.swift](Plume/Plume/AppearanceSettings.swift): effective Match Device theme drives displayed selection; manual preference retained. | Corrected fixture asserts selected trait for each of Basic/Warm/Muted. Earlier launch-argument-only theme evidence was invalid and replaced. |
| C12 Deletion | [DocumentDeletion.swift](Plume/Plume/DocumentDeletion.swift): permanent wording, queue removal, missing-entry skipping, current playback release, writer drain before deleting data. Auto-purge shares the same path. | Queue and isolated permanent-deletion tests passed, including an outstanding writer. Full destructive UI confirmation flow has not been automated. |
| Visual 1 Warm contrast | Dark brown reader text and subtle brown paragraph tint, accent/white active word retained. | Correct three-theme screenshots reviewed; physical highlight captured. |
| Visual 2 Reader/player edge | Native UITextView and contained UIHostingController retained; measured dock clearance and one public gradient-masked material restore the intentional progressive veil. Native bottom edge disabled to avoid overlap. | Final follow-up screenshots, recordings, and checks are in [UI_PLAYER_RESTORATION.md](UI_PLAYER_RESTORATION.md). |
| Visual 3 Player exits | Minimize uses down chevron; X releases playback and closes player. | Physical follow-up tested X release/close and minimize/reopen; accessibility labels retained. |
| Visual 4 Contextual Add | Library/folder-specific Add; mini-player safe-area inset reserves its measured space. | Folder UI passed; screenshot clearance checked. |
| Visual 5 Chapter identity | Two-line titles, folder context and truthful imported-text labels. Mini-player display values snapshot model data to avoid rendering deleted SwiftData instances. | Library UI and deletion lifecycle tests passed. |
| Visual 6 Voice copy | [VoiceSettingsView.swift](Plume/Plume/VoiceSettingsView.swift): listening-focused copy; selecting voice is separate from previewing. | Source review; no comprehension study claimed. |
| Visual 7 Short sessions | Positive subminute listening displays `<1 min`; accessible chart totals/values. | Host and Stats UI passed. |
| Visual 8 Header targets | Native toolbar actions have explicit names and minimum 44-point targets. Reader presentation has its own background so Library content cannot bleed through navigation glass. | Source target dimensions and final landscape renders checked. |

## Verification record — October 14, 2026

- Host package: **63 XCTest + 21 Swift Testing tests passed**, including cache races, imports/deadlines, search/ranges, font migration and follow timing. Log: `/tmp/plume-host-tests-final.log`.
- Earlier iOS 26.5 focused run: **28 tests passed** (UI and behavior contracts). Later corrected theme/large-text fixture checks replace the earlier misleading visual evidence, rather than relying on those screenshots.
- iOS 26.5 final playback lifecycle suite: **5 passed**. Covers preserved play intent during handoff cancellation, stale fallback after release, stale seek on chapter switch/same-chapter reload, and permanent deletion with an outstanding writer. Result: `test_sim_2026-10-14T22-11-33-066Z_pid72904_c8d6471a.xcresult`.
- iOS 26.5 corrected three-theme/paused Return UI passed; final landscape/large-text UI passed after screenshot review found and fixed duplicate navigation, clipped dock text/symbols, and overflowing remaining-time copy. A handoff test initially reused an invalidated generation gate; correcting the fixture and activating a fresh gate made the ordinary-cancellation comparison valid.
- iOS 27 corrected three-theme/paused Return, landscape and accessibility5 sheet tests passed. Final layout rerun result is recorded in [ui-evidence/README.md](ui-evidence/README.md).
- Physical iPhone “Saumya,” iOS 27: **playback/seek/two background round trips/pause/settings/Stop test passed**, using clean, unpatched dependencies. Result: `test_device_2026-10-14T22-07-02-675Z_pid72904_5af579af.xcresult`. This reproduced two real failures first: delayed seek reset play intent, and generation cancellation paused intent before fallback. Fixes restore intent after regeneration, preserve it during handoff, and keep Apple Speech flowing until replacement audio is ready. A subsequent guard against delayed fallback restarting a released session passed the isolated lifecycle test.
- Screenshots and scrolling video are in [ui-evidence](ui-evidence/README.md). Earlier false large-text/theme captures were replaced; app-only landscape screenshots were replaced by full-screen captures after rotation.
- Xcode result bundles/logs remain locally under `~/Library/Developer/XcodeBuildMCP/workspaces/Plume-ccf85facdece/`; these are build artifacts and are excluded from git.
- Simulator dependency workaround: [prepare-ui-simulator.py](scripts/prepare-ui-simulator.py) applies the upstream [MLX #354](https://github.com/ml-explore/mlx-swift/pull/354) two-header weak-link fix to a disposable DerivedData checkout. Lockfile stays at 0.30.2. Simulator checks do not verify MLX synthesis. Device dependencies are unmodified.
- Existing Swift 5-mode concurrency warnings and audio-session activation warnings remain; this experiment does not claim a full Swift 6 migration or audio-session performance audit.

## Unfinished gates

The user is checking real VoiceOver, Reduce Motion, and Reduce Transparency on the physical iPhone. Until results arrive, that acceptance gate remains unfinished. Broad external-site/Files-provider/EPUB coverage and destructive confirmation UI are also not claimed as exhaustive. No merge has occurred.

## Repeatable inspection

Use the Plume scheme with iOS 26.5 or 27 and an isolated fixture:

```text
--ui-experiment-fixture       In-memory models, isolated audio/queue/appearance storage; skips shared inbox
--ui-experiment-reader        Opens fixture reader paused at a known highlighted word
--ui-experiment-large-text    accessibility5 and bold, including presented sheets
--ui-experiment-position     Gives the paused fixture a visible progress/buffer position
--ui-experiment-reduce-motion       Forces the reader reduced-motion presentation branch
--ui-experiment-reduce-transparency Forces the reader opaque presentation branch
```

The focused UI tests explicitly initialize and assert theme selection. Physical playback uses Kokoro `af_heart`; UI tests do not delete the user's library. Worker changes were integrated from isolated worktrees; scratch files and build output remain excluded.
