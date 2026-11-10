#!/bin/bash
# Verifies traffic accounting in temporary files without reading profiles, credentials or live network state.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/dashboard-tests
xcrun swiftc -parse-as-library -swift-version 5 Shared/*.swift Connection/ConnectionServices.swift App/DashboardModel.swift Tests/DashboardSmoke/main.swift -o .build/dashboard-tests/smoke
.build/dashboard-tests/smoke
