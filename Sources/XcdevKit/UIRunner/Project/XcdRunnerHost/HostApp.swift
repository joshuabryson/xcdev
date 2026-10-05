import SwiftUI

// A UI-test target needs a target application. xcodebuild never launches or installs this one.
@main
struct XcdRunnerHostApp: App {
    var body: some Scene {
        WindowGroup { Text("XcdRunnerHost") }
    }
}
