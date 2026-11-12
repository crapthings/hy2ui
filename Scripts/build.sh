#!/bin/bash
# Builds the macOS UI with a verified prebuilt upstream CLI and the Swift administrator helper.
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-debug}"
architecture="${2:-$(uname -m)}"
case "$configuration" in
  debug) xcode_configuration=Debug ;;
  release) xcode_configuration=Release ;;
  *) echo 'Use debug or release' >&2; exit 1 ;;
esac
# Pass the selected local manifest explicitly through Xcode's build settings.
core_settings=("HY2_CLI_DEV_MANIFEST=")
if [ -n "${HY2_CLI_DEV_MANIFEST:-}" ]; then
  if [ "$configuration" != debug ]; then echo 'Development CLI requires a debug build.' >&2; exit 1; fi
  core_manifest="$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).expanduser().resolve(strict=True))' "$HY2_CLI_DEV_MANIFEST")"
  core_settings=("HY2_CLI_DEV_MANIFEST=$core_manifest")
fi
Scripts/bootstrap-tools.sh
python3 Scripts/generate-installer-payload.py
.tools/xcodegen/bin/xcodegen generate
signing=(CODE_SIGNING_ALLOWED=NO)
if [ "${HY2_SIGN:-0}" = 1 ]; then signing=(CODE_SIGNING_ALLOWED=YES); fi
xcodebuild -project Hy2UI.xcodeproj -scheme Hy2UI -configuration "$xcode_configuration" \
  -derivedDataPath .build/xcode "ARCHS=$architecture" ONLY_ACTIVE_ARCH=YES "${signing[@]}" "${core_settings[@]}" build
if [ "${HY2_SIGN:-0}" != 1 ]; then
  Scripts/sign-local-app.sh ".build/xcode/Build/Products/$xcode_configuration/Hy2UI.app"
fi
