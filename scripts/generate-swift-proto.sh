#!/usr/bin/env bash
# Regenerates the Swift proto/gRPC stubs the `cli` package needs from
# docs/protocols/agent.proto. Run this after cloning (and again any time
# agent.proto changes) before `swift build` in cli/ — see
# cli/Sources/omnia/Generated/README.md.
#
# Requires: protoc, protoc-gen-swift, protoc-gen-grpc-swift-2
#   brew install protobuf swift-protobuf grpc-swift
# (the brew grpc-swift formula ships gRPC Swift v2's plugin, whose binary
# is named protoc-gen-grpc-swift-2 — the cli package builds against
# grpc-swift-2 / grpc-swift-nio-transport / grpc-swift-protobuf)
#
# Rust's equivalent stubs (guest-agent/) need no such manual step — they're
# generated at build time by guest-agent/build.rs via tonic-build. Swift
# doesn't have an equivalent zero-config SwiftPM build-plugin path that this
# repo has been able to verify without a Swift toolchain (see BUILDING.md),
# so this stays a manual, explicit script rather than an automatic plugin.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_DIR="$REPO_ROOT/cli/Sources/omnia/Generated"

for bin in protoc protoc-gen-swift protoc-gen-grpc-swift-2; do
  command -v "$bin" >/dev/null 2>&1 || {
    echo "Missing $bin — see this script's header comment." >&2
    exit 1
  }
done

mkdir -p "$OUT_DIR"

protoc \
  --proto_path="$REPO_ROOT/docs/protocols" \
  --swift_out="$OUT_DIR" \
  --swift_opt=Visibility=Public \
  --grpc-swift-2_out="$OUT_DIR" \
  --grpc-swift-2_opt=Visibility=Public,Client=true,Server=false \
  "$REPO_ROOT/docs/protocols/agent.proto"

echo "Generated Swift proto/gRPC stubs in $OUT_DIR"
