#!/bin/bash
# Verifies unified rule editing with in-memory inputs when compilation is explicitly requested.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/rule-list-tests
xcrun swiftc -parse-as-library -swift-version 5 Shared/*.swift App/RuleListEntry.swift \
  Tests/RuleListSmoke/main.swift -o .build/rule-list-tests/smoke
.build/rule-list-tests/smoke
