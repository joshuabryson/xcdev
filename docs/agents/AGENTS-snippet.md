<!-- xcd:begin: written by xcd; edit outside this block, since `xcd doctor --fix` rewrites it -->
## Apple-platform work: use xcd

Use `xcd` for every build, test, run, simulator, and log task, not `xcodebuild`, `xcrun simctl`, or Xcode. It gives
each checkout its own simulators and build folder, so agents working at once never collide.

- Work in the checkout you are in. xcd sets it up on its first command; don't make another worktree unless the user
  asks.
- Before your first xcd command, run `xcd guide start`: the commands, and how to read what they print.
- Every failure ends with `next:`. Do it first; when it says to ask the user, ask.
- `xcd doctor --restart-simulators` shuts down every agent's simulators: ask the user first.
- If xcd says the project has no `.xcdev.yml`, follow `xcd guide setup`.
- When your work on the device is finished (the change is done, committed, or the investigation is over), run `xcd sim shutdown --all`. A clone nobody has used for 10 minutes shuts itself down; the next command boots it again in about 15 seconds, with the app still installed.
<!-- xcd:end -->
