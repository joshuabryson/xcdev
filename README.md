# xcdev

`xcd` is a command-line tool that AI agents (and humans) use for Apple-platform development: build, test, run, logs,
screenshots and recordings, and simulators for iOS, iPadOS, watchOS, tvOS, visionOS, and macOS apps and Swift packages. Every git worktree gets its
own simulator clones and build folders, so many agents can work at once without colliding.

## Install

```sh
brew install <owner>/tap/xcdev      # installs `xcd` and the `xcdev` alias
```

Or download `xcdev-<version>-macos.tar.gz` from the GitHub releases (a universal binary for Apple silicon and Intel),
or build from source with `swift build -c release`. Requires macOS 15 or later and Xcode. CI builds and tests with Xcode 26.2 on a
`macos-26` runner (pinned in `.github/workflows`).

Homebrew installs shell completion for zsh, bash, and fish. Tab completes commands and flags, and the values of
`--device`, `--scheme`, `--preset`, and `--worktree` come from the current project. Without Homebrew, install the script
yourself, e.g. for zsh into a directory on your `fpath`:

```sh
xcd --generate-completion-script zsh > ~/.zsh/completions/_xcd
```

## Quick start

```sh
cd MyApp                  # a git repository with an Xcode project or Package.swift
xcd init --plan           # see what xcd detected and the choices to make; writes nothing
xcd init --defaults       # write .xcdev.yml with the recommendations (or --set key=value ...)
xcd wt create login-flow  # a worktree with its own branch, simulators, and DerivedData
cd ../MyApp.worktrees/login-flow
xcd build && xcd test && xcd run
xcd ui screenshot         # a PNG of the simulator in .xcdev-media/<worktree>/<branch>/
xcd ui tree               # what is on screen; then xcd ui tap, type, swipe, and wait drive it
xcd open                  # the project's routes: links and scripts that take the app straight to a screen
xcd lint                  # the lint findings this worktree's change introduced, with the project's own linter
xcd help                  # every command, project command, and plugin
```

## For agents

- `xcd guide setup` walks an agent through configuring a project with the user.
- `xcd guide ui` teaches the see, act, verify loop for driving the app in the simulator.
- `xcd guide deeplinks` shows how to describe the app's links, launch arguments, and navigation scripts as routes,
  which `xcd open` lists and opens.
- `xcd guide quality` covers `xcd lint`, which runs the project's linter on the Swift files a change touched and
  shows only the findings the change introduced.
- `skills/xcdev/SKILL.md` is an agent skill, and `docs/agents/AGENTS-snippet.md` is a snippet for a project's
  `AGENTS.md`, that teach agents to use `xcd`.
- Every failure ends with a `next:` line, and `--json` prints one JSON object per command.
- Ctrl-C (or SIGTERM, or SIGHUP when the terminal closes) stops what xcd started, xcodebuild and its compilers
  included, and exits 130 (143 for SIGTERM, 129 for SIGHUP) with one `xcd: interrupted` line on stderr.
- `xcd doctor` checks simulators, worktrees, xcd's scratch folders and leftover package caches, and the project's
  setup; `xcd doctor --fix` repairs what it can. It may restart CoreSimulator, which shuts down every agent's
  simulators, so read the problems first.
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

`xcd config explain <key>` documents every setting.

## Releasing

`scripts/release.sh <version>` builds the universal binary and the Homebrew formula into `dist/`; pushing a `v<version>`
tag runs it in GitHub Actions and publishes the release. Copy `dist/xcdev.rb` into your tap's `Formula/` folder.

## License

MIT. See `LICENSE`.
