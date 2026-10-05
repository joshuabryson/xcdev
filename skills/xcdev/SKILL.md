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
| Screenshot or video | `xcd ui screenshot`, `xcd ui record start` … `xcd ui record stop` (each prints the file's path; read it) |
| Read and drive the UI (iPhone/iPad) | Launch the app first (`xcd run` or `xcd launch`; not needed with `--system`). `xcd ui tree` lists what is on screen with refs; `xcd ui tap <target>`; `xcd ui type <text> --into <target> [--clear] [--submit]`; `xcd ui swipe up\|down\|left\|right [--on <target>]`; `xcd ui long-press <target>`; `xcd ui wait <target> [--gone]`; `xcd ui button home`; `xcd ui rotate landscape-left`. A target is `id:<identifier>`, `"label:<text>"`, `"label~<part>"`, `ref:e<N>`, or `@x,y` (tap and long-press only). Read `xcd guide ui` before the first time |
| Device state | `xcd sim open-url <url>`, `xcd sim push --alert <text>`, `xcd sim privacy grant photos`, `xcd sim status-bar --time 9:41`, `xcd sim appearance dark`, `xcd sim location <lat>,<lon>`, `xcd sim pasteboard set --text <s>` (or `--image <file>`), `xcd sim addmedia <file>` |
| Context for scripts | `xcd context` (prints XCD_* variables) |
| Explain a config key | `xcd config explain <key>` |
| Fix simulators or worktrees | `xcd doctor`, then `xcd doctor --fix` (read the problems first: it may restart CoreSimulator, which shuts down every agent's simulators) |

## Reading results

- Captures go to the media folder (`ui.media.dir`, default `.xcdev-media/<worktree>/<branch>` in the main checkout;
  `$XCD_MEDIA_DIR` in scripts). Screenshot sizes are pixels; divide by the reported scale for points.
- Driving loop: `xcd ui tree` (see), an action such as `xcd ui tap …` or `xcd ui type …` (act), then verify: add
  `--tree` to the action, or run `xcd ui wait …`. An action that reports success can still have done nothing, so
  always verify. Refs are only good until the next tree (`xcd ui tree`, an action with `--tree`, or an "ambiguous"
  failure, whose numbered candidates become the refs).
- Actions and `xcd ui wait` act on the app in front and any system alert over it; when the app isn't in front they
  fail, saying so (`xcd launch` or `xcd run` fixes that). While a system alert is up nothing in the app can be acted
  on, and neither can an element under the keyboard: deal with the alert or keyboard first.
- `xcd ui swipe up` moves the finger up, which scrolls a list towards its end. Off-screen elements are only in
  `xcd ui tree --all`.
- `xcd test` stops the UI runner when the run includes UI tests; the next `xcd ui` command starts it again.
- Output is compact text by default; add `--json` (or set `XCD_OUTPUT=json`) for one JSON object per command.
- Every failure ends with `next:`. Do what it says before trying anything else.
- Exit codes: 1 = the task failed (fix the code), 2 = fix the command line or config, 3 = fix the environment
  (`xcd doctor`). `xcd help errors` lists every error code.
