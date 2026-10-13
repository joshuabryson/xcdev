# Lint the code you changed

Use this guide before you say a change is done. `xcd lint` checks the Swift files you changed against the project's own lint rules, with the linter the project names under `lint:` in `.xcdev.yml`. You don't need to know which linter that is or how the project runs it.

## Run it

```sh
xcd lint                  # the findings your change introduced
xcd lint --files          # every finding in the files you changed
xcd lint --all            # every finding in the project
xcd lint Sources/Login    # any of the three, for these files and folders only
```

"Your change" is the working tree against the commit where your work left its base: what you committed, staged, and left unstaged, and files git does not track yet. The base is the branch your worktree was made from (`xcd worktree create` records it), or else the repository's default branch. `--base <ref>` names another one.

On the base branch itself, for example in the main checkout on `main`, your work never left the base, so only what is not committed yet counts as your change. After you commit there, `xcd lint` says no Swift files changed. To lint work you already committed on the base branch, pass `--base <ref>` with the commit or branch it started from.

Nothing needs to be built or booted, and the command writes nothing in the project apart from a log under `.xcdev/`.

## Read the result

```
lint: 3 new findings  tool=swiftlint  files=4  base=main  2.3s
Sources/Login/LoginForm.swift:31:9: warning: TODOs should be resolved (show the error state) (todo)
Sources/Login/LoginForm.swift:57:1: warning: Function body should span 50 lines or less; currently spans 53 lines (function_body_length)
Sources/Login/Session.swift:12:30: error: Force casts should be avoided (force_cast)
9 older findings in these files (xcd lint --files)
next: fix the findings and run `xcd lint` again
```

- Each finding is in compiler format, with the rule's name in parentheses at its end.
- A finding is new when the base version of the file does not have it. So a new finding can be on a line you did not touch: lines added to a function can make the function too long, and the finding is then on the function's first line.
- Fix the new findings. Leave the older ones alone unless the user asks for them: they were there before your change, and fixing them makes the change harder to review. `xcd lint --files` lists them.
- The command fails when a finding is an error. Warnings are listed and the command succeeds; fix them too unless the user says otherwise.
- A `note:` that starts with `swiftlint:` is something the linter itself warned about. Up to three of its lines are shown, and the `log:` file has the rest. When a note says the linter could not read or find a config file (`Cannot parse YAML file`, `Unable to load remote config`, `was not found. Ignoring this part of the configuration`), it linted without those rules, falling back on its default rules, and the findings are not the project's: tell the user instead of fixing them.
- `lint: no Swift files changed since main` means there was nothing to lint. On `main` itself that is also what you see after you commit: see "Run it" above.
- `lint: no linter is set up  (lint.tool is none)` means the project said it has no linter. The command succeeded, and there is nothing to do.

## When it does not run

| Error | What it means | What to do |
|---|---|---|
| `not_configured` | `.xcdev.yml` has no `lint:` section: nobody has said whether the project has a linter. | Ask the user. Which linter a project uses, or that it uses none, is theirs to decide. Then add the line the `next:` gives, or run `xcd doctor --fix` when the `next:` offers it, and commit `.xcdev.yml`. |
| `tool_missing` | The linter the project names is not on this Mac, or `lint.path` names nothing. | Tell the user what the `next:` says: how to install it, or where to set its path. Do not install it yourself. |
| `lint_failed` | A finding is an error, or the project's own lint command exited non-zero. | Fix what is listed and run `xcd lint` again. |
| `usage` | Two scopes at once, a path outside the worktree, or a base git does not know. Also when no base can be found. | Do what the `next:` says: usually `--base <ref>`, or `--all`. |
| `config_invalid` | The lint config names a file or a folder by an absolute path, which xcd cannot follow: it lints copies of your files in a folder of its own. | Tell the user which file and key the message names. Whether to make the path relative to the worktree or to give the project its own command under `lint.run` is theirs to decide. |
| `subprocess_failed` | The linter broke instead of reporting findings, or it linted files other than the ones xcd gave it. | Read the error's details and tell the user: it is not a finding to fix. |

## How a project sets it up

`xcd init` asks which linter to use and writes the section. In a project that was set up before, add it by hand:

```yaml
lint:
  tool: swiftlint          # swiftlint, or none for a project with no linter
  args: ["--strict"]       # optional: extra arguments; --strict makes warnings fail the command
```

The rules stay in the linter's own file, `.swiftlint.yml`. A path to the linter that differs per Mac goes in `.xcdev.local.yml`, as `lint: { path: … }`.

A project whose linter xcd does not know names its own command instead:

```yaml
lint:
  run: ./scripts/lint.sh
```

xcd runs it from the worktree root with the changed Swift files as its arguments, and with none for `xcd lint --all`. Exit 0 means it passed. Its output is shown as it is. A command sees whole files, so its result does not tell new findings from old ones.

`xcd config explain lint` describes every key.
