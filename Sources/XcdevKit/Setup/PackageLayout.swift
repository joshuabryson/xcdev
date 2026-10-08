import Foundation

/// A package's products and targets from `swift package dump-package`, for the schemes Xcode gives it.
public struct PackageLayout: Sendable, Equatable {
    public enum Style: Sendable, Equatable {
        /// The project is the package (Package.swift at the root).
        case root
        /// An `XCLocalSwiftPackageReference` in a project.
        case packageReference
        /// A package folder in a project's navigator or a workspace.
        case folder
    }

    struct Product: Sendable, Equatable { let name: String; let targets: [String]; let kind: String }
    struct Target: Sendable, Equatable { let name: String; let kind: String; let dependencies: [String] }

    let name: String
    let products: [Product]
    let targets: [Target]

    public static func parse(_ data: Data) throws -> PackageLayout {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let name = json["name"] as? String else {
            throw XcdError(.subprocessFailed, "could not read `swift package dump-package` output",
                           next: "run `swift package dump-package` in the package folder to check Package.swift")
        }
        let products = (json["products"] as? [[String: Any]] ?? []).compactMap { product -> Product? in
            guard let name = product["name"] as? String else { return nil }
            let kind = (product["type"] as? [String: Any])?.keys.first ?? ""
            return Product(name: name, targets: product["targets"] as? [String] ?? [], kind: kind)
        }
        let targets = (json["targets"] as? [[String: Any]] ?? []).compactMap { target -> Target? in
            guard let name = target["name"] as? String else { return nil }
            // Same-package dependencies: {"byName": [name, condition]} or {"target": [name, condition]}.
            let dependencies = (target["dependencies"] as? [[String: Any]] ?? []).compactMap { dependency -> String? in
                ((dependency["byName"] ?? dependency["target"]) as? [Any])?.first as? String
            }
            return Target(name: name, kind: target["type"] as? String ?? "", dependencies: dependencies)
        }
        return PackageLayout(name: name, products: products, targets: targets)
    }

    /// The schemes Xcode lists for the package, as observed with Xcode 27. An executable target that no product
    /// holds counts as a product of its own; a plugin product gets no scheme.
    /// - at the root: a scheme per product plus "<name>-Package", which is the only one for a package without
    ///   products; but a package with exactly one product has a single scheme, named for the package;
    /// - as a package reference: a scheme per declared product;
    /// - as a folder: a scheme per product, and per test target that tests no product's target.
    public func schemes(as style: Style) -> [String] {
        let declared = products.filter { $0.kind != "plugin" }.map(\.name)
        let productTargets = Set(products.flatMap(\.targets))
        let executables = targets.filter { $0.kind == "executable" && !declared.contains($0.name) && !productTargets.contains($0.name) }
            .map(\.name)
        switch style {
        case .root:
            let all = declared + executables
            return all.count == 1 ? [name] : all + [name + "-Package"]
        case .packageReference:
            return declared
        case .folder:
            let tests = targets.filter { $0.kind == "test" && !$0.dependencies.contains(where: productTargets.contains) }.map(\.name)
            return declared + executables + tests
        }
    }
}
