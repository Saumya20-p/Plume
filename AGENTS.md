# Plume workspace conventions

## Scratch work and outputs

- Keep all temporary Plume work under `/Users/saumyapatel/Documents/Plume/.scratch/<task>/`: logs, screenshots, temporary reports, scripts, exported test attachments, build products, dependency workarounds, and experimental checkouts. Do not create additional `Plume-*` folders directly in Documents.
- Use task-specific subfolders such as `build/`, `logs/`, `screenshots/`, and `scripts/`. Preserve useful reports and source changes; being ignored or untracked does not make an artifact disposable.
- Configure explicit output paths where supported: XcodeBuildMCP `derivedDataPath`, SwiftPM `--scratch-path`, tool export paths, and script output arguments must point inside `.scratch/<task>/`. Avoid the tracked legacy `.build` symlink, which points to an unavailable `/tmp` cache.
- XcodeBuildMCP manages some logs/result bundles/test products in its own workspace, and simulator/app data belongs to CoreSimulator. When a tool cannot redirect an output, explain that exception and record the resulting path. Never move signing material, model assets, dependencies, or tool-managed state merely to satisfy this convention.
- `.scratch/` is ignored by Git and lives outside all Xcode synchronized source groups. Do not add it to targets, resources, Copy Files phases, package source lists, or the app bundle. Retained project documentation, source, configuration, and required resources belong in their normal locations.

## Worktrees and cleanup

- Inspect task history, contents, Git status, and references before relocating or deleting artifacts. Preserve unique source changes and useful evidence. Leave unrelated or uncertain items alone and explain what needs review.
- Create experimental worktrees with `git worktree add` under `.scratch/<task>/worktree`. Relocate registered worktrees with `git worktree move`; verify their HEAD, staged/unstaged changes, and registration afterward. If Git does not support relocation, leave them intact and explain why. Never manually move/delete worktrees or discard source changes for cleanup.
- Before deleting a confirmed disposable file, verify it is not needed by app functionality, builds, tests, resources, dependencies, signing, or an active development workflow. A passing build alone does not establish that deletion is safe.
