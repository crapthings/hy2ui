#!/bin/bash
# Verifies server-list migration and selection in temporary storage without system or Keychain changes.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/server-library-tests
xcrun swiftc -parse-as-library -swift-version 5 Shared/*.swift App/ProfileStore.swift \
  Tests/ServerLibrarySmoke/main.swift -o .build/server-library-tests/server-library-smoke
.build/server-library-tests/server-library-smoke
