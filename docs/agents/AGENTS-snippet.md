## Apple-platform builds: use xcd

This project uses xcdev (`xcd`) for every build, test, run, simulator, and log task. Don't call `xcodebuild`,
`xcrun simctl`, or Xcode directly: xcd gives each git worktree its own simulator clones and build folder, so agents
working in parallel never collide.

- Discover: `xcd help` lists every command, including this project's own commands; `xcd help <command>` gives details.
- Work in your own worktree: `xcd wt create <name>`, then `cd` into the path it prints. One agent per worktree.
- Build and test: `xcd build`, `xcd test` (`--only Target/test()` to narrow). Failures print compiler-style
  `file:line:col: error:` lines.
- Run: `xcd run` builds, installs, launches, and watches for a crash; `xcd logs` and `xcd logs --app` show output.
- See the app: `xcd ui screenshot` prints the PNG's path; `xcd ui record start` / `xcd ui record stop` make a video.
  Set device state with `xcd sim open-url`, `xcd sim push`, `xcd sim privacy`, `xcd sim status-bar`, and friends
  (`xcd help sim`).
- Go straight to a screen: `xcd open` lists the project's routes (links, launch arguments, and scripts that reach a
  screen); `xcd open <route> name=value` opens one and checks that it arrived. `xcd guide deeplinks` shows how to add
  routes.
- Drive the app (iPhone/iPad simulators), once it is running in front: `xcd ui tree` lists elements with refs;
  `xcd ui tap id:<identifier>` (or `"label:<text>"`, `e<N>` from the newest tree, `@x,y`);
  `xcd ui type <text> --into <target>`; `xcd ui swipe up`; `xcd ui wait <target>` to confirm what happened, or add
  `--tree` to an action to get the tree after it. An "ambiguous" failure lists the candidates with refs to
  pick from. None of it takes focus on the Mac. `xcd guide ui` has the whole loop.
- Before you call a change done: `xcd format` puts the lines you changed in the project's format, then `xcd lint`
  lists the lint findings your change introduced, each with the project's own tool. Fix those findings, and leave
  the older ones it counts alone. `xcd guide quality` explains both results.
- Every failure ends with `next:`; do that. `--json` gives one JSON object per command; `xcd help errors` lists codes.
- If simulators or worktrees misbehave: `xcd doctor`, then `xcd doctor --fix`, which repairs only this project.
  `xcd doctor --restart-simulators` shuts down every agent's simulators: ask the user first.
- No `.xcdev.yml` yet? Follow `xcd guide setup`.
