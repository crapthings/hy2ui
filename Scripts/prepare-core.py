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

# Pins the dependency archive independently from Cargo's mutable registry extraction cache.
NETSTACK_VERSION = '0.2.5'
# Rejects any registry archive that differs from the reviewed dependency release.
NETSTACK_SHA256 = 'f5abcddf2ae2d1642c492c1043041548200a176a3b5c3db6e5169ab1ed8d62b8'

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
    for path in [root / 'Patches/netstack-smoltcp-0.2.5.patch', pathlib.Path(__file__).resolve(), *patches, root / 'Patches/embedded.rs', root / 'Patches/desktop-routing.rs', root / 'Patches/desktop-rule-index.rs', root / 'Patches/desktop-flow-index.rs', root / 'Patches/desktop-process-owners.rs', root / 'Patches/desktop-flow-diagnostics.rs', root / 'Patches/desktop-direct-routes.rs', root / 'Patches/desktop-address-policy.rs']:
        digest.update(path.name.encode())
        digest.update(path.read_bytes())
    return digest.hexdigest()


def prepare_netstack(root, staging):
    """Verify a fixed crate archive and apply the client TCP lifecycle adapter outside the registry cache."""
    filename = f'netstack-smoltcp-{NETSTACK_VERSION}.crate'
    cargo_home = pathlib.Path(os.environ.get('CARGO_HOME', pathlib.Path.home() / '.cargo'))
    candidates = list((cargo_home / 'registry/cache').glob(f'*/{filename}'))
    archive = next((p for p in candidates if hashlib.sha256(p.read_bytes()).hexdigest() == NETSTACK_SHA256), None)
    if archive is None:
        downloads = root / '.build/downloads'
        downloads.mkdir(parents=True, exist_ok=True)
        archive = downloads / filename
        if not archive.exists() or hashlib.sha256(archive.read_bytes()).hexdigest() != NETSTACK_SHA256:
            temporary = downloads / (filename + '.' + uuid.uuid4().hex)
            try:
                subprocess.run(['/usr/bin/curl', '--fail', '--location', '--silent', '--show-error', '--max-time', '60',
                    f'https://static.crates.io/crates/netstack-smoltcp/{filename}', '--output', str(temporary)], check=True)
                if hashlib.sha256(temporary.read_bytes()).hexdigest() != NETSTACK_SHA256:
                    raise SystemExit('The pinned netstack archive failed its checksum.')
                os.replace(temporary, archive)
            finally:
                temporary.unlink(missing_ok=True)
    vendor = staging / 'vendor'
    with tarfile.open(archive) as stream:
        for member in stream.getmembers():
            parts = pathlib.PurePosixPath(member.name).parts
            if not parts or parts[0] != f'netstack-smoltcp-{NETSTACK_VERSION}' or '..' in parts or member.issym() or member.islnk():
                raise SystemExit('The pinned netstack archive has an invalid member.')
        stream.extractall(vendor)
    dependency = vendor / 'netstack-smoltcp'
    (vendor / f'netstack-smoltcp-{NETSTACK_VERSION}').rename(dependency)
    patch = root / f'Patches/netstack-smoltcp-{NETSTACK_VERSION}.patch'
    subprocess.run(['git', 'apply', '--check', str(patch)], cwd=dependency, check=True)
    subprocess.run(['git', 'apply', str(patch)], cwd=dependency, check=True)


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
        prepare_netstack(root, staging)
        shutil.copyfile(root / 'Patches/embedded.rs', staging / 'crates/hysteria/src/embedded.rs')
        shutil.copyfile(root / 'Patches/desktop-routing.rs', staging / 'crates/hysteria/src/desktop_routing.rs')
        for adapter in ['desktop-rule-index', 'desktop-flow-index', 'desktop-process-owners', 'desktop-flow-diagnostics', 'desktop-direct-routes', 'desktop-address-policy']:
            shutil.copyfile(root / f'Patches/{adapter}.rs', staging / f'crates/hysteria/src/{adapter.replace("-", "_")}.rs')
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
