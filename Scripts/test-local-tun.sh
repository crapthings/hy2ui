#!/bin/bash
# Exercises local helper IPC with ordinary-user socketpairs and never starts privileged networking.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/local-tun-ipc-tests
xcrun swiftc -parse-as-library -swift-version 5 Shared/IPNetwork.swift Shared/LocalTunIPC.swift \
  LocalTunHelper/TrustedInstallation.swift LocalTunHelper/HelperSocket.swift \
  Tests/LocalTunIntegrationSmoke/main.swift -o .build/local-tun-ipc-tests/helper-ipc-smoke
.build/local-tun-ipc-tests/helper-ipc-smoke
