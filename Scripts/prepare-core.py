#!/usr/bin/env python3
"""Publish an immutable, explicitly patched copy of the pinned upstream source."""
import fcntl
import hashlib
import io
import json
import os
import pathlib
import shutil
import subprocess
import tarfile
import tempfile
import uuid

# Identifies the only upstream source revision accepted by this adapter.
PINNED_COMMIT = 'f364dab51b3908d5c158309b1eba54445628641a'


def verify_source(source):
    """Reject a mismatched or modified upstream checkout before preparing source."""
    commit = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
    if commit != PINNED_COMMIT:
        raise SystemExit(f'Expected upstream commit {PINNED_COMMIT}, found {commit}')
    if subprocess.check_output(['git', '-C', str(source), 'status', '--porcelain'], text=True).strip():
        raise SystemExit('The pinned upstream checkout must be clean; put adapter changes in Patches/.')


def generation_key(root, patches):
    """Identify prepared source by the pinned revision and every adapter input."""
    digest = hashlib.sha256(PINNED_COMMIT.encode())
    for path in [pathlib.Path(__file__).resolve(), *patches, root / 'Patches/embedded.rs']:
        digest.update(path.name.encode())
        digest.update(path.read_bytes())
    return digest.hexdigest()


def prepare_generation(root, source, destination, patches):
    """Extract a clean archive and apply reviewable patches in an isolated directory."""
    staging = pathlib.Path(tempfile.mkdtemp(prefix='.preparing-', dir=destination.parent))
    try:
        archive = subprocess.check_output(['git', '-C', str(source), 'archive', '--format=tar', PINNED_COMMIT])
        with tarfile.open(fileobj=io.BytesIO(archive)) as stream:
            # The archive comes from the exact asserted upstream commit, never arbitrary input.
            stream.extractall(staging)
        for patch in patches:
            subprocess.run(['git', 'apply', '--check', str(patch)], cwd=staging, check=True)
            subprocess.run(['git', 'apply', str(patch)], cwd=staging, check=True)
        shutil.copyfile(root / 'Patches/embedded.rs', staging / 'crates/hysteria/src/embedded.rs')
        (staging / '.hy2-prepared.json').write_text(json.dumps({'commit': PINNED_COMMIT, 'generation': destination.name}) + '\n')
        staging.rename(destination)
    finally:
        if staging.exists():
            shutil.rmtree(staging)


def publish_generation(build, destination):
    """Atomically switch the stable core symlink without deleting an in-use generation."""
    target = build / 'core'
    temporary = build / ('.core-link-' + uuid.uuid4().hex)
    temporary.symlink_to(destination.relative_to(build), target_is_directory=True)
    try:
        if target.exists() and not target.is_symlink():
            # One-time migration from the previous mutable directory layout.
            target.rename(build / ('.legacy-core-' + uuid.uuid4().hex))
        os.replace(temporary, target)
    finally:
        if temporary.is_symlink():
            temporary.unlink()


def main():
    """Serialize source preparation and publish the requested immutable generation."""
    root = pathlib.Path(__file__).resolve().parent.parent
    source = root / 'Vendor/hysteria-rust'
    build = root / '.build'
    generations = build / 'core-sources'
    generations.mkdir(parents=True, exist_ok=True)
    patches = sorted((root / 'Patches').glob('core-*.patch'))
    if not patches:
        raise SystemExit('No explicit core adapter patches found.')
    with (build / 'core-prepare.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        verify_source(source)
        destination = generations / generation_key(root, patches)
        if not destination.exists():
            prepare_generation(root, source, destination, patches)
        publish_generation(build, destination)
    print(f'Prepared pinned core generation {destination.name[:12]}; Cargo cache remains in Native/target.')


if __name__ == '__main__':
    main()
