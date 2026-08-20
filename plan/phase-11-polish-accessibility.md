# Phase 11 — UI/UX Polish & Accessibility

## Goal
Now that the full pipeline works end to end (share → extract → generate →
play → theme), do a dedicated pass on visual polish, motion, and
accessibility across the whole app. This phase intentionally comes after
functionality is proven, per the project's build philosophy — don't polish
what might still change structurally.

## Tasks

1. **Visual consistency pass**
   - Audit every screen (Library, Player, Appearance sheet, Settings, Share
     Extension confirmation) against the Phase 1 design tokens — consistent
     spacing, corner radii, and accent color usage (buttons, active states,
     progress indicators, selection highlights only — accent should not be
     overused as a background color).
   - Real app icon and launch screen (replacing Phase 1's placeholders),
     using the warm ruby accent and dark base as the visual identity.

2. **Motion & transitions**
   - Smooth transitions between Library → Player, sheet presentations
     (Appearance, Settings), and state changes (generating → ready-to-play).
   - Subtle animation for the word-highlighting cursor in the player so it
     doesn't feel like it's snapping harshly between words.

3. **Empty/loading/error states**
   - Confirm every async operation (extraction, synthesis, queue
     processing) has a clear loading state and a clear, non-technical error
     state — this pairs with Phase 12's error handling but focuses here on
     making those states look intentional rather than default/system.

4. **Accessibility**
   - **Dynamic Type**: all text (including the reading view's font-size
     controls from Phase 7) should scale sensibly with the system's Dynamic
     Type setting, without breaking layout.
   - **VoiceOver**: meaningful accessibility labels on all interactive
     elements — playback controls, Library rows (should announce title,
     progress, and state together), theme preset cards, queue reorder
     controls.
   - **Contrast**: verify all three reading themes (Basic/Warm/Muted) meet
     reasonable contrast standards for body text against their backgrounds.
   - **Reduce Motion**: respect the system's Reduce Motion setting by
     simplifying/removing non-essential animations.

## Acceptance criteria
- The app feels cohesive and intentional across every screen, not like
  separate phases bolted together.
- VoiceOver can navigate the entire core flow (share a chapter → find it in
  Library → play it → adjust appearance) without dead ends or unlabeled
  controls.
- Dynamic Type at larger accessibility sizes doesn't break any layout
  (verify at both a default size and the largest accessibility size).
- Reduce Motion setting visibly simplifies animations when enabled.
