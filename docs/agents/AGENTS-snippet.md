## Apple-platform builds: use xcd

This project uses xcdev (`xcd`) for every build, test, run, simulator, and log task. Don't call `xcodebuild`,
`xcrun simctl`, or Xcode directly: xcd gives each git worktree its own simulator clones and build folder, so agents
working in parallel never collide.

- Discover: `xcd help` lists every command, including this project's own commands; `xcd help <command>` gives details.
- Work in your own worktree: `xcd wt create <name>`, then `cd` into the path it prints. One agent per worktree.
- Build and test: `xcd build`, `xcd test` (`--only Target/test()` to narrow). Failures print compiler-style
  `file:line:col: error:` lines.
- Run: `xcd run` builds, installs, launches, and watches for a crash; `xcd logs` and `xcd logs --app` show output.
- Every failure ends with `next:`; do that. `--json` gives one JSON object per command; `xcd help errors` lists codes.
- If simulators or worktrees misbehave: `xcd doctor`, then `xcd doctor --fix`. Read the problems first: `--fix` may
  restart CoreSimulator, which shuts down every agent's simulators.
- No `.xcdev.yml` yet? Follow `xcd guide setup`.
