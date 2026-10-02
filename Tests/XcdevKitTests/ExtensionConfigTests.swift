import Foundation
import Testing
@testable import XcdevKit

@Suite struct ExtensionConfigTests {
    static let base = "version: 1\nproject: App.xcodeproj\n"

    @Test func parsesCommandsAndHooks() throws {
        let config = try ConfigLoader.parse(main: Self.base + """
        commands:
          seed-db:
            description: "Load fixture data into the running app's container"
            run: ./scripts/seed.sh
            needs: [device, build]
            timeout: 10m
          format: { run: swift-format }
        hooks:
          post-worktree-create: ./scripts/bootstrap.sh
          pre-build: swiftgen
          post-launch: ./scripts/grant-permissions.sh
          pre-worktree-remove: ./scripts/teardown.sh
        """)
        let seed = try #require(config.commands?["seed-db"])
        #expect(seed.run == "./scripts/seed.sh")
        #expect(seed.needsDevice && seed.needsBuild)
        #expect(seed.timeoutDuration == .seconds(600))
        #expect(config.commands?["format"]?.timeoutDuration == .seconds(1800))
        #expect(config.commands?["format"]?.needsDevice == false)
        #expect(config.hooks?.command(for: .preBuild) == "swiftgen")
        #expect(config.hooks?.command(for: .postWorktreeCreate) == "./scripts/bootstrap.sh")
        #expect(config.hooks?.command(for: .postLaunch) == "./scripts/grant-permissions.sh")
        #expect(config.hooks?.command(for: .preWorktreeRemove) == "./scripts/teardown.sh")
    }

    @Test func aHookNameTypoSuggestsTheRealOne() {
        let error = #expect(throws: XcdError.self) {
            try ConfigLoader.parse(main: Self.base + "hooks:\n  pre-buld: swiftgen\n")
        }
        #expect(error?.code == .configInvalid)
        #expect(error?.details == ["hooks.pre-buld: unknown key (did you mean 'pre-build'?)"])
    }

    @Test func aCommandNeedsARunLine() {
        let error = #expect(throws: XcdError.self) {
            try ConfigLoader.parse(main: Self.base + "commands:\n  seed: { description: Seed }\n")
        }
        #expect(error?.details == ["commands.seed.run: is required"])
    }

    @Test func commandMistakesAreReportedTogether() {
        let error = #expect(throws: XcdError.self) {
            try ConfigLoader.parse(main: Self.base + """
            commands:
              build: { run: make }
              seed: { run: ./seed.sh, needs: [devices], timeout: soon }
              "bad name": { run: x }
            """)
        }
        #expect(error?.details == [
            "commands.bad name: 'bad name' is not a valid command name (use letters, digits, '.', '_' or '-')",
            "commands.build: 'build' is a built-in xcd command, so `xcd build` would never run this; rename it",
            "commands.seed.needs[0]: 'devices' is not one of: device, build (did you mean 'device'?)",
            "commands.seed.timeout: 'soon' is not a duration like \"30s\", \"10m\", or \"1h\"",
        ])
    }

    @Test func commandsAndHooksAreNoLongerReserved() {
        #expect(!ConfigSchema.reservedTopLevelKeys.contains("commands"))
        #expect(!ConfigSchema.reservedTopLevelKeys.contains("hooks"))
        #expect(BuiltinCommands.reservedNames.isSuperset(of: ["build", "wt", "help", "init", "guide", "doctor", "prune", "errors"]))
    }

    @Test func jsonSchemaDescribesCommandsAndHooks() throws {
        let root = try #require(try JSONSerialization.jsonObject(with: Data(JSONSchemaWriter.write().utf8)) as? [String: Any])
        let properties = try #require(root["properties"] as? [String: Any])
        let hooks = try #require(properties["hooks"] as? [String: Any])
        let hookNames = try #require(hooks["properties"] as? [String: Any]).keys.sorted()
        #expect(hookNames == HookName.allCases.map(\.rawValue).sorted())
        let commands = try #require(properties["commands"] as? [String: Any])
        let command = try #require(commands["additionalProperties"] as? [String: Any])
        #expect(command["required"] as? [String] == ["run"])
    }
}
