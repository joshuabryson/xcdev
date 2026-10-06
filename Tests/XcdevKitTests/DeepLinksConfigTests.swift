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
