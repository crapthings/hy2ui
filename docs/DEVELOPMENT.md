# Development guide

Hy2UI manages the official hysteria-rust executable through CLI configuration and
lifecycle APIs. Swift owns the interface, Keychain, system proxy settings and the
administrator helper. Rust owns protocol forwarding, native TUN and its routes.

## Build and core selection

Requirements: macOS 14+, full Xcode and Python 3. Rust is not required to build
Hy2UI. `project.yml` is the XcodeGen source; generated projects and artifacts are
not committed.

```sh
python3 Scripts/setup-signing.py
Scripts/build.sh debug arm64
Scripts/build.sh release arm64
```

Applications are written to `.build/xcode/Build/Products/{Debug,Release}/Hy2UI.app`.
Builds are single architecture; `x86_64` is also supported. Local signing setup
creates a persistent identity outside this repository. Developer ID signing and
notarization require the distributor's own credentials.

`Scripts/prepare-cli.py` is the only core artifact selector. Normal builds pin
v0.1.0-rc.7 and the SHA-256 of each official macOS executable. The same executable
is bundled as `hysteria` and `hy2-tun-worker`. The GUI never invokes Cargo or
patches Rust source.

Debug integration builds can select a binary built in the separate Rust repository:

```sh
HY2_CLI_DEV_MANIFEST=/absolute/path/to/manifest.json Scripts/build.sh debug arm64
```

The JSON manifest requires `schema_version: 1`, a full Git `commit`, and an
`artifacts` map keyed by architecture, each with `path` and `sha256`. Executable
permissions, architecture and hash are verified. Release rejects this override.
The source commit is builder-provided provenance, not a remote attestation. A
core may retain its rc.7 version string; use its manifest and hash to identify it.
Unsetting the variable affects the next build, not an existing app. Signing changes
the embedded executable digest, so it can differ from the verified source artifact.

## Runtime and rules

Both local proxy and TUN workers run `client --config /dev/stdin
--disable-update-check`. Credentials travel through a bounded pipe and remain in
Keychain between sessions. The administrator IPC accepts only bounded settings;
callers cannot supply executable paths or arbitrary root-owned output paths.

Rule/global/direct modes are independent of capture. System-proxy rules compile
to Rust native routing. Process rules precede address rules, local bypass and
FINAL; applying changes requires reconnecting. Exact process name/path rules
require a capable development core and apply only to local HTTP/SOCKS TCP. A
missing process identity fails closed. Attribution is not a security boundary.
PAC is no longer offered or installed; legacy storage and recovery remain readable.

macOS TUN rule routing, Fake DNS, TUN process matching and Network Extension are
not enabled. Custom routing combined with TUN is rejected rather than ignored.
The independent `Experiments/PacketFlowAdapter` is outside the app build.

## Administrator TUN lifecycle

The helper is installed separately from a native interface. Enhanced mode creates
utun on demand; stopping closes the owned device after route cleanup. There is no
persistent network-driver installation and no scanning/deletion of arbitrary utun
interfaces. Supported cores record a session UUID, actual name/index, process birth
identities and helper-parent identity. Borrowed matching routes are never deleted
as owned routes.

State queries inspect idle ownership without applying recovery. Startup and
explicit stop retain recovery gates. Unresolved DNS/route receipts prevent a new
session or successful uninstall. Recovery files must not be deleted to bypass a
failure. Older cores without these capabilities cannot supply session tracking.
Helper updates and uninstall are explicitly initiated from settings or the installer.

Startup logs expose recovery, core probing/configuration, observed server and
interface readiness, identity verification, DNS application and total durations.
Readiness observations are elapsed since core launch, not independent operation
costs. Being connected requires authentication and local readiness; it does not
prove every remote target is reachable.

The interface uses IPv4 `100.100.100.101/30` and IPv6 `fd72:6832::1/126`, outside
the planned synthetic pools. macOS core preflight rejects overlapping existing
non-default routes before creating a device. Local bypass avoids generating an
unspecified IPv6 host route (`::/128`). See
[Fake DNS integration](macos-fake-dns-integration.md) for remaining prerequisites.

## Verification and diagnostics

Follow `AGENTS.md`: default to inspection, build/test when requested, and keep
real proxy, DNS, TUN, route and helper changes user initiated. Test and package on
APFS with real symlinks when working from the exFAT migration copy. Exclude macOS
metadata from traversal, source lists and packaging.

Model/lifecycle tests use `swift test`. `Scripts/test-*.sh` provide ordinary-user
process, helper IPC, installer-planning and policy checks. Tests do not establish
live network recovery or production readiness.

- `diagnose-tun-network.py`: compare system DNS, IPv4/IPv6 HTTPS and a pinned-address
  path. HTTP error status codes still prove a response, not authenticated API use.
- `diagnose-physical-egress.py --interface en1`: inspect ordinary/scoped routes and
  verified interface-bound TCP/DNS sockets. It tests Darwin primitives, not the
  complete Rust Fake DNS integration. No unbound retry is made.

These scripts write private reports and do not change network settings. Diagnostic
reports, binaries and benchmark outputs belong in ignored build directories, not
the documentation tree. Preserve capability and deployment limits when reporting
results. See [remaining work](ROADMAP.md).
