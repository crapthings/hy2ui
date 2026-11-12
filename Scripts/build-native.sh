#!/bin/bash
# Prepares the official CLI and compiles only the macOS administrator helper.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 Scripts/generate-installer-payload.py
export MACOSX_DEPLOYMENT_TARGET=14.0
configuration="${1:-debug}"
architecture="${2:-$(uname -m)}"
case "$configuration" in
  debug) ;;
  release) ;;
  *) echo 'Use debug or release' >&2; exit 1 ;;
esac
python3 Scripts/prepare-cli.py "$configuration" "$architecture"
artifacts=".build/native/$configuration/$architecture"
# Compile the root helper from its narrow shared protocol instead of importing application UI code.
helper_staging="$(mktemp -d "$artifacts/.helper.XXXXXX")"
helper_temporary="$helper_staging/hy2-local-tun-helper"
trap 'rm -f "$helper_temporary"; rmdir "$helper_staging"' EXIT
swift_flags=(-Onone)
if [ "$configuration" = release ]; then swift_flags=(-O); fi
xcrun swiftc -parse-as-library -swift-version 5 -target "$architecture-apple-macos14.0" \
  "${swift_flags[@]}" Shared/CLITunConfiguration.swift Shared/LocalDNSPolicy.swift Shared/IPNetwork.swift Shared/LocalTunIPC.swift Shared/CoreFlowDiagnostic.swift Shared/CoreDiagnosticParser.swift LocalTunHelper/*.swift -o "$helper_temporary"
chmod 755 "$helper_temporary"
if ! cmp -s "$helper_temporary" "$artifacts/hy2-local-tun-helper"; then
  mv "$helper_temporary" "$artifacts/hy2-local-tun-helper"
fi
chmod 755 "$artifacts/hy2-local-tun-helper" "$artifacts/hy2-tun-worker"
