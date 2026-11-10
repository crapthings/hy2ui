#!/bin/bash
# Generates the Xcode project and lets its dependency graph build the native engine exactly once.
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-debug}"
architecture="${2:-$(uname -m)}"
case "$configuration" in
  debug) xcode_configuration=Debug ;;
  release) xcode_configuration=Release ;;
  *) echo 'Use debug or release' >&2; exit 1 ;;
esac
Scripts/bootstrap-tools.sh
python3 Scripts/generate-installer-payload.py
.tools/xcodegen/bin/xcodegen generate
signing=(CODE_SIGNING_ALLOWED=NO)
if [ "${HY2_SIGN:-0}" = 1 ]; then signing=(CODE_SIGNING_ALLOWED=YES); fi
xcodebuild -project Hy2UI.xcodeproj -scheme Hy2UI -configuration "$xcode_configuration" \
  -derivedDataPath .build/xcode "ARCHS=$architecture" ONLY_ACTIVE_ARCH=YES "${signing[@]}" build
if [ "${HY2_SIGN:-0}" != 1 ]; then
  Scripts/sign-local-app.sh ".build/xcode/Build/Products/$xcode_configuration/Hy2UI.app"
fi
