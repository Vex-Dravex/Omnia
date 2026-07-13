// swift-tools-version:5.10
//
// See BUILDING.md and vmd/Package.swift's header — no Swift toolchain was
// available while writing this, so nothing here has been through `swift
// build`. The riskiest unverified piece is ShellSession.swift's grpc-swift
// client wiring (see that file's header comment) — everything else (the
// ArgumentParser command structure, the XPC connection to vmd) is ordinary
// Foundation code with a much smaller chance of needing changes.
import PackageDescription

let package = Package(
    name: "omnia",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/grpc/grpc-swift.git", from: "1.21.0"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.26.0"),
        // Local path dependency so the CLI shares VMDXPCProtocol /
        // VMDXPCServiceName with vmd instead of redeclaring them — see
        // vmd/Package.swift's `products` entry.
        .package(path: "../vmd"),
    ],
    targets: [
        .executableTarget(
            name: "omnia",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "GRPC", package: "grpc-swift"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "OmniaVMDCore", package: "vmd"),
            ],
            path: "Sources/omnia",
            exclude: ["Generated/README.md"]
        )
    ]
)
