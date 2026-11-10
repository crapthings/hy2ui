#!/bin/bash
# Exercises the local TUN client against unprivileged mock Unix sockets without changing network settings.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/local-tun-tests
xcrun swiftc -parse-as-library -swift-version 5 Shared/*.swift Connection/*.swift \
  App/LocalTunTransport.swift App/LocalTunService.swift Tests/LocalTunServiceSmoke/main.swift \
  -o .build/local-tun-tests/local-tun-service-smoke
.build/local-tun-tests/local-tun-service-smoke
