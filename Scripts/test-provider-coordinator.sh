#!/bin/bash
# Tests provider lifecycle ordering and Network Extension API types without applying network settings.
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/hy2ui-provider-test.XXXXXX")"
trap 'rm -f "$test_dir/provider-smoke"; rmdir "$test_dir"' EXIT
xcrun swiftc -swift-version 5 -parse-as-library \
  Experiments/PacketFlowAdapter/PacketFlowContracts.swift \
  Experiments/PacketFlowAdapter/ExperimentalPacketAdapter.swift \
  Experiments/PacketFlowAdapter/ExperimentalEndpointCandidate.swift \
  Experiments/PacketFlowAdapter/NetworkExtensionPacketFlow.swift \
  Experiments/PacketFlowAdapter/ProviderContracts.swift \
  Experiments/PacketFlowAdapter/ExperimentalProviderCoordinator.swift \
  Experiments/PacketFlowAdapter/ExperimentalNetworkExtensionProvider.swift \
  Tests/ProviderCoordinatorSmoke/main.swift -framework NetworkExtension \
  -o "$test_dir/provider-smoke"
"$test_dir/provider-smoke"
