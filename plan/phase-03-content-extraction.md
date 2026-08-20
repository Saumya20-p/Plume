# Phase 3 — Content Extraction & Data Model

## Goal
Turn the raw HTML/URL captured in Phase 2 into clean chapter text (title +
body, no ads/nav/comments), and persist it as a proper document the rest of
the app can use.

## Tasks

1. **Define the SwiftData model**, e.g. `Document`:
   - `id: UUID`
   - `title: String`
   - `sourceURL: URL?`
   - `bodyText: String` (the cleaned chapter text)
   - `dateAdded: Date`
   - `progress: Double` (0–1, playback progress — updated in Phase 5)
   - `audioFileURL: URL?` (populated in Phase 4/10, nil until generated)
   - `wordTimestamps: Data?` (encoded timing data from Kokoro, populated in Phase 4)
   - `extractionFailed: Bool` (default false — used by Phase 3's fallback and Phase 12)
   - `isPinned: Bool` (default false — used by Phase 6's pin action)
   - `deletedAt: Date?` (nil = active. Set instead of hard-deleting when the
     user taps delete — see Phase 6's "Recently Deleted" flow. A background
     cleanup — e.g. on app launch — permanently purges rows where
     `deletedAt` is older than 30 days, along with their cached audio file.)
   - `wordCount: Int` (word count of `bodyText`, computed at extraction time
     — feeds the listening-stats math in Phase 8, cheaper than recomputing
     it from `bodyText` every time)

2. **Define a lightweight listening-session model**, e.g. `ListeningSession`:
   - `id: UUID`
   - `documentId: UUID` (which chapter this session belongs to)
   - `date: Date` (day the session happened, for daily/weekly rollups)
   - `secondsListened: Double`
   - `wordsListened: Int` (approximate — words covered by playback progress
     during this session, using `wordTimestamps`)
   - `playbackSpeed: Double` (speed the session was played at, used to
     compute "time saved" vs. 1.0x in Phase 8)
   - Written to incrementally during playback in Phase 5 (e.g. flush a
     session row every time playback pauses, finishes, or the app
     backgrounds) rather than one giant row per chapter — this is what
     lets Phase 8 build daily/weekly charts without re-deriving history
     from scratch.

3. **Build the readability-style extractor**
   - Input: raw HTML string.
   - Approach: implement a simplified readability heuristic in Swift —
     - Parse HTML (a lightweight HTML parser is fine; doesn't need to be a
       full DOM engine).
     - Strip `<script>`, `<style>`, `<nav>`, `<header>`, `<footer>`,
       elements with class/id names matching common noise patterns (`ad`,
       `sidebar`, `comment`, `share`, `nav`, `menu`, `related`, `footer`).
     - Score remaining block elements by text density (ratio of text length
       to tag count) to find the main content block — the classic
       Readability.js approach, simplified.
     - Extract the largest/highest-scoring content block as `bodyText`.
     - Extract `<title>` or the first `<h1>` as `title`.
   - If extraction produces suspiciously little text (e.g. under ~200
     characters), set `extractionFailed = true` instead of saving garbage —
     Phase 12 will add a manual-paste fallback UI for this case.

4. **Wire it into the pending-share pickup flow from Phase 2**
   - When the main app picks up a pending shared item, run it through the
     extractor and save a new `Document`.
   - Clear the pending item from shared storage once successfully processed.

5. **Basic sanity UI (temporary, real UI comes in Phase 6)**
   - A simple debug list showing extracted documents' titles and a text
     preview, just enough to confirm extraction is working correctly.

## Acceptance criteria
- Sharing a chapter from 3+ different web novel sites (varied HTML structure)
  produces clean `bodyText` with no visible nav/ad/comment noise, and a
  sensible `title`.
- Extraction runs entirely on-device, no network calls beyond what Phase 2
  already captured.
- A deliberately messy or unusual page correctly sets `extractionFailed =
  true` rather than saving junk text.
- Extracted documents persist across app relaunches (SwiftData store works).
