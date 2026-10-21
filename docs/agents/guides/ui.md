# See and drive the app's UI

Use this guide to check your work in the running app: read what is on screen, act on it, and confirm what happened. It works on iPhone and iPad simulators running iOS 17 or later, and on Mac apps. Nothing here opens Device Hub (Simulator.app before Xcode 27), takes focus on the Mac, or (but for `--show`) brings a Mac app forward; when a person wants to watch, `xcd sim open` shows them the simulator and `xcd launch --show` the Mac app.

## The loop

1. Start the app with `xcd run` (build, install, launch) or `xcd launch`. Actions need the app in front.
2. See: `xcd ui tree` lists the elements on screen. Each row has a ref (`e1`, `e2`, …), a role, the label, the value, the identifier, and the frame in points. `xcd ui screenshot` saves a PNG and prints its path, for what the tree can't show: layout, colour, images.
3. Act: tap, type, or swipe (see Actions).
4. Verify: add `--tree` to the action to get the tree as it is afterwards, or run `xcd ui wait <target>`. An action that succeeds only means the gesture was sent. It does not mean the app reacted.

```sh
xcd run
xcd ui tree
xcd ui type "me@example.com" --into id:email
xcd ui tap "label:Sign In" --tree
xcd ui wait "label~Welcome" --timeout 10
```

## Targets

A target is one argument. Quote it when it has spaces.

| Form | Matches |
|---|---|
| `id:<identifier>` | The accessibility identifier, exactly. Prefer this: it doesn't change with the app's language. |
| `label:<text>` | The label, exactly. |
| `label~<text>` | Part of the label, in any case. |
| `ref:e<N>`, or just `e<N>` | A row of the newest tree. |
| `@x,y` | A point, in points (tap and long-press only). Nothing is checked: it taps whatever is there. |

When several elements match, the error lists them with their refs, so `e2` picks one. `--role button` or `--index 0` also narrow a match.

An element keeps its ref from one tree to the next (`xcd ui tree`, or an action with `--tree`) for as long as each tree lists it. A ref whose element the newest tree does not list is refused with `stale_ref`. Its number is not used again, so an old ref never names another element.

## Actions

| Command | What it does |
|---|---|
| `xcd ui tap <target>` | Taps the element's centre. |
| `xcd ui long-press <target> [--duration 2s]` | Presses and holds (default 1s). Refused on a Mac app. |
| `xcd ui type <text> [--into <target>] [--clear] [--submit]` | Types into the field (`--into` taps it first), or into whatever has focus. `--clear` replaces what the field holds. `--submit` presses Return. |
| `xcd ui swipe up\|down\|left\|right [--on <target>]` | Swipes from the centre of the element, or of the screen. The direction is the way the finger moves, so `up` scrolls a list towards its end. |
| `xcd ui swipe --from x,y --to x,y` | Swipes between two points. |
| `xcd ui button home\|action\|camera` | Presses a hardware button. `home` works everywhere; the others only on devices that have them. |
| `xcd ui rotate portrait\|landscape-left\|landscape-right\|portrait-upside-down` | Rotates the device. |
| `xcd ui wait <target> [--gone] [--timeout 10s]` | Waits for an element to be on screen, or to be gone. |

An action on an element waits up to `--timeout` (default 2s; 10s for `wait`) for it to exist and be reachable. Every action except `wait` takes `--tree`, which prints the tree as it is afterwards. The app is the one from the last build; `--bundle <id>` picks another, and `--system` acts on the Home Screen.

## Things to know

- **Getting to a screen.** When the project has routes, `xcd open <route>` goes there in one step, and it keeps working when the screens in between change. `xcd open` lists the routes, and `xcd guide deeplinks` explains them.
- **System alerts** (permission prompts) are listed at the end of the tree, marked `system`. While one is up, nothing in the app can be acted on: tap one of the alert's buttons first.
- **The keyboard** covers the lower part of the screen, and an element under it is refused. Scroll the element up with `xcd ui swipe up`, or dismiss the keyboard first: `xcd ui type "" --submit` presses Return, which closes it in most single-line fields (and submits the field), or tap the keyboard's own Return or Done key (`xcd ui tree --all` lists the keys).
- **Off-screen elements** are not in the default tree. `xcd ui tree --all` lists them, marked `offscreen`. Swipe, then read the tree again.
- **Typing** sends key presses to the field that has keyboard focus, with or without a keyboard on screen; the report says `by keyboard`. Only when no keyboard comes up and the simulator can't say what has focus is the text pasted instead, which replaces the device's pasteboard (`by paste`). Check the field's value in the tree afterwards. With nothing focused there is nowhere to type, and the command fails: pass `--into <target>`.
- **A crash** during an action is reported as `app_crashed`, with the crash report when one was written.
- **The first `xcd ui` command** builds a small runner once per Xcode (about 30 seconds) and starts it on your simulator. On a brand-new simulator the start can take minutes. Later commands take about a second.
- **`xcd test`** stops the runner when the test run includes UI tests, since both would drive the same device. The next `xcd ui` command starts it again.
- **Device state** is set with `xcd sim`: `xcd sim open-url <url>`, `xcd sim push --alert <text>`, `xcd sim privacy grant photos`, `xcd sim pasteboard set --text <text>` or `--image <file>`, `xcd sim appearance dark`, `xcd sim text-size accessibility-large` (the Dynamic Type size).
- **The pasteboard while Device Hub is open** is synced with the Mac's clipboard from some tens of seconds after the simulator boots, and from then on the simulator drops text that `xcd sim pasteboard set --text` sends. The command reads the pasteboard back, so it fails with `simulator_failed` and says so; it never reports text that is not there. To get text into a field, use `xcd ui type`. The pasteboard then holds what the person at the Mac copied, so read it with `xcd sim pasteboard get` only for text you put there.
- **The app's files** are in a folder on this Mac: `xcd sim container` prints the path of its data container, so `ls "$(xcd sim container)/Documents"` lists what the app saved.
- **A foldable (iPhone Duo)** opens and closes with `xcd sim fold open|half|closed`; `xcd sim fold --angle <degrees>` sets any angle, though the simulator confirms only 0°, 90°, and 180°, so another angle is reported `unverified`. After an unverified angle the next read may still show the last confirmed posture. `xcd sim fold` alone reports the posture, the active display, and the orientation. `xcd ui rotate` on it goes through the same pose pipeline, since the Duo ignores the runner's rotation; `portrait-upside-down` is not available there. Both wait up to 5 s for the simulator to report the change: `xcd sim fold` says `unverified` when only the display agreed and no hinge line confirmed the angle, and a rotation the simulator does not report fails with `posture_failed`. Nothing comes to the foreground. A device without a hinge is refused with `platform_unsupported`; a route that fails is `posture_failed`, whose details name the step.
- Add `--json` to any command for one JSON object: the tree's elements, or an action's `element`, `x`, `y`, and `tree`.

## On a Mac

The same loop drives the Mac build of the app, with the app hidden: `xcd run --device mac` starts it with no window on the desktop, and the loop below works on it there; the commands a Mac cannot do are listed in the bullets and refuse with a reason and an alternative. Nothing takes focus or moves the pointer. `xcd launch --device mac --show` starts it visible and in front, for a person.

- **The tree** is the app's windows, sheets, popovers, and open menus, with frames in each window's own points; the first line says `running (hidden)` or `running (visible)`, the main window's title and size, and the scale. The menu bar is not in it: `xcd ui menu` lists it as paths, the Apple menu first, then the app's own menus.
- **Taps** press the element; a tap on a field focuses it. `@x,y` is refused: clicks posted to a background Mac app do not land, so name the element. A tap on a pop-up button or a menu button (a `popUpButton` or `menuButton` in the tree, such as a menu-style picker) is refused with `platform_unsupported`, since it opens the menu on the person's screen: use `xcd ui menu` for the app's commands, or set the value another way, such as a link with `xcd open`.
- **Typing** focuses the field, then posts the keys to the app; `--clear` empties it first and `--submit` presses Return. A tab in the text acts as the Tab key and moves focus on. `--clear` is the only chord there is: every other ⌘ shortcut is refused. One `ui type` takes at most 2000 characters. A field that will not take focus is `element_not_hittable`.
- **Shortcuts** go through the menu bar: `xcd ui menu "File > Save…"` presses the item; posted ⌘-chords do not reach a background app. A submenu is not an item: name one inside it. The Apple menu is listed but never pressed (`platform_unsupported`): its items sleep, lock, or restart the Mac, or open System Settings in front.
- **A long-press** is refused with `platform_unsupported`: it would open the element's context menu on the person's screen, hidden app or not, as a menu window that stays there until one of its items is pressed. The message reads "a long-press opens the element's context menu on the person's screen (a visible menu window until one of its items is pressed)", and `next:` says to use `xcd ui menu "<Menu> > <Item>"` for the app's commands.
- **A swipe** scrolls the enclosing scroll area one page (`up` towards the end), through its scroll bar; `--from`/`--to`, `ui button`, and `ui rotate` are refused.
- **Screenshots and recordings** take the app's main window, hidden or covered, through ScreenCaptureKit. They need the Screen Recording permission; macOS reminds the person now and then that the host app can record the screen. A recording is stills at about 5 per second, so motion looks stepped.
- **Windows the app restored** (macOS brings an app back with the windows it had) are all in the tree; the header says `windows: n` when there is more than one. When an identifier appears in more than one window, narrow it with `--index` or close the extra window. A screenshot takes the main window, and after a link can land on an empty twin of it.
- **Permissions** belong to the app that runs xcd (the terminal, the Claude desktop app, an IDE). A missing one fails fast with `permission_missing`, naming the app and the System Settings pane; `xcd doctor` lists the same. Nothing prompts.
- **A locked screen** refuses every Mac `ui` command except `ui stop`, including `ui screenshot` and `ui record start`: `runner_failed`, "the Mac's screen is locked, so the app's windows cannot be read", `next:` "ask the user to unlock the Mac, then run the command again". Ask the user; nothing else helps.
- **System prompts** the app raises (contacts, photos, automation) belong to the person at the Mac; while one is up, reads fail with `runner_failed` saying so. Ask the user to answer it once.
- **App Nap** is off for an app xcd launches hidden (a `--show` launch adds nothing). An app started some other way while hidden answers slowly, many times slower, so start it with `xcd run` or `xcd launch`.
- **Refs** last across commands as on a simulator, and a relaunch makes them all stale (numbers start again at e1). `xcd ui stop` forgets them; there is no runner to stop.
- **The `xcd sim` state commands** (`boot`, `shutdown`, `erase`, `open`, `open-url`, `push`, `privacy`, `appearance`, `text-size`, `status-bar`, `location`, `addmedia`, `pasteboard`, `fold`) are refused on a Mac device with `platform_unsupported`, each naming its reason and the alternative; the shared one reads "device 'mac' is a macOS device and has no simulator", with `next:` pointing to `xcd ui …` after `xcd run --device mac` and to `xcd launch --device mac --show`. `xcd sim screenshot` and `xcd sim record` are `ui screenshot` and `ui record`, and work on the Mac window.

## When something fails

Every failure ends with `next:`. Do what it says first.

| Error | Meaning | What to do |
|---|---|---|
| `element_not_found` | Nothing matched in time, or the app isn't in front. | Read `xcd ui tree`; the error names the closest labels and identifiers. |
| `element_not_hittable` | It exists but is off screen, disabled, or covered. | Scroll it into view, or deal with the alert or keyboard over it. |
| `element_ambiguous` | Several elements matched. | Pick one with `ref:e<N>`, `--index`, or `--role`. |
| `stale_ref` | The newest tree does not list the ref's element, or the element has gone since. | Run `xcd ui tree` and use a ref from it. |
| `wait_timeout` | The element didn't appear (or go) in time. | The error lists what is on screen. Check the app did what you expected. |
| `app_crashed` | The action ended the app. | Read the crash report in the error, fix the crash, then `xcd run`. |
| `runner_failed` | The runner didn't start or stopped answering. On a Mac: the screen is locked, or an Accessibility call timed out (a system prompt may be up). | `xcd ui stop`, retry, then `xcd doctor`. On a Mac, ask the user to unlock the Mac or answer the prompt. |
| `permission_missing` | On a Mac, the app that runs xcd lacks Accessibility (or, for screenshots and recordings, Screen Recording). | Follow the `next:` (System Settings pane); `xcd doctor` lists the same. |
