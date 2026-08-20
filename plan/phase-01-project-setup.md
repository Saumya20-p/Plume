# Phase 1 — Project Setup, App Group, Design Tokens

## Goal
Stand up the Xcode project with the shared infrastructure every later phase
depends on, plus a minimal running app shell.

## Before you start
- **You'll need a real iPhone for most of this build, not just the
  simulator.** Later phases (Kokoro/MLX synthesis in Phase 4, background
  audio in Phase 5) require Metal support and hardware features the iOS
  Simulator doesn't fully provide. Get a device connected and trusted in
  Xcode now.
- **A free Apple ID is enough** for everything in this plan — personal
  on-device testing of Share Extensions, App Groups, and background audio
  all work fine with free (non-paid) provisioning. You only need the paid
  $99/year Apple Developer Program if/when you actually submit to the App
  Store.

## Tasks

1. **Create a new Xcode project**
   - Name: `Plume`
   - Interface: SwiftUI, Lifecycle: SwiftUI App
   - Minimum deployment target: iOS 18.0
   - Language: Swift

2. **Enable capabilities**
   - Add an **App Group** capability (e.g. `group.com.yourteam.plume`) to the
     main app target. This will be shared with the Share Extension in Phase 2.
   - Add **Background Modes** capability with **Audio, AirPlay, and Picture in
     Picture** enabled (needed for Phase 5 background playback).

3. **Set up SwiftData**
   - Add a `ModelContainer` configured to use the App Group container path
     (not the default app sandbox) so both the main app and the share
     extension can eventually read/write the same store.
   - Leave the schema empty for now except a placeholder — real models arrive
     in Phase 3.

4. **On-disk storage layout (defines where everything actually lives)**
   - Everything Plume stores lives inside the App Group's shared
     container — `FileManager.default.containerURL(forSecurityApplicationGroupIdentifier:)`
     — not the app's default private sandbox. This is what lets the Share
     Extension (a separate process/sandbox) and the main app both see the
     same data without copying files back and forth.
   - Within that container, use two subfolders:
     - `SwiftData/` — the SwiftData store itself (`.sqlite` + companion
       files). All chapter text (`Document.bodyText`) lives inside this
       database, not as loose text files.
     - `AudioCache/` — one `.m4a` file per document, named by its `id`
       (e.g. `AudioCache/3F2A1B9C-...m4a`), created in Phase 4 and referenced
       by `Document.audioFileURL`. Phase 10's caching/clearing logic and
       Phase 6's Recently Deleted purge both operate on files in this
       folder.
   - None of this is visible to the user via the Files app or Finder — it's
     inside the app's private container, same as any other iOS app's data.
     The user only ever interacts with it through the Library UI, not as
     browsable files. (If a "browse raw files" feature is ever wanted later,
     it isn't in this plan — flag it as a future idea, not a v1 feature.)

5. **Design tokens**
   - Create a `DesignSystem.swift` (or similar) file defining:
     - `Color.accent` — warm ruby red, `#A6342A` (light variant `#C2564A`,
       dark/on-accent variant `#7E2620`). Define as a Color Asset in
       Assets.xcassets so it can have separate light/dark values if needed
       later, but for now a single warm-ruby value is fine.
     - Base surface colors for app chrome (not the reading view — that's
       Phase 7): near-black / charcoal for dark mode, soft off-white for
       light mode. Follow system appearance automatically.
     - Typography scale for UI chrome (system font, a handful of weight/size
       presets: title, headline, body, caption).

6. **Basic SwiftUI shell**
   - Tab-based or simple navigation shell with at least two destinations:
     - **Library** (placeholder view for now — real implementation in Phase 6)
     - **Settings** (placeholder view for now — real implementation in Phase 8)
   - Apply the accent color as the app's global tint.
   - App icon and launch screen can be placeholder/system default for now;
     real polish happens in Phase 11.

## Acceptance criteria
- Project builds and runs on a simulator/device with iOS 18+.
- App Group entitlement is present and the identifier is noted somewhere
  (e.g. a comment or a `Constants.swift`) so Phase 2's extension target can
  reference the exact same group ID.
- Background audio capability is checked in the target's Signing & Capabilities.
- Tapping between Library and Settings placeholder tabs works.
- Accent color renders as the warm ruby red across default SwiftUI controls
  (buttons, tab selection, etc.).
