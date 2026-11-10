#!/bin/bash
# Tests administrator-operation planning and mock UI state without requesting privileges or changing services.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 Scripts/generate-installer-payload.py
mkdir -p .build/helper-installer-tests
xcrun swiftc -parse-as-library -swift-version 5 Shared/HelperInstallation.swift Shared/IPNetwork.swift Shared/LocalTunIPC.swift \
  .build/generated/HelperInstallerPayload.swift App/HelperInstallationProbe.swift \
  App/HelperInstallerAuthorization.swift App/HelperInstallationManager.swift Tests/HelperInstallerSmoke/main.swift \
  -o .build/helper-installer-tests/helper-installer-smoke
.build/helper-installer-tests/helper-installer-smoke
# Compiling AppleScript verifies escaping and syntax without executing the authorization request.
/usr/bin/osacompile -l AppleScript -o .build/helper-installer-tests/authorization.scpt \
  .build/helper-installer-tests/authorization.applescript
