# Phase 2 — Safari Share Extension

## Goal
Let the user share a web page from Safari into Plume, capturing the page's
URL and raw HTML so Phase 3 can extract the chapter text from it.

## Tasks

1. **Add a Share Extension target** to the Xcode project (File → New → Target
   → Share Extension). Name it something like `PlumeShare`.

2. **Configure the extension's `Info.plist`**
   - Activation rule: accept URLs and web pages (`NSExtensionActivationSupportsWebURLWithMaxCount`
     and/or `NSExtensionActivationSupportsWebPageWithMaxCount` = 1).
   - This makes "Plume" show up in Safari's share sheet when viewing any page.

3. **Enable the same App Group** on the extension target that was created in
   Phase 1, so it can write into shared storage the main app can read.

4. **Capture the shared content**
   - Use `NSExtensionItem` / `NSItemProvider` to pull out:
     - The page URL
     - The rendered HTML if available (via `public.url` + a JavaScript
       preprocessing file (`SLComposeServiceViewController` + an accompanying
       `.js` extension file) that grabs `document.documentElement.outerHTML`)
   - If only the URL is available (HTML not captured), that's fine — store the
     URL and let Phase 3 fetch/extract from it directly as a fallback.

5. **Minimal extension UI**
   - Keep it simple: a brief "Saving to Plume…" confirmation view, then
     auto-dismiss. No need for a compose/edit screen — this isn't a
     Twitter-style share sheet, it should feel instant.

6. **Write to shared storage**
   - Save the captured URL + HTML (or just URL) into the App Group's shared
     container — either directly into the shared SwiftData store as a
     lightweight "pending share" record, or as a simple file/plist that the
     main app picks up on next launch. Prefer writing directly to the shared
     SwiftData store if that's stable across the extension and main app
     process; otherwise use a shared `UserDefaults(suiteName:)` queue of
     pending items as a fallback.

7. **Notify / wake the main app (best effort)**
   - It's fine if the main app only picks up new shared items the next time
     it's foregrounded — don't over-engineer background wake-up for this
     phase. Just make sure the main app checks for pending shared items on
     launch and on foreground.

## Acceptance criteria
- "Plume" appears in Safari's share sheet on a real device or simulator.
- Sharing a web novel chapter page from Safari triggers the extension, shows
  a brief confirmation, and dismisses without errors.
- After sharing, opening the main Plume app surfaces the new item as a
  "pending" entry somewhere inspectable (a debug print or a temporary list is
  fine — real Library UI comes in Phase 6).
- Sharing works for at least 2–3 different real web novel sites, capturing
  either full HTML or at minimum the URL reliably.
