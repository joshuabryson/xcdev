import Foundation
import Testing
@testable import XcdevKit

@Suite struct RouteResolverTests {
    static let yaml = """
    version: 1
    project: App.xcodeproj
    presets:
      fresh: { args: ["-reset"] }
    deeplinks:
      vars:
        base: "myapp://host"
        greeting: "Hello {id}"
      routes:
        item:
          description: "Open one item"
          url: "{base}/item/{id}?tab={tab}&q={q}#{anchor}"
          expect: "label~{id}"
          preset: fresh
          params:
            id: { description: "The item's id" }
            tab: { description: "Which tab", values: [notes, preview], optional: true }
            q: { optional: true }
            anchor: { default: top }
        page:
          description: "Open a page by path"
          url: "{base}/{path}?from={from}"
          params:
            path: { raw: true }
            from: { default: "a b" }
        onboarding:
          description: "Start at a step"
          launch: { args: ["-startRoute", "onboarding/{step}", "{greeting}"], env: { STEP: "{step}", FIXED: "1" } }
          params:
            step: { default: 1, values: [1, 2, 3] }
        seeded:
          description: "Seed and open"
          run: "./scripts/seed.sh {not a placeholder}"
          timeout: 90s
          params:
            title: {}
            Count: { default: 3 }
            note: { optional: true }
    """

    /// A launch route whose parameter is free text, to show that nothing outside a `url` is encoded.
    static let launchYaml = """
    version: 1
    project: App.xcodeproj
    deeplinks:
      routes:
        greet:
          description: "Greet someone"
          launch: { args: ["-greet", "{who}"], env: { WHO: "{who}" } }
          params:
            who: { default: "a b&c/é" }
    """

    /// A value can leave an `expect` with nothing to look for: `label~{id}` with an empty id is `label~`, which is
    /// no target. That is found before anything touches a device.
    @Test func anExpectThatAValueLeavesEmptyIsRefused() throws {
        let resolver = try resolver()
        #expect(try resolver.resolve(.route(name: "item", values: ["id": "Milk"])).expect == "label~Milk")
        let error = #expect(throws: XcdError.self) { _ = try resolver.resolve(.route(name: "item", values: ["id": ""])) }
        #expect(error?.code == .usage)
        #expect(error?.message == "route 'item' expects 'label~{id}', which names nothing with these values: 'label~'")
        #expect(error?.next == "give the parameters it uses a value that is not empty")
    }

    func resolver(_ yaml: String = RouteResolverTests.yaml) throws -> RouteResolver {
        RouteResolver(config: try ConfigLoader.parse(main: yaml))
    }

    func failure(_ name: String, _ values: [String: String] = [:]) throws -> XcdError? {
        let resolver = try resolver()
        return #expect(throws: XcdError.self) { try resolver.resolve(.route(name: name, values: values)) }
    }

    @Test func aURLRouteIsFilledAndEncoded() throws {
        let route = try resolver().resolve(.route(name: "item", values: ["id": "a b&c/é", "tab": "notes"]))
        #expect(route.delivery == .url("myapp://host/item/a%20b%26c%2F%C3%A9?tab=notes#top"))
        #expect(route.name == "item" && route.preset == "fresh" && route.delivery.kind == .url)
        #expect(route.expect == "label~a b&c/é")                           // nothing but a URL is encoded
    }

    @Test func optionalItemsAreDroppedAndAnEmptyValueIsKept() throws {
        let resolver = try resolver()
        #expect(try resolver.resolve(.route(name: "item", values: ["id": "7"])).delivery == .url("myapp://host/item/7#top"))
        #expect(try resolver.resolve(.route(name: "item", values: ["id": "7", "q": ""])).delivery == .url("myapp://host/item/7?q=#top"))
        #expect(try resolver.resolve(.route(name: "item", values: ["id": "7", "q": "x", "anchor": "a#b"])).delivery
                == .url("myapp://host/item/7?q=x#a%23b"))
    }

    /// A raw parameter goes in as given; a default is encoded like any other value; a var is never encoded.
    @Test func rawDefaultsAndVars() throws {
        let route = try resolver().resolve(.route(name: "page", values: ["path": "docs/a%20b/c"]))
        #expect(route.delivery == .url("myapp://host/docs/a%20b/c?from=a%20b"))
        #expect(route.preset == nil && route.expect == nil)
    }

    /// One pass: a var whose text holds `{id}` is not filled in a second time.
    @Test func aLaunchRouteFillsArgumentsAndEnvironmentWithoutEncoding() throws {
        let route = try resolver().resolve(.route(name: "onboarding", values: ["step": "2"]))
        #expect(route.delivery == .launch(arguments: ["-startRoute", "onboarding/2", "Hello {id}"],
                                          environment: ["STEP": "2", "FIXED": "1"]))
        #expect(try resolver().resolve(.route(name: "onboarding", values: [:])).delivery
                == .launch(arguments: ["-startRoute", "onboarding/1", "Hello {id}"], environment: ["STEP": "1", "FIXED": "1"]))
        let greetResolver = try resolver(Self.launchYaml)
        #expect(try greetResolver.resolve(.route(name: "greet", values: ["who": "x y&z#?é/%"])).delivery
                == .launch(arguments: ["-greet", "x y&z#?é/%"], environment: ["WHO": "x y&z#?é/%"]))
        #expect(try greetResolver.resolve(.route(name: "greet", values: [:])).delivery
                == .launch(arguments: ["-greet", "a b&c/é"], environment: ["WHO": "a b&c/é"]))
    }

    /// A script gets its values as environment variables, upper-cased, and its command is never filled in.
    @Test func aScriptRouteGetsItsValuesAsVariables() throws {
        let route = try resolver().resolve(.route(name: "seeded", values: ["title": "Hello $(rm -rf) \"there\""]))
        #expect(route.delivery == .script(command: "./scripts/seed.sh {not a placeholder}",
                                          environment: ["XCD_ROUTE": "seeded", "XCD_PARAM_TITLE": "Hello $(rm -rf) \"there\"",
                                                        "XCD_PARAM_COUNT": "3"],
                                          unset: ["XCD_PARAM_NOTE"]))
        #expect(route.timeout == .seconds(90) && route.delivery.kind == .run)
        let full = try resolver().resolve(.route(name: "seeded", values: ["title": "t", "note": ""]))
        guard case .script(_, let environment, let unset) = full.delivery else {
            Issue.record("not a script: \(full.delivery)")
            return
        }
        #expect(environment["XCD_PARAM_NOTE"]?.isEmpty == true && unset.isEmpty)
    }

    @Test func aURLGivenDirectlyIsSentAsGiven() throws {
        let route = try resolver().resolve(.url("myapp://x/a b?c=%20"))
        #expect(route == ResolvedRoute.direct("myapp://x/a b?c=%20"))
        #expect(route.name == nil && route.delivery == .url("myapp://x/a b?c=%20") && route.expect == nil)
    }

    @Test func anUnknownRouteNamesTheClosest() throws {
        let unknown = try failure("itm")
        #expect(unknown?.code == .usage && unknown?.message == "no route named 'itm'")
        #expect(unknown?.next == "did you mean `item`? `xcd open` lists every route")
        #expect(try failure("zzzzzz")?.next == "`xcd open` lists every route")
        let empty = try resolver("version: 1\nproject: A.xcodeproj\n")
        let none = #expect(throws: XcdError.self) { try empty.resolve(.route(name: "item", values: [:])) }
        #expect(none?.code == .usage && none?.message == "this project defines no routes, so there is no route 'item'")
        #expect(none?.next == "add routes under `deeplinks:` in .xcdev.yml (`xcd guide deeplinks`)")
    }

    @Test func parameterMistakesShowTheRoutesParameters() throws {
        let rows = ["anchor  default=top", "id      required  The item's id", "q       optional",
                    "tab     optional  notes|preview  Which tab"]
        let usage = "run it as `xcd open item id=<id> [anchor=<anchor>] [q=<q>] [tab=<notes|preview>]`"
        let missing = try failure("item")
        #expect(missing?.code == .usage && missing?.message == "route 'item' needs id")
        #expect(missing?.details == rows && missing?.next == usage)
        let unknown = try failure("item", ["id": "1", "idd": "2"])
        #expect(unknown?.message == "route 'item' has no parameter 'idd' (did you mean 'id'?)" && unknown?.details == rows)
        let outside = try failure("item", ["id": "1", "tab": "other"])
        #expect(outside?.message == "tab=other is not one of: notes, preview" && outside?.next == usage)
        #expect(try failure("seeded")?.message == "route 'seeded' needs title")
        #expect(try failure("onboarding", ["step": "9"])?.message == "step=9 is not one of: 1, 2, 3")
    }

    @Test func theArgumentsSayWhatWasAskedFor() throws {
        #expect(try OpenRequest.parse([]) == .list)
        #expect(try OpenRequest.parse(["item"]) == .route(name: "item", values: [:]))
        #expect(try OpenRequest.parse(["settings/appearance", "a=1", "b=x=y", "c=", "d=two words"])
                == .route(name: "settings/appearance", values: ["a": "1", "b": "x=y", "c": "", "d": "two words"]))
        #expect(try OpenRequest.parse(["myapp://item?id=1&tab=a"]) == .url("myapp://item?id=1&tab=a"))
        #expect(try OpenRequest.parse(["https://example.com/a"]) == .url("https://example.com/a"))
    }

    @Test func badArgumentsAreUsageErrors() {
        func failure(_ arguments: [String]) -> XcdError? { #expect(throws: XcdError.self) { try OpenRequest.parse(arguments) } }
        #expect(failure(["item", "id"])?.message == "'id' is not name=value")
        #expect(failure(["item", "=1"])?.message == "'=1' is not name=value")
        #expect(failure(["item", "id=1", "id=2"])?.message == "the parameter 'id' is given twice")
        #expect(failure(["myapp://x", "id=1"])?.message == "a URL takes no parameters, but got: id=1")
        let noScheme = failure(["1:2"])
        #expect(noScheme?.code == .usage && noScheme?.message == "'1:2' is not a URL: it has no scheme before the ':'")
        #expect(noScheme?.next == OpenRequest.forms)
        #expect(failure(["a b:c"])?.code == .usage)
    }
}
