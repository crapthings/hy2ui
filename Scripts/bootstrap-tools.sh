#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -x .tools/xcodegen/bin/xcodegen ]; then exit 0; fi
mkdir -p .tools
archive="$(mktemp -t hy2ui-xcodegen)"
trap 'rm -f "$archive"' EXIT
curl -fsSL https://github.com/yonaskolb/XcodeGen/releases/download/2.46.0/xcodegen.zip -o "$archive"
checksum="$(shasum -a 256 "$archive" | cut -d ' ' -f 1)"
if [ "$checksum" != 4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806 ]; then
  echo 'XcodeGen archive checksum mismatch' >&2
  exit 1
fi
unzip -q "$archive" -d .tools
