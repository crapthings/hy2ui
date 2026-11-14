#!/bin/bash
# Exercises PAC requests over loopback without modifying proxies, DNS, routes or helpers.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/routing-tests
shared_sources=()
while IFS= read -r -d '' source; do shared_sources+=("$source"); done < <(find Shared -maxdepth 1 -type f -name '*.swift' ! -name '._*' -print0)
xcrun swiftc -parse-as-library -swift-version 5 "${shared_sources[@]}" App/PACServer.swift App/RoutingPreferences.swift App/ProcessIdentity.swift \
  Tests/RoutingSmoke/main.swift -o .build/routing-tests/smoke
.build/routing-tests/smoke
