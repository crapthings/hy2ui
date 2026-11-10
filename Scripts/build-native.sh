#!/bin/bash
# Builds configuration-specific native artifacts while retaining Cargo's cache outside generated sources.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 Scripts/generate-installer-payload.py
export MACOSX_DEPLOYMENT_TARGET=14.0
configuration="${1:-debug}"
architecture="${2:-$(uname -m)}"
case "$configuration" in
  debug) flags=(--profile dev) ;;
  release) flags=(--release) ;;
  *) echo 'Use debug or release' >&2; exit 1 ;;
esac
case "$architecture" in
  arm64) target=aarch64-apple-darwin ;;
  x86_64) target=x86_64-apple-darwin ;;
  *) echo "Unsupported architecture: $architecture" >&2; exit 1 ;;
esac
python3 Scripts/prepare-core.py
cargo build --locked --manifest-path Native/Cargo.toml --target "$target" -p hy2-bridge --lib --bin hy2-client --bin hy2-tun-worker "${flags[@]}"
artifacts=".build/native/$configuration/$architecture"
mkdir -p "$artifacts"
# Avoid touching outputs when Cargo reused the same artifact, preserving downstream incremental builds.
if ! cmp -s "Native/target/$target/$configuration/libhy2_bridge.a" "$artifacts/libhy2_bridge.a"; then
  cp "Native/target/$target/$configuration/libhy2_bridge.a" "$artifacts/libhy2_bridge.a"
fi
if ! cmp -s "Native/target/$target/$configuration/hy2-client" "$artifacts/hysteria"; then
  cp "Native/target/$target/$configuration/hy2-client" "$artifacts/hysteria"
fi

if ! cmp -s "Native/target/$target/$configuration/hy2-tun-worker" "$artifacts/hy2-tun-worker"; then
  cp "Native/target/$target/$configuration/hy2-tun-worker" "$artifacts/hy2-tun-worker"
fi
# Compile the root helper from its narrow shared protocol instead of importing application UI code.
helper_staging="$(mktemp -d "$artifacts/.helper.XXXXXX")"
helper_temporary="$helper_staging/hy2-local-tun-helper"
trap 'rm -f "$helper_temporary"; rmdir "$helper_staging"' EXIT
swift_flags=(-Onone)
if [ "$configuration" = release ]; then swift_flags=(-O); fi
xcrun swiftc -parse-as-library -swift-version 5 -target "$architecture-apple-macos14.0" \
  "${swift_flags[@]}" Shared/LocalTunIPC.swift Shared/CoreDiagnosticParser.swift LocalTunHelper/*.swift -o "$helper_temporary"
chmod 755 "$helper_temporary"
if ! cmp -s "$helper_temporary" "$artifacts/hy2-local-tun-helper"; then
  mv "$helper_temporary" "$artifacts/hy2-local-tun-helper"
fi
chmod 755 "$artifacts/hy2-local-tun-helper" "$artifacts/hy2-tun-worker"
