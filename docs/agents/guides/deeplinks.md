# Open the app's links and routes

Use this guide to get the app straight to a screen: with a link the app already handles, a launch argument, or the project's own script. The project describes each way in once, as a **route** under `deeplinks:` in `.xcdev.yml`, and `xcd open` delivers it. It works on simulators and on Mac apps.

## Use the routes that are there

1. `xcd open` lists the project's routes with their parameters.
2. `xcd open <route> [name=value …]` opens one. Quote a value that has spaces: `xcd open item "title=Two Words"`.
3. `xcd open '<url>'` sends a link that no route describes, exactly as given. Quote a link that has `?` or `&`.

```sh
xcd run                         # `xcd open` never builds or installs
xcd open                        # the routes and their parameters
xcd open item id=42 tab=notes
xcd open item id=42 --dry-run   # prints what would be sent, and sends nothing
```

The app is started if it is not running. The result says what was sent and what became of the app:

```
opened item  device=iphone (iPhone 18 Pro, iOS 27.0)  app=running  pid=4312
url: myapp://host/item?id=42&tab=notes
check: label~Item 42 appeared after 0.6s
```

`app=` is `running` (the link went to the copy that was up), `started`, `restarted`, `started-by-link` (`--cold`), or `untouched` (a script route). xcd watches the app for a few seconds after the delivery, and a crash is reported as `app_crashed` with the crash report.

Use `xcd open` for the app's own links, not `xcd sim open-url`. `xcd open` makes sure the app is running, refuses a scheme the built app does not register, approves the scheme so that no "Open in …?" alert holds the link, and watches for a crash. `xcd sim open-url` is for a link meant for another app, such as a page in Safari.

## Find how the app takes links

Look in the app's source for these:

| Look for | It tells you | Route kind |
|---|---|---|
| `CFBundleURLTypes` in Info.plist, or URL Types in the target's settings | The custom schemes the app registers, like `myapp`. | `url` |
| `.onOpenURL`, `application(_:open:options:)`, `scene(_:openURLContexts:)` | Where a link arrives. Read it for the paths and query items the app understands. | `url` |
| `applinks:` domains in the entitlements, `onContinueUserActivity`, `application(_:continue:restorationHandler:)` | The https links the app takes. They reach it only where its associated domains work. | `url`, always with `expect` |
| `ProcessInfo.processInfo.arguments`, `CommandLine.arguments`, `UserDefaults` keys read at launch, environment variables | A launch argument or variable that starts the app on a screen, or in a state. | `launch` |
| None of these | The app has no way in for this screen. | `run`, with a script that goes there |

## Write routes

```yaml
deeplinks:
  vars:
    base: "myapp://host"
  routes:
    item:
      description: "Open one saved link"
      url: "{base}/item?id={id}&tab={tab}"
      expect: "label~Item {id}"
      params:
        id:  { description: "The link's number" }
        tab: { description: "Which tab to show", values: [notes, preview], optional: true }
    onboarding:
      description: "Start at an onboarding step"
      launch: { args: ["-startRoute", "onboarding/{step}"] }
      preset: fresh-install
      params:
        step: { description: "1 to 4", default: "1" }
    settings/about:
      description: "Tap through to the About screen"
      run: ./scripts/open-about.sh
      expect: "id:about-version"
```

A route has a `description` and exactly one of these three keys, which is its kind:

| Key | What xcd does | Use it when |
|---|---|---|
| `url` | Opens the link on the device. The app is started first if it is not running. | The app handles the link. This is the usual kind. |
| `launch` (`args`, `env`) | Restarts the app with these arguments and environment variables. | The app reads a launch argument, or the state has to be set before the app starts. |
| `run` | Runs the project's script from the worktree root. xcd boots the simulator and leaves the app to the script. | Nothing in the app goes there, or data has to be put in place first. |

The other keys:

| Key | Meaning |
|---|---|
| `params` | The route's parameters. One is required unless it has a `default` or is `optional`. `values` lists the only values allowed. |
| `preset` | A launch preset from `presets:`. The app is restarted with it before the link is sent, so the route gives the same result every time. Not allowed with `run`. |
| `expect` | An element that shows the route arrived. See "Check that it arrived". |
| `timeout` | How long a `run` script may take. The default is `5m`. |

- **Names** group with `/`, like `settings/about`.
- **`{name}`** stands for a parameter or a var. It is read in `url`, in `launch` args and env values, and in `expect`. It is not read in `run`: a script gets its values as environment variables.
- **Encoding.** In a `url`, a parameter's value is percent-encoded, so it cannot change the link's structure. `raw: true` on a parameter inserts its value as given. Use it for a value that is already encoded or that holds several path segments, and know that such a value can change the link's structure.
- **An optional parameter** may only be the whole value of a query item, like `tab={tab}`. The item is left out when no value is given.
- **`vars`** hold text that routes share, like the scheme and host. `.xcdev.local.yml` can override one, which points every route at another host on this machine:

```yaml
deeplinks:
  vars:
    base: "myapp-dev://staging"
```

A mistake in a route, such as an unknown placeholder, two kinds, or an unknown preset, is reported when the config loads. After editing, run `xcd open` and `xcd open <route> --dry-run`. `xcd config explain deeplinks` documents every key.

## Check that it arrived

Sending a link only means it was sent. `expect` names an element that shows the route worked, in a form `xcd ui wait` takes: `id:<identifier>`, `label:<text>`, or `label~<part>`. After the delivery xcd waits up to 10 seconds for it.

- **Give every https route an `expect`.** An https link reaches the app only where the app's associated domains work on that simulator. Otherwise Safari opens it, and the simulator still reports success. With `expect` the command fails with `wait_timeout` and says the app is in the background.
- **Name something specific to the parameters**, like `"label~Item {id}"`. If the element is already on screen when a link goes to the running app, the check proves nothing, and the result says `check: inconclusive`. It says the same when xcd could not look at the app before the link was sent, for example because the app was in the background.
- **The check is skipped**, and the result says so, for a Mac app and for a simulator that is not an iPhone or iPad on iOS 17 or later.
- **A link given directly** has no check. Follow `xcd open '<url>'` with `xcd ui wait <target>`.

## Warm and cold starts

A link that arrives while the app is not running takes a different path through the app than one that arrives while it is up, and that path is where link bugs tend to be.

- `xcd open <route>` sends the link to the running app. If the app is not running, xcd starts it and then sends the link.
- `xcd open <route> --cold` stops the app and lets the link itself start it.
- On a simulator, `--cold` cannot be combined with a preset: the system starts the app, so launch arguments cannot be passed. What the app prints is not captured for that run; its log messages are still in `xcd logs`. On a Mac both work.
- An app that attaches its link handler late, after a sign-in or a loading screen, can miss a link sent right after launch, exactly as it would miss a real link that started it. For such an app run `xcd launch`, then `xcd ui wait` for something on the first real screen, then `xcd open <route>`.

## Script routes

The script runs with `/bin/sh -c` from the worktree root, and its output goes to a log that the result names. It gets the worktree's context (`xcd context` prints it) and these:

| Variable | Holds |
|---|---|
| `XCD_ROUTE` | The route's name. |
| `XCD_PARAM_<NAME>` | One per parameter that has a value, with the name in capitals. An optional parameter with no value is unset. |

```sh
#!/bin/sh
# scripts/open-about.sh
set -eu
xcd launch --device "$XCD_DEVICE"
xcd ui tap "label:Settings" --device "$XCD_DEVICE"
xcd ui tap "label:About" --device "$XCD_DEVICE"
```

- Pass `--device "$XCD_DEVICE"` to every `xcd` command in the script. Built-in commands do not read `XCD_DEVICE`.
- No build is needed before a script route, so the script may build or install. `XCD_APP_PATH` and `XCD_BUNDLE_ID` are unset when nothing is built.
- The script may open another route with `xcd open`. That route does not get this one's parameters.
- A non-zero exit is `route_failed`, with the last lines of the log. Running past `timeout` is `timeout`.
- `--preset` and `--cold` do not apply, because the script starts the app itself.

## Mac apps

`xcd open --device mac` sends the link to this worktree's build of the app, in the background. The frontmost app does not change, and another worktree's copy of the app does not get the link. An https link is handed to the app as an opened URL (`onOpenURL`, `application(_:open:)`). It does not arrive as a universal-link user activity, so an app that only handles `NSUserActivity` will not see it.

## When something fails

Every failure ends with `next:`. Do what it says first.

| Error | Meaning | What to do |
|---|---|---|
| `usage` | An unknown route, a missing or unknown parameter, a value outside `values`, or a scheme the built app does not register. | The error lists the route's parameters, or the schemes the app registers. |
| `config_invalid` | A route in `.xcdev.yml` breaks a rule. | The error names the key. `xcd config explain deeplinks` documents it. |
| `app_not_built` | There is no build to deliver to. `xcd open` never builds. | `xcd run`. |
| `app_crashed` | The app ended in the seconds after the delivery. | Read the crash report in the error. |
| `wait_timeout` | The route's `expect` did not appear. | The error lists what is on screen. "The app is in the background" means the link opened somewhere else. |
| `route_failed` | A script exited non-zero, or a `--cold` link did not start the app. | Read the script's log, or `xcd logs`. |
| `runner_failed` | The arrival check could not run. The link had already been sent. | `xcd ui stop`, retry, then `xcd doctor`. |
