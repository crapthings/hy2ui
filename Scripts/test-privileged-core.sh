#!/bin/bash
# Tests helper command validation using ordinary-user mock executables only.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/privileged-core-tests
xcrun swiftc -parse-as-library -swift-version 5 Shared/IPNetwork.swift Shared/LocalTunIPC.swift \
  Shared/CLITunConfiguration.swift Shared/CoreDiagnosticParser.swift Shared/CoreFlowDiagnostic.swift \
  LocalTunHelper/TrustedInstallation.swift LocalTunHelper/HelperSocket.swift LocalTunHelper/PrivilegedWorker.swift \
  LocalTunHelper/PrivilegedCoreCommand.swift \
  Tests/PrivilegedCoreSmoke/main.swift -o .build/privileged-core-tests/smoke
.build/privileged-core-tests/smoke
