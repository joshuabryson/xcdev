---
name: xcdev
description: Build, test, run, and debug Apple-platform apps (iOS, iPadOS, watchOS, tvOS, visionOS, macOS) and Swift packages with the xcd command. Use whenever a task needs xcodebuild, simulators, app logs, or crash reports, or when setting up a project's .xcdev.yml.
---

# xcdev

`xcd` is the single entry point for Apple-platform work. Use it instead of `xcodebuild`, `xcrun simctl`, or Xcode:
it gives each git worktree its own simulator clones and DerivedData, so parallel agents never collide.

## Start here

1. Run `xcd help`. It lists every command, the project's own commands (from `.xcdev.yml`), and installed plugins.
2. If the project has no `.xcdev.yml`, run `xcd guide setup` and follow it: `xcd init --plan`, ask the user each
   decision, then `xcd init --set key=value ...`.
3. Create your own worktree with `xcd wt create <name>` and work inside the path it prints. One agent per worktree.

## Everyday commands

| Task | Command |
|---|---|
| Build | `xcd build [--device <name>] [--scheme <name>] [--warnings]` |
| Test | `xcd test [--only Target/Class/test()] [--skip ...]` |
| Run and watch for a crash | `xcd run [--preset <name>] [-- <app args>]` |
| App output or unified log | `xcd logs --app`, `xcd logs [--since 2m] [--grep <text>] [--follow --for 30s]` |
| Install, launch, stop | `xcd install`, `xcd launch`, `xcd terminate` |
| Simulator | `xcd sim boot`, `xcd sim open`, `xcd sim erase` |
| Context for scripts | `xcd context` (prints XCD_* variables) |
| Explain a config key | `xcd config explain <key>` |
| Fix simulators or worktrees | `xcd doctor`, then `xcd doctor --fix` (read the problems first: it may restart CoreSimulator, which shuts down every agent's simulators) |

## Reading results

- Output is compact text by default; add `--json` (or set `XCD_OUTPUT=json`) for one JSON object per command.
- Every failure ends with `next:`. Do what it says before trying anything else.
- Exit codes: 1 = the task failed (fix the code), 2 = fix the command line or config, 3 = fix the environment
  (`xcd doctor`). `xcd help errors` lists every error code.
