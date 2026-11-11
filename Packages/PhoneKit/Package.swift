// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PhoneKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PhoneCore", targets: ["PhoneCore"]),
        .library(name: "FritzTR064", targets: ["FritzTR064"]),
    ],
    targets: [
        .target(name: "PhoneCore"),
        .target(name: "FritzTR064", dependencies: ["PhoneCore"]),
        .testTarget(name: "PhoneCoreTests", dependencies: ["PhoneCore"]),
        .testTarget(name: "FritzTR064Tests", dependencies: ["FritzTR064", "PhoneCore"],
                    resources: [.copy("Fixtures")]),
    ]
)
