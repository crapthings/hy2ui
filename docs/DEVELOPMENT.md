# Development guide

Hy2UI is a native macOS Hysteria 2 client. It uses SwiftUI and AppKit with a pinned Rust core. It supports System Proxy and Enhanced Mode through a local administrator service. A Network Extension backend is also included.

Run all commands below from the repository root. Installing or removing the service, and changing system network settings, require an explicit user action. Automated checks use builds, mock services, and local loopback tests.

## Interface and servers

The default language is Simplified Chinese. Choose English in Settings. Text settings are validated and saved when a field loses focus or you press Return. Server edits use an explicit Save button.

The sidebar shows up to three servers, ordered by pins, most recent successful use, then newest additions. More opens the full list, where you can add, pin, edit, delete, or test servers. Deleting a server requires confirmation. Ordering preferences are stored in local UserDefaults and contain no credentials.

The title bar has Enhanced Mode and System Proxy menus. A green dot means active, amber means selected but waiting to connect, and gray means off. Install and manage the background service in Settings. The first-run guide is optional. Installation status is plain red Not Installed or green Installed text. Passwords are stored in the macOS Keychain, using each server's UUID.

Test Latency measures TCP connection setup time to each server address. It runs only when requested, with up to four tests at once and a three-second timeout per server. It does not connect through the Hy2 protocol, read passwords, or change system network settings. TCP latency is not QUIC RTT, and a TCP timeout does not mean Hy2 is unavailable. An active proxy or TUN may affect results. Measurements stay on the page and are hidden if the endpoint changes.

## Architecture

```text
SwiftUI / AppKit app
├── System Proxy: SystemConfiguration → local HTTP / SOCKS5 → Rust process
└── Enhanced Mode
    ├── Local TUN: restricted Unix socket → root service → Rust TUN worker
    └── Network Extension: System Extension → packetFlow ↔ Rust packet engine
```

The local service manages DNS, worker processes, and recovery. It uses the Rust core for TCP and UDP forwarding. In the Network Extension backend, macOS manages the interface, routes, and DNS. The extension uses bounded packet queues and serial access to Rust handles. It pauses reads when the input queue is full.

Before connecting, the app resolves the server address while preserving TLS SNI. When both modes are enabled, they use the same resolved address. Local TUN adds a route through the physical interface for that address to avoid routing its own connection back into the tunnel. Reconnect if the server IP changes.

Credentials reach the proxy process through a bounded stdin pipe. They are not written to plaintext files or persistent VPN settings. The extension receives credentials only in its start message, so starting from System Settings, on-demand connections, and automatic connections after restart are not supported.

System Proxy starts only after the remote connection and both local listeners are ready. Before applying settings, the app saves a recovery record. Recovery compares the enabled flag, host, and port together for each HTTP, HTTPS, and SOCKS entry. It preserves entries changed by other software.

The Rust proxy exits when its parent process ends. After an app crash, reopen Hy2UI and choose Restore System Proxy. There is no separate service that restores proxy settings automatically. Local listeners have fixed ports and no authentication; another local process could claim those ports after the worker exits.

## Requirements and builds

You need macOS 14 or later, the full Xcode app, Rust, and Python 3. Command-line builds have been checked on Apple Silicon with Xcode 26.6. The Intel build path is provided but has not been verified.

```sh
git submodule update --init --recursive
python3 Scripts/setup-signing.py
Scripts/build.sh
```

The build script downloads and verifies XcodeGen 2.46.0 in `.tools/`, generates the Xcode project, and builds the app. Xcode build phases compile the Rust library, client, TUN worker, and Swift service. The final app is sealed with the persistent local signing identity. Build output stays in the repository's ignored directories; private signing files stay outside the repository. The first build downloads Cargo dependencies.

The Debug app is at `.build/xcode/Build/Products/Debug/Hy2UI.app`.

For Release builds or a different architecture:

```sh
Scripts/build.sh release arm64

# Install the Rust target before building for Intel.
rustup target add x86_64-apple-darwin
Scripts/build.sh release x86_64
```

Each build produces a single-architecture app, not a Universal Binary.

You can also open the generated `Hy2UI.xcodeproj`. Each Xcode build lets Cargo check the dependency graph. Native output is separated by configuration and architecture under `.build/native/{debug,release}/{arm64,x86_64}/`. Edit `project.yml`, the project source, rather than the generated Xcode project.

## Local TUN service

Local TUN does not require Network Extension, an Apple Developer account, App Store distribution, or disabling SIP. Its privileges come from the service the user installs. The app itself runs as a normal user.

```sh
Scripts/build.sh
open .build/xcode/Build/Products/Debug/Hy2UI.app
```

Distribute the complete `Hy2UI.app`. It contains both service executables and the installer; no separate scripts are needed for normal use. In Settings, choose the Local TUN backend and install the service. Approve the macOS administrator prompt, then enable Enhanced Mode and connect. The app does not collect or store the administrator password.

Settings provides install, update, repair, and uninstall actions, and refreshes status when opened. Disconnect and complete cleanup before updating or uninstalling. System Proxy can be enabled independently or alongside Enhanced Mode. Network settings are locked during a connection. Turn off other apps' TUN modes before testing to avoid route conflicts.

The installer copies executables to `/Library/PrivilegedHelperTools/dev.hy2ui/`, makes them root-owned, and registers `/Library/LaunchDaemons/dev.hy2ui.local-tun.plist`. The service accepts only the user UID approved at installation. The app verifies that the service runs as root. IPC cannot supply arbitrary executable paths, file paths, or core configurations. Credentials pass through the Unix socket and stdin in memory. The service does not record raw worker logs.

System Proxy uses macOS authorization to change network preferences. The app reuses the authorization object while running, but macOS decides how long it remains valid. Connections through an installed Local TUN service do not use that authorization flow. You can leave System Proxy off when using only TUN. Connecting with an unchanged saved server does not read or write its Keychain entry again.

The service creates no TUN interface while idle. It applies DNS and routes on connection, and attempts recovery on stop, client disconnect, and service restart. DNS also has a root-owned recovery journal. If stop is not confirmed, the app retains ownership of the resources and offers Retry Cleanup.

### Recovery and updates

For manual DNS recovery, first stop the service, then run:

```sh
sudo /Library/PrivilegedHelperTools/dev.hy2ui/hy2-local-tun-helper --recover-dns
```

Recovery refuses to run while the service holds its exclusive lock. Prefer disconnecting in the app, or use the uninstall script below to stop the service and recover DNS.

Rebuilding the app does not replace the installed root-owned copies. The app compares executable hashes and offers Update when needed. Before requesting administrator approval, it verifies the app and bundled code. After approval, staged copies must match the SHA-256 hashes captured before authorization.

If you rebuild a running app, quit and reopen it before installing or updating the service. The installer rejects a running process that no longer matches the app on disk.

Use `Scripts/build.sh` to seal local builds. An unsigned Xcode build may fail the installer checks. The installer uses macOS administrator authorization and does not use SMAppService.

The following scripts are for manual setup and recovery. They change system services and require administrator approval. Normal users can perform these actions in Settings instead.

```sh
sudo Scripts/install-local-tun-helper.sh .build/xcode/Build/Products/Release/Hy2UI.app
sudo Scripts/uninstall-local-tun-helper.sh
```

Both update and uninstall stop the old service and try to restore DNS first. If recovery fails, installed files remain available for a retry. Server profiles and Keychain credentials are kept. Automated validation does not run these administrator commands.

## Persistent local signing

Run setup once before the first build:

```sh
python3 Scripts/setup-signing.py
Scripts/build.sh
python3 Scripts/test-signing.py
```

The certificate, encrypted private-key backup, and keychain password are stored in `~/Library/Application Support/Hy2UI-Signing/`, readable only by the current user. Keep a secure backup of the whole directory. Never commit it, include it in a DMG, or publish it.

Later builds reuse the same certificate. If signing material is missing or invalid, the build stops instead of creating a new identity or falling back to ad-hoc signing. During signing, the dedicated keychain is added to the user search list temporarily, then the previous list is restored. No trusted root certificate is installed.

A stable certificate and bundle ID preserve the app's signing identity across builds and reduce repeated Keychain prompts. Moving from an ad-hoc build may still require one more approval; choose Always Allow if appropriate. A new certificate, changed Keychain permissions, or system policy can trigger another prompt. Server credentials update the same UUID-based entries rather than creating a copy for each build.

Self-signed apps can be distributed, but they do not have Developer ID trust or notarization. On first launch, users may need to choose Open Anyway in System Settings → Privacy & Security. They do not need to install a root certificate or disable Gatekeeper. Developer ID signing and notarization make distribution easier and do not require App Store release.

Local self-signing supports the Local TUN build; it does not grant Network Extension entitlements. `HY2_SIGN=1` keeps the Xcode Apple-signing path. First install and upgrades from a self-signed DMG still need testing on a clean machine.

## Network Extension signing

This backend uses a System Extension for direct Developer ID distribution. You need an Apple Developer team, an App ID, and a matching Network Extension provisioning profile.

1. Copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig`. Set your team ID and bundle ID prefix.
2. Configure signing capabilities for the app and extension. The app needs Network Extension and System Extension installation entitlements. The extension needs Packet Tunnel System Extension support and a matching App Group for Mach service naming.
3. Build with `HY2_SIGN=1 Scripts/build.sh`.
4. Install the app in `/Applications`, connect from the app, and approve the extension and VPN configuration when macOS asks.

These steps apply only to the Network Extension backend. Local TUN uses the installer described above. Automated checks do not enable extensions, install privileged services, or change system network settings. Unsigned builds cannot validate Network Extension behavior. Distribution still needs the correct signing, notarization, and clean-machine installation tests.

Apple references: [Packet Tunnel](https://developer.apple.com/documentation/networkextension/nepackettunnelprovider), [deployment requirements](https://developer.apple.com/documentation/technotes/tn3134-network-extension-provider-deployment), and [supported use cases](https://developer.apple.com/documentation/technotes/tn3120-expected-use-cases-for-network-extension-packet-tunnel-providers).

## Diagnostics

If Local TUN loses IPC, the app shows Recovery Required and retains resource ownership. It does not claim to be reconnecting. Use Retry Cleanup until the service confirms it has stopped. Actual Network Extension reconnect states are handled separately.

The service reports fixed failure categories for core startup, timeout, process exit, DNS, and cleanup. Exit reports include the numeric status and whether a signal ended the process. The app keeps these details in its logs. The service writes structured, timestamped failures to `/private/var/log/dev.hy2ui.local-tun.log`.

Unknown errors are not forwarded as raw text. Diagnostics do not pass through credentials, raw configuration, Rust stderr, or destination addresses. An rc5 QUIC disconnect event marks the session as needing recovery; only a later connected event restores connected status. The core reconnects when new requests arrive. The app adds no separate reconnect loop, and callers must retry existing TCP streams. A single TCP or UDP flow error does not mark the whole TUN as disconnected.

These signals are not an end-to-end health check. A running core that reports no state change may still have a failed connection or flow. Update the installed service from Settings after upgrading the app; old root-owned copies are not replaced automatically. PacketTunnel reuses the rc5 TCP/UDP forwarding and error-limiting code rather than replacing upstream session, IPv6, or reconnect logic.

## Tests

```sh
swift test
Scripts/test-helper-installer.sh
Scripts/test-server-library.sh
Scripts/test-server-latency.sh
Scripts/test-core-process.sh
Scripts/test-local-tun.sh
Scripts/test-local-tun-service.sh
python3 Scripts/prepare-core.py
cargo test --locked --manifest-path Native/Cargo.toml -p hy2-bridge
```

Installer tests inject an authorization runner to cover install, uninstall, cancellation, failure, duplicate actions, and stale checks. AppleScript is compiled for syntax checks but is not run with administrator authorization.

Swift tests cover configuration encoding, address validation, proxy ownership, cancellation, stale callbacks, server ordering, and connection lifecycles with mock services. Configuration or Keychain errors must not block recovery, and failed recovery must not discard resource ownership. Process tests use mock workers to check stdin delivery, startup exits, and repeated stops.

Rust tests cover ABI arguments, worker input limits, and local Hysteria packet round trips. The latency smoke test uses an ephemeral loopback TCP listener. Network tests use loopback only; they do not create TUN interfaces or change system proxies, DNS, or routes.

## Code structure and data migration

`Connection/` separates resource lifecycles, profile editing, and initialization. Protocols inject workers, proxy recovery, VPN, and storage services for failure and cancellation tests. `AppModel` combines UI state without tying errors to resource ownership. The VPN provider and packet engine share a serial lifecycle queue. Asynchronous DNS and settings callbacks check session IDs.

Saved profiles and Keychain credentials use versioned formats. Legacy plain JSON remains readable, and missing fields receive defaults. Unknown future versions are not overwritten. Every first-party top-level declaration has a one-sentence responsibility comment; split code first if one sentence cannot explain it clearly.

System Proxy and Enhanced Mode are independent choices. The old `mode` field is read only to migrate profiles that lack these choices; new saves omit it. Users choose the Enhanced Mode backend explicitly. Failure triggers an error and cleanup, not an automatic backend switch. An invalid recovery record is preserved and reported rather than treated as empty settings.

## Scope and remaining work

Implemented features include multiple servers, legacy profile migration, Keychain storage, independent capture modes, the Local TUN service and its installer, a Network Extension backend, DNS recovery, server route exclusion, the Rust packet bridge, startup cancellation, and cleanup on exit.

Further testing and work include:

- Clean-machine service install, update, uninstall, and recovery; signed Network Extension authorization and lifecycle tests.
- Real-server TCP, UDP, IPv6, DNS, sleep and wake, network changes, and recovery.
- Applying System Proxy settings to network services added during a connection. Currently, only services present at startup are configured.
- Automatic System Proxy recovery after an app crash. Recovery records currently remain until the next launch.
- Subscriptions, routing rules, traffic statistics, launch at login, automatic connections, and a kill switch.

Hysteria carries TCP and UDP. It does not provide a general ICMP tunnel.

## Upstream and licenses

The core is [crapthings/hysteria-rust](https://github.com/crapthings/hysteria-rust), pinned as a submodule at `f364dab51b3908d5c158309b1eba54445628641a` (source version `0.1.0-rc.5`). Adaptations live in `Patches/core-*.patch` and `Patches/embedded.rs`. The preparation script checks the commit and clean source tree, applies patches to an archive, creates an immutable source directory keyed by content, and atomically updates the `.build/core` symlink. Cargo caches stay in `Native/target`.

Keep `Native/Cargo.lock`. It is derived from the upstream lockfile and includes customized Quinn and Rustls dependencies. Do not replace it with a lockfile that selects the latest registry versions.

Upstream uses the MIT License. Dependency notices remain in [`Vendor/hysteria-rust/LICENSE`](../Vendor/hysteria-rust/LICENSE) and the upstream [`THIRD_PARTY_NOTICES.md`](../Vendor/hysteria-rust/THIRD_PARTY_NOTICES.md). Include the required notices when distributing the app. See the repository's [third-party notices](../THIRD_PARTY_NOTICES.md) for an overview.
