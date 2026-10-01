import SwiftUI
import os

@main
struct SampleAppApp: App {
    private static let logger = Logger(subsystem: "dev.xcdev.SampleApp", category: "app")

    init() {
        let greeting = ProcessInfo.processInfo.environment["GREETING"] ?? "none"
        print("SampleApp launched greeting=\(greeting)")
        Self.logger.info("sample log line")
        if ProcessInfo.processInfo.arguments.contains("-crashOnLaunch") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                fatalError("SampleApp crashed on purpose")
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
