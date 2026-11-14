#!/bin/bash
# Builds an unsigned, capture-disabled NE application for offline review; never activates it.
set -euo pipefail
cd "$(dirname "$0")/.."
architecture="${1:-$(uname -m)}"
case "$architecture" in arm64|x86_64) ;; *) echo 'Unsupported architecture' >&2; exit 1 ;; esac
: "${HY2_NE_CORE_DEV_MANIFEST:?Select a pinned prebuilt packet-core manifest}"
manifest="$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).expanduser().resolve(strict=True))' "$HY2_NE_CORE_DEV_MANIFEST")"
Scripts/bootstrap-tools.sh
python3 Scripts/generate-installer-payload.py
.tools/xcodegen/bin/xcodegen generate
xcodebuild -project Hy2UI.xcodeproj -scheme Hy2UINE -configuration Debug \
  -derivedDataPath .build/ne-xcode "ARCHS=$architecture" ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=NO HY2_NE_ENABLE_CAPTURE=NO "HY2_NE_CORE_DEV_MANIFEST=$manifest" \
  "HY2_CLI_DEV_MANIFEST=${HY2_CLI_DEV_MANIFEST:-}" build
printf '%s\n' 'Offline unsigned NE build complete. Capture is disabled; no extension or VPN was activated.'
