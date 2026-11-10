#!/bin/bash
# Seals the local app with a stable private identity without restricted extension entitlements.
set -euo pipefail
exec python3 "$(dirname "$0")/sign-app.py" "$@"
