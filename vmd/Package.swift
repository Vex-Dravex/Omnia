// swift-tools-version:5.10
//
// NOTE ON BUILD STATUS: this package depends on Virtualization.framework and
// XPC, both Apple-private-SDK APIs unavailable outside macOS + Xcode. It has
// been written to the interfaces documented in docs/01-architecture.md and
// docs/02-linux-runtime.md but has NOT been compiled — the environment that
// wrote this has no Swift toolchain or macOS SDK at all (see the M1 handoff
// notes in this repo's top-level BUILDING.md). Treat this as a careful first
// draft: the first thing to do on a real Mac is `swift build` and fix
// whatever the compiler finds, starting with `OmniaVMDCore`.
import PackageDescription

let package = Package(
    name: "vmd",
    platforms: [.macOS(.v14)],
    products: [
        // Consumed by the `cli` package (local path dependency) so it can
        // share VMDXPCProtocol/VMDXPCServiceName without redeclaring them —
        // see cli/Package.swift.
        .library(name: "OmniaVMDCore", targets: ["OmniaVMDCore"]),
    ],
    targets: [
        // Pure guest-lifecycle logic (docs/06-lifecycle-memory.md) plus the
        // VMDXPCProtocol contract shared with the CLI. GuestState.swift has
        // no Apple-only imports and is unit-testable without a real VM (see
        // OmniaVMDCoreTests); VMDXPCProtocol.swift uses @objc/Foundation for
        // XPC interop and is macOS-only, but declaring the protocol alone
        // doesn't pull in NSXPCConnection itself.
        .target(
            name: "OmniaVMDCore",
            dependencies: []
        ),
        .executableTarget(
            name: "vmd",
            dependencies: ["OmniaVMDCore"]
        ),
        .testTarget(
            name: "OmniaVMDCoreTests",
            dependencies: ["OmniaVMDCore"]
        ),
    ]
)
