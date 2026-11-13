#!/usr/bin/env python3
"""Fetch the pinned upstream CLI without compiling or modifying its source."""
import hashlib
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

# Pins release artifacts independently of the remotely served checksum files.
RELEASE = "v0.1.0-rc.7"
# Maps supported Xcode architectures to immutable upstream asset names and SHA-256 digests.
ARTIFACTS = {
    "arm64": ("hysteria-rust-macos-arm64", "be88ddaf8e6e310b2d704761149b2616f0885c801544f9c8153f56527a48d63d"),
    "x86_64": ("hysteria-rust-macos-x64", "599681fd94a8b8b4a93c7b6a60ab46842e76d9a7ac07030851ce39d13d71fd61"),
}


# Verifies an existing artifact before allowing it into a build.
def verified(path, digest):
    return path.is_file() and hashlib.sha256(path.read_bytes()).hexdigest() == digest


# Resolves an explicitly selected debug-only core artifact with fixed commit and digest.
def development_artifact(configuration, architecture, manifest_path):
    if configuration != "debug":
        raise SystemExit("Development CLI artifacts are allowed only in debug builds")
    manifest = pathlib.Path(manifest_path).expanduser().resolve(strict=True)
    if manifest.stat().st_size > 16_384:
        raise SystemExit("Development CLI manifest is too large")
    try:
        metadata = json.loads(manifest.read_text(encoding="utf-8"))
        if metadata["schema_version"] != 1 or not re.fullmatch(r"[0-9a-f]{40}", metadata["commit"]):
            raise ValueError("unsupported schema or commit")
        artifact = metadata["artifacts"][architecture]
        digest = artifact["sha256"]
        if not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise ValueError("invalid SHA-256")
        source = pathlib.Path(artifact["path"])
        if not source.is_absolute():
            source = manifest.parent / source
        source = source.resolve(strict=True)
    except (KeyError, TypeError, ValueError, OSError) as error:
        raise SystemExit(f"Invalid development CLI manifest: {error}") from error
    if not verified(source, digest):
        raise SystemExit("Development CLI SHA-256 mismatch; refusing artifact")
    if not os.access(source, os.X_OK):
        raise SystemExit("Development CLI artifact is not executable")
    subprocess.run(["/usr/bin/lipo", str(source), "-verify_arch", architecture], check=True)
    return source, digest, f"development {metadata['commit']}"


# Downloads a release into private staging and caches only a verified executable.
def release_artifact(root, architecture):
    name, digest = ARTIFACTS[architecture]
    cache = root / ".build" / "cli" / RELEASE / name
    cache.parent.mkdir(parents=True, exist_ok=True)
    if not verified(cache, digest):
        with tempfile.TemporaryDirectory(dir=cache.parent) as staging:
            download = pathlib.Path(staging) / name
            subprocess.run(["/usr/bin/curl", "--fail", "--location", "--silent", "--show-error",
                            "--proto", "=https", "--tlsv1.2", "--connect-timeout", "20", "--max-time", "300",
                            f"https://github.com/crapthings/hysteria-rust/releases/download/{RELEASE}/{name}",
                            "--output", str(download)], check=True)
            if not verified(download, digest):
                raise SystemExit("Upstream CLI SHA-256 mismatch; refusing artifact")
            download.chmod(0o755)
            os.replace(download, cache)
    return cache, digest


# Selects the explicit development artifact or pinned release and publishes both worker names.
def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ("debug", "release") or sys.argv[2] not in ARTIFACTS:
        raise SystemExit("Usage: Scripts/prepare-cli.py debug|release arm64|x86_64")
    configuration, architecture = sys.argv[1:]
    root = pathlib.Path(__file__).resolve().parent.parent
    manifest = os.environ.get("HY2_CLI_DEV_MANIFEST")
    if manifest:
        cache, digest, label = development_artifact(configuration, architecture, manifest)
    else:
        cache, digest = release_artifact(root, architecture)
        label = f"upstream {RELEASE}"
    output = root / ".build" / "native" / configuration / architecture
    output.mkdir(parents=True, exist_ok=True)
    # The privileged installation retains its fixed worker filename and signature checks.
    for filename in ("hysteria", "hy2-tun-worker"):
        destination = output / filename
        if not verified(destination, digest):
            with tempfile.NamedTemporaryFile(dir=output, delete=False) as temporary:
                staged = pathlib.Path(temporary.name)
            try:
                shutil.copyfile(cache, staged)
                if not verified(staged, digest):
                    raise SystemExit("CLI changed during preparation; refusing staged executable")
                staged.chmod(0o755)
                os.replace(staged, destination)
            finally:
                staged.unlink(missing_ok=True)
    print(f"Prepared {label} CLI ({architecture}); SHA-256 {digest}; no Rust build or source patches")


if __name__ == "__main__":
    main()
