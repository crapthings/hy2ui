#!/bin/bash
# Exercises the promoted adapter and selected static core using loopback fixtures only.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${HY2_NE_CORE_DEV_MANIFEST:?Select a pinned static packet-core manifest}"
if [ "$#" -ne 1 ]; then echo "Usage: $0 HYSTERIA_EXECUTABLE" >&2; exit 2; fi
python3 Scripts/prepare-ne-core.py Debug "$(uname -m)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/hy2ui-ne-integration.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PY'
from pathlib import Path
import sys
text = Path('Tests/PacketFlowAdapterIntegration/main.swift').read_text()
for old,new in {'ExperimentalPacketFlow':'TunnelPacketFlow','ExperimentalProviderSystem':'ProviderSystem',
                'ExperimentalPacketError':'PacketEngineError','ExperimentalPacketAdapter':'PacketAdapter',
                'ExperimentalProviderCoordinator':'ProviderCoordinator'}.items():
    text = text.replace(old,new)
Path(sys.argv[1]).write_text(text)
PY
library_dir="$PWD/.build/ne-core/$(uname -m)"
python3 "${HY2_RUST_SOURCE:-../hysteria-rust}/crates/hysteria-packet-bridge/tests/swift/run.py" \
  --library-dir "$library_dir" --header "$library_dir/hysteria_packet_bridge.h" --hysteria "$1" \
  --static-library --swift-parse-as-library --network-extension \
  --swift-source NetworkExtension/Engine/PacketFlowContracts.swift \
  --swift-source NetworkExtension/Engine/PacketAdapter.swift \
  --swift-source NetworkExtension/Engine/RustPacketCore.swift \
  --swift-source NetworkExtension/Engine/ProviderContracts.swift \
  --swift-source NetworkExtension/Engine/ProviderCoordinator.swift \
  --swift-source "$test_dir/main.swift"
