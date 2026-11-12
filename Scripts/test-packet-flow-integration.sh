#!/bin/bash
# Links a selected development Rust library and tests the Swift adapter using loopback fixtures.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "$#" -ne 2 ]; then
  echo "Usage: $0 BRIDGE_LIBRARY_DIR HYSTERIA_EXECUTABLE" >&2
  exit 2
fi
library_dir="$(cd "$1" && pwd -P)"
cli="$2"
python3 - "$library_dir" <<'PY'
import hashlib
import json
import pathlib
import platform
import subprocess
import sys

root = pathlib.Path(sys.argv[1])
manifest = json.loads((root / 'manifest.json').read_text())
if manifest.get('schema_version') != 1 or manifest.get('abi_version') != 1:
    raise SystemExit('Unsupported bridge manifest or ABI')
arch = platform.machine()
if arch not in ('arm64', 'x86_64') or manifest.get('platform') != 'macos' or manifest.get('architecture') != arch:
    raise SystemExit(f'This test needs a macOS {arch} bridge artifact')
for name in ('libhysteria_packet_bridge.dylib', 'hysteria_packet_bridge.h'):
    digest = hashlib.sha256((root / name).read_bytes()).hexdigest()
    if digest != manifest.get('artifacts', {}).get(name, {}).get('sha256'):
        raise SystemExit(f'Bridge artifact hash mismatch: {name}')
subprocess.run(['/usr/bin/lipo', str(root / 'libhysteria_packet_bridge.dylib'), '-verify_arch', arch], check=True)
PY
python3 ../hysteria-rust/crates/hysteria-packet-bridge/tests/swift/run.py \
  --library-dir "$library_dir" --header "$library_dir/hysteria_packet_bridge.h" --hysteria "$cli" \
  --swift-parse-as-library --network-extension \
  --swift-source Experiments/PacketFlowAdapter/PacketFlowContracts.swift \
  --swift-source Experiments/PacketFlowAdapter/ExperimentalPacketAdapter.swift \
  --swift-source Experiments/PacketFlowAdapter/NetworkExtensionPacketFlow.swift \
  --swift-source Experiments/PacketFlowAdapter/RustPacketCore.swift \
  --swift-source Experiments/PacketFlowAdapter/ProviderContracts.swift \
  --swift-source Experiments/PacketFlowAdapter/ExperimentalProviderCoordinator.swift \
  --swift-source Experiments/PacketFlowAdapter/ExperimentalNetworkExtensionProvider.swift \
  --swift-source Tests/PacketFlowAdapterIntegration/main.swift
