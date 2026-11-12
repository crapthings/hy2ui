#!/bin/bash
# Verifies application policy transitions using injected services without touching system networking or credentials.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/policy-tests
python3 Scripts/generate-installer-payload.py
sources=()
for source in App/*.swift; do
  case "$source" in
    App/Hy2UIApp.swift) ;;
    *) sources+=("$source") ;;
  esac
done
xcrun swiftc -parse-as-library -swift-version 5 Shared/*.swift Connection/*.swift "${sources[@]}" \
  .build/generated/HelperInstallerPayload.swift Tests/PolicySmoke/main.swift -o .build/policy-tests/smoke
.build/policy-tests/smoke
