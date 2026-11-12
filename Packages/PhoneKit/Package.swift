// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PhoneKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PhoneCore", targets: ["PhoneCore"]),
        .library(name: "FritzTR064", targets: ["FritzTR064"]),
        .library(name: "PJBridge", targets: ["PJBridge"]),
        .library(name: "SIPEngine", targets: ["SIPEngine"]),
        .library(name: "VPN", targets: ["VPN"]),
    ],
    targets: [
        .target(name: "PhoneCore"),
        .binaryTarget(name: "PJSIP", path: "Frameworks/PJSIP.xcframework"),
        .target(name: "PJBridge", dependencies: ["PJSIP"],
                cxxSettings: [.unsafeFlags(["-std=c++17"]),
                              // same -D the PJSIP library build uses (pulls in the autoconf-generated headers)
                              .define("PJ_AUTOCONF", to: "1")],
                linkerSettings: [.linkedLibrary("c++"),
                                 .linkedFramework("CoreAudio"), .linkedFramework("AudioToolbox"),
                                 .linkedFramework("AudioUnit"), .linkedFramework("AVFoundation"),
                                 .linkedFramework("CoreFoundation"), .linkedFramework("Security"),
                                 .linkedFramework("SystemConfiguration"), .linkedFramework("Network")]),
        .target(name: "SIPEngine", dependencies: ["PhoneCore", "PJBridge"]),
        .target(name: "FritzTR064", dependencies: ["PhoneCore"]),
        .target(name: "VPN", dependencies: ["PhoneCore"],
                linkerSettings: [.linkedFramework("NetworkExtension"), .linkedFramework("SystemExtensions")]),
        .executableTarget(name: "fritzdump", dependencies: ["FritzTR064", "PhoneCore"]),
        .executableTarget(name: "siptool", dependencies: ["SIPEngine", "PhoneCore"]),
        .testTarget(name: "SIPEngineTests", dependencies: ["SIPEngine"]),
        .testTarget(name: "PhoneCoreTests", dependencies: ["PhoneCore", "PJBridge"]),
        .testTarget(name: "VPNTests", dependencies: ["VPN", "PhoneCore"]),
        .testTarget(name: "FritzTR064Tests", dependencies: ["FritzTR064", "PhoneCore"],
                    resources: [.copy("Fixtures")]),
    ]
)
