// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SmolVM",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "SmolVM", type: .dynamic, targets: ["SmolVM"])
    ],
    targets: [
        .target(
            name: "SmolVM",
            path: "Sources",
            linkerSettings: [
                .linkedFramework("Virtualization"),
                .linkedFramework("vmnet"),
            ]
        )
    ]
)
