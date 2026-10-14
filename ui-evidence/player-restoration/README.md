# Player restoration evidence

Final source on `experiment/ios27-ui-ux`, October 14, 2026. See [implementation and model usage](../../UI_PLAYER_RESTORATION.md).

## Three themes

| Theme | iOS 26.5 | iOS 27 | Browsing / spoken-word return |
|---|---|---|---|
| Basic | [Reader](ios26-reader-restored-Basic.png) | [Reader](ios27-reader-restored-Basic.png) | [Return](ios27-reader-return-word-Basic.png) |
| Warm | [Reader](ios26-reader-restored-Warm.png) | [Reader](ios27-reader-restored-Warm.png) | [Return](ios27-reader-return-word-Warm.png) |
| Muted | [Reader](ios26-reader-restored-Muted.png) | [Reader](ios27-reader-restored-Muted.png) | [Return](ios27-reader-return-word-Muted.png) |

[Scrolling and manual Return recording — Basic, Warm, Muted](ios27-themes-scroll-and-return.mp4). The recording removes the initial build wait and uses a smaller export; full-resolution screenshots remain above. It shows theme selection, content passing beneath the translucent header, line continuity beneath/below the dock, and the transition back to sharp text when returning. Fixture playback is paused at “The”; changing live words and automatic Return were separately verified on the iPhone.

## Physical iPhone, iOS 27

- [Playback and highlighting](iphone27-device-playing-and-seeking.png)
- [Upper-edge slider after actual drag](iphone27-device-edge-slider.png)
- [Paused spoken-word Return](iphone27-device-paused-return-word.png)
- [Returned passage](iphone27-device-returned-and-paused.png)
- [Minimize and reopen](iphone27-device-minimize-reopen.png)

The extended physical test passed live word changes with stable button width/position, immediate Return, three-second automatic Return, paused retention beyond three seconds, paused explicit Return, skip/slider seek, two background handoffs, settings, minimize/reopen, and X release/close.

## Layout and accessibility fallback

- [iOS 26.5 landscape](ios26-reader-landscape.png) / [iOS 27 landscape](ios27-reader-landscape.png)
- [iOS 26.5 largest text](ios26-reader-largest-text.png) / [iOS 27 largest text](ios27-reader-largest-text.png)
- Reduced effects: [Basic](ios27-reader-reduced-effects-Basic.png), [Warm](ios27-reader-reduced-effects-Warm.png), [Muted](ios27-reader-reduced-effects-Muted.png)

Both OS versions passed the expanded-sheet and accessibility5 reachability tests. Reduced-effects fixtures force the production reader rendering-policy inputs; they do not certify actual OS toggles or VoiceOver speech behavior. Hands-on VoiceOver adjustment, focus, and absence of disruptive word-update announcements, and physical system Reduce Motion/Transparency confirmation remain open gates.

All data is isolated fixture content. No destructive test touched the user’s library. Xcode logs/result bundles stay outside git; rejected prototypes and unsuccessful recording attempts are excluded.
