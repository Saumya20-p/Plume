# Phase 7 — Reading Appearance Settings

## Goal
Give the reading/player view its own independent appearance system, decoupled
from system light/dark mode — modeled closely on Speechify's "Appearance"
sheet (see reference screenshot: Player theme selector, three named presets,
font picker, font size stepper, bold toggle).

## Tasks

1. **Theme model**
   - Define an enum, e.g. `ReadingTheme`, with three cases plus a device-
     matching mode:
     - `basic` — black background, off-white text
     - `warm` — cream/sepia background, warm dark-brown text
     - `muted` — charcoal background, soft gray text
     - Separately, a `playerAppearanceMode` setting: `matchDevice` vs
       `locked` (locked = always use the selected theme regardless of
       system light/dark mode; matchDevice = pick between reasonable
       light/dark variants automatically). Model this after the reference
       screenshot's "Player: Match Device" row.
   - Each theme should define at minimum: background color, primary text
     color, and the highlight color used for the currently-spoken word
     (tie to the accent color at reduced opacity, consistent app-wide).

2. **Font settings**
   - Font family picker. Default: **Georgia**. Include a handful of other
     serif/sans options (e.g. system serif, system sans, a couple of other
     bundled/system-available fonts) — doesn't need to be exhaustive.
   - Font size stepper (+/-), with a sensible min/max range.
   - Bold toggle (bolds the reading text without necessarily changing the
     rest of the UI).

3. **Appearance sheet UI**
   - A modal sheet (matches the reference screenshot's layout): dismiss
     button, "Appearance" title, Player match-device row, Cursor/highlight
     color row (can reuse the accent color rather than being separately
     configurable, unless you want to expose it), the three theme preset
     cards with icons, then Font / Font Size / Bold Font rows below.
   - Reachable from the Phase 5 player screen (e.g. an appearance/settings
     icon in the player's toolbar).

4. **Persistence**
   - Store the selected theme, font, size, and bold state via
     `@AppStorage` or a small settings store — should persist across app
     launches and apply immediately/live when changed (no need to reopen the
     chapter).

5. **Apply throughout the reading experience**
   - The full player screen's text rendering (Phase 5) and the word
     highlighting color should respect whichever theme/font/size is
     currently selected.

## Acceptance criteria
- All three themes (Basic, Warm, Muted) are selectable and visibly change
  the reading view's background/text colors immediately.
- Font, font size, and bold toggle changes apply immediately and persist
  after force-quitting and reopening the app.
- "Match Device" mode correctly follows system light/dark mode changes live
  (test by toggling system appearance while the app is open).
- Appearance sheet visually matches the reference screenshot's structure and
  interaction pattern (preset cards, row-based settings below).
