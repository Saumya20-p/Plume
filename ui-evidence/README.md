# UI experiment evidence

The subsequent five player corrections, final screenshots, and scrolling recording are in [player-restoration](player-restoration/README.md); those captures supersede the earlier reader-edge and exit-icon choices here.

Captured October 14, 2026 from isolated fixture data. These files document rendered behavior, not exhaustive device/accessibility certification. See [the implementation ledger](../UI_IMPLEMENTATION_LEDGER.md) for open gates and source changes.

| Files | Evidence |
|---|---|
| `ios26-reader-soft-{Basic,Warm,Muted}.png` | iOS 26.5 manual themes with the selected trait asserted, paused Return exercised. |
| `ios27-reader-soft-{Basic,Warm,Muted}.png` | iOS 27 manual themes with the selected trait asserted, paused Return exercised. |
| `ios26/ios27-reader-landscape.png` | Full-screen landscape captures after window rotation; native text, measured dock clearance and clean navigation background. |
| `ios26/ios27-reader-largest-text.png` | accessibility5 + bold reader and dock. Icon glyphs remain inside their touch targets, speed/time fit. |
| `ios26/ios27-appearance-largest-text.png`, `*-speed-largest-text.png` | Adaptive choices, scrollable settings; tests scroll to and reach Bold Font / automatic-speed switch. A screenshot may show an intermediate scroll position. |
| `*-appearance-sheet.png`, `*-speed-landscape.png` | Normal Appearance and compact-height Speed sheet. |
| `ios26-folder-search-result.png` | Text imported into Experiment Book then found through Library-wide search. |
| `ios26-invalid-link-recovery.png`, `ios26-statistics-year.png` | Visible invalid-link error and selected yearly Stats state. |
| `iphone27-device-*.png` | Physical iPhone playback, seek, highlight, then paused after two background round trips. Captured before the final presentation-background polish; a Library filter was still visible behind navigation and was subsequently fixed and verified in simulator captures. |
| `ios26-soft-scroll.mp4` | Native soft-edge scrolling and paused explicit Return; frames reviewed to check that text stays visible underneath the dock and clear above it. Recorded before the final navigation and large-text polish, which does not change the edge implementation. |
| `ios26-soft.jpg`, `ios26-automatic-comparison.jpg` | Warm reader native-edge comparison only. `.automatic` is a DEBUG comparison argument, not a follow-mode preference. |

The earlier false theme/large-text screenshots and app-only black/cropped landscape captures were replaced. The fixture now explicitly applies theme choice, asserts selected state, and propagates Dynamic Type to presented sheets.

Final local result bundles live under `~/Library/Developer/XcodeBuildMCP/workspaces/Plume-ccf85facdece/result-bundles/` and are excluded from git:

- iOS 27 final three UI tests: `test_sim_2026-10-14T22-11-55-747Z_pid72904_0fc36e22.xcresult` — 3 passed.
- iOS 26.5 final landscape/large-text checks: `test_sim_2026-10-14T22-10-07-933Z_pid72904_0cc07291.xcresult` — 2 UI checks passed; its handoff unit-test fixture was corrected and passed in the next focused run.
- iOS 26.5 final lifecycle suite: `test_sim_2026-10-14T22-11-33-066Z_pid72904_c8d6471a.xcresult` — 5 passed.
- iOS 26.5 refreshed theme capture: `test_sim_2026-10-14T22-15-02-286Z_pid72904_ec0d4962.xcresult` — 1 passed (three themes and paused Return).
- Physical iPhone playback: `test_device_2026-10-14T22-07-02-675Z_pid72904_5af579af.xcresult` — 1 passed.
- Final signed device build: `build_device_2026-10-14T22-14-38-513Z_pid72904_462c7799.log` — succeeded. The phone was not relaunched while the user performed manual accessibility checks.

Simulator builds require the documented disposable MLX header workaround. Physical builds use clean dependencies. All destructive behavioral tests use disposable model/cache data.
