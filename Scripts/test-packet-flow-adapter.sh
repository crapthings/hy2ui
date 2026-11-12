#!/bin/bash
# Tests the isolated packet-flow adapter with fake endpoints and no network changes.
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/hy2ui-packet-adapter.XXXXXX")"
trap 'rm -f "$test_dir/adapter-smoke"; rmdir "$test_dir"' EXIT
xcrun swiftc -swift-version 5 -parse-as-library \
  Experiments/PacketFlowAdapter/PacketFlowContracts.swift \
  Experiments/PacketFlowAdapter/ExperimentalPacketAdapter.swift \
  Experiments/PacketFlowAdapter/NetworkExtensionPacketFlow.swift \
  Tests/PacketFlowAdapterSmoke/main.swift -framework NetworkExtension \
  -o "$test_dir/adapter-smoke"
"$test_dir/adapter-smoke"
