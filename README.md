# xcdev

`xcd` is a command-line tool that AI agents (and humans) use for Apple-platform development: build, test, run, logs,
and simulators for iOS, iPadOS, watchOS, tvOS, visionOS, and macOS apps and Swift packages. Every git worktree gets its
own simulator clones and build folders, so many agents can work at once without colliding.

## Install

```sh
brew install <owner>/tap/xcdev      # installs `xcd` and the `xcdev` alias
```

Or download `xcdev-<version>-macos.tar.gz` from the GitHub releases (a universal binary for Apple silicon and Intel),
or build from source with `swift build -c release`. Requires macOS 15 or later and Xcode. CI builds and tests with Xcode 26.2 on a
`macos-26` runner (pinned in `.github/workflows`).

## Quick start

```sh
cd MyApp                  # a git repository with an Xcode project or Package.swift
xcd init --plan           # see what xcd detected and the choices to make; writes nothing
xcd init --defaults       # write .xcdev.yml with the recommendations (or --set key=value ...)
xcd wt create login-flow  # a worktree with its own branch, simulators, and DerivedData
cd ../MyApp.worktrees/login-flow
xcd build && xcd test && xcd run
xcd help                  # every command, project command, and plugin
```

## For agents

- `xcd guide setup` walks an agent through configuring a project with the user.
- `skills/xcdev/SKILL.md` is an agent skill, and `docs/agents/AGENTS-snippet.md` is a snippet for a project's
  `AGENTS.md`, that teach agents to use `xcd`.
- Every failure ends with a `next:` line, and `--json` prints one JSON object per command.
- `xcd doctor` checks simulators, worktrees, xcd's scratch folders, and the project's setup; `xcd doctor --fix`
  repairs what it can. It may restart CoreSimulator, which shuts down every agent's simulators, so read the problems
  first.

## Extending

- **Project commands** in `.xcdev.yml` (`commands:`) run as `xcd <name>`, with the worktree's context in `XCD_*`
  environment variables.
- **Plugins**: any `xcd-<name>` executable on `PATH` runs as `xcd <name>`; `xcd-<name> --xcd-describe` gives `xcd help`
  its one-line description.
- **Hooks** (`hooks:`): `post-worktree-create`, `pre-build`, `post-launch`, and `pre-worktree-remove`.

`xcd config explain <key>` documents every setting.

## Releasing

`scripts/release.sh <version>` builds the universal binary and the Homebrew formula into `dist/`; pushing a `v<version>`
tag runs it in GitHub Actions and publishes the release. Copy `dist/xcdev.rb` into your tap's `Formula/` folder.

## License

MIT. See `LICENSE`.
