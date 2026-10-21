import AppKit
import SwiftUI

func log(_ s: String) { FileHandle.standardOutput.write((s + "\n").data(using: .utf8) ?? Data()) }

final class Model: ObservableObject {
    @Published var count = 0
    @Published var name = ""
    @Published var submits = 0
    @Published var active = false
    @Published var lastRow = ""
    @Published var appKitCount = 0
}

let model = Model()

final class Delegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        log("launched pid=\(getpid()) home=\(NSHomeDirectory()) hidden=\(NSApp.isHidden) active=\(NSApp.isActive)")
        log("appearance=\(NSApp.effectiveAppearance.name.rawValue)")
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                     NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                model.active = NSApp.isActive
                log("event \(name.rawValue) active=\(NSApp.isActive) hidden=\(NSApp.isHidden)")
            }
        }
    }
    func application(_ app: NSApplication, open urls: [URL]) {
        for url in urls {
            let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "count" }?.value
            if let value, let n = Int(value) { model.count = n }
            log("opened \(url.absoluteString) hidden=\(NSApp.isHidden)")
        }
    }
}

struct AppKitButton: NSViewRepresentable {
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "AppKit", target: context.coordinator, action: #selector(Coordinator.pressed))
        button.setAccessibilityIdentifier("appkit-button")
        return button
    }
    func updateNSView(_ view: NSButton, context: Context) { view.title = "AppKit" }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { @objc func pressed() { model.appKitCount += 1; log("appkit \(model.appKitCount)") } }
}

@main
struct MacProbeApp: App {
    @NSApplicationDelegateAdaptor(Delegate.self) var delegate
    var body: some Scene {
        WindowGroup("Probe") { ContentView().frame(minWidth: 420, minHeight: 560) }
            .commands { CommandMenu("Probe") { Button("Bump by ten") { model.count += 10; log("menu bump \(model.count)") }.keyboardShortcut("b") } }
    }
}

struct ContentView: View {
    @ObservedObject var m = model
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("count: \(m.count)").accessibilityIdentifier("count")
            Button("Increment") { m.count += 1; log("increment \(m.count)") }.accessibilityIdentifier("increment")
            TextField("Name", text: $m.name).accessibilityIdentifier("name").onSubmit { m.submits += 1; log("submit \(m.name)") }
            Text("name: \(m.name)").accessibilityIdentifier("name-mirror")
            Text("submits: \(m.submits)").accessibilityIdentifier("submits")
            Text("active: \(m.active)").accessibilityIdentifier("active")
            Text("last row: \(m.lastRow)").accessibilityIdentifier("last-row")
            HStack { AppKitButton(); Text("appkit: \(m.appKitCount)").accessibilityIdentifier("appkit-count") }
            Text("appearance: \(NSApp.effectiveAppearance.name.rawValue)").accessibilityIdentifier("appearance")
            List(1...40, id: \.self) { i in
                Button("Row \(i)") { m.lastRow = "\(i)"; log("row \(i)") }.buttonStyle(.plain).accessibilityIdentifier("row-\(i)")
                    .contextMenu { Button("Row action \(i)") { m.lastRow = "menu \(i)"; log("context \(i)") } }
            }
            .frame(minHeight: 200)
        }
        .padding()
        .onChange(of: m.name) { _, new in log("name changed to \(new)") }
    }
}
