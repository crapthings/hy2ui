#!/bin/bash
# Tests QUIC-latency sampling and worker cleanup using a local mock without changing system networking.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/server-latency-tests
xcrun swiftc -parse-as-library -swift-version 5 Shared/Profile.swift Shared/LocalTunIPC.swift App/CoreProcess.swift App/ServerLatencyProbe.swift Tests/ServerLatencySmoke/main.swift -o .build/server-latency-tests/smoke
.build/server-latency-tests/smoke
