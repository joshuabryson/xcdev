import Foundation

enum Fixture {
    static func string(_ name: String) -> String {
        return try! String(contentsOf: url(name), encoding: .utf8)
    }

    /// A fixture file or folder, such as "ProjectFiles/Phone".
    static func url(_ name: String) -> URL {
        Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")!
    }

    /// The simulator the recorded crash report (`crash-sim.ips`) came from.
    static let crashSimulator = "C268DCFB-3E56-4C43-8947-B25ED3833F7E"
    /// Where that report says its process ran, below the home folder.
    static let crashProcessPath = "Library/Developer/CoreSimulator/Devices/\(crashSimulator)/data/Containers/Bundle/Application/"
        + "C455E44B-F3EF-4268-949F-8C874BD18713/SampleApp.app/SampleApp"

    /// The recorded crash report as the crash of a process in simulator `udid`, or with nil of one that ran on this
    /// Mac itself, from a build folder.
    static func crashReport(in udid: String?) -> String {
        let recorded = string("crash-sim.ips")
        guard let udid else {
            return recorded.replacingOccurrences(of: crashProcessPath, with: "Developer/Mac/.xcdev/DerivedData/Build/Products/Debug/Mac.app/Contents/MacOS/Mac")
        }
        return recorded.replacingOccurrences(of: crashSimulator, with: udid)
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
