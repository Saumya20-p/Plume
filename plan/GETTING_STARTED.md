# Getting Started with Plume + Antigravity

## Folder structure
Here's what you said + what you should add:

```
~/projects/plume/                    # Main app folder (create this)
├── plume-plan/                      # All 13 phases + docs (copy from outputs)
│   ├── 00_START_HERE.md
│   ├── phase-01-project-setup.md
│   ├── phase-02-share-extension.md
│   ├── ... (phases 3–12)
│   ├── MODEL_ROUTING.md             # Model/agent strategy
│   └── GETTING_STARTED.md           # This file
├── .agents/
│   └── agents/                      # Custom agent definitions (you'll create these)
│       ├── engineer/
│       │   └── agent.md
│       ├── fast-runner/
│       │   └── agent.md
│       ├── researcher/
│       │   └── agent.md
│       ├── architect/
│       │   └── agent.md
│       └── reviewer/
│           └── agent.md
├── plume/                           # Actual Xcode project (created by Phase 1)
│   ├── Plume.xcodeproj
│   ├── Plume/
│   ├── PlumShare/                   # Share Extension (created by Phase 2)
│   └── ...
└── README.md                        # Quick project overview
```

The `.agents/agents/` folder is where Antigravity auto-discovers your custom
agents — place all five agent `.md` files there, and they'll appear in the
`/agents` panel automatically.

## Pre-flight checklist (do this before opening Antigravity)

### 1. Device setup
- **Connect a real iPhone** to your Mac via USB and trust it in Xcode.
  Later phases (Phase 4–5) absolutely need a real device for Metal/MLX
  support. Do this first.
- You do **not** need a paid Apple Developer account yet — a free Apple ID
  covers everything in this plan.

### 2. Antigravity installation & credentials
- Make sure Antigravity is installed and you're logged in with your Google
  account (where your Gemini Pro credits are).
- Test a simple `/help` command in an Antigravity session to confirm it's
  working.

### 3. Agent Skills (Step 0 from 00_START_HERE.md)
- In a terminal, run:
  ```bash
  git clone https://github.com/agentskill-sh/ags.git ~/.gemini/antigravity/skills/learn
  ```
  This installs the `/learn` command for grabbing skills.
- Open Antigravity and install the four required skills (takes ~5 minutes
  total):
  1. `/learn @superagents-lab/xcode27-skills` — Apple's official Xcode skills
  2. `/learn @wshobson/agents` then find `mobile-ios-design` within it
  3. `/learn @vermont42/iOS-Design-Agent-Skill`
  4. `/learn @dimillian/skills` (or `npx skills add dimillian/skills`)
- These land in `~/.gemini/antigravity/skills/` globally and are now
  available to all your projects.

### 4. Create the custom agents
- Create the folder structure `.agents/agents/` inside `~/projects/plume/`.
- Copy the five agent definitions from the "Example subagent definitions"
  section of `MODEL_ROUTING.md` into separate `.md` files:
  - `.agents/agents/engineer/agent.md`
  - `.agents/agents/fast-runner/agent.md`
  - `.agents/agents/researcher/agent.md`
  - `.agents/agents/architect/agent.md`
  - `.agents/agents/reviewer/agent.md`
- **Before you paste them**: open your own `/agents` panel in Antigravity
  and confirm the exact model strings shown there (e.g. is it
  `gemini-3-pro` or `gemini-3.1-pro`? is Claude called `claude-sonnet-4.5`
  or something else?). Update the `model:` field in each agent definition
  to match your actual model strings — don't use the placeholder names
  directly.
- Once the files are in place, open Antigravity, run `/agents`, and verify
  all five agents appear under "Available Agents" — if they don't show up,
  check that the folder paths and YAML frontmatter are exactly right.

### 5. Git repo (optional but recommended)
- In `~/projects/plume/`, run:
  ```bash
  git init
  echo "plume/" >> .gitignore      # Ignore the Xcode project folder
  git add -A
  git commit -m "Initial: Plume build plan and agent config"
  ```
  This lets you track Phase 1's Xcode project creation and all subsequent
  changes in one repo.

## Running the build

### Session 1: Phase 1 — Project Setup

1. Open Antigravity and navigate to `~/projects/plume/`.
2. Pick **Gemini Pro** as your starting model (via `/agents` panel).
3. Paste the contents of `phase-01-project-setup.md` into the chat with a
   preamble like:
   ```
   I'm building an iOS app called Plume. Here's Phase 1 of the build plan.
   Execute all the tasks in this phase — create the Xcode project, add
   capabilities, set up SwiftData, define design tokens, and build the
   shell UI. Let me know when you're done and what you created.

   [then paste the full phase file]
   ```
4. The agent will create `~/projects/plume/plume/` (the actual Xcode
   project). It might ask clarifying questions — answer them as needed.
5. When done, verify in Xcode that the project opens and runs on your
   connected device.

### Sessions 2–12: Each remaining phase

- Open a **new Antigravity session** for each phase (don't reuse the same
  one, since you'll have different context each time).
- Default to **Gemini Pro** for each phase, *except* if you're explicitly
  escalating to Claude for a specific reason.
- Paste the phase file the same way you did Phase 1.
- After the agent finishes and you've tested locally, commit your changes:
  ```bash
  git add -A
  git commit -m "Phase N: [brief description]"
  ```

### Escalation workflow (if Gemini gets stuck)

1. **First sign of trouble**: if the agent reports "I've tried this twice
   and it's still not working" or you spot output that looks suspicious,
   open the `/agents` panel with Ctrl+A (or the CLI equivalent).
2. **Invoke the right subagent**: type `/invoke @architect` or `/invoke
   @reviewer` depending on whether you need a full re-attempt or just a
   careful review.
3. **OR switch the primary model**: if you want to re-run the whole Phase
   as Claude instead, use `/agents` to switch to Claude Opus/Sonnet — this
   will fork your current session so you don't lose context.
4. **Document the failure**: make a note of what Gemini tried and why it
   didn't work — this helps you spot patterns (is Phase 4 always hard? is
   one particular library integration a pain point?) and tune your
   escalation strategy going forward.

### After Phase 6 (MVP checkpoint)

You now have a complete, testable app. **Pause here if you want** — you can
use it to read web novels for real at this point, and Phases 7–12 are
refinement, not new features. Come back to Phases 7–12 whenever you feel
ready. No penalty for stopping.

## Troubleshooting

**Agent doesn't appear in `/agents` panel**
- Check folder path: must be `.agents/agents/<name>/agent.md`, not
  `.agent/` (singular) or other variations.
- Check YAML frontmatter: `name:`, `description:`, `model:`, and
  `subagent: true` must all be present and valid.
- Restart Antigravity after creating new agent files.

**Model string doesn't work ("unknown model")**
- Open `/agents` and look at the exact strings shown in the model picker.
- Update your agent `.md` files to match exactly.
- Common issue: the docs might say `gemini-3-pro` but your actual instance
  has `gemini-3.1-pro` — the difference matters.

**Xcode project won't build after Phase 1**
- Make sure you connected a real device first (Phase 1's "Before you start"
  section).
- If it's a signing issue, go to Xcode → Signing & Capabilities and
  confirm your free Apple ID is selected.
- Phase 1's acceptance criteria include "project builds on a simulator/
  device" — if it doesn't, flag it to the agent before moving on.

**Phase 4 (Kokoro) is taking forever or failing**
- This is normal — Phase 4 is the hardest phase. The first `gemini-3-pro`
  attempt might stall trying to build eSpeak NG or wire up MLX.
- After 1–2 attempts, escalate to `/invoke @architect` or switch the
  primary session to Claude Opus. This phase is genuinely worth Claude
  credits if Gemini struggles.
- Alternatively, consult the "Troubleshooting reference" section of
  `phase-04-kokoro-tts.md` directly — it has common eSpeak/MLX gotchas
  listed.

## Credit usage expectations

Rough estimates (actual will vary based on how many iterations you need):

- **Gemini Pro**: ~1–2 full phase runs per session, depending on complexity.
  Most phases run on Gemini's first or second attempt.
- **Gemini Flash**: Used sparingly for Phase 11–12's mechanical work.
- **Claude credits**: Spend only if Gemini gets visibly stuck on Phase 4/5,
  or for a targeted review pass on the Danger Zone / audio-sync logic.

If you're iterating a lot or hitting bugs, Gemini credits will go faster
than expected — that's fine, it's why you have more of them available.
Don't hoard Claude credits "just in case" — only pull them in when Gemini
actually struggles.

## Next step
1. Set up your device (if you haven't already).
2. Install the agent skills (Step 0).
3. Create the `.agents/agents/` folder and drop in the five agent `.md`
   files with your actual model strings.
4. Open Antigravity, navigate to `~/projects/plume/`, and start Phase 1.

You're ready to go.
