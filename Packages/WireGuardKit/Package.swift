// swift-tools-version:5.9
// Vendored WireGuardKit from https://git.zx2c4.com/wireguard-apple (MIT, see COPYING) at commit
// 2fec12a6e1f6e3460b6ee483aa00ad29cddadab1. Changes: this manifest, one `#include <sys/types.h>` in
// WireGuardKitC.h (explicit Clang modules in current Xcode reject its implicit u_int32_t/u_char), and the
// "SIP Phone patch" for split tunnels: `WireGuardAdapter.dnsMatchDomains`, passed to
// PacketTunnelSettingsGenerator, limits the tunnel's DNS servers to those domains (nil = upstream behaviour). Upstream declares tools 5.3 with `.macOS(.v12)`, which current Xcode rejects ("'v12' is unavailable"),
// so the package cannot be resolved remotely. The Go bridge (libwg-go.a) is NOT built by SwiftPM: the
// app's `WireGuardGoBridgemacOS` external-build target runs Sources/WireGuardKitGo/Makefile.
import PackageDescription

let package = Package(
    name: "WireGuardKit",
    platforms: [.macOS(.v12)],
    products: [
        .library(name: "WireGuardKit", targets: ["WireGuardKit"])
    ],
    targets: [
        .target(name: "WireGuardKit", dependencies: ["WireGuardKitGo", "WireGuardKitC"]),
        .target(name: "WireGuardKitC", publicHeadersPath: "."),
        .target(
            name: "WireGuardKitGo",
            exclude: ["goruntime-boottime-over-monotonic.diff", "go.mod", "go.sum", "api-apple.go", "Makefile"],
            publicHeadersPath: ".",
            linkerSettings: [.linkedLibrary("wg-go")]
        ),
    ]
)
