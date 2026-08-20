# Model Routing for the Plume Build (Antigravity)

## How this actually works (confirmed, not assumed)
Earlier drafts of this file assumed Antigravity's `.agents/agents/*.md`
custom subagent files would let the root agent auto-delegate specific
tasks to specific pinned models. **That doesn't work in this environment.**
Confirmed by direct diagnostic: the running agent's `invoke_subagent` tool
only accepts `inherit`, `flash_lite`, `flash`, `pro` — no Claude models at
all — and it doesn't auto-load the `.agents/agents/` files regardless.

What actually works is simpler: **the model picker directly below the chat
input** (the dropdown showing Gemini 3.6 Flash / 3.5 Flash / 3.1 Pro /
Claude Sonnet 4.6 (Thinking) / Claude Opus 4.6 (Thinking) / GPT-OSS 120B)
controls the model for your **entire session** — there's no automatic
per-task switching. Every time you want a different model, you pick it
there yourself, and it applies going forward (switching may fork the
conversation, so do it at a natural break point — e.g. right after a phase
finishes, before starting the next one).

The `.agents/agents/*.md` files still exist in the project and are kept
below as **reference documentation only** — they describe the reasoning
behind each tier, not something Antigravity actually loads or executes.

## Credit-aware strategy: Gemini as the default, Claude as the manual escalation
You have meaningfully more Gemini credits than Claude credits, so the
approach below is built around that: **default every phase to Gemini 3.1
Pro, and manually switch to Claude only at specific, deliberate points** —
not as a background automation, but as a conscious decision you make each
time using the picker.

**Default rule: start every phase on Gemini 3.1 Pro (Medium is fine for
routine CRUD/UI work; bump to High for anything involving debugging,
integration, or timing-sensitive logic). Only switch to Claude when Gemini
is visibly struggling** — repeated failed attempts at the same bug, subtly
wrong output you catch on review, or one of the specific escalation points
below. Don't pre-emptively switch "just in case."

## Routing table — Plume phases → recommended tier

| Phase | Task | Default | Manually switch to Claude if... |
|---|---|---|---|
| 1 — Project setup | Xcode project, App Group, design tokens, shell UI | **Gemini 3.1 Pro (Medium)** | Basically never — standard boilerplate |
| 2 — Share extension | Extension target, activation rules, App Group wiring | **Gemini 3.1 Pro (Medium)** | Extension/App Group entitlement issues resist 2+ fix attempts |
| 3 — Content extraction | Extraction pipeline, scoring heuristic, data model | **Gemini 3.1 Pro (High)** | The extraction/scoring logic keeps producing wrong results after a couple of real fix attempts (as happened here — this phase turned out to need High effort and close review even on Gemini) |
| 4 — Kokoro TTS | Native library integration, eSpeak NG build, MLX wiring | **Gemini 3.1 Pro (High)** first | The MLX/build-system integration gets genuinely stuck — this is the single most failure-prone phase in the whole plan, and the one spot where switching to **Claude Sonnet or Opus 4.6** is most likely worth it |
| 5 — Player UI | Word-highlighting sync, background audio, lock screen | **Gemini 3.1 Pro (High)** | The audio-timestamp sync or `AVAudioSession` interruption handling produces subtly-wrong behavior that isn't obviously a "bug" until you actually test it — worth a manual Claude review pass even if Gemini's first attempt "looks" done |
| 6 — Library | List UI, pin/delete/Recently Deleted | **Gemini 3.1 Pro (Medium)** | Rarely — straightforward CRUD |
| 7 — Reading appearance | Theme system, font controls | **Gemini 3.5/3.6 Flash** | Rarely |
| 8 — Settings & stats | Stats rollups, Danger Zone confirmation flow | **Gemini 3.1 Pro (Medium)** | The Danger Zone's two-step confirmation logic specifically — worth a quick manual Claude review since a bug here means data loss without confirmation |
| 9 — Queueing | Auto-advance state machine | **Gemini 3.1 Pro (Medium)** | State bugs survive a first fix attempt |
| 10 — Audio caching | Cache-aware synthesis triggers | **Gemini 3.1 Pro (Medium)** | Rarely |
| 11 — Polish & accessibility | Broad pass across every screen | **Gemini 3.5/3.6 Flash** for volume edits, **Gemini 3.1 Pro** for visually-judged polish | Only if visual taste isn't landing after a Gemini pass |
| 12 — Testing & edge cases | Running builds/tests, parsing failures, fixing them | **Gemini Flash** to run/parse, **Gemini 3.1 Pro** to diagnose/fix | A specific bug resists two Gemini fix attempts in a row |

**In short: Claude's role in this plan is a small number of manual
escalation points, concentrated mostly around Phase 4 and Phase 5** (and,
based on how Phase 3 actually went, worth keeping in mind for extraction
issues too). Everything else should comfortably run on Gemini.

## Practical workflow
1. Before starting a phase, open the model picker and confirm you're on
   **Gemini 3.1 Pro**. Bump Medium → High for phases flagged above as
   needing it, or if a task turns out harder than expected mid-phase.
2. Work the phase normally. If something is stuck after 2 real attempts,
   or you're at one of the specific review points above (Danger Zone,
   audio sync), open the model picker and switch to **Claude Sonnet 4.6
   (Thinking)** for a review/fix, or **Claude Opus 4.6 (Thinking)** for a
   harder stuck-integration problem.
3. Switch back to Gemini 3.1 Pro before starting the next phase, so you're
   not idling on the more expensive tier by default.

## Reference: original per-role reasoning (documentation only — not
## functioning subagent config)
These describe the *intent* behind each tier, useful context for deciding
when to manually switch, even though nothing in Antigravity actually
invokes them automatically:

- **engineer** (Gemini 3.1 Pro) — primary implementer for the large
  majority of Plume's work: standard SwiftUI, CRUD, well-specified
  features, and first attempts at everything, including Phase 4/5, before
  escalation is warranted.
- **fast-runner** (Gemini Flash) — high-volume, low-ambiguity work: running
  builds/tests, parsing output, repetitive mechanical edits across many
  files (Phase 11, Phase 12).
- **researcher** (Gemini 3.1 Pro) — digesting large unfamiliar codebases or
  docs in one pass before implementation starts (e.g. reading through
  kokoro-ios before Phase 4).
- **architect** (Claude Opus 4.6, Thinking) — escalation-only, for
  problems that have already resisted a real attempt: native library
  integration stuck points, bugs surviving 2+ fix attempts.
- **reviewer** (Claude Sonnet 4.6, Thinking) — focused correctness review
  for a small number of high-stakes spots (Danger Zone confirmation flow,
  audio-sync logic) after the primary work is reported done — cheaper than
  a full re-implementation pass, used to catch "looks right but isn't"
  bugs specifically.
