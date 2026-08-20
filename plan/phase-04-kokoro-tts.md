# Phase 4 — Kokoro TTS Integration

## Goal
Convert a `Document`'s `bodyText` into natural-sounding speech entirely
on-device using Kokoro, and capture word-level timestamps for highlighting.

## ⚠️ Licensing note — read before bundling eSpeak NG
eSpeak NG (required for phonemization, step 1 below) is licensed under
**GPLv3, not a permissive license like Kokoro's Apache 2.0**. Statically
linking GPL code into a closed-source app generally obligates the whole app
to be GPL-licensed too — a real conflict if you ever want to sell Plume or
keep its source private on the App Store. eSpeak NG's own iOS example
project works around this by splitting the GPL-licensed speech component
into a separate process that only communicates with the rest of the app via
XPC/IPC, rather than linking it directly — that separate piece stays GPL,
but the main app code doesn't inherit it. **For this personal-use build,
direct linking is fine and simplest.** If this project is ever going to be
distributed publicly (App Store, GitHub as source, etc.), revisit this
before release — either adopt the same process-separation pattern, or look
into whether a differently-licensed phonemizer can be swapped in.

## Background
- Package: [github.com/mlalma/kokoro-ios](https://github.com/mlalma/kokoro-ios)
  (Swift Package Manager, MIT-licensed wrapper around the Apache 2.0-licensed
  Kokoro-82M model).
- Reference integration app:
  [github.com/mlalma/KokoroTestApp](https://github.com/mlalma/KokoroTestApp) —
  consult this for exact bundling/usage patterns since the README alone is
  minimal. The library's own repo also ships an example project at
  `mlxtest/mlxtest.xcodeproj` demonstrating the same integration.
- Requires iOS 18+ (already our deployment target) and runs via Apple's MLX
  framework. **Must be tested on a real device, not the simulator** — MLX
  needs Metal support, which iOS Simulator doesn't provide.
- As of package version 1.0.8+, Kokoro returns **per-token timestamps**,
  which is what we'll use for word-highlighting in Phase 5.
- Canonical source/reference: [github.com/hexgrad/kokoro](https://github.com/hexgrad/kokoro)
  — the original Python inference library and model authors (Apache 2.0
  license confirmed here directly). Not used in the iOS build itself, but
  useful for browsing available voice names before picking one to bundle.
  Voice names follow a pattern like `af_heart` (language/accent prefix +
  voice name — `a` = American English, `f` = female, `heart` = the specific
  voice). Pick one American English female or male voice to start with;
  more can be added later per Phase 8's voice selection settings.

## Tasks

1. **Build the eSpeak NG framework first (prerequisite)**
   - Kokoro relies on eSpeak NG for phonemization (turning text into
     phonetic units before synthesis). The `kokoro-ios` repo includes an
     `espeak-ng/espeak-ng.xcodeproj` sub-project — clone the repo, open that
     project, select the `espeak-ng.xcframework` target, and build it
     (⌘+B). This produces `ESpeakNG.xcframework`.
   - Add the resulting `ESpeakNG.xcframework` to the main Plume app
     target under "Frameworks, Libraries, and Embedded Content," set to
     **Embed & Sign**.

2. **Add the KokoroSwift package dependency**
   - Swift Package Manager URL: `https://github.com/mlalma/kokoro-ios.git`,
     from version `1.0.0` (confirm you're on 1.0.8+ for the timestamp
     feature — specify a minimum version accordingly).
   - Also add the **MLX Swift** package:
     `https://github.com/ml-explore/mlx-swift`, and select these products:
     `MLX`, `MLXFFT`, `MLXFast`, `MLXLinalg`, `MLXNN`.

3. **Download and bundle the model weights**
   - Download `kokoro-v1_0.safetensors` from Hugging Face:
     `huggingface.co/prince-canuma/Kokoro-82M` (this is the MLX-compatible
     conversion referenced directly by the kokoro-ios docs — confirm this is
     still the correct/current source at build time, community-hosted model
     mirrors do move).
   - Also grab the voice embedding/style file for whichever voice you pick
     (see the Background section above re: voice naming) — check
     KokoroTestApp's resources folder for exactly which companion files
     accompany the voice.
   - Add these files into the app target's `Resources/` folder (mirror the
     reference app's structure: `mlxtest/mlxtest/Resources/` in their repo)
     so they're bundled into the compiled app.

4. **Build `KokoroTTSService`**
   - A wrapper class/actor responsible for:
     - Loading the model once (lazily, on first use, not at app launch —
       avoid slowing down cold start). Basic usage pattern:
       ```swift
       import KokoroSwift
       let modelPath = URL(fileURLWithPath: "path/to/bundled/model")
       let tts = KokoroTTS(modelPath: modelPath, g2p: .misaki)
       ```
     - Chunking long chapter text into segments that respect Kokoro's ~510
       token context limit per generation call (chapters can be several
       thousand words). **Chunk at paragraph or sentence boundaries, not
       arbitrary token cutoffs** — cutting mid-sentence produces awkward
       prosody and unnatural pauses at chunk boundaries when the audio is
       stitched together.
     - Generating audio + timestamps per chunk, then concatenating audio
       buffers into a single playable file and merging timestamp arrays with
       correctly offset time values so they're continuous across the whole
       chapter.
     - Exposing a simple async API, e.g.
       `func synthesize(document: Document) async throws -> SynthesisResult`
       where `SynthesisResult` contains an output audio file URL and a
       `[WordTimestamp]` array (`word: String`, `startTime: TimeInterval`,
       `endTime: TimeInterval`).

5. **Persist the output**
   - Write the generated audio to a file (e.g. `.caf` or `.m4a` via
     `AVAudioFile`) in the `AudioCache/` folder inside the App Group
     container — the exact location defined in Phase 1's storage layout,
     not the app's default documents directory. This is what makes the
     file reachable/consistent with Phase 6's Recently Deleted purge and
     Phase 10's caching logic later.
   - Save the file URL to `Document.audioFileURL` and encode
     `[WordTimestamp]` into `Document.wordTimestamps`.
   - (Full caching strategy — avoiding regeneration on every open — is
     formalized in Phase 10; for this phase it's enough that synthesis
     happens once per explicit "generate" trigger.)

6. **Trigger point (temporary)**
   - Add a simple "Generate Audio" button somewhere reachable (can live on
     the Phase 3 debug list for now) that runs synthesis for a selected
     document and reports success/failure and elapsed time.

## Troubleshooting reference (from the library's own docs)
- **Missing ESpeakNG.xcframework**: means step 1 wasn't completed — build
  that target first before touching the main app.
- **Model loading failures**: double-check the model file's exact location
  and filename match what the code expects.
- **"Works on my Mac but not my phone"**: you're probably running in
  Simulator — switch to a real device.
- **Signing errors on device**: standard Xcode signing/bundle ID
  configuration, unrelated to Kokoro itself.

## Acceptance criteria
- A real extracted chapter (multi-paragraph, 2000+ words) synthesizes
  successfully into a single continuous audio file.
- Generation happens fully on-device, no network calls, no API keys.
- Word timestamps are captured and roughly align with the audio when spot-
  checked (e.g. print the word at t=10s and confirm it's audibly close).
- Generation speed is reasonably faster than real-time on a real device
  (per the library's own claims, ~3x realtime on iPhone 13 Pro class
  hardware) — flag it if it's dramatically slower.
- Chunking/merging produces no audible gaps, clicks, or duplicated words at
  chunk boundaries.
