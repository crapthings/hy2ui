#!/bin/bash
# Checks GUI-generated pool JSON with the real core without starting any client listeners.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${1:?Usage: test-client-pool.sh CORE_EXECUTABLE}"
core="$1"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/hy2ui-pool-contract.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
"$core" capabilities --output json > "$test_dir/capabilities.json"
shared_sources=()
while IFS= read -r -d '' source; do shared_sources+=("$source"); done < <(find Shared -maxdepth 1 -type f -name '*.swift' ! -name '._*' -print0)
xcrun swiftc -parse-as-library -swift-version 5 "${shared_sources[@]}" Tests/PoolConfigurationSmoke/main.swift -o "$test_dir/generate"
"$test_dir/generate" "$test_dir" "$test_dir/capabilities.json"
for kind in url-test fallback load-balance; do
  "$core" --config "$test_dir/$kind.json" check client --output json > "$test_dir/result.json"
  python3 - "$test_dir/result.json" <<'PY'
import json,sys
report=json.load(open(sys.argv[1]))
assert report['schema_version']==1 and report['valid'] is True
PY
done
printf '%s\n' 'Three GUI automatic-group configurations accepted by the real core, offline.'
