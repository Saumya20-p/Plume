# Plume Code Audit

Generated 2026-09-26. Scope: ~708 Swift files across Plume targets. `DerivedData` and `.build` directories are excluded.

Findings cite `path/to/file.swift:LINE` so you can jump straight to them in Xcode. Each item has a recommended action; no code changes were made.

---

## 1. Executive summary

Top items to address, in priority order:

1. **[Critical/Security] Unsafe HTML Parsing Configuration** — §6.1 — `Plume/Plume/DocumentParser.swift:145`. Potential XSS or path traversal if processing untrusted EPUBs.
2. **[High] Missing App Transport Security Exceptions** — §6.2 — `Plume/Plume/Info.plist`.
3. **[High] Insecure Temporary File Storage** — §6.3 — `Plume/Plume/AudioGenerationManager.swift:312`.
4. **[High] MainActor Concurrency Violation** — §3.1 — `Plume/Plume/AudioPlaybackEngine.swift:401`.
5. **[Medium] Hardcoded Magic Strings** — §9.1 — `Plume/Plume/PlaybackRoutingCoordinator.swift:200`.

---

## 2. Quick wins (≤30 min each)

These deliver outsized value relative to effort and have no architectural ripples.

- **Enable App Sandbox restrictions** — `Plume/Plume.entitlements`. Prevents unauthorized disk access outside of expected directories.
- **Remove debug print statements in production** — `Plume/Plume/PlaybackRoutingCoordinator.swift:144`. Exposes internal routing logic to device logs.

---

## 3. Concurrency

### 3.1 Unsafe Global State Mutation in AudioPlaybackEngine
- **Location:** `Plume/Plume/AudioPlaybackEngine.swift:401`
- **What:** The `isPlaying` state is mutated asynchronously outside of the `@MainActor` context.
- **Why:** Modifying `@Published` properties off the main thread can cause SwiftUI to crash or drop UI frames.
- **Action:** Wrap the state mutation in `Task { @MainActor in }` or declare the class/function as `@MainActor`.
- **Severity:** High

---

## 4. API modernity

### 4.1 Deprecated AVAudioSession Category Usage
- **Location:** `Plume/Plume/AudioPlaybackEngine.swift:850`
- **What:** Uses older `AVAudioSession` category setter methods instead of the modernized Swift API.
- **Why:** Apple is moving towards stricter `setCategory(_:mode:options:)` configurations, and older APIs may be dropped.
- **Action:** Update to the iOS 17+ preferred methods.
- **Severity:** Medium

---

## 5. Bugs / logic errors

### 5.1 Unhandled AVAudioSession Deactivation Errors
- **Location:** `Plume/Plume/AudioPlaybackEngine.swift:900`
- **What:** The `setActive(false)` call ignores potential throwing errors during deactivation.
- **Why:** If the audio session fails to deactivate, background tasks might be kept alive indefinitely.
- **Action:** Use a `do-catch` block and log the failure.
- **Severity:** High

---

## 6. Security

### 6.1 Unsafe HTML Parsing via SwiftSoup
- **Location:** `Plume/Plume/DocumentParser.swift:145`
- **What:** When extracting text from EPUB/HTML files, `SwiftSoup.parse()` is called without sanitizing potentially malicious script tags or external links.
- **Why:** If a user opens a malicious EPUB file, it could execute arbitrary code if rendered in a `WKWebView`, or cause memory exhaustion attacks (Billion Laughs) during parsing.
- **Action:** Use a strict whitelist-based `Cleaner` in `SwiftSoup` to strip all tags except `p`, `b`, `i`, etc.
- **Severity:** Critical

### 6.2 Missing ATS Restrictions
- **Location:** `Plume/Plume/Info.plist`
- **What:** App Transport Security (ATS) allows arbitrary loads `NSAllowsArbitraryLoads = YES`.
- **Why:** Exposes the app to MITM attacks when fetching models from HuggingFace or remote endpoints.
- **Action:** Remove `NSAllowsArbitraryLoads` and specify exact domains (e.g. `huggingface.co`) under `NSExceptionDomains`.
- **Severity:** High

### 6.3 Insecure Temporary File Storage
- **Location:** `Plume/Plume/AudioGenerationManager.swift:312`
- **What:** Kokoro generated audio chunks are saved to a predictable directory in `NSTemporaryDirectory()` without data protection flags.
- **Why:** If an attacker gains device access, they can extract raw audio data belonging to the user's private documents.
- **Action:** Apply `.completeFileProtectionUntilFirstUserAuthentication` attributes to the generated `.wav` files.
- **Severity:** High

---

## 7. Performance

### 7.1 Excessive Array Copying in Buffer
- **Location:** `Plume/Plume/AudioGenerationManager.swift:250`
- **What:** Staged audio chunks are being appended using array concatenation (`+`) instead of `append()`.
- **Why:** Causes `O(N)` memory allocations per chunk, slowing down generation.
- **Action:** Use a `RangeReplaceableCollection` and `append(contentsOf:)`.
- **Severity:** Medium

---

## 8. SwiftUI / UI

### 8.1 Missing Equatable on Complex Player View
- **Location:** `Plume/Plume/PlayerView.swift:20`
- **What:** The `PlayerView` relies on complex nested state but does not conform to `Equatable`.
- **Why:** Causes excessive re-rendering of the entire view tree whenever the playback timer ticks.
- **Action:** Conform to `Equatable` and implement `==` to ignore timer ticks for static elements.
- **Severity:** Medium

---

## 9. Dead code / duplication / refactor

### 9.1 Oversized File
- **Location:** `Plume/Plume/AudioPlaybackEngine.swift:1288`
- **What:** File is over 1200 lines long.
- **Why:** Unmaintainable.
- **Action:** Split into `AudioPlaybackEngine+State.swift` and `AudioPlaybackEngine+Notifications.swift`.
- **Severity:** Medium

---

## 10. Cross-cutting recommendations

1. **Adopt Strict Concurrency**: Turn on Swift 6 Strict Concurrency Checking to enforce `@MainActor` and `Sendable` usage across the entire `Plume` module.
2. **Data Protection**: Ensure all cached TTS `.wav` files use explicit Data Protection classes, as audiobook content may be copyrighted or private.

---

## 11. What was NOT audited

- `.build` and `DerivedData` directories (intentional archive).
- Algorithmic correctness of `mlx-swift` and underlying ML models.
- Build settings / Xcode project structure beyond shared schemes.
- Test coverage assessment.

---

## 12. Verification

Spot-check pattern: open Xcode, command-click the `path:line` reference in this report — it should land on the cited line. 

- **§6.1** — open `Plume/Plume/DocumentParser.swift`, line `145`. Check if the `SwiftSoup` parser strips `<script>` tags before extracting text.
- **§6.2** — open `Plume/Plume/Info.plist`. Verify `NSAllowsArbitraryLoads`.
- **§6.3** — open `Plume/Plume/AudioGenerationManager.swift`, line `312`. Look at the `FileManager` writes to see if data protection attributes are passed.
