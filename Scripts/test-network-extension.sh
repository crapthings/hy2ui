#!/bin/bash
# Exercises promoted packet/lifecycle adapters with fakes and builds NE settings as values only.
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/hy2ui-ne-tests.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir" <<'PY'
from pathlib import Path
import sys
mapping = {'ExperimentalEndpointCandidate':'PacketTunnelEndpoint','ExperimentalEndpointError':'PacketTunnelEndpointError','ExperimentalPacketAdapter':'PacketAdapter','ExperimentalPacketAdmission':'PacketAdmission',
'ExperimentalPacketFlow':'TunnelPacketFlow','ExperimentalCoreStatus':'PacketCoreStatus',
'ExperimentalPacketCore':'PacketCore','ExperimentalPacketError':'PacketEngineError',
'ExperimentalProviderCoordinator':'ProviderCoordinator','ExperimentalProviderEngine':'ProviderEngine',
'ExperimentalProviderSystem':'ProviderSystem','ExperimentalProviderError':'ProviderError'}
for name, source in [('adapter','Tests/PacketFlowAdapterSmoke/main.swift'), ('provider','Tests/ProviderCoordinatorSmoke/main.swift')]:
    text = Path(source).read_text()
    for old,new in mapping.items(): text = text.replace(old,new)
    (Path(sys.argv[1])/(name+'.swift')).write_text(text)
PY
for name in adapter provider; do
  xcrun swiftc -swift-version 5 -parse-as-library \
    Shared/PacketTunnelEndpoint.swift NetworkExtension/Engine/PacketFlowContracts.swift NetworkExtension/Engine/PacketAdapter.swift \
    NetworkExtension/Engine/ProviderContracts.swift NetworkExtension/Engine/ProviderCoordinator.swift \
    "$test_dir/$name.swift" -o "$test_dir/$name"
  "$test_dir/$name"
done
shared_sources=()
while IFS= read -r -d '' source; do shared_sources+=("$source"); done < <(find Shared -maxdepth 1 -type f -name '*.swift' ! -name '._*' -print0)
xcrun swiftc -swift-version 5 -parse-as-library "${shared_sources[@]}" \
  NetworkExtension/PacketTunnelSettings.swift Tests/NetworkExtensionSmoke/main.swift \
  -framework NetworkExtension -o "$test_dir/settings"
"$test_dir/settings"
