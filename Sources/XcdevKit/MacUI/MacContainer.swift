import Foundation

/// `xcd sim container` on a Mac: a sandboxed app's data is in its container
/// whatever `HOME` says; an unsandboxed one's is spread under ~/Library, which the error names instead, with the folder
/// the app would use. An unsigned build has no entitlements to read, so xcd cannot tell which of the two it is and says so.
public enum MacContainer {
    /// `bundleId` is the device's product's (the copy's under `isolation: suffix`); the entitlements are read from
    /// `built`, the build the copy keeps them from.
    public static func path(bundleId: String, built: AppProduct, reader: any MacBundleReading,
                            home: String) throws -> String {
        guard let signing = try reader.signingInfo(of: built.path) else {
            throw XcdError(.usage, "\(bundleId) is not signed, so xcd cannot read its entitlements and does not know whether it has a container",
                           next: "sign the build (Xcode's Sign to Run Locally is enough), or look under ~/Library/Containers/\(bundleId)/Data yourself")
        }
        guard MacEntitlements.isSandboxed(signing.entitlements) else {
            throw XcdError(.usage, "\(bundleId) is not sandboxed, so it has no container: its preferences are the \(bundleId) domain "
                               + "(`defaults read \(bundleId)`) and its files are under ~/Library/Application Support/\(built.executableName) "
                               + "and ~/Library/Caches/\(bundleId)",
                           next: "look there, or add the App Sandbox capability to the app")
        }
        return home + "/Library/Containers/" + bundleId + "/Data"
    }
}
