import Foundation

/// This worktree's own copy of a Mac app under `isolation: suffix`: `.xcdev/mac/<App>.app`, with the
/// suffixed bundle id, no provisioning profile, and an ad-hoc signature that keeps the `com.apple.security.*`
/// entitlements, so macOS gives it its own container and preferences.
public struct MacIsolatedCopy: Sendable {
    public let runner: any ProcessRunning
    public let reader: any MacBundleReading

    public init(runner: any ProcessRunning, reader: any MacBundleReading = SystemBundleReader()) {
        self.runner = runner
        self.reader = reader
    }

    /// The copy's executable is missing, or older than the newer of the source's executable and the source's bundle
    /// folder: Xcode's last build step touches the folder, so a rebuild that changed only resources shows there. Equal
    /// dates are fresh: `ditto` keeps the source's dates (measured 2026-10-21).
    public static func isStale(source: AppProduct, copy: AppProduct) -> Bool {
        guard let copied = Disk.modificationDate(copy.executablePath) else { return true }
        let built = [source.executablePath, source.path].compactMap(Disk.modificationDate).max()
        return built.map { copied < $0 } ?? false
    }

    /// Makes or refreshes `copy` from `source` when stale; returns true when it (re)made the copy. A refused source
    /// leaves nothing behind. The new copy is built beside the old one at `<copy>.partial` (ditto, identifier, profile,
    /// signature) and only a signed one replaces `copy`, so an interrupt or a failure never leaves a copy that looks fresh.
    public func refresh(source: AppProduct, copy: AppProduct, device: String) async throws -> Bool {
        guard Self.isStale(source: source, copy: copy) else { return false }
        let facts = try MacBundle.facts(of: source.path, reader: reader)
        try MacIsolationRefusal.check(facts, device: device)
        let partial = copy.path + ".partial"
        do {
            try await copyBundle(from: source.path, to: partial)
            try Self.rewriteIdentifier(at: partial + "/Contents/Info.plist", to: copy.bundleId)
            Disk.remove(partial + "/Contents/embedded.provisionprofile")
            let next = "check the build with `codesign --verify --deep --strict --verbose=2 \(Shell.quote(source.path))`, or set devices.\(device).isolation: shared in .xcdev.yml"
            try await sign(copy, at: partial, entitlements: facts.signing?.entitlements, next: next)
            Disk.remove(copy.path)
            try Disk.move(partial, to: copy.path)
        } catch {
            Disk.remove(partial)
            throw error
        }
        return true
    }

    func copyBundle(from source: String, to copy: String) async throws {
        let folder = (copy as NSString).deletingLastPathComponent
        Disk.remove(copy)
        try Disk.makeFolder(folder)
        try await runner.runChecked(Invocation("/usr/bin/ditto", [source, copy]), message: "ditto could not copy \(source) to \(copy)",
                                    next: "check that \(Shell.quote(folder)) is writable and the disk has room; isolation: shared needs no copy")
    }

    /// Sets `CFBundleIdentifier` and writes the plist back in the format it was read in: Xcode writes binary.
    static func rewriteIdentifier(at plistPath: String, to bundleId: String) throws {
        let url = URL(fileURLWithPath: plistPath)
        var format = PropertyListSerialization.PropertyListFormat.xml
        let read = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), options: [], format: &format)
        guard var plist = read as? [String: Any] else {
            throw XcdError(.internalError, "the Info.plist at \(plistPath) is not a dictionary", next: "build the app again, or use isolation: shared")
        }
        plist["CFBundleIdentifier"] = bundleId
        try PropertyListSerialization.data(fromPropertyList: plist, format: format, options: 0).write(to: url, options: .atomic)
    }

    /// Re-signs ad hoc, with the designated requirement pinned to the copy's identifier: a rebuilt copy has a new
    /// cdhash, and the requirement its container stored must still hold. The kept entitlements go in a file beside the
    /// copy, removed whatever happens. The copy runs without the hardened runtime (no `--preserve-metadata=flags`): a
    /// copy that kept the flag cannot load its own embedded framework (different Team IDs).
    func sign(_ copy: AppProduct, at path: String, entitlements: Data?, next: String) async throws {
        let file = (copy.path as NSString).deletingPathExtension + ".entitlements.plist"
        defer { Disk.remove(file) }
        var arguments = ["--force", "--sign", "-"]
        if let entitlements {
            try MacEntitlements.kept(entitlements).write(to: URL(fileURLWithPath: file), options: .atomic)
            arguments += ["--entitlements", file]
        }
        arguments += ["--requirements", "=designated => identifier \"\(copy.bundleId)\"", path]
        let invocation = Invocation("/usr/bin/codesign", arguments)
        let output = try await runner.run(invocation)
        guard output.succeeded else {
            let reason = Self.reason(from: output.stderrString, exit: output.exitCode)
            throw XcdError.subprocess(invocation, output, message: "codesign could not re-sign \(copy.path): \(reason)", next: next)
        }
    }

    /// The failure on one line: stderr's lines trimmed, empty ones and the `replacing existing signature` notice dropped.
    static func reason(from stderr: String, exit: Int32) -> String {
        let lines = stderr.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasSuffix(": replacing existing signature") }
        return lines.isEmpty ? "exit \(exit)" : lines.joined(separator: "; ")
    }
}
