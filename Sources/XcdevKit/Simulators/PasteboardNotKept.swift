import Foundation

extension SimctlClient {
    /// What Device Hub's process is called. Xcode 27 shows simulators in it.
    static let deviceHubProcess = "DeviceHub"

    /// The error for text that `simctl pbcopy` took without complaint and the pasteboard does not hold. Device Hub
    /// syncs the Mac's clipboard with every simulator from some tens of seconds after it boots, and a simulator it
    /// syncs with ignores what simctl sends. What the pasteboard holds instead may be the person's own,
    /// so it is not part of the error.
    func textNotKept(by device: String, udid: String) async -> XcdError {
        let pgrep = Invocation("/usr/bin/pgrep", ["-x", Self.deviceHubProcess], timeout: .seconds(10))
        let deviceHubIsOpen = (try? await runner.run(pgrep))?.succeeded == true
        let next = deviceHubIsOpen
            ? "Device Hub is open, and while it is, a simulator shares its pasteboard with the Mac's clipboard and drops text "
                + "that simctl sends. To put text into a field, use `xcd ui type`. `xcrun devicectl device pasteboard copy --device \(udid) "
                + "--file <file>` does set the pasteboard, and it replaces the Mac's clipboard with the same text, so ask the person at the Mac first"
            : "run `xcd doctor`"
        return XcdError(.simulatorFailed, "simctl reported success, but \(device)'s pasteboard does not hold the text", next: next)
    }
}
