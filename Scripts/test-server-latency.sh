#!/bin/bash
# Tests TCP measurement against a loopback listener without proxy, route or service changes.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/server-latency-tests
xcrun swiftc -parse-as-library -swift-version 5 App/ServerLatencyProbe.swift Tests/ServerLatencySmoke/main.swift -o .build/server-latency-tests/smoke
.build/server-latency-tests/smoke
