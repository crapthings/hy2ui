#!/usr/bin/env python3
"""Verify a development packet-core artifact; never builds Rust or downloads unpinned code."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile


# Copies only verified ABI-v1 inputs selected by an explicit Debug manifest.
def main():
    if len(sys.argv) != 3 or sys.argv[1].lower() != 'debug' or sys.argv[2] not in ('arm64', 'x86_64'):
        raise SystemExit('Network Extension core currently requires Debug and one supported architecture')
    selection = os.environ.get('HY2_NE_CORE_DEV_MANIFEST', '')
    if not selection:
        raise SystemExit('Set HY2_NE_CORE_DEV_MANIFEST to a pinned packet-core manifest from hysteria-rust')
    manifest = Path(selection).expanduser().resolve(strict=True)
    if manifest.stat().st_size > 16384:
        raise SystemExit('Packet-core manifest exceeds size limit')
    metadata = json.loads(manifest.read_text())
    if metadata.get('schema_version') != 1 or metadata.get('abi_version') != 1 or metadata.get('platform') != 'macos' or metadata.get('minimum_macos') != '14.0' or metadata.get('architecture') != sys.argv[2] or not re.fullmatch('[0-9a-f]{40}', str(metadata.get('commit', ''))):
        raise SystemExit('Unsupported packet-core manifest, ABI, provenance or architecture')
    names = ['libhysteria_packet_bridge.a', 'hysteria_packet_bridge.h']
    for name in names:
        path = manifest.parent / name
        expected = metadata.get('artifacts', {}).get(name, {}).get('sha256', '')
        if not re.fullmatch('[0-9a-f]{64}', expected) or hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            raise SystemExit('Packet-core artifact hash mismatch: ' + name)
    subprocess.run(['/usr/bin/lipo', str(manifest.parent / names[0]), '-verify_arch', sys.argv[2]], check=True)
    destination = Path(__file__).resolve().parents[1] / '.build/ne-core' / sys.argv[2]
    destination.mkdir(parents=True, exist_ok=True)
    for name in names:
        with tempfile.NamedTemporaryFile(dir=destination, delete=False) as handle:
            staged = Path(handle.name)
        try:
            shutil.copyfile(manifest.parent / name, staged)
            staged.chmod(0o644)
            os.replace(staged, destination / name)
        finally:
            staged.unlink(missing_ok=True)
    shutil.copyfile(manifest, destination / 'manifest.json')


if __name__ == '__main__':
    main()
