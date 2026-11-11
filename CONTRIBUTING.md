# Contributing

xcdev is a Swift package with two targets: `XcdevKit`, the library that does the work, and `xcd`, the command that
parses arguments and prints. Swift Package Manager builds and tests it; there is no Xcode project to open.

## Build and test

```sh
swift build                 # a debug build at .build/debug/xcd
swift test                  # the unit suites: fakes stand in for xcodebuild and simctl, git runs for real in temporary folders
XCD_INTEGRATION=1 swift test --filter BuildRunIntegrationTests    # one integration suite, for real
```

The integration suites under `Tests/IntegrationTests` drive real Xcode, git, and simulators; each one's `@Suite`
line says what it needs (an iOS simulator runtime, SwiftLint, the Accessibility grant, the iPhone Duo). Run them
one suite at a time with `--filter`: run together, one failing `xcodebuild test` starts a minutes-long
`simctl diagnose` that stalls the rest. On a slow machine, such as a CI runner, `XCD_TIMEOUT_SCALE=4` gives every
command xcd runs, and its wait for a crash report, four times as long.

Two files are generated, and a unit test fails until they are regenerated:

- `scripts/embed-guides.sh` after editing anything in `docs/agents/guides/` or `docs/agents/AGENTS-snippet.md`;
  the binary carries the guides as Swift strings.
- `scripts/embed-runner.sh` after editing anything under `Sources/XcdevKit/UIRunner/Project` or
  `Sources/XcdevKit/UIRunner/Core`; the binary carries the UI runner's source and builds it on first use.

CI (`.github/workflows/ci.yml`) runs the unit suites on every push and pull request with the Xcode it pins, and the
integration suites nightly.

## What a change needs

- A test that was seen to fail before the code that makes it pass. Most behaviour is tested through the fakes in
  `Tests/XcdevTestSupport`; a real-tool fact gets an integration test.
- Every failure a person can hit ends with a `next:` line that says what to do, and has an error code listed by
  `xcd help errors`. `--json` output stays one object per command.
- Nothing xcd does takes focus, brings a window forward, or opens Device Hub or Simulator.app, except
  `xcd sim open` and `--show`, which exist for that. Agents and the person share the Mac.
- Help text, guides, and messages say what happens in plain words, one fact per sentence.
- One-line imperative commit messages that say what changed and why, as in the log.

## Releasing

`scripts/release.sh <version>` builds the universal binary and the Homebrew formula into `dist/`; pushing a
`v<version>` tag runs it in GitHub Actions (`.github/workflows/release.yml`) and publishes the release.
