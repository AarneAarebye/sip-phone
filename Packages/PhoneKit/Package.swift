// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PhoneKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PhoneCore", targets: ["PhoneCore"]),
        .library(name: "FritzTR064", targets: ["FritzTR064"]),
        .library(name: "PJBridge", targets: ["PJBridge"]),
    ],
    targets: [
        .target(name: "PhoneCore"),
        .binaryTarget(name: "PJSIP", path: "Frameworks/PJSIP.xcframework"),
        .target(name: "PJBridge", dependencies: ["PJSIP"],
                cxxSettings: [.unsafeFlags(["-std=c++17"]),
                              // PJSIP headers need the autoconf platform defines (both archs are little-endian)
                              .define("PJ_AUTOCONF", to: "1"),
                              .define("PJ_IS_LITTLE_ENDIAN", to: "1"),
                              .define("PJ_IS_BIG_ENDIAN", to: "0")],
                linkerSettings: [.linkedLibrary("c++"),
                                 .linkedFramework("CoreAudio"), .linkedFramework("AudioToolbox"),
                                 .linkedFramework("AudioUnit"), .linkedFramework("AVFoundation"),
                                 .linkedFramework("CoreFoundation"), .linkedFramework("Security"),
                                 .linkedFramework("SystemConfiguration"), .linkedFramework("Network")]),
        .target(name: "FritzTR064", dependencies: ["PhoneCore"]),
        .executableTarget(name: "fritzdump", dependencies: ["FritzTR064", "PhoneCore"]),
        .testTarget(name: "PhoneCoreTests", dependencies: ["PhoneCore", "PJBridge"]),
        .testTarget(name: "FritzTR064Tests", dependencies: ["FritzTR064", "PhoneCore"],
                    resources: [.copy("Fixtures")]),
    ]
)
