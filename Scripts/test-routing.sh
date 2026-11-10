#!/bin/bash
# Exercises PAC requests over loopback without modifying proxies, DNS, routes or helpers.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/routing-tests
xcrun swiftc -parse-as-library -swift-version 5 Shared/*.swift App/PACServer.swift App/RoutingPreferences.swift App/ProcessIdentity.swift \
  Tests/RoutingSmoke/main.swift -o .build/routing-tests/smoke
.build/routing-tests/smoke
