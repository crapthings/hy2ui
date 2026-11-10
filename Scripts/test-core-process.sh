#!/bin/bash
# Runs local mock-worker checks without modifying network settings or opening proxy listeners.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/process-tests
xcrun swiftc -parse-as-library -swift-version 5 Shared/Profile.swift Shared/LocalTunIPC.swift App/CoreProcess.swift \
  Tests/CoreProcessSmoke/main.swift -o .build/process-tests/core-process-smoke
.build/process-tests/core-process-smoke
