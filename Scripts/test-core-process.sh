#!/bin/bash
# Runs local mock-worker checks without modifying network settings or opening proxy listeners.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/process-tests
shared_sources=()
while IFS= read -r -d '' source; do shared_sources+=("$source"); done < <(find Shared -maxdepth 1 -type f -name '*.swift' ! -name '._*' -print0)
xcrun swiftc -parse-as-library -swift-version 5 "${shared_sources[@]}" App/CoreProcess.swift App/CoreCapabilityProbe.swift \
  Tests/CoreProcessSmoke/main.swift -o .build/process-tests/core-process-smoke
.build/process-tests/core-process-smoke
