---
name: xcdev
description: Build, test, run, and debug Apple-platform apps (iOS, iPadOS, watchOS, tvOS, visionOS, macOS) and Swift packages with the xcd command. Use whenever a task needs xcodebuild, simulators, app logs, or crash reports, or when setting up a project's .xcdev.yml.
---

# xcdev

`xcd` is the single entry point for Apple-platform work. Use it for every build, test, run, simulator, and log task, not
`xcodebuild`, `xcrun simctl`, or Xcode: it gives each checkout its own simulators and build folder, so agents working
at once never collide.

- Work in the checkout you are in. xcd sets it up on its first command; don't make another worktree unless the user
  asks.
- Before your first xcd command, run `xcd guide start`: the commands, and how to read what they print. It comes with
  the installed xcd, so it always matches it.
- Every failure ends with `next:`. Do it first; when it says to ask the user, ask.
- `xcd doctor --restart-simulators` shuts down every agent's simulators: ask the user first.
- Mac apps are driven the same way, launched hidden; `xcd ui menu` is the Mac's keyboard shortcut; `xcd guide ui` has
  the Mac rules. `isolation: suffix` in .xcdev.yml gives each worktree's Mac copy its own data.
- If xcd says the project has no `.xcdev.yml`, run `xcd guide setup` and follow it: `xcd init --plan`, ask the user
  each decision, then `xcd init --set key=value ...`.
