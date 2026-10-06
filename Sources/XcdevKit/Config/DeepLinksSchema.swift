extension ConfigSchema {
    /// `deeplinks:`.
    static let deeplinks: SchemaNode = .object("Links the app can open, by name. `xcd open` lists them and `xcd open <route> [name=value …]` opens one.", [
        SchemaField("vars", .stringMap("Text that any route can use as {name}: the link's scheme and host, for example. `.xcdev.local.yml` can override one, which points every route somewhere else."),
                    example: "deeplinks:\n  vars:\n    base: \"myapp://app\""),
        SchemaField("routes", .map("Named routes. A name is one or more segments joined by `/` (settings/appearance); a segment starts with a letter or digit and holds letters, digits, `-`, `_`, and `.`.", route),
                    example: "deeplinks:\n  routes:\n    settings:\n      description: \"Open settings\"\n      url: \"myapp://app/settings\""),
    ])

    private static let route: SchemaNode = .object("A route. It has exactly one of url, launch, and run.", [
        SchemaField("description", .string("One line shown when routes are listed."), required: true,
                    example: "deeplinks:\n  routes:\n    settings: { description: \"Open settings\", url: \"myapp://app/settings\" }"),
        SchemaField("url", .string("A link opened on the device: a custom scheme or https. {name} stands for a parameter or a var; {{ and }} are literal braces. A parameter's value is percent-encoded."),
                    example: "deeplinks:\n  routes:\n    item:\n      description: \"Open one item\"\n      url: \"myapp://app/item?id={id}\"\n      params:\n        id: { description: \"The item's id\" }"),
        SchemaField("launch", .object("Arguments and environment variables the app is started with. At least one of args and env. Values may hold {name} placeholders.", [
            SchemaField("args", .stringList("Launch arguments, after the preset's."),
                        example: "deeplinks:\n  routes:\n    onboarding:\n      description: \"Start at onboarding\"\n      launch: { args: [\"-startRoute\", \"onboarding\"] }"),
            SchemaField("env", .stringMap("Environment variables, over the preset's."),
                        example: "deeplinks:\n  routes:\n    staging:\n      description: \"Start against staging\"\n      launch: { env: { API_ENV: staging } }"),
        ]), example: "deeplinks:\n  routes:\n    onboarding:\n      description: \"Start at onboarding\"\n      launch: { args: [\"-startRoute\", \"onboarding\"] }"),
        SchemaField("run", .string("A shell command, the project's own way to get there. It runs from the worktree root with the XCD_* context variables, XCD_ROUTE, and one XCD_PARAM_<NAME> per parameter. Placeholders are not read here."),
                    example: "deeplinks:\n  routes:\n    seeded-album:\n      description: \"Create a sample album and open it\"\n      run: ./scripts/open-album.sh"),
        SchemaField("params", .map("The route's parameters, given as name=value. A name starts with a letter and holds letters, digits, and `_`.", param),
                    example: "deeplinks:\n  routes:\n    item:\n      description: \"Open one item\"\n      url: \"myapp://app/item?id={id}\"\n      params:\n        id: { description: \"The item's id\" }"),
        SchemaField("preset", .string("A launch preset (a key under presets). The app is restarted with it before the link is delivered. Not allowed with run."),
                    example: "deeplinks:\n  routes:\n    welcome:\n      description: \"The welcome screen of a fresh install\"\n      url: \"myapp://app/welcome\"\n      preset: fresh-install"),
        SchemaField("expect", .string("An element that shows the link arrived: `id:<identifier>`, `label:<text>`, or `label~<part>`. It may hold {name} placeholders."),
                    example: "deeplinks:\n  routes:\n    settings:\n      description: \"Open settings\"\n      url: \"myapp://app/settings\"\n      expect: \"id:settings-screen\""),
        SchemaField("timeout", .string("Longest a run script may take, e.g. \"2m\". Only with run."), default: "5m",
                    example: "deeplinks:\n  routes:\n    seeded-album:\n      description: \"Create a sample album and open it\"\n      run: ./scripts/open-album.sh\n      timeout: 2m"),
        SchemaField("push", .reserved("links carried in a push notification"), example: ""),
    ])

    private static let param: SchemaNode = .object("A parameter. It is required unless it has a default or is optional.", [
        SchemaField("description", .string("Shown when routes are listed."),
                    example: "deeplinks:\n  routes:\n    item:\n      description: \"Open one item\"\n      url: \"myapp://app/item?id={id}\"\n      params:\n        id: { description: \"The item's id\" }"),
        SchemaField("default", .string("Used when the caller gives no value."),
                    example: "deeplinks:\n  routes:\n    onboarding:\n      description: \"Start at an onboarding step\"\n      launch: { args: [\"-startRoute\", \"onboarding/{step}\"] }\n      params:\n        step: { default: \"1\" }"),
        SchemaField("optional", .boolean("The parameter may be left out, with no default. Allowed only as the whole value of a query item in a url (tab={tab}), which is then dropped, or in a run route."),
                    default: "false",
                    example: "deeplinks:\n  routes:\n    item:\n      description: \"Open one item\"\n      url: \"myapp://app/item?id={id}&tab={tab}\"\n      params:\n        id: {}\n        tab: { optional: true }"),
        SchemaField("values", .stringList("The only values allowed."),
                    example: "deeplinks:\n  routes:\n    item:\n      description: \"Open one item\"\n      url: \"myapp://app/item?tab={tab}\"\n      params:\n        tab: { values: [notes, preview] }"),
        SchemaField("raw", .boolean("In a url, insert the value as given instead of percent-encoding it: for a value that is already encoded or that holds several path segments."),
                    default: "false",
                    example: "deeplinks:\n  routes:\n    page:\n      description: \"Open a page by its path\"\n      url: \"myapp://app/{path}\"\n      params:\n        path: { raw: true }"),
    ])
}
