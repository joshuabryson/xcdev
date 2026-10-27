# xcdev

`xcd` is a command-line tool that AI agents (and humans) use for Apple-platform development: build, test, run, logs,
screenshots and recordings, simulators, and driving the app's UI, for iOS, iPadOS, watchOS, tvOS, visionOS, and
macOS apps and Swift packages. Every git worktree gets its own simulator clones and build folders, so many agents can
work at once without colliding, and nothing xcd does takes focus from the person using the Mac.

Status: early. Version 0.1.0 is in daily use on the author's projects; commands and output may still change before 1.0.

## Install

Until the first tagged release, build from source. Requires macOS 15 or later and Xcode; the author builds with
Xcode 27, and CI pins Xcode 26.2 (`.github/workflows`).

```sh
git clone https://github.com/joshuabryson/xcdev.git && cd xcdev
swift build -c release
ln -s "$PWD/.build/release/xcd" /usr/local/bin/xcd     # or anywhere on your PATH
```

Release binaries (a universal tarball) and a Homebrew tap follow the first release; `scripts/release.sh` builds both.

Shell completion for zsh, bash, and fish: tab completes commands and flags, and the values of `--device`, `--scheme`,
`--preset`, and `--worktree` come from the current project. Install the script into a directory on your `fpath`,
e.g. for zsh:

```sh
xcd --generate-completion-script zsh > ~/.zsh/completions/_xcd
```

## Quick start

```sh
cd MyApp                  # a git repository with an Xcode project or Package.swift
xcd init --plan           # see what xcd detected and the choices to make; writes nothing
xcd init --defaults       # write .xcdev.yml with the recommendations (or --set key=value ...)
xcd wt create login-flow  # another worktree, when you want one: its own branch, simulators, and DerivedData
cd ../MyApp.worktrees/login-flow
xcd build && xcd test && xcd run
xcd ui screenshot         # a PNG of the simulator in .xcdev-media/<worktree>/<branch>/
xcd ui tree               # what is on screen; then xcd ui tap, type, swipe, and wait drive it
xcd run --device mac      # the Mac app (a device with platform: macOS), launched hidden; xcd ui drives it too
xcd sim fold open         # a foldable's hinge, on the iPhone Duo simulator
xcd open                  # the project's routes: links and scripts that take the app straight to a screen
xcd format                # put the lines this worktree's change touched in the project's format
xcd lint                  # the lint findings this worktree's change introduced, with the project's own linter
xcd xcode                 # open this worktree's project in Xcode, the one xcd uses
xcd help                  # every command, project command, and plugin
```

## Simulators and Mac apps

- Each worktree's devices are clones of the devices in `.xcdev.yml`, named `xcd · <project> · <worktree> · <device>`,
  made on first use and deleted with the worktree. `xcd sim` controls a clone without a prompt: `boot`, `shutdown`,
  `erase`, `open` (show it in Device Hub, or Simulator.app before Xcode 27), `open-url`, `push`, `privacy`,
  `status-bar`, `appearance`, `text-size`, `location`, `pasteboard`, `addmedia`, `container`, `fold`, `screenshot`,
  and `record`.
- `xcd ui` sees and drives the app: `tree` lists what is on screen, each element with a ref, and `tap`, `long-press`,
  `type`, `swipe`, `wait`, `button`, and `rotate` act on them. On a simulator it goes through an XCUITest runner that
  xcd builds once per Xcode and keeps running; iPhone and iPad simulators running iOS 17 or later.
- A device with `platform: macOS` builds the Mac app and launches it hidden. `xcd ui` reads and drives it through the
  accessibility API, and `ui menu` presses menu items. This needs the Accessibility grant for the app that runs xcd
  (the terminal, or the agent's host app), and Screen Recording for screenshots; `xcd doctor --grant-accessibility`
  and `--grant-screen-recording` ask macOS for them at the user's word, and nothing else ever prompts.
  `isolation: suffix` gives each worktree its own copy of the app under a suffixed bundle id, so worktrees do not
  share its data, for apps whose entitlements allow an ad-hoc re-sign. `--show` brings the app forward when a person
  wants to see it.
- `xcd sim fold open|half|closed` and `xcd ui rotate` on the iPhone Duo (Xcode 27.1, iOS 27.1 runtime) go through
  the simulator's pose pipeline. No public command opens a foldable's hinge, so this uses a private CoreSimulator
  interface, the same one RocketSim uses, looked up by name at run time. If an Xcode update changes it, the command
  fails and says which piece is missing.

## For agents

- `xcd guide start` is where an agent begins: its checkout, the everyday commands, and how to read what they print.
- `xcd guide setup` walks an agent through configuring a project with the user.
- `xcd guide ui` teaches the see, act, verify loop for driving the app in the simulator or on the Mac.
- `xcd guide deeplinks` shows how to describe the app's links, launch arguments, and navigation scripts as routes,
  which `xcd open` lists and opens.
- `xcd guide quality` covers `xcd format` and `xcd lint`, which run the project's formatter and linter on the Swift
  code a change touched: only the changed lines are reformatted, and only the findings the change introduced are
  shown.
- `xcd init` writes xcd's block, a few rules that point to `xcd guide start` (`docs/agents/AGENTS-snippet.md`), into
  the project's AGENTS.md and CLAUDE.md, and `xcd init --agents` does it in a project already set up. `xcd doctor`
  reports a block that differs from the installed xcd's, and `xcd doctor --fix` rewrites it.
  `skills/xcdev/SKILL.md` is an agent skill with the same rules.
- An agent works in the checkout it was given, whatever made it. In a worktree another tool made, xcd sets the checkout
  up on its first command, uses the main checkout's `.xcdev.yml` when the branch has none, and runs the project's
  `post-worktree-create` hook once the branch has its own `.xcdev.yml` and the worktree has no uncommitted changes.
  `xcd wt remove` of such a checkout removes only xcd's part of it.
- Every failure ends with a `next:` line, and `--json` prints one JSON object per command.
- Ctrl-C (or SIGTERM, or SIGHUP when the terminal closes) stops what xcd started, xcodebuild and its compilers
  included, and exits 130 (143 for SIGTERM, 129 for SIGHUP) with one `xcd: interrupted` line on stderr.
- `xcd doctor` checks simulators, worktrees, xcd's scratch folders and leftover package caches, and the project's
  setup; `xcd doctor --fix` repairs this project's problems, those of projects whose folders are gone, and xcd's own
  leftovers. Another project's problems are listed apart, under a heading that says to ask the user, and never fail
  the run. `xcd doctor --restart-simulators` restarts CoreSimulator when it isn't answering, which shuts down every
  agent's simulators, so ask the user first.
- SwiftLint searches hidden folders, so it would lint `.xcdev/` (DerivedData and package checkouts) on every build.
  `xcd init` adds `.xcdev` to the `excluded` list of the project's `.swiftlint.yml`, and `xcd doctor` reports a
  config that lacks it (`--fix` adds it). Until then `xcd build`, `xcd run`, and `xcd test` say so in a `note:`.

## Extending

- **Project commands** in `.xcdev.yml` (`commands:`) run as `xcd <name>`, with the worktree's context in `XCD_*`
  environment variables.
- **Plugins**: any `xcd-<name>` executable on `PATH` runs as `xcd <name>`; `xcd-<name> --xcd-describe` gives `xcd help`
  its one-line description.
- Project commands and plugins share xcd's terminal, so they can prompt and read input, and Ctrl-C reaches them
  directly; `xcd <name>` exits with their exit code (128 + the signal if one ended them, 130 for Ctrl-C).
- **Hooks** (`hooks:`): `post-worktree-create`, `pre-build`, `post-launch`, and `pre-worktree-remove`.
- Project commands and hooks are shell lines from the project's `.xcdev.yml`. Running xcd inside a project you did
  not write runs that project's lines, as `npm run` runs a package's scripts, so read them first.

`xcd config explain <key>` documents every setting.

## Releasing

`scripts/release.sh <version>` builds the universal binary and the Homebrew formula into `dist/`; pushing a `v<version>`
tag runs it in GitHub Actions and publishes the release. Copy `dist/xcdev.rb` into a tap's `Formula/` folder.

## License

MIT. See `LICENSE`.
