// swift-tools-version: 6.0
// xtool SwiftPM build for GostWG (app + packet-tunnel extension).
// The Go engine (libwg-go.a) is built first by ../scripts/build-go-framework.sh
// into ../framework/ and linked into the tunnel extension.
import PackageDescription

let frameworkInclude = "framework/include"
let frameworkLib = "framework"

let package = Package(
    name: "GostWG",
    platforms: [.iOS(.v16)],
    products: [
        .executable(name: "GostWG", targets: ["GostWG"]),
        .library(name: "GostWGTunnel", targets: ["GostWGTunnel"]),
    ],
    targets: [
        .target(
            name: "WireGuardKitC",
            path: "WireGuardKit/WireGuardKitC",
            publicHeadersPath: "."
        ),
        .target(
            name: "GostWGTunnel",
            dependencies: ["WireGuardKitC"],
            path: "TunnelAll",
            swiftSettings: [
                .unsafeFlags(["-I", frameworkInclude])
            ],
            linkerSettings: [
                .unsafeFlags(["-L", frameworkLib]),
                .linkedLibrary("wg-go"),
                .linkedLibrary("resolv"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("NetworkExtension"),
            ],
        ),
        .executableTarget(
            name: "GostWG",
            path: "GostWG"
        ),
    ]
)
