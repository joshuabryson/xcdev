# Format and lint the code you changed

Use this guide before you say a change is done. `xcd format` puts the Swift code you changed in the project's format, and `xcd lint` checks it against the project's lint rules. Each uses the tool the project names in `.xcdev.yml`, under `format:` and `lint:`. You don't need to know which tools those are or how the project runs them.

Run `xcd format` first, then `xcd lint`: formatting can clear findings the linter would otherwise report. When you edit code to fix a finding, run both again.

## Run them

```sh
xcd format                # reformat the lines your change touched
xcd lint                  # the findings your change introduced
```

Both take the same scopes:

```sh
xcd format --files        # the files you changed, whole
xcd lint --files          # every finding in the files you changed
xcd format --all          # every Swift file in the project
xcd lint --all            # every finding in the project
xcd lint Sources/Login    # either command, any scope, for these files and folders only
xcd format --check        # write nothing: list what would change, and fail when something would
```

"Your change" is the working tree against the commit where your work left its base: what you committed, staged, and left unstaged, and files git does not track yet. The base is the branch your worktree was made from (`xcd worktree create` records it), or else the repository's default branch. `--base <ref>` names another one.

On the base branch itself, for example in the main checkout on `main`, your work never left the base, so only what is not committed yet counts as your change. After you commit there, both commands say no Swift files changed. To cover work you already committed on the base branch, pass `--base <ref>` with the commit or branch it started from.

Nothing needs to be built or booted. `xcd lint` writes nothing in the project apart from a log under `.xcdev/`. `xcd format` rewrites the Swift files it reformats, and nothing else.

## Read what `xcd format` did

```
format: 2 files reformatted  tool=swiftformat  files=4  base=main  0.3s
Sources/Login/LoginForm.swift  lines 31-33
Sources/Login/Session.swift  lines 12, 57-58
```

- Each file the formatter changed is listed with the lines that differ, numbered in the file as it is now. Read the diff before you commit it.
- Only the lines your change touched are reformatted, and every other byte of the file stays as it was. Older code that is not in the project's format is left alone: reformatting it makes the change harder to review. `xcd format --files` reformats the files whole when the user asks for that. A file that is new is formatted whole in every scope.
- `format: nothing to reformat` means the code is already as the formatter wants it.
- `xcd format --check` rewrites nothing. It lists what `xcd format` would change, with the lines numbered in the file as it is, and fails with `format_failed` when there is anything. Use it when you were asked to check and not to change.
- A file the formatter cannot process is left as it was and listed with the formatter's own error, and the command fails. The other files are still formatted. Such a file usually does not parse: fix it and run `xcd format` again. A file with an unresolved merge conflict is one of these.
- A file that `has Windows line endings (CRLF)` is not reformatted by lines, because a formatter given lines of such a file damages the lines around them. `xcd format --files <file>` formats it whole, which changes every line of it: ask the user first.
- SwiftFormat joins some lines to the line above them: an `else {`, a `catch {`, or a `{` on a line of its own, a line that starts with a comma, and a `]` under an element that has no comma. When that is the first line you changed, the line above it is reformatted and listed too. A file listed with `swiftformat changed a line above …` is one where that line is blank or ends in a `//` comment, and SwiftFormat's join goes wrong. Make the join yourself (put the `{` at the end of the line it belongs to, or the comma before the comment) and run `xcd format` again. `xcd format --files <file>` does it too, and reformats the rest of the file with it: ask the user first.
- A `note:` that starts with `swiftformat:` or `swift-format:` is something the formatter itself warned about. A note that a file `changed while it was being formatted` means someone saved it meanwhile and xcd left it alone: run `xcd format` again.
- `format: no formatter is set up  (format.tool is none)` means the project said it has no formatter. The command succeeded, and there is nothing to do.

## Read what `xcd lint` found

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
- `lint: no Swift files changed since main` means there was nothing to lint. On `main` itself that is also what you see after you commit: see "Run them" above.
- `lint: no linter is set up  (lint.tool is none)` means the project said it has no linter. The command succeeded, and there is nothing to do.

## When a command does not run

| Error | What it means | What to do |
|---|---|---|
| `not_configured` | `.xcdev.yml` has no `lint:` or no `format:` section: nobody has said whether the project has that tool. Also `xcd format --check` in a project whose own format command has no `check`. | Ask the user. Which linter or formatter a project uses, or that it uses none, is theirs to decide. Then add the line the `next:` gives, or run `xcd doctor --fix` when the `next:` offers it, and commit `.xcdev.yml`. |
| `tool_missing` | The linter or formatter the project names is not on this Mac, or its `path` names nothing. | Tell the user what the `next:` says: how to install it, or where to set its path. Do not install it yourself. |
| `lint_failed` | A finding is an error, or the project's own lint command exited non-zero. | Fix what is listed and run `xcd lint` again. |
| `format_failed` | `xcd format --check` found code the formatter would change, the formatter could not process a file, or the project's own format command exited non-zero. | After a check, run `xcd format`. Otherwise fix what is listed for the file and run `xcd format` again. |
| `usage` | Two scopes at once, a path outside the worktree, or a base git does not know. Also when no base can be found. | Do what the `next:` says: usually `--base <ref>`, or `--all`. |
| `config_invalid` | The lint config names a file or a folder by an absolute path, which xcd cannot follow: it lints copies of your files in a folder of its own. | Tell the user which file and key the message names. Whether to make the path relative to the worktree or to give the project its own command under `lint.run` is theirs to decide. |
| `subprocess_failed` | The linter broke instead of reporting findings, or it linted files other than the ones xcd gave it. Also a formatter that could not be started. | Read the error's details and tell the user: it is not a finding to fix. |

## How a project sets them up

`xcd init` asks which linter and which formatter to use and writes both sections. In a project that was set up before, add them by hand:

```yaml
lint:
  tool: swiftlint          # swiftlint, or none for a project with no linter
  args: ["--strict"]       # optional: extra arguments; --strict makes warnings fail the command

format:
  tool: swiftformat        # swiftformat, swift-format (Apple's, inside Xcode), or none
```

The rules stay in each tool's own file: `.swiftlint.yml`, `.swiftformat`, or `.swift-format`. A path to a tool that differs per Mac goes in `.xcdev.local.yml`, as `lint: { path: … }` or `format: { path: … }`. A script named as `format.path` must print the formatted file and nothing else. Apple's swift-format needs no install, and with no `.swift-format` file it indents with 2 spaces.

A project whose tool xcd does not know names its own command instead:

```yaml
lint:
  run: ./scripts/lint.sh "$@"

format:
  run: ./scripts/format.sh "$@"            # rewrites the files
  check: ./scripts/format.sh --dry "$@"    # optional: only reports, for `xcd format --check`
```

xcd runs it from the worktree root. `"$@"` is where the changed Swift files go: xcd adds nothing to the command, so one with no `"$@"` gets no files, and the result has a note saying so. `--all` passes none. Exit 0 means it passed. Its output is shown as it is. A command sees whole files, so `xcd lint` does not tell new findings from old ones with it, and `xcd format` reformats whole files and lists the ones that changed without their lines.

`xcd config explain lint` and `xcd config explain format` describe every key.
