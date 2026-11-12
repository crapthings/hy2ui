# Development guide

Hy2UI is a SwiftUI/AppKit interface for the official hysteria-rust CLI. The application manages configuration, credentials, process lifecycle and macOS integration. Protocol and TUN forwarding are provided by the unmodified upstream executable.

Default verification is static code inspection. Compile the application or tests only when requested. Never use browser automation, computer use, CUA or image viewing unless explicitly requested. Verification must not install services or modify the host's proxy, DNS, TUN or routes.

## Build and distribution

Requirements: macOS 14+, full Xcode, Python 3 and network access for the first artifact download. Rust, Cargo and recursive submodule checkout are not required.

```sh
python3 Scripts/setup-signing.py
Scripts/build.sh debug arm64
# Alternatively:
Scripts/build.sh release arm64
Scripts/build.sh release x86_64
```

The app is produced at `.build/xcode/Build/Products/{Debug,Release}/Hy2UI.app`. Each build is single-architecture. `project.yml` is the source for the generated Xcode project; run `.tools/xcodegen/bin/xcodegen generate` after changing it.

`Scripts/prepare-cli.py` pins v0.1.0-rc.6 and the SHA-256 digest of each macOS release asset. It verifies cached artifacts, downloads missing artifacts to private staging, verifies the pinned digest and atomically publishes executables. The cache lives in `.build/cli/v0.1.0-rc.6/`; configuration-specific copies live in `.build/native/{debug,release}/{arm64,x86_64}/`.

The same upstream executable is bundled as `hysteria` and `hy2-tun-worker`. The latter name preserves the helper installer's fixed trusted paths and executable hash checks. It is not a custom Rust worker. The helper remains first-party Swift code and is compiled locally. The preparation phase runs on every build so switching a development manifest cannot silently reuse a different core. Verified CLI copies are reused when their hashes match.

The build does not invoke Cargo or apply source patches. The retired submodule, Rust bridge, patches, packet extension, telemetry dashboard and latency probe have been removed. Git history retains their earlier committed versions. Keep new core work in the independent hysteria-rust repository.

Only the downloaded core's command-line/configuration APIs may be used. To update the core, review the release's supported client configuration and behavior, update the release and both artifact digests together, and review the helper configuration adapter. Do not silently fall back to compiling a patched core.

## Local core integration testing

Debug builds may opt into an unmodified binary compiled in the separate
`hysteria-rust` repository. The GUI never builds the core or applies old patches.
Select a private local manifest explicitly:

```sh
HY2_CLI_DEV_MANIFEST="$PWD/.build/cli-dev/f6064cdb27e4fcba2afcf3c2798002153b46d689/manifest.json" \
  python3 Scripts/prepare-cli.py debug arm64
# When ready to build the GUI, keep the same selection:
HY2_CLI_DEV_MANIFEST="$PWD/.build/cli-dev/f6064cdb27e4fcba2afcf3c2798002153b46d689/manifest.json" \
  Scripts/build.sh debug arm64
```

The manifest records `schema_version: 1`, a full Git `commit`, and an `artifacts`
map keyed by `arm64` / `x86_64`; each entry contains `path` (absolute or relative to
the manifest) and `sha256`. Only built architectures are listed. Preparation
verifies the digest, executable permission and Mach-O architecture before copying
the binary under both worker names. An invalid selection fails, without falling
back to a release. Release builds reject this environment variable entirely.
The commit is provenance supplied by the local builder, not a remote attestation.

Unset `HY2_CLI_DEV_MANIFEST` to return to the pinned release on the next preparation
or build. An already-built app continues to contain its bundled binary until
rebuilt. Generated binaries/manifests stay under ignored `.build/`; do not commit
them. App signing changes the embedded executable digest, not the source cache.
The core's `version` command may still show rc.7 during development: distinguish
this test artifact by its manifest commit and SHA-256, not by that version alone.

Core f6064cd supplies stdio control, payload-byte traffic samples and TCP connection
management; installing it does not itself wire these features into the GUI. Current
GUI configuration still occupies stdin, so control-channel integration must first
separate configuration delivery from ongoing control. Keep the existing privileged
helper request restrictions. The independent Rust source also contains an
experimental C packet ABI. `Experiments/PacketFlowAdapter` tests a separate
Swift adapter against that ABI, but is not part of the app build and does not
enable a Network Extension or a CLI packet transport. See its README for the
test-only artifact and network-safety boundaries.

Verify manifest handling with `python3 Scripts/test-prepare-cli.py`. Real TUN and
helper installation still require an explicit user action. After integration is
stable, publish rc.8 and update the release version and both architecture digests
in `Scripts/prepare-cli.py`; no development override should be needed for release.

## Runtime boundary

```text
SwiftUI app
├── SystemConfiguration → local HTTP/SOCKS5 → official CLI
├── Local PAC server → system PAC decisions → local HTTP proxy
└── Restricted Unix socket → administrator Swift helper → official CLI TUN
```

Both proxy and TUN processes run `client --config /dev/stdin --disable-update-check`. JSON is valid YAML and is accepted by the upstream configuration parser. Credentials travel through a bounded pipe; they are not written to a plaintext configuration file or command arguments. Credentials remain in the macOS Keychain between sessions.

The proxy starts before system settings are changed and must report its remote connection and both listeners as ready. The UI interrupts the CLI for graceful shutdown, then uses bounded termination if it fails to stop. Unlike the retired custom worker, the upstream CLI does not monitor its parent PID. A hard UI crash can leave its proxy child alive; automatic orphan-process recovery is outstanding work.

For enhanced mode, the UI resolves the endpoint before capture and preserves TLS SNI. The helper validates a restricted request with a numeric endpoint (it does not perform root-side DNS resolution), selects an unused numeric utun name and constructs only supported upstream settings. It never accepts a user-supplied executable path or arbitrary root CLI options. The helper owns DNS snapshot/recovery and supplemental local resolver integration. The CLI owns its TUN interface and routes.

Public dual-stack capture uses split default routes with local prefixes subtracted when bypass is enabled. A host exclusion keeps the proxy server reachable outside the tunnel. Custom process rules, per-flow adapters and custom direct-route journals are not used. Reconnect after physical-interface or server-address changes.

## Supported interface

- Saved servers, per-server Keychain credentials, pins and selected server switching.
- Local HTTP/SOCKS5 and system proxy controls.
- Administrator-authorized local TUN, DNS maintenance and explicit helper installation/update/removal.
- Generated PAC with domain/IP rules, or an external PAC URL. Generated rules apply only to PAC-aware applications and literal IP targets; the PAC generator does not resolve domains to apply IP rules.
- System process activity sampled through unprivileged `nettop`. These are system process counters, not proof that traffic passed through Hy2UI.
- CLI startup and connection logs.

The production app does not implement Network Extension, process DIRECT routing, custom QUIC counters/RTT charts or the old telemetry-based server RTT test. The system PAC path can select a DIRECT default; that does not add DIRECT routing to TUN. Upstream rc.6 ACL and traffic-statistics settings belong to the server configuration; they are not client routing/telemetry APIs.

Saved process-rule and DIRECT-default records remain decodable. Active process rules are rejected when enabling capture because the current CLI cannot enforce them; remove or disable those rules before connecting. The saved record is not overwritten on load. Legacy Network Extension capture is disabled during profile migration instead of automatically enabling administrator TUN. Legacy traffic history is not displayed or rewritten.

## Administrator service and migration

Install, update, repair and uninstall remain explicit user actions from Settings or the provided terminal scripts. Building does not install or replace root-owned executables. A new app compares bundled executable hashes with the installed manifest and offers an update. Quit and reopen an app rebuilt on disk before installing or updating its service.

Before replacing an old patched helper, disconnect and let that installed helper restore DNS and its direct-route journal. Installation already invokes the old helper's recovery path before replacing it. If a legacy direct-route journal remains after replacement, the new helper refuses to run the official CLI with the obsolete `--recover-direct-routes` option and reports that cleanup with the old version is required. It does not guess at or delete system routes.

The installer verifies the signed app and executable digests before privileged replacement. Paths, ownership checks, user binding, bounded IPC and DNS recovery records retain their existing protections. No automated check may invoke sudo or run the installer.

## Signing

Local signing uses the persistent certificate created by `Scripts/setup-signing.py`. Signing material is stored outside the repository under `~/Library/Application Support/Hy2UI-Signing/`; never commit or distribute it. Builds fail if the expected identity is missing rather than generating a replacement.

`Scripts/sign-local-app.sh` signs nested code and the enclosing bundle, then verifies it. Signing modifies the embedded executable's code signature; the downloaded cache remains unchanged and hash-verifiable. There are no Network Extension entitlements. Developer ID signing/notarization and clean-machine distribution validation remain outstanding.

## Verification

Static syntax checks and XcodeGen generation do not compile the app. Swift model/connection tests and smoke scripts are available for explicit test requests. The experimental packet adapter and provider have separate test scripts and do not validate the current CLI backend. Real TUN and administrator-service behavior must be tested separately by a user initiating those operations.
