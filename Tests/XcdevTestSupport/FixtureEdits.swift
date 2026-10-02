import Foundation

/// Edits to the hand-written Xcode projects in Tests/XcdevKitTests/Fixtures/ProjectFiles, shared by the unit tests
/// and the parity tests that run real xcodebuild on the same setups.
public enum FixtureEdit {
    /// Makes the target with ID `dependent` depend on the target with ID `target` in the same project, as Xcode
    /// records it: a PBXTargetDependency and its PBXContainerItemProxy (IDs `ids`), and a `dependencies` list.
    public static func addDependency(pbxproj: String, dependent: String, on target: String, targetName: String,
                                     project: String, ids: (dependency: String, proxy: String)) throws {
        var text = try String(contentsOfFile: pbxproj, encoding: .utf8)
        guard let start = text.range(of: "\n\t\t\(dependent) "),
              let name = text.range(of: "\t\t\tname = ", range: start.upperBound..<text.endIndex) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        text.insert(contentsOf: "\t\t\tdependencies = (\(ids.dependency));\n", at: name.lowerBound)
        guard let objects = text.range(of: "\tobjects = {\n") else { throw CocoaError(.fileReadCorruptFile) }
        text.insert(contentsOf: """
            \t\t\(ids.proxy) = {isa = PBXContainerItemProxy; containerPortal = \(project); proxyType = 1; remoteGlobalIDString = \(target); remoteInfo = "\(targetName)"; };
            \t\t\(ids.dependency) = {isa = PBXTargetDependency; target = \(target); targetProxy = \(ids.proxy); };

            """, at: objects.upperBound)
        try text.write(toFile: pbxproj, atomically: true, encoding: .utf8)
    }

    /// Removes a scheme's Testables, so it tests nothing.
    public static func removeTestables(scheme: String) throws {
        let text = try String(contentsOfFile: scheme, encoding: .utf8)
        guard let open = text.range(of: "<Testables>"), let close = text.range(of: "</Testables>") else { return }
        try text.replacingCharacters(in: open.upperBound..<close.lowerBound, with: "\n").write(toFile: scheme, atomically: true, encoding: .utf8)
    }
}
