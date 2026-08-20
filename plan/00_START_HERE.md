# Plume — Build Plan (Start Here)

Read this file first. It explains what Plume is, the tech decisions already made,
and how to work through the rest of this folder.

## Step 0 — Install these Agent Skills first (do this before Phase 1)

Before starting any phase file, install the following Agent Skills. They give
the agent authoritative, current knowledge on SwiftUI/iOS patterns and design
quality that it wouldn't reliably have otherwise. Skip this step and expect
worse code and worse-looking UI throughout every phase.

**How to install:** Antigravity supports the open Agent Skills format
(`SKILL.md`). The fastest path is the `/learn` command:

```
git clone https://github.com/agentskill-sh/ags.git ~/.gemini/antigravity/skills/learn
```

Then inside an Antigravity session, install each skill below with
`/learn @owner/repo` (or the specific install command listed if different).
Skills install to `~/.gemini/antigravity/skills/` (global, all projects) —
that's the right scope for these, since none of them are Plume-specific.

1. **Apple's official Xcode skills** — `superagents-lab/xcode27-skills`
   Apple's own Agent Skills, exported directly from Xcode 27. Covers
   SwiftUI, UIKit modernization, Swift Testing, security hardening, and
   on-device UI verification via screenshots/touch interaction. Install
   first — this is the most authoritative baseline.

2. **mobile-ios-design** — `wshobson/agents` (skill: `mobile-ios-design`)
   Comprehensive iOS Human Interface Guidelines + SwiftUI patterns:
   layouts, NavigationStack/TabView, SF Symbols, Dynamic Type, semantic
   color/materials for light/dark mode, accessibility, safe areas, VoiceOver
   testing. This is the general design/HIG foundation.

3. **iOS Design Agent Skill** — `vermont42/iOS-Design-Agent-Skill`
   A design-critique skill focused on actual visual quality, not just
   compliance — typographic sophistication, color cohesion, spatial
   composition, motion, depth. Enforces an "anti-slop" standard against
   generic template UI (unstyled lists, flat backgrounds, screens that look
   like Apple's own Settings app). Use this for a critique/polish pass after
   screens are built, especially relevant for Phase 11.

4. **SwiftUI Liquid Glass** — `dimillian/skills` (skill: `swiftui-liquid-glass`)
   Confirmed working in Antigravity. Install with:
   `npx skills add dimillian/skills`
   (lands at `~/.gemini/antigravity/skills/dimillian/skills/swiftui-liquid-glass/`)
   Covers correct `.glassEffect()` modifier ordering, `GlassEffectContainer`
   usage, `#available(iOS 26, *)` gating with fallback UI for older versions,
   and morphing transitions. **Design rule for Plume specifically: glass
   effects belong on navigation/chrome and controls only (mini-player bar,
   the full player's bottom control dock, the Appearance sheet's toolbar) —
   never on the reading surface itself.** Keep chapter text and theme
   backgrounds flat so the Basic/Warm/Muted themes stay legible and don't
   fight the glass material.

5. **(Optional) Design audit skill** — `devanshuDesai/agent-skills`
   (skill: `design-audit`)
   A separate, broader design-review checklist (15 scored dimensions, 8
   design rules) — useful for a final pre-launch pass across the whole app
   alongside #3 above.

Do not install every Swift skill you can find — these five (four required,
one optional) are enough. Overlapping/conflicting skills competing for the
same context slows the agent down and can produce inconsistent guidance.

## What is Plume

Plume is an iOS app for listening to web novels. The user shares a web novel
chapter from Safari into Plume. Plume extracts the clean chapter text, converts
it to natural-sounding speech entirely on-device, and plays it back with
word-by-word highlighting synced to the audio — similar to Speechify, but free,
private, and fully offline after the model is downloaded once.

## Core user flow

1. User is reading a web novel chapter in Safari.
2. User taps Share → Plume.
3. Plume extracts the chapter title + body text from the page and saves it to the Library.
4. User opens the chapter in Plume and hits play.
5. Text-to-speech audio generates on-device via Kokoro TTS and plays back with
   the currently-spoken word highlighted on screen.
6. User can customize the reading view (theme, font, size) and control playback
   (speed, skip, lock screen controls) independently of the visuals.

## Tech stack (decided — do not re-litigate unless something is broken)

- **Platform:** iOS 18.0+, Swift, SwiftUI, SwiftData for persistence.
- **Sharing:** Native iOS Share Extension target + shared App Group container.
- **Content extraction:** Custom readability-style parser (no server, all on-device).
- **Text-to-speech:** [KokoroSwift](https://github.com/mlalma/kokoro-ios) — an
  on-device port of the Kokoro-82M TTS model running via Apple's MLX framework.
  Apache 2.0 licensed, free for commercial and personal use, no API keys, no
  network calls at runtime. Model file (~330MB, `kokoro-v1_0.safetensors` from
  `prince-canuma/Kokoro-82M` on Hugging Face) is bundled directly into the
  app for now — see Phase 4 for details. Reference app:
  [KokoroTestApp](https://github.com/mlalma/KokoroTestApp) for integration patterns.
- **Audio playback:** AVFoundation, background audio mode, `MPNowPlayingInfoCenter`
  + `MPRemoteCommandCenter` for lock screen / Control Center controls.
- **No paid APIs, no cloud TTS, no subscriptions.** Everything runs on-device.

## Design direction (decided)

- **App-wide theme:** Follows system light/dark mode. Base palette is
  near-black / charcoal in dark mode, soft off-white in light mode — not pure
  white or pure black, to reduce eye strain.
- **Accent color:** Warm ruby red / garnet. Suggested starting value:
  `#A6342A` (primary), with a lighter variant around `#C2564A` for pressed/hover
  states and a darker variant around `#7E2620` for text-on-accent contexts.
  Warm, not orange-coral, not cold blue-red. Use it for buttons, progress bars,
  active states, and selection highlights only — keep everything else neutral.
- **Reading view theming is independent of the app theme.** Three named presets,
  full spec in Phase 7:
  - **Basic** — black background, off-white text.
  - **Warm** — cream/sepia background, warm dark brown text.
  - **Muted** — charcoal background, soft gray text.
  Plus a "Match Device" option that follows system appearance instead.
- **Default font:** Georgia (serif, for the reading view specifically — general
  app UI can use system font / San Francisco).

## How to work through this folder

**Step 0 (above) comes first, before touching any phase file.** Once skills
are installed, each `phase-NN-*.md` file is a **self-contained build step**.
Feed them to the coding agent one at a time, in order. Each phase assumes all
previous phases are complete. Do not skip ahead — later phases depend on data
models and services built in earlier ones.

Phase order:

0. Install Agent Skills (see Step 0 above) — do this first, once, not per-phase
1. `phase-01-project-setup.md` — Xcode project, App Group, design tokens, shell UI
2. `phase-02-share-extension.md` — Safari share extension
3. `phase-03-content-extraction.md` — readability parser + data model
4. `phase-04-kokoro-tts.md` — on-device TTS integration
5. `phase-05-player-ui.md` — playback UI, highlighting, background audio
6. `phase-06-library.md` — library / saved chapters list

**→ MVP checkpoint.** After Phase 6, you have a complete, working, testable
app: share a chapter → it gets extracted → generate audio → play it back
with highlighting → find it again in the Library. Everything from here on
(7–12) is refinement, not new core functionality. If you want to pause and
just use the app for a while before continuing, this is a reasonable place
to do it.

7. `phase-07-reading-appearance.md` — Basic/Warm/Muted themes, font controls
8. `phase-08-settings.md` — app-wide settings screen
9. `phase-09-queueing.md` — multi-chapter queue + auto-advance
10. `phase-10-audio-caching.md` — persist generated audio, avoid re-synthesis
11. `phase-11-polish-accessibility.md` — visual polish, Dynamic Type, VoiceOver
12. `phase-12-testing-edge-cases.md` — failure modes, error handling, edge cases

## Known open questions / things to double-check as you go
- **eSpeak NG's license (GPLv3)** — fine for personal use, a real
  consideration if this ever becomes a public/App Store release. Flagged in
  detail in `phase-04-kokoro-tts.md`.
- **Model hosting URLs move.** The exact Hugging Face repo hosting Kokoro's
  MLX-converted weights (referenced in Phase 4) is accurate as of this
  plan's writing but community-hosted model mirrors can change — verify the
  link still resolves before downloading.
- **KokoroSwift package version numbers** — pin to whatever the latest
  stable release is when you actually start Phase 4, and confirm it still
  includes the per-token timestamp feature the highlighting system depends
  on.

## Ground rules for the agent

- Bundle the Kokoro model directly in the app for now (this is a personal
  build, not shipping to the App Store yet). Do not build first-launch model
  download logic unless a later phase explicitly asks for it.
- Prefer SwiftData over Core Data unless there's a concrete reason not to.
- Keep each phase's changes scoped to what that phase file describes — resist
  the urge to jump ahead to later phases' features.
- If a phase's requirements conflict with something already built, flag it
  instead of silently overriding earlier work.
