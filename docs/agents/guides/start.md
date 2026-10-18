# Start here: Apple-platform work with xcd

`xcd` is the single entry point for Apple-platform work. Use it instead of `xcodebuild`, `xcrun simctl`, or Xcode: it gives
each checkout its own simulator clones and build folder, so agents working at once never collide. `xcd help` lists every
command, the project's own commands (from `.xcdev.yml`), and installed plugins.

## Your checkout

- The checkout you are in is yours, whoever made it: you, the user, or the tool that started you. xcd gives it its own
  simulator clones and build folder on its first command. The main checkout gets clones of its own too, apart from the
  user's simulators.
- Make another worktree (`xcd wt create <name>`) only when the user asks for one, then work in the path it prints.
- `xcd wt status` shows what xcd set up here: the checkout's name, branch, pinned Xcode, and clones. `hook=pending` means the project's `post-worktree-create` hook has not run in this checkout yet: it runs
  on the first xcd command that does more than look, once the branch has its own `.xcdev.yml` and the worktree has no
  uncommitted changes.
- A `note:` saying the branch has no `.xcdev.yml` means xcd is using the main checkout's. Its hooks don't run here until
  the branch has its own.
- A `note:` saying `post-worktree-create` hasn't run because the worktree has uncommitted changes means: ask the user.
  The hook could overwrite those changes. It runs on the first xcd command at which the worktree has none.

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
| Read and drive the UI (iPhone/iPad) | Launch the app first (`xcd run` or `xcd launch`; not needed with `--system`). `xcd ui tree` lists what is on screen with refs; `xcd ui tap <target>`; `xcd ui type <text> --into <target> [--clear] [--submit]`; `xcd ui swipe up\|down\|left\|right [--on <target>]`; `xcd ui long-press <target>`; `xcd ui wait <target> [--gone]`; `xcd ui button home`; `xcd ui rotate landscape-left`. A target is `id:<identifier>`, `"label:<text>"`, `"label~<part>"`, `ref:e<N>` (or just `e<N>`), or `@x,y` (tap and long-press only). Read `xcd guide ui` before the first time |
| Go straight to a screen | `xcd open` lists the project's routes; `xcd open <route> [name=value …]` opens one (a link, launch arguments, or the project's script) and checks that it arrived; `xcd open '<url>'` sends any link the app handles; `--cold` lets the link start the app. Read `xcd guide deeplinks` before adding routes |
| Device state | `xcd sim open-url <url>`, `xcd sim push --alert <text>`, `xcd sim privacy grant photos`, `xcd sim status-bar --time 9:41`, `xcd sim appearance dark`, `xcd sim text-size <size>` (Dynamic Type), `xcd sim location <lat>,<lon>`, `xcd sim pasteboard set --text <s>` (or `--image <file>`), `xcd sim addmedia <file>`; `xcd sim container` prints the folder of the app's data on this Mac |
| Format and lint what you changed | `xcd format` reformats the lines your change touched, with the project's own formatter (`xcd format --check` only lists them). Then `xcd lint` lists the findings your change introduced, with the project's own linter. `--files` widens either to the changed files, and `--all` to the project. Read `xcd guide quality` when one of them says it is not set up |
| Context for scripts | `xcd context` (prints XCD_* variables) |
| Explain a config key | `xcd config explain <key>` |

## Reading results

- Captures go to the media folder (`ui.media.dir`, default `.xcdev-media/<worktree>/<branch>` in the main checkout;
  `$XCD_MEDIA_DIR` in scripts). Screenshot sizes are pixels; divide by the reported scale for points.
- Driving loop: `xcd ui tree` (see), an action such as `xcd ui tap …` or `xcd ui type …` (act), then verify: add
  `--tree` to the action, or run `xcd ui wait …`. An action that reports success can still have done nothing, so
  always verify. An element keeps its ref while each new tree (`xcd ui tree`, or an action with `--tree`) lists it; a
  ref whose element the newest tree leaves out is refused, and never names another element.
- Actions and `xcd ui wait` act on the app in front and any system alert over it; when the app isn't in front they
  fail, saying so (`xcd launch` or `xcd run` fixes that). While a system alert is up nothing in the app can be acted
  on, and neither can an element under the keyboard: deal with the alert or keyboard first.
- `xcd ui swipe up` moves the finger up, which scrolls a list towards its end. Off-screen elements are only in
  `xcd ui tree --all`.
- `xcd test` stops the UI runner when the run includes UI tests; the next `xcd ui` command starts it again.
- Output is compact text by default; add `--json` (or set `XCD_OUTPUT=json`) for one JSON object per command.

## When something is wrong

- Every failure ends with `next:`. Do what it says before trying anything else; when it says to ask the user, ask.
- Exit codes: 1 = the task failed (fix the code), 2 = fix the command line or config, 3 = fix the environment: do
  what `next:` says (often `xcd doctor`). `xcd help errors` lists every error code.
- `xcd doctor` checks simulators, worktrees, xcd's leftovers, and the project's setup. `xcd doctor --fix` repairs only
  this project's problems, those of projects whose folders are gone, and xcd's own leftovers.
- Problems `xcd doctor` lists under "elsewhere" belong to other projects. They are not this checkout's to fix, even when
  doctor exits 0: tell the user about them, and do not act on them.
- `xcd doctor --restart-simulators` restarts CoreSimulator when it isn't answering, which shuts down every agent's
  simulators: ask the user first.

## Setting up a project

If xcd says the project has no `.xcdev.yml`, run `xcd guide setup` and follow it: `xcd init --plan`, ask the user each
decision, then `xcd init --set key=value ...`. In a project already set up, `xcd init --agents` puts xcd's block in its
AGENTS.md or CLAUDE.md.
