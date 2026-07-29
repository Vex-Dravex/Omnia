# Generated proto sources go here

Run `scripts/generate-swift-proto.sh` (from the repo root) on a machine
with `protoc`, `protoc-gen-swift`, and `protoc-gen-grpc-swift-2`
installed (`brew install protobuf swift-protobuf grpc-swift` — the brew
formula ships gRPC Swift v2's plugin). It regenerates `agent.pb.swift`
and `agent.grpc.swift` in this directory from `docs/protocols/agent.proto`
— the single source of truth for the message and service shapes (see that
file's own header comment).

These files are intentionally **not** committed — regenerate them locally
after cloning, the same way `guest-agent`'s Rust proto stubs are generated
at build time by `guest-agent/build.rs` rather than checked in.
`ShellSession.swift` imports the types this step produces
(`Omnia_Agent_V1_*`); the cli package will not compile until you've run
the script once.
