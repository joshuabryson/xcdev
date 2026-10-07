import SwiftUI
import os

/// What the app was last asked to show, and how the request reached it.
@MainActor
final class Arrival: ObservableObject {
    static let shared = Arrival()

    @Published var value = ""
    /// "cold" (the link started the app), "warm" (the app was already running), or "argument" (`-startRoute`).
    @Published var source = ""
    /// Set when the scene connects with a link: the system started the app to open it.
    var startedByLink = false

    func receive(_ url: URL) {
        if url.host() == "crash" { fatalError("SampleApp crashed on a link") }
        value = url.absoluteString
        source = startedByLink ? "cold" : "warm"
        startedByLink = false
        print("SampleApp link=\(value) source=\(source)")
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        if !options.urlContexts.isEmpty { Arrival.shared.startedByLink = true }
    }
}

@main
struct SampleAppApp: App {
    private static let logger = Logger(subsystem: "dev.xcdev.SampleApp", category: "app")
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var arrival = Arrival.shared

    init() {
        let greeting = ProcessInfo.processInfo.environment["GREETING"] ?? "none"
        print("SampleApp launched greeting=\(greeting)")
        Self.logger.info("sample log line")
        if ProcessInfo.processInfo.arguments.contains("-crashOnLaunch") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                fatalError("SampleApp crashed on purpose")
            }
        }
        if let route = UserDefaults.standard.string(forKey: "startRoute") {
            Arrival.shared.value = route
            Arrival.shared.source = "argument"
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(arrival)
                .onOpenURL { arrival.receive($0) }
        }
    }
}
