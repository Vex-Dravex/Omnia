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
    // gRPC Swift 2 (the supported major — v1 is maintenance-only and its
    // protoc plugin no longer ships as a brew bottle) requires macOS 15+.
    // Every Apple Silicon Mac can run 15, so this raises the CLI's floor
    // from the repo's original macOS 14 target at effectively zero cost.
    platforms: [.macOS("15.0")],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.0.0"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "2.0.0"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.28.0"),
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
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "OmniaVMDCore", package: "vmd"),
            ],
            path: "Sources/omnia",
            exclude: ["Generated/README.md"]
        )
    ]
)
