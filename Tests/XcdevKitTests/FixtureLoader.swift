import Foundation

enum Fixture {
    static func string(_ name: String) -> String {
        return try! String(contentsOf: url(name), encoding: .utf8)
    }

    /// A fixture file or folder, such as "ProjectFiles/Phone".
    static func url(_ name: String) -> URL {
        Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")!
    }

    /// Copies a fixture folder's contents into `destination`, creating it.
    static func copy(_ name: String, to destination: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: destination, withIntermediateDirectories: true)
        let source = url(name).path
        for entry in try fm.contentsOfDirectory(atPath: source) {
            try fm.copyItem(atPath: source + "/" + entry, toPath: destination + "/" + entry)
        }
    }
}
