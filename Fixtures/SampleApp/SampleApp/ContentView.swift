import Photos
import SwiftUI

struct ContentView: View {
    @State private var email = ""
    @State private var remember = false
    @State private var signedIn = false
    @State private var taps = 0

    var body: some View {
        Form {
            Section {
                Text("SampleApp")
                TextField("Email", text: $email)
                    .accessibilityIdentifier("emailField")
                Toggle("Remember me", isOn: $remember)
                    .accessibilityIdentifier("rememberMe")
            }
            Section {
                Button("Sign In") { signedIn = true }
                    .accessibilityIdentifier("signInButton")
                Button { taps += 1 } label: { Image(systemName: "gearshape") }
                    .accessibilityIdentifier("gearButton")
                Button("Unavailable") { /* disabled: never runs */ }
                    .disabled(true)
                    .accessibilityIdentifier("disabledButton")
                Text("taps: \(taps)")
                    .accessibilityIdentifier("tapCount")
                if signedIn {
                    Text("Welcome back")
                        .accessibilityIdentifier("welcome")
                }
            }
            Section {
                Button("Ask for Photos") { PHPhotoLibrary.requestAuthorization(for: .readWrite) { _ in /* the answer is not used */ } }
                    .accessibilityIdentifier("askPhotos")
            }
            Section("Rows") {
                ForEach(1...40, id: \.self) { row in
                    Text("Row \(row)")
                }
            }
        }
    }
}
