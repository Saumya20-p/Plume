# Player polish evidence

Final seven-correction implementation on `experiment/ios27-ui-ux`, captured October 14, 2026 local time. See [implementation, model usage, and open gates](../../UI_PLAYER_POLISH.md). This directory supersedes the earlier player-restoration captures for the compact caption, rounded timeline, dock height, header edge, and foreground blur.

| Files | What to inspect |
|---|---|
| `ios26/ios27-reader-restored-{Basic,Warm,Muted}.png` | Exact theme background, highlighting, compact dock, curved timeline, header transition, softened text beneath/below the dock. |
| `ios26/ios27-reader-return-word-{Basic,Warm,Muted}.png` | Compact centered pill with “The”; manual browsing while paused. |
| `ios26/ios27-saved-before-play-{Basic,Warm,Muted}.png` | Chapter restored at a saved UTF-16 position before Play. |
| `ios26/ios27-saved-compact-return-{Basic,Warm,Muted}.png` | Resolved “Morning” caption before Play; centered, stable dimensions and immediate paused Return tested. |
| `ios26/ios27-reader-landscape.png` | Full-screen landscape layout and measured clearance. |
| `ios26/ios27-reader-largest-{text,return}.png` | accessibility5 reader/dock and scaled return pill. |
| `ios26/ios27-{appearance-largest-text,speed-largest-text,appearance-sheet,speed-landscape}.png` | Reachable settings controls, scrollable/expanded presentation. |
| `ios26/ios27-reader-reduced-effects-{Basic,Warm,Muted}.png` | Forced Reduce Transparency/Motion policy branches: opaque controls and no foreground blur. |
| [ios27-scroll-and-return.mp4](ios27-scroll-and-return.mp4) | About 39 seconds: Basic, Warm, Muted in sequence; scrolling beneath header/dock, compact pill, immediate paused Return. Reviewed for text continuity/alignment and gradual sharpening. |

`capture-index.json` maps each screenshot to its test, device, and capture timestamp. The recording uses the final source with the plain-container hosting mask fix. Rejected material candidates and initial warning-producing builds are excluded.

These simulator captures do not demonstrate current active synthesis, seeking, automatic return during playback, or background handoff. The signed physical build succeeded but its test could not start while Saumya was locked; the user requested simulator evidence for now. Actual OS accessibility and physical playback/performance gates remain open.
