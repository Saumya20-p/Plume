# Plume UI/UX audit — screenshots and implementation

Reviewed October 14, 2026, using `apple-design`, `swiftui-native-design-27`, and `swiftui-expert-skill`.

## Assessment

**The visual identity is coherent; the implementation has several user-facing defects and accessibility risks.** The expanded code review confirms that Font Style has no effect, importing from an empty folder does not populate that folder, streamed audio is omitted from cache management, and failed imports can produce no visible explanation. The player timeline also lacks an accessible adjustment interface. Address these alongside the two reading improvements: Warm-theme contrast and the amount of content covered by the bottom veil.

Plume's quiet dark surfaces, rosewood accent, Georgia reading text, and prominent playback button are worth preserving. This report recommends specific improvements rather than a replacement visual identity.

This is a review of the supplied 1000 × 1000 collage and the app's UI implementation. The collage has six screens in its first and second rows, and five in its third. Screen references below use those row and column positions. Screens are reduced to roughly 154–196 pixels wide; apparent small type is not proof of an undersized original interface. The local image path supplied with the attachment was unavailable, so screenshot measurements and pixel sampling were not performed. The attached image itself was inspected.

No app implementation was changed. No build, simulator session, device interaction, or accessibility test was run. Source code can corroborate a visual finding but cannot prove that the supplied screenshots reflect the latest build.

## Scope and evidence

Reviewed the app entry and shell; Library and document rows; folder detail; full and mini players; the UIKit reading surface; Appearance, Voice, Speed, and Settings screens; Up Next; statistics; URL and text import; Recently Deleted; and Delete All Files. Traced the relevant preferences, folder relationships, queue identity, and audio-cache paths where these affect what the interface promises.

Audio synthesis, Metal lifecycle correctness, broad security, and dependency correctness were not independently audited. This is a UI/UX implementation review, not a replacement for the audio handoff's physical-device validation.

**Evidence labels:** confirmed means the behavior follows directly from the current source; risk means the problematic structure exists but its runtime effect needs verification; visual judgment means a design recommendation informed by the collage. None of these labels implies device reproduction. No critical runtime accessibility or layout failure was verified from this reduced collage.

## Implementation findings

### C1. High — Font Style changes a preference that the reader never uses

**Evidence: confirmed.** The Appearance sheet in row 2, column 3 exposes System / Serif / Rounded / Monospaced. [AppearanceSettingsView.swift:38](/Users/saumyapatel/Documents/Plume/Plume/Plume/AppearanceSettingsView.swift:38) binds the picker to `fontStyle`; [AppearanceSettings.swift:57](/Users/saumyapatel/Documents/Plume/Plume/Plume/AppearanceSettings.swift:57) persists it. The reader receives `fontFamily` in [PlayerView.swift:33](/Users/saumyapatel/Documents/Plume/Plume/Plume/PlayerView.swift:33), and constructs its actual font from that family in [PlayableTextView.swift:51](/Users/saumyapatel/Documents/Plume/Plume/Plume/PlayableTextView.swift:51). There is no consumer of the selected `fontStyle` or `FontStyle.design` in the reading path.

**User effect:** Selecting a different style updates the menu value without changing the reading text. The screenshot's “System” value can coexist with the Georgia reader default.

**Recommendation:** Connect the setting to the rendered font, with a clearly defined relationship to Georgia, or remove the nonfunctional choice until implemented. This requires a behavior fix; it is not solved by restyling the picker.

**Basis:** `feedback.md › Best practices`, reflecting the user's need to understand the result of an action.

### C2. High — The empty folder's Add instruction routes imports outside that folder

**Evidence: confirmed.** Row 2, column 6 says “Tap + to add a chapter.” [FolderDetailView.swift:30](/Users/saumyapatel/Documents/Plume/Plume/Plume/FolderDetailView.swift:30) supplies that instruction, but the visible plus belongs to the root shell in [MainTabView.swift:43](/Users/saumyapatel/Documents/Plume/Plume/Plume/MainTabView.swift:43). That shell has no active-folder parameter. Pasted text is inserted without a folder at [MainTabView.swift:125](/Users/saumyapatel/Documents/Plume/Plume/Plume/MainTabView.swift:125), PDF/TXT import does the same at [MainTabView.swift:196](/Users/saumyapatel/Documents/Plume/Plume/Plume/MainTabView.swift:196), and URL import follows the same pattern at [AddURLView.swift:90](/Users/saumyapatel/Documents/Plume/Plume/Plume/AddURLView.swift:90). EPUB import explicitly creates a new book folder at [MainTabView.swift:226](/Users/saumyapatel/Documents/Plume/Plume/Plume/MainTabView.swift:226).

**User effect:** Following the empty-state instruction can leave the current folder empty even though import succeeded.

**Recommendation:** Either give Add a folder-aware route and save destination, or change the instruction to explain adding to Library and then moving the item. Make the destination explicit. Existing Move to Folder support is at [LibraryView.swift:411](/Users/saumyapatel/Documents/Plume/Plume/Plume/LibraryView.swift:411).

**Basis:** `writing.md › Best practices`, clear next steps on empty screens. This corrects the earlier screenshot-only assessment that the empty-folder instruction was sufficient.

### C3. High — Cached Audio and Clear All omit streamed chapter files

**Evidence: confirmed.** The screenshot's “Zero KB” is consistent with a mismatch in what the UI counts. [SettingsView.swift:127](/Users/saumyapatel/Documents/Plume/Plume/Plume/SettingsView.swift:127) counts only `document.audioFileURL`, and [SettingsView.swift:153](/Users/saumyapatel/Documents/Plume/Plume/Plume/SettingsView.swift:153) clears only those files. That property addresses a consolidated `<documentID>.m4a` in [Document.swift:37](/Users/saumyapatel/Documents/Plume/Plume/Plume/Document.swift:37). Streaming instead writes `chunk_<index>_<voice>.m4a` inside the document's cache directory through [KokoroTTSService.swift:613](/Users/saumyapatel/Documents/Plume/Plume/Plume/KokoroTTSService.swift:613); [Document.swift:46](/Users/saumyapatel/Documents/Plume/Plume/Plume/Document.swift:46) defines that directory.

**User effect:** Generated chunks can occupy storage while the interface reports zero, and “Clear All Cached Audio” can leave them behind. The confirmation promises all generated audio files at [SettingsView.swift:76](/Users/saumyapatel/Documents/Plume/Plume/Plume/SettingsView.swift:76).

**Recommendation:** Define the cache scope once and use it for size calculation, clearing, and the completion message. Include streamed files and refresh the number after generation or deletion. Coordinate any eventual clearing implementation with active playback so files in use are handled intentionally.

**Basis:** `feedback.md › Best practices`, accurate status and result reporting. This is a UI promise and implementation mismatch, not just a label preference.

### C4. High — Import failure and cancellation need a visible recovery path

**Evidence: confirmed source behavior; slow-network timing unverified.** [AddURLView.swift:103](/Users/saumyapatel/Documents/Plume/Plume/Plume/AddURLView.swift:103) logs fetch failures and clears the spinner without showing an error. [AddURLView.swift:57](/Users/saumyapatel/Documents/Plume/Plume/Plume/AddURLView.swift:57) silently returns when URL construction fails; it also does not validate the intended HTTP(S) scheme and host. Cancel is disabled at [AddURLView.swift:41](/Users/saumyapatel/Documents/Plume/Plume/Plume/AddURLView.swift:41) and interactive dismissal at `:52` during extraction. Optional cover fetching is awaited with `waitsForConnectivity` enabled at `:72`.

PDF/TXT import also drops unreadable or empty content without an import error: [MainTabView.swift:190](/Users/saumyapatel/Documents/Plume/Plume/Plume/MainTabView.swift:190) suppresses read errors and `:194` inserts only nonempty text. That is especially relevant to scanned PDFs with no extracted text. These failure states are not shown in the collage.

**User effect:** Tapping Import can appear to do nothing or return to an idle form without explanation; a slow optional cover request can keep the user waiting with no enabled Cancel action.

**Recommendation:** Validate and explain invalid links; show a plain-language failure with Retry and Manual Import; expose a safe cancellation path; make optional artwork fetching independent of completion. Explain unsupported or empty file content instead of silently ignoring it.

**Basis:** `feedback.md › Best practices`: “Show people when a command can’t be carried out and help them understand why.” `loading.md › Best practices` supports letting people continue working while waiting. [Apple HIG: Feedback](https://developer.apple.com/design/human-interface-guidelines/feedback).

### C5. High — The custom timeline has no accessible adjustment interface

**Evidence: confirmed structural gap; VoiceOver behavior not device-tested.** The thin top edge of the player dock is [LiveEdgeScrubber in PlayerView.swift:385](/Users/saumyapatel/Documents/Plume/Plume/Plume/PlayerView.swift:385). Its seek interaction is a `DragGesture` on a transparent strip at [PlayerView.swift:434](/Users/saumyapatel/Documents/Plume/Plume/Plume/PlayerView.swift:434). The strip is **24 points high** despite a 44-point outer view. The implementation supplies no accessible label, playback-position value, native Slider representation, or adjustable accessibility action. The thumb only appears after dragging begins at `:425`.

**User effect:** The timeline is hard to discover visually and has no explicit assistive-technology route for setting a position. Skip buttons offer some movement but do not make this control itself accessible.

**Recommendation:** Preserve the existing seek callback, but expose the timeline as an adjustable control with position and duration, and a comfortable touch region. A native Slider or an accessibility representation can retain the compact visual treatment. Verify scrubber and button hit regions together to avoid overlap.

**Basis:** `accessibility.md › Mobility`, alternatives to gesture-only interactions; SwiftUI expert `accessibility-patterns.md › Custom Controls`.

### C6. Medium — Appearance and Speed have no adaptable overflow route

**Evidence: risk confirmed in structure; clipping is not proven from the collage.** [AppearanceSettingsView.swift:73](/Users/saumyapatel/Documents/Plume/Plume/Plume/AppearanceSettingsView.swift:73) disables Form scrolling and `:86` fixes the sheet at 650 points. [SpeedSettingsView.swift:49](/Users/saumyapatel/Documents/Plume/Plume/Plume/SpeedSettingsView.swift:49) uses a non-scrolling VStack with 32-point group spacing and a fixed 420-point sheet at `:142`. Neither supplies an expanded detent. Labels scale, but the available presentation height does not provide a matching scroll route.

**User effect:** Larger accessibility text or compact-height contexts can make lower settings unreachable. The collage alone cannot prove whether the bottom of the Speed sheet is clipped in the original capture.

**Recommendation:** Let these settings scroll, permit expansion when needed, and reduce spacing at compact heights. Keep the current compact presentation when all content fits. Verify the largest supported text sizes and landscape.

**Basis:** `layout.md › Adaptability` and `typography.md › Supporting Dynamic Type`.

### C7. Medium — Several custom actions need explicit accessibility semantics

**Evidence: risk; synthesized system announcements unverified.** Voice selection is attached to an HStack tap gesture at [VoiceSettingsView.swift:463](/Users/saumyapatel/Documents/Plume/Plume/Plume/VoiceSettingsView.swift:463) and `:504`, while preview is a separate Button. The main mini-player opening action is an HStack tap at [MainTabView.swift:369](/Users/saumyapatel/Documents/Plume/Plume/Plume/MainTabView.swift:369). Neither path explicitly supplies a named accessibility action for its task. The player icon controls likewise mostly rely on symbol-derived labels; queue and voice intent deserve explicit names.

Appearance sliders at [AppearanceSettingsView.swift:50](/Users/saumyapatel/Documents/Plume/Plume/Plume/AppearanceSettingsView.swift:50) and `:62` have neighboring visible headings but no explicit semantic label/value pairing. Theme cards show selection through a color border without a selected accessibility trait. The reader builds its font directly at [PlayableTextView.swift:51](/Users/saumyapatel/Documents/Plume/Plume/Plume/PlayableTextView.swift:51), so it does not independently follow system Larger Text or Bold Text; it instead uses its own size and bold preferences. This is not a blanket claim that the reader cannot be made readable.

**Recommendation:** Treat voice selection, preview, and opening the player as distinct named actions. Name slider values and theme selection. Verify that automatic labels already work before replacing them. Decide how the reader's explicit typography controls should cooperate with system accessibility settings. Preserve word navigation and the existing typography choices.

**Basis:** `accessibility.md › Vision` and SwiftUI expert `accessibility-patterns.md › Accessibility Traits / Custom Controls`.

### C8. Medium — Stats range labels disagree with the selected dataset

**Evidence: confirmed.** [ListeningStatisticsView.swift:77](/Users/saumyapatel/Documents/Plume/Plume/Plume/ListeningStatisticsView.swift:77) displays “This Week” only for W and “This Month” for every other selection, including 6M and Y. [ListeningStatisticsView.swift:196](/Users/saumyapatel/Documents/Plume/Plume/Plume/ListeningStatisticsView.swift:196) calculates the preceding 7 days, month, 6 months, or year, rather than the current calendar week/month implied by the title.

**User effect:** Selecting Y can show a year's total under a “This Month” heading. Even W's heading describes a different interval from the rolling range in the code. Separately, `formatDuration` at `:307` floors a positive subminute total to 0m, confirming the mechanism behind visual finding 7.

**Recommendation:** Derive the heading, date range, chart domain, and daily-average denominator from the same range definition. Use “Last 7 Days,” “Last Month,” “Last 6 Months,” and “Last Year” if rolling ranges are intended. Retain the simple summary-card design.

**Basis:** `charting-data.md › Designing effective charts`, explanatory text and consistent meaning across related charts.

### C9. Medium — Search and filter states lose their context

**Evidence: confirmed.** [LibraryView.swift:82](/Users/saumyapatel/Documents/Plume/Plume/Plume/LibraryView.swift:82) replaces the visible filter picker with the search field, but [LibraryView.swift:32](/Users/saumyapatel/Documents/Plume/Plume/Plume/LibraryView.swift:32) continues applying the previous filter to search results. In Progress can remain active invisibly. [LibraryView.swift:115](/Users/saumyapatel/Documents/Plume/Plume/Plume/LibraryView.swift:115) uses the same “No chapters yet” message for an empty library, a search miss, and a filter with no matches. Folder counts at `:156` also include soft-deleted documents although folder detail hides those documents.

**User effect:** A known chapter can appear missing in search, with no visible filter explanation. An existing library can be presented as having no chapters, and a folder count can disagree with its visible contents.

**Recommendation:** Keep the active scope visible during search. Use separate first-run, no-search-results, and no-filter-results messages with an appropriate clear/reset action. Count active folder documents consistently with the folder screen.

**Basis:** `writing.md › Best practices`, contextual next steps and consistent language; `layout.md › Visual hierarchy`, visibility of relationships and grouping.

### C10. Medium — Manual reading position is reclaimed automatically after three seconds

**Evidence: confirmed behavior; degree of disruption unverified.** [PlayableTextView.swift:214](/Users/saumyapatel/Documents/Plume/Plume/Plume/PlayableTextView.swift:214) schedules automatic follow to resume three seconds after manual scrolling stops; `:217` forces the next word update to recenter the reader. Auto-follow uses animated scrolling at `:174`.

**User effect:** Someone scrolling back to reread while audio continues can be pulled away from the passage before finishing it. This behavior cannot be judged from static screenshots.

**Recommendation:** Consider an explicit “Return to Current Word” affordance while the user is browsing elsewhere, rather than a fixed short timeout. Verify Reduce Motion for automatic scrolling and the repeating keyframe spinner at [PlayerView.swift:485](/Users/saumyapatel/Documents/Plume/Plume/Plume/PlayerView.swift:485); the source has no explicit Reduce Motion branch for either.

**Basis:** `accessibility.md › Cognitive`, avoiding controls or transitions constrained by short timers. The proposed follow policy is a design judgment and would require a behavior change.

### C11. Medium — Theme selection can disagree with Match Device

**Evidence: confirmed state mismatch.** Theme cards compare `selectedTheme` in [AppearanceSettingsView.swift:19](/Users/saumyapatel/Documents/Plume/Plume/Plume/AppearanceSettingsView.swift:19), but [AppearanceSettings.swift:93](/Users/saumyapatel/Documents/Plume/Plume/Plume/AppearanceSettings.swift:93) ignores that preference while Match Device is on. After selecting Muted and then enabling Match Device in dark appearance, Muted remains visually selected although the reader uses Basic.

**Recommendation:** Distinguish the remembered manual choice from the currently applied theme, or remove its selected styling while Match Device is active. Keep the ability to return to a remembered manual preference.

**Basis:** `feedback.md › Best practices`, clear current state. The collage shows Match Device off, so this particular mismatch is source-derived rather than screenshot-observed.

### C12. Medium — Deletion wording should distinguish retention and permanent removal

**Evidence: confirmed actions; user misunderstanding unverified.** Ordinary chapter Delete marks `deletedAt` at [LibraryView.swift:214](/Users/saumyapatel/Documents/Plume/Plume/Plume/LibraryView.swift:214), allowing restoration. The same visible “Delete” label in Recently Deleted immediately invokes permanent removal at [RecentlyDeletedView.swift:30](/Users/saumyapatel/Documents/Plume/Plume/Plume/RecentlyDeletedView.swift:30). No per-item confirmation or undo is supplied. Folder deletion at [FolderDetailView.swift:64](/Users/saumyapatel/Documents/Plume/Plume/Plume/FolderDetailView.swift:64) can affect all contained chapters based on an app-wide preference, with no action-local explanation.

**Recommendation:** Call permanent deletion “Delete Permanently” and consider confirmation or an undo mechanism appropriate to that action. At folder deletion, clearly communicate whether chapters will move to Library or Recently Deleted. A destructive role alone does not communicate the affected scope.

**Basis:** `feedback.md › Best practices`, matching warnings to unexpected, irreversible loss. This is not a demand to confirm every routine reversible deletion. Existing Delete All Files already explains scope and asks before proceeding.

## Visual findings and polish

### 1. High — Give the Warm theme a neutral reading color

**Evidence:** Row 1, column 4. The entire passage uses rosewood text on a greige background, while the current paragraph also uses a rosewood tint. This weakens the distinction between ordinary text, the active paragraph, and the current word. Confidence: high.

**Source:** `Plume/Plume/AppearanceSettings.swift:32` and `:40`; `Plume/Plume/PlayableTextView.swift:131`.

**Computed evidence:** Base colors `#AF3E4D` on `#DDD5CD` produce approximately **4.00:1** sRGB contrast. Compositing the 20% accent paragraph background over that surface produces approximately `#D4B7B3`, reducing ordinary paragraph text to **3.10:1**. These are calculations from the current code, not sampled screenshot pixels; material overlays and display conditions can alter the rendered result. The Basic and Muted base pairs calculate to 17.88:1 and 8.91:1 respectively. White on the solid accent for the current word calculates to 5.80:1.

**Fix:** Keep the Warm background and Georgia. Try a dark brown body color such as `#3B302A`, which produces approximately **8.81:1** on the existing background. Preserve accent emphasis for the current word and use a subtler paragraph tint. Test the highlighted state at the smallest permitted reading size. The current ratios alone do not establish failure at every font size; Apple's size-dependent thresholds differ.

**Code-review refinement:** The slider permits 12–36-point reading text at [AppearanceSettingsView.swift:50](/Users/saumyapatel/Documents/Plume/Plume/Plume/AppearanceSettingsView.swift:50). At smaller regular-weight sizes up to 17 points, both calculated Warm ratios fall below the 4.5:1 guidance in `accessibility.md › Vision`. This is therefore a supported-setting contrast concern, not merely a preference for brown text. It does not establish failure of the default 18-point setting under every applicable standard or rendering condition.

**Basis:** `color.md › Inclusive color`: “Avoid using colors that make it hard to perceive content in your app.” [Apple HIG: Color](https://developer.apple.com/design/human-interface-guidelines/color). Preferring neutral body text for extended reading is also a design judgment.

### 2. High — Reduce the reading space lost to the player veil

**Evidence:** Reading screens in row 3, columns 2 and 4. Multiple lines above the controls become faint before reaching the control dock. The reading surface should carry more visual weight than the chrome. Confidence: high.

**Source:** `Plume/Plume/PlayerView.swift:49` applies a 240-point progressive blur; `:66` adds a second 240-point theme fade. `Plume/Plume/PlayableTextView.swift:37` provides a 280-point bottom text inset, so this is not evidence that the last paragraph can never be reached.

**Fix:** Shorten the fading area to the dock height plus a modest transition, with an initial comparison around 120–160 points. Use one coordinated edge treatment instead of two independently strong effects. Verify manually scrolled and auto-follow states, plus the last paragraph. Preserve all playback handlers.

**Implementation risk:** [VariableBlurView.swift:107](/Users/saumyapatel/Documents/Plume/Plume/Plume/VariableBlurView.swift:107) accesses a private `CAFilter` class and selectors; `:125` reaches into the first subview of `UIVisualEffectView` to replace its layer filters. This depends on undocumented internal structure. Consider a supported scroll-edge/material treatment when revisiting the veil for iOS 27. A screenshot that looks correct today cannot establish stability across OS updates. This review makes no independent claim about store-review outcomes.

**Basis:** `layout.md › Visual hierarchy`: “Differentiate controls from content.” [Apple HIG: Layout](https://developer.apple.com/design/human-interface-guidelines/layout). The proposed height range is a starting design experiment, not an Apple specification.

### 3. Medium — Make the two player exit actions distinguishable

**Evidence:** Every reading screen has a downward chevron at the top and an X in the player dock. Both visually suggest dismissal, but they have different effects. Confidence: high.

**Source:** `Plume/Plume/PlayerView.swift:100` dismisses through the chevron; `:222` pauses playback, cancels active generation when applicable, and dismisses through the X.

**Fix:** Preserve the two behaviors, but give the dock action a stop symbol and a clear accessibility name such as “Stop Playback and Close.” Describe the top action as “Minimize Player.” Confirm the symbols are understood at normal size; a short visible label can be considered if the stop icon remains ambiguous.

**Basis:** `buttons.md › Content`: “Ensure that each button clearly communicates its purpose.” [Apple HIG: Buttons](https://developer.apple.com/design/human-interface-guidelines/buttons).

### 4. Medium — Keep the Add button tied to library tasks

**Evidence:** A prominent rosewood plus appears over Settings and Listening Stats as well as the Library. In Settings it competes with the options people came to adjust. Confidence: high for placement; medium for actual user confusion.

**Source:** `Plume/Plume/MainTabView.swift:35` shows the global bottom overlay whenever the full player is not presented, including the 64-point Add button at `:43`.

**Code-review refinement:** The overlay occupies the parent ZStack without reserving content space using a safe-area inset. [SettingsView.swift:103](/Users/saumyapatel/Documents/Plume/Plume/Plume/SettingsView.swift:103) compensates with a fixed 120-point bottom padding, while Library, folder detail, Recently Deleted, and Stats lack an equivalent reservation. Those screens' final rows/actions can be covered by the persistent dock. Actual reachability needs live scrolling verification; the collage does not prove a final row is permanently inaccessible. Measure the dock and reserve space consistently rather than adding separate arbitrary padding to each screen.

**Fix:** Prefer showing Add in the Library and folder context. Keep playback accessible wherever listening continues. Before changing placement, confirm whether importing while viewing Settings is a deliberate shortcut worth retaining elsewhere.

**Basis:** `settings.md › Task-specific options` and `layout.md › Visual hierarchy`. This is a contextual hierarchy recommendation, not a claim that floating buttons violate iOS rules.

### 5. Medium — Give chapters enough title space to identify them

**Evidence:** Library and queue rows truncate the chapter name and number; the same book's chapters could look nearly identical. Confidence: high for truncation, medium for the impact on a larger library.

**Source:** [LibraryView.swift:366](/Users/saumyapatel/Documents/Plume/Plume/Plume/LibraryView.swift:366) and [QueueSheetView.swift:50](/Users/saumyapatel/Documents/Plume/Plume/Plume/QueueSheetView.swift:50) both constrain the title to one line. At [LibraryView.swift:472](/Users/saumyapatel/Documents/Plume/Plume/Plume/LibraryView.swift:472), content with no source URL is labeled “web,” including locally imported files; use a truthful generic label if import type is not stored.

**Fix:** Let document titles use two lines, with the chapter number retained wherever possible. Keep duration and source as secondary metadata. Consider a concise series name and chapter title treatment only when the imported data reliably supports it. The mini-player may remain one line; the browsing list has room to carry more information.

**Basis:** `typography.md › Supporting Dynamic Type`: “Keep text truncation to a minimum as font size increases.” [Apple HIG: Typography](https://developer.apple.com/design/human-interface-guidelines/typography). Applying this to ordinary-size chapter identification is a design judgment.

### 6. Medium — Replace voice-engine language with listening outcomes

**Evidence:** Row 1, column 2 shows a sizable “Playback in Progress” notice. Its text introduces an “original voice snapshot,” and the restart action is long. The fallback explanation also takes substantial attention before the available voices. Confidence: high.

**Source:** `Plume/Plume/VoiceSettingsView.swift:294` and `:305`.

**Fix:** Try: “This chapter keeps its current voice. Your selection applies to the next chapter.” Shorten the action to “Restart with Selected Voice.” For fallback, lead with “Used when your main voice can't continue,” and retain the eligibility explanation as secondary help. Ensure the wording still matches the existing restart and fallback behavior.

**Basis:** `writing.md › Getting started`: “Be clear.” [Apple HIG: Writing](https://developer.apple.com/design/human-interface-guidelines/writing).

### 7. Medium — Make short listening sessions understandable in Stats

**Evidence:** Row 2, column 2 shows “0m” and a populated chart; row 1, column 1 shows words listened alongside a zero-minute lifetime total. This can make genuine small progress look like a recording failure. Confidence: high for the displayed combination; medium for its cause.

**Source:** `Plume/Plume/ListeningStatisticsView.swift:108` charts time in hours, while `:81` and `:163` use formatted durations.

**Fix:** Display “<1 min” for a positive duration under one minute, reserving “0 min” for no time. Prefer minute units for short sessions, and show a useful total next to each chart. Do not infer that tracking itself is broken from this collage; verify that separately if the recorded values disagree with device use.

**Basis:** `charting-data.md › Designing effective charts`: “Aid comprehension by adding descriptive text to the chart.” [Apple HIG: Charting data](https://developer.apple.com/design/human-interface-guidelines/charting-data).

### 8. Medium — Protect Library header actions at larger text sizes

**Evidence:** Folder creation, search, and Settings are three compact icons to the right of the large Library title. Their visible targets are tight in the collage. Confidence: medium.

**Source:** `Plume/Plume/LibraryView.swift:55` creates the action group without an explicit 44-point target for each item. This does not prove the final hit regions are smaller than recommended; styles and the rendered hierarchy must be inspected. In contrast, the full player explicitly uses 44-point targets for its secondary controls.

**Fix:** Verify the header at normal and accessibility text sizes. Ensure a comfortable hit region for each action, preferably through native toolbar placement. Maintain clear accessibility labels and avoid squeezing the title and actions into one fixed-height row.

**Basis:** `accessibility.md › Mobility`: “Offer sufficiently sized controls.” `layout.md › Adaptability`: “Be prepared for text-size changes.” [Apple HIG: Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility).

## What to preserve

- Georgia and the uncluttered reading surface; the typeface fits a novel reader.
- The rosewood primary play button, which makes the essential action obvious.
- Separate reading themes and app chrome; a reading preference does not need to behave like a global appearance override.
- Cover thumbnails, folders, and All / In Progress / Finished filters.
- The compact mini-player's chapter and paused-state information.
- The speed sheet's large current value and clearly selected preset.
- Grouped Settings sections and the simple Up Next screen. The empty-folder composition is clear, but its Add instruction needs the routing correction in C2.
- Voice previews already have explicit accessible names at `VoiceSettingsView.swift:544`; keep that distinction when improving row selection.
- The main player gives secondary button labels explicit 44-point frames and the primary play button a 52-point frame. The separate timeline gesture strip is the exception described in C5.
- Delete All Files already explains what is removed and what history is retained, and requests confirmation.

The large empty area beneath a short Library list is not inherently a defect. Adding promotional cards or decorative content would weaken its focus. Additional glass is not required to make these screenshots feel current.

## Verification still needed

- Original, uncropped screenshots to judge real text sizes, margins, sheet bottoms, and exact material appearance. Do not count the cropped bottom of the collage's speed sheet as a confirmed app defect.
- VoiceOver labels and reading order, especially queue, voice, minimize, stop, search, and folder actions.
- Dynamic Type and Bold Text, including the reader's independent size/bold preferences and both fixed-height settings sheets.
- Increase Contrast and Reduce Transparency in both app appearances and all reading themes.
- The speed sheet's fixed 420-point detent (`SpeedSettingsView.swift:142`) at large text sizes and compact height; confirm all settings remain reachable.
- Scrolling to the end of Settings and Stats with the persistent bottom controls, and opening/dismissing the keyboard in Library search and New Folder.
- Playing, buffering, paused, voice-change, empty queue, and error states on the actual iOS 27 build.

## Suggested first pass

1. Resolve the confirmed user-facing mismatches: Font Style, folder import destination, cache scope, silent import failures, search scope, and Stats labels.
2. Expose accessible timeline and selection semantics; verify sheet reachability and smaller-font Warm contrast.
3. Improve Warm body/highlight colors and reduce the reading veil.
4. Clarify stop versus minimize, title wrapping, voice copy, and short-duration formatting.
5. Verify contextual Add placement, bottom-content reservation, reduced motion/transparency, and larger text on the actual iOS 27 build.

C1–C4 and other state/routing findings require behavior changes if accepted. They are reported for review only. No implementation fix, code refactor, build-setting change, or audio-engine change was made during this audit.
