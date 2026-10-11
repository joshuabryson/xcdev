import Foundation
import Testing
@testable import XcdevKit

@Suite struct DeepLinksConfigTests {
    /// The example deep links config, with the preset it names.
    static let example = """
    version: 1
    project: App.xcodeproj
    defaultDevice: iphone
    devices:
      iphone: { type: "iPhone 18 Pro" }
      mac: { platform: macOS }
    presets:
      fresh-install: { args: ["-resetOnboarding", "YES"], env: { API_ENV: staging } }
    deeplinks:
      vars:
        base: "sampleapp://sampleapp"
      routes:
        item:
          description: "Open one saved link"
          url: "{base}/item?id={id}&tab={tab}"
          expect: "id:item-detail"
          params:
            id:  { description: "The link's UUID" }
            tab: { description: "Which tab to show", values: [notes, preview], optional: true }
        settings/appearance:
          description: "Appearance settings"
          url: "{base}/settings/appearance"
        onboarding:
          description: "Start at an onboarding step"
          launch: { args: ["-startRoute", "onboarding/{step}"] }
          preset: fresh-install
          params:
            step: { description: "1 to 4", default: 1 }
        seeded-album:
          description: "Create a sample album and open it"
          run: ./scripts/open-album.sh
    """

    /// A config with one route, written as the lines under `routes:` (indented four spaces), plus optional vars.
    static func config(_ routes: String, vars: String = "") -> String {
        """
        version: 1
        project: App.xcodeproj
        presets:
          fresh: { args: ["-reset"] }
        deeplinks:
          vars: {\(vars)}
          routes:
        \(routes)
        """
    }

    func issues(_ routes: String, vars: String = "") -> [String] {
        do {
            _ = try ConfigLoader.parse(main: Self.config(routes, vars: vars))
            return []
        } catch {
            return (error as? XcdError)?.details ?? ["\(error)"]
        }
    }

    @Test func theExampleConfigLoads() throws {
        let config = try ConfigLoader.parse(main: Self.example)
        #expect(config.linkVars == ["base": "sampleapp://sampleapp"])
        #expect(config.routes.keys.sorted() == ["item", "onboarding", "seeded-album", "settings/appearance"])
        let item = try #require(config.routes["item"])
        #expect(item.kinds == [.url] && item.expect == "id:item-detail")
        #expect(item.allParams["id"]?.isRequired == true)
        #expect(item.allParams["tab"] == RouteParam(description: "Which tab to show", optional: true, values: ["notes", "preview"]))
        let onboarding = try #require(config.routes["onboarding"])
        #expect(onboarding.kinds == [.launch] && onboarding.preset == "fresh-install")
        #expect(onboarding.launch?.args == ["-startRoute", "onboarding/{step}"])
        #expect(onboarding.allParams["step"]?.defaultValue == "1")          // a YAML number is read as text
        #expect(config.routes["seeded-album"]?.kinds == [.run])
        #expect(config.routes["seeded-album"]?.timeoutDuration == .seconds(300))
        #expect(RouteSpec(description: "d", run: "./a.sh", timeout: "90s").timeoutDuration == .seconds(90))
    }

    @Test func aConfigWithoutTheSectionHasNoRoutes() throws {
        let config = try ConfigLoader.parse(main: "version: 1\nproject: A.xcodeproj\n")
        #expect(config.deeplinks == nil && config.routes.isEmpty && config.linkVars.isEmpty)
        #expect(try ConfigLoader.parse(main: "version: 1\nproject: A.xcodeproj\ndeeplinks: {}\n").routes.isEmpty)
        #expect(!ConfigSchema.reservedTopLevelKeys.contains("deeplinks"))
    }

    /// `.xcdev.local.yml` points every route at another host by overriding one var.
    @Test func theLocalFileOverridesAVar() throws {
        let config = try ConfigLoader.parse(main: Self.example, local: "deeplinks:\n  vars:\n    base: \"sampleapp-dev://local\"\n")
        #expect(config.linkVars["base"] == "sampleapp-dev://local")
        #expect(config.routes.count == 4)
    }

    @Test func structuralMistakesNameTheKey() {
        #expect(issues("    a: { url: \"x://y\" }") == ["deeplinks.routes.a.description: is required"])
        #expect(issues("    a: { description: d, url: \"x://y\", push: {} }")
                == ["deeplinks.routes.a.push: is reserved for links carried in a push notification, which this version of xcd does not support yet"])
        #expect(issues("    a: { description: d, url: \"x://y\", exspect: \"id:a\" }")
                == ["deeplinks.routes.a.exspect: unknown key (did you mean 'expect'?)"])
        #expect(issues("    a: { description: d, url: \"x://y?t={t}\", params: { t: { optional: maybe } } }")
                == ["deeplinks.routes.a.params.t.optional: expected true or false"])
        #expect(issues("    a: { description: d, launch: { args: \"-x\" } }") == ["deeplinks.routes.a.launch.args: expected a list of strings"])
    }

    /// A name made of digits is allowed, quoted or not. (Quoted, the YAML decoder alone would not find the key.)
    @Test func aRouteNamedWithDigitsLoadsQuotedOrNot() throws {
        let config = try ConfigLoader.parse(main: Self.config("""
            404: { description: d, run: ./a.sh }
            "500": { description: d, run: ./a.sh, params: { "on": { default: "true" } } }
        """))
        #expect(config.routes.keys.sorted() == ["404", "500"])
        #expect(config.routes["500"]?.allParams["on"]?.defaultValue == "true")
    }

    @Test func theSectionIsExplainedAndInTheSchema() throws {
        #expect(try ConfigExplainer.explain("deeplinks.routes.item.url").key == "deeplinks.routes.<name>.url")
        #expect(try ConfigExplainer.explain("deeplinks.routes.item.params.id.optional").type == "true or false")
        #expect(try ConfigExplainer.explain("deeplinks.routes.<name>.timeout").defaultValue == "5m")
        #expect(try ConfigExplainer.explain("deeplinks.vars").type == "map of strings")
        let keys = ConfigExplainer.keys().map(\.key)
        #expect(!keys.contains { $0.hasSuffix(".push") })
        let pushed = #expect(throws: XcdError.self) { try ConfigExplainer.explain("deeplinks.routes.item.push") }
        #expect(pushed?.code == .usage)

        let root = try #require(try JSONSerialization.jsonObject(with: Data(JSONSchemaWriter.write().utf8)) as? [String: Any])
        let properties = try #require(root["properties"] as? [String: Any])
        let deeplinks = try #require(properties["deeplinks"] as? [String: Any])
        let routes = try #require((deeplinks["properties"] as? [String: Any])?["routes"] as? [String: Any])
        let route = try #require(routes["additionalProperties"] as? [String: Any])
        let fields = try #require(route["properties"] as? [String: Any])
        #expect(fields.keys.sorted() == ["description", "expect", "launch", "params", "preset", "run", "timeout", "url"])
        #expect(route["required"] as? [String] == ["description"])
        let param = try #require((fields["params"] as? [String: Any])?["additionalProperties"] as? [String: Any])
        let optional = try #require((param["properties"] as? [String: Any])?["optional"] as? [String: Any])
        #expect(optional["type"] as? String == "boolean")
    }
}

/// The cross-field rules of a deep links config. Each mistake is reported with the path of its key.
extension DeepLinksConfigTests {
    @Test func aRouteHasExactlyOneKind() {
        #expect(issues("    a: { description: d }") == ["deeplinks.routes.a: needs one of url, launch, or run"])
        #expect(issues("    a: { description: d, url: \"x://y\", run: ./a.sh }")
                == ["deeplinks.routes.a: has url and run; a route has exactly one of url, launch, or run"])
        #expect(issues("    a: { description: d, launch: {} }") == ["deeplinks.routes.a.launch: needs args or env"])
        #expect(issues("    a: { description: \" \", run: \" \" }")
                == ["deeplinks.routes.a.description: must not be empty", "deeplinks.routes.a.run: must not be empty"])
    }

    @Test func namesFollowTheRules() {
        #expect(issues("    \"a:b\": { description: d, run: ./a.sh }")
                == ["deeplinks.routes.a:b: 'a:b' is not a valid route name (segments of letters, digits, '.', '_' and '-', joined by '/')"])
        for bad in ["a b", "a=b", "/a", "a/", "a//b", "-a", "a/-b"] {
            #expect(issues("    \"\(bad)\": { description: d, run: ./a.sh }").count == 1, "\(bad) was accepted")
        }
        for good in ["a", "settings/appearance", "v1.2/item_3", "9", "a-b/c.d"] {
            #expect(issues("    \"\(good)\": { description: d, run: ./a.sh }").isEmpty, "\(good) was refused")
        }
        #expect(issues("    a: { description: d, run: ./a.sh, params: { 1st: {}, a-b: {} } }") == [
            "deeplinks.routes.a.params.1st: '1st' is not a valid parameter name (a letter, then letters, digits, and '_')",
            "deeplinks.routes.a.params.a-b: 'a-b' is not a valid parameter name (a letter, then letters, digits, and '_')",
        ])
        #expect(issues("    a: { description: d, run: ./a.sh }", vars: " my-host: x ")
                == ["deeplinks.vars.my-host: 'my-host' is not a valid var name (a letter, then letters, digits, and '_')"])
    }

    @Test func placeholdersMustBeKnownAndClosed() {
        #expect(issues("    a: { description: d, url: \"x://y/{id}\" }")
                == ["deeplinks.routes.a.url: {id} is neither a parameter of this route nor a var"])
        #expect(issues("    a: { description: d, url: \"x://y/{id\" }")
                == ["deeplinks.routes.a.url: has a '{' that is never closed (write '{{' for a literal brace)"])
        #expect(issues("    a: { description: d, launch: { args: [\"-a\", \"{b}\"], env: { K: \"{c}\" } } }") == [
            "deeplinks.routes.a.launch.args[1]: {b} is neither a parameter of this route nor a var",
            "deeplinks.routes.a.launch.env.K: {c} is neither a parameter of this route nor a var",
        ])
        #expect(issues("    a: { description: d, url: \"x://y\", expect: \"id:{nope}\" }")
                == ["deeplinks.routes.a.expect: {nope} is neither a parameter of this route nor a var"])
        // A script gets its values as environment variables, so braces in `run` are the shell's.
        #expect(issues("    a: { description: d, run: \"echo ${HOME} {x}\" }").isEmpty)
        #expect(issues("    a: { description: d, url: \"{base}/y/{{literal}}\" }", vars: " base: \"x://h\" ").isEmpty)
    }

    @Test func everyParameterOfALinkOrLaunchRouteIsUsed() {
        #expect(issues("    a: { description: d, url: \"x://y\", params: { id: {} } }")
                == ["deeplinks.routes.a.params.id: is not used by any placeholder"])
        #expect(issues("    a: { description: d, launch: { args: [\"-x\"] }, params: { id: {} } }")
                == ["deeplinks.routes.a.params.id: is not used by any placeholder"])
        #expect(issues("    a: { description: d, url: \"x://y\", expect: \"label~{title}\", params: { title: {} } }").isEmpty)
        #expect(issues("    a: { description: d, run: ./a.sh, params: { id: {} } }").isEmpty)
    }

    @Test func namesThatDifferOnlyInCaseAreRefused() {
        #expect(issues("    a: { description: d, run: ./a.sh, params: { id: {}, ID: {}, Id: {} } }") == [
            "deeplinks.routes.a.params.ID: differs from the parameter 'Id' only in case",
            "deeplinks.routes.a.params.ID: differs from the parameter 'id' only in case",
            "deeplinks.routes.a.params.Id: differs from the parameter 'id' only in case",
        ])
        #expect(issues("    a: { description: d, run: ./a.sh, params: { Base: {} } }", vars: " base: x ")
                == ["deeplinks.routes.a.params.Base: differs from the var 'base' only in case"])
        #expect(issues("    a: { description: d, run: ./a.sh, params: { base: {} } }", vars: " base: x ")
                == ["deeplinks.routes.a.params.base: has the same name as a var; rename one of them"])
    }

    @Test func defaultsOptionalsAndValues() {
        #expect(issues("    a: { description: d, url: \"x://y?t={t}\", params: { t: { default: a, optional: true } } }")
                == ["deeplinks.routes.a.params.t: has both default and optional; an optional parameter has no default"])
        #expect(issues("    a: { description: d, url: \"x://y?t={t}\", params: { t: { values: [] } } }")
                == ["deeplinks.routes.a.params.t.values: must not be empty"])
        #expect(issues("    a: { description: d, url: \"x://y?t={t}\", params: { t: { values: [a, b], default: c } } }")
                == ["deeplinks.routes.a.params.t.default: 'c' is not one of values: a, b"])
        #expect(issues("    a: { description: d, url: \"x://y?t={t}\", params: { t: { values: [1, 2], default: 2, optional: false } } }").isEmpty)
    }

    @Test func anOptionalParameterIsOnlyAWholeQueryValue() {
        let message = "is optional, so {t} may only be the whole value of a query item in the url, like t={t}"
        #expect(issues("    a: { description: d, url: \"x://y?t={t}\", params: { t: { optional: true } } }").isEmpty)
        #expect(issues("    a: { description: d, url: \"x://y/{t}\", params: { t: { optional: true } } }")
                == ["deeplinks.routes.a.params.t: \(message)"])
        #expect(issues("    a: { description: d, url: \"x://y?t=v{t}\", params: { t: { optional: true } } }")
                == ["deeplinks.routes.a.params.t: \(message)"])
        #expect(issues("    a: { description: d, url: \"x://y#{t}\", params: { t: { optional: true } } }")
                == ["deeplinks.routes.a.params.t: \(message)"])
        #expect(issues("    a: { description: d, launch: { args: [\"{t}\"] }, params: { t: { optional: true } } }")
                == ["deeplinks.routes.a.params.t: is optional, which a launch route does not allow: give it a default, or leave it required"])
        #expect(issues("    a: { description: d, url: \"x://y?t={t}\", expect: \"label~{t}\", params: { t: { optional: true } } }")
                == ["deeplinks.routes.a.expect: uses {t}, which is optional; expect may only use parameters that always have a value"])
        #expect(issues("    a: { description: d, run: ./a.sh, params: { t: { optional: true } } }").isEmpty)
    }

    @Test func rawOnlyAppliesToAURLRoute() {
        #expect(issues("    a: { description: d, launch: { args: [\"{p}\"] }, params: { p: { raw: true } } }")
                == ["deeplinks.routes.a.params.p.raw: only applies to a parameter of a url route"])
        #expect(issues("    a: { description: d, url: \"x://y/{p}\", params: { p: { raw: true } } }").isEmpty)
    }

    @Test func aURLNeedsASchemeThatNoParameterSupplies() {
        let message = "has no scheme (like myapp: or https:) once its vars are filled in; a parameter cannot supply it"
        #expect(issues("    a: { description: d, url: \"/settings\" }") == ["deeplinks.routes.a.url: \(message)"])
        #expect(issues("    a: { description: d, url: \"{base}/settings\" }", vars: " base: \"host/path\" ") == ["deeplinks.routes.a.url: \(message)"])
        #expect(issues("    a: { description: d, url: \"{s}://settings\", params: { s: {} } }") == ["deeplinks.routes.a.url: \(message)"])
        #expect(issues("    a: { description: d, url: \"{base}/settings\" }", vars: " base: \"https://example.com\" ").isEmpty)
    }

    @Test func presetTimeoutAndExpect() {
        #expect(issues("    a: { description: d, url: \"x://y\", preset: nope }") == ["deeplinks.routes.a.preset: 'nope' is not a key under presets"])
        #expect(issues("    a: { description: d, url: \"x://y\", preset: fresh }").isEmpty)
        #expect(issues("    a: { description: d, run: ./a.sh, preset: fresh }")
                == ["deeplinks.routes.a.preset: is not allowed on a run route: its script starts the app itself"])
        #expect(issues("    a: { description: d, url: \"x://y\", timeout: 1m }") == ["deeplinks.routes.a.timeout: only applies to a run route"])
        #expect(issues("    a: { description: d, run: ./a.sh, timeout: soon }")
                == ["deeplinks.routes.a.timeout: 'soon' is not a duration like \"30s\", \"5m\", or \"1h\""])
        #expect(issues("    a: { description: d, run: ./a.sh, timeout: 90s }").isEmpty)
        for bad in ["item-detail", "ref:e3", "e3", "@10,20", "id:", "label"] {
            #expect(issues("    a: { description: d, url: \"x://y\", expect: \"\(bad)\" }")
                    == ["deeplinks.routes.a.expect: '\(bad)' is not an `id:<identifier>`, `label:<text>`, or `label~<part>` target"])
        }
        for good in ["id:item-detail", "label:Settings", "label~Step"] {
            #expect(issues("    a: { description: d, url: \"x://y\", expect: \"\(good)\" }").isEmpty)
        }
    }

    /// Several mistakes come back together, routes in name order.
    @Test func everyProblemIsReportedAtOnce() {
        let found = issues("""
            b: { description: d }
            a: { description: d, url: "nope", params: { id: {} } }
        """)
        #expect(found == [
            "deeplinks.routes.a.url: has no scheme (like myapp: or https:) once its vars are filled in; a parameter cannot supply it",
            "deeplinks.routes.a.params.id: is not used by any placeholder",
            "deeplinks.routes.b: needs one of url, launch, or run",
        ])
    }

    /// The checks run on the two files merged, so a local override can break a route and is reported.
    @Test func theMergedFilesAreChecked() {
        let error = #expect(throws: XcdError.self) {
            try ConfigLoader.parse(main: Self.example, local: "deeplinks:\n  vars:\n    base: \"no-scheme\"\n")
        }
        #expect(error?.code == .configInvalid)
        #expect(error?.message == ".xcdev.yml + .xcdev.local.yml is invalid (2 problems)")
        #expect(error?.details.allSatisfy { $0.hasSuffix("a parameter cannot supply it") } == true)
    }
}
