#!/bin/bash
# Verifies activity table behavior with fake counters without reading or changing live networking.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/process-activity-tests
xcrun swiftc -parse-as-library -swift-version 5 Shared/*.swift App/ProcessIdentity.swift App/ProcessNetworkModel.swift \
  Tests/ProcessActivitySmoke/main.swift -o .build/process-activity-tests/smoke
.build/process-activity-tests/smoke
