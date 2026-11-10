#!/usr/bin/env python3
"""Probe the pinned userspace TCP stack without creating sockets, interfaces or routes."""
import argparse
import datetime
import hashlib
import json
import pathlib
import re
import shutil
import subprocess


# Copies the isolated probe inputs and records dependency and output evidence under ignored build artifacts.
def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--upstream', action='store_true', help='Compare the unpatched registry version instead of the client adapter.')
    options = parser.parse_args()
    root = pathlib.Path(__file__).resolve().parent.parent
    directory = root / '.build/tun-stack-diagnostics'
    fixture = directory / ('upstream-probe' if options.upstream else 'probe')
    fixture.mkdir(parents=True, exist_ok=True)
    manifest = (root / 'Tests/TunStackProbe/Cargo.toml').read_text()
    shutil.copytree(root / 'Tests/TunStackProbe/src', fixture / 'src', dirs_exist_ok=True)
    lock = (root / 'Native/Cargo.lock').read_bytes()
    package = re.search(r'\[\[package\]\]\s+name = "netstack-smoltcp"\s+version = "([^"]+)"', lock.decode())
    if not package:
        raise SystemExit('The native lockfile does not identify netstack-smoltcp.')
    version = package.group(1)
    manifest = re.sub(r'netstack-smoltcp = "=[^"]+"', f'netstack-smoltcp = "={version}"', manifest)
    if not options.upstream:
        subprocess.run(['python3', str(root / 'Scripts/prepare-core.py')], cwd=root, check=True, capture_output=True)
        manifest += '\n[patch.crates-io]\nnetstack-smoltcp = { path = ' + json.dumps(str(root / '.build/core/vendor/netstack-smoltcp')) + ' }\n'
    (fixture / 'Cargo.toml').write_text(manifest)
    (fixture / 'Cargo.lock').write_bytes(lock)
    result = subprocess.run(['cargo', 'run', '--offline', '--manifest-path', str(fixture / 'Cargo.toml'),
                             '--target-dir', str(root / 'Native/target')], cwd=root, capture_output=True, text=True, timeout=120)
    report = {'timestamp': datetime.datetime.now().astimezone().isoformat(),
              'scope': 'Synthetic packets only. No host sockets, TUN, DNS, proxies or routes changed.',
              'netstack_version': version, 'adapter': not options.upstream, 'native_lock_sha256': hashlib.sha256(lock).hexdigest(),
              'exit': result.returncode, 'stdout': result.stdout, 'stderr': result.stderr}
    path = directory / ('upstream-report.json' if options.upstream else 'report.json')
    path.write_text(json.dumps(report, indent=2) + '\n')
    print(f'Report: {path}')
    print(result.stdout, end='')
    if result.returncode:
        print(result.stderr)
        raise SystemExit(result.returncode)


if __name__ == '__main__':
    main()
