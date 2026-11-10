# Development guide

Hy2UI is a native macOS Hysteria 2 client. It uses SwiftUI and AppKit with a pinned Rust core. It supports System Proxy and Enhanced Mode through a local administrator service. A Network Extension backend is also included.

Run all commands below from the repository root. Installing or removing the service, and changing system network settings, require an explicit user action. Automated checks use builds, mock services, and local loopback tests.

## Interface and servers

The default language is Simplified Chinese. Choose English in Settings. Text settings are validated and saved when a field loses focus or you press Return. Server edits use an explicit Save button.

The sidebar shows up to three servers, ordered by pins, most recent successful use, then newest additions. More opens the full list, where you can add, pin, edit, delete, or test servers. Deleting a server requires confirmation. Ordering preferences are stored in local UserDefaults and contain no credentials.

The title bar has Enhanced Mode and System Proxy menus. A green dot means active, amber means selected but waiting to connect, and gray means off. Install and manage the background service in Settings. The first-run guide is optional. Installation status is plain red Not Installed or green Installed text. Passwords are stored in the macOS Keychain, using each server's UUID.

Test Latency opens a short authenticated Hy2 connection and reads its QUIC path RTT. Each test uses a disposable worker with loopback listeners on OS-assigned ports. It reads that server's Keychain credentials but never changes system proxy, DNS, TUN, or route settings. Tests run only when requested, with up to four at once. Startup is bounded by the normal core timeout. The worker resolves the server and preserves TLS SNI. DNS work stays inside that disposable process, so cancelling a test can stop it without waiting for a separate UI resolver task. Measurements stay on the page and are hidden if the endpoint changes. The active network path can affect results.

## Dashboard and accounting

Overview keeps the connection controls, current QUIC latency, upload and download rates, and today's and this month's traffic in the same window. Detailed process activity has its own navigation page.

Local TUN and System Proxy report opt-in QUIC metrics once per second. The pinned core is adapted in `Patches/core-traffic-metrics.patch`; the submodule is not modified. Samples contain only a connection ID, cumulative byte counters, RTT, and a relative monotonic timestamp. The helper forwards numeric samples over its existing authenticated socket. Metric frames do not enter the user log.

Counters cover QUIC UDP payload bytes, including QUIC overhead and retransmissions, but not IP or UDP headers. System Proxy and Local TUN streams are counted separately and then added. Server latency probes are not included. Worker generations and connection IDs prevent reconnects or delayed samples from counting the same traffic twice. Rates use core sampling time rather than IPC arrival time, so queued startup frames cannot inflate them. Rates reset when disconnected or when reporting stops. The Network Extension backend does not report these metrics yet.

Daily totals are stored in `~/Library/Application Support/Hy2UI/traffic.json` with user-only permissions. Totals use local calendar dates and retain up to 400 days. The app saves about every 15 seconds and when disconnecting. A crash can lose the last unsaved samples, and sample boundaries can shift a small amount of usage across midnight. These are local usage estimates, not a provider billing meter. Unknown or corrupt history files are preserved rather than overwritten. History begins when this version is used; it does not reconstruct older usage.

## Process network activity

Network Activity uses the built-in `nettop` tool without administrator privileges. While the page is open, it samples process counters about every two seconds and displays upload and download rates plus received and sent bytes. It stops sampling when the page closes. If macOS does not allow a sample, the page reports that activity is unavailable.

These are system process counters, not a list of flows proven to use Hy2UI. They include direct, proxied, and local connections. An app and the forwarding worker can both appear, so their values must not be added to the Dashboard totals. System counters can reset when processes or sockets end; decreasing counters reset the rate baseline rather than producing negative usage. Process activity is not saved to disk and is not used to enforce routing rules.

Planned bypass and routing work is tracked in the [roadmap](ROADMAP.md).

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

### Collect a network report

When a connection fails, run this before switching to another client:

```sh
python3 Scripts/diagnose-network.py
```

The script records DNS, routes, system proxy settings, relevant processes, and unauthenticated transport checks in a private JSON file under `.build/network-diagnostics/`. It does not change network settings. Reports include network addresses and local paths; review them before sharing. Proxy credentials and unrelated process environment values are excluded.

Checks include UDP and TCP DNS queries, IPv4 HTTPS, and IPv6 HTTPS with an explicit destination address. The IPv6 check avoids a false pass when the system resolver returns only IPv4 addresses. A bare TCP handshake is reported separately: the local TUN stack may accept it before the remote connection succeeds. Use the HTTPS result to confirm that TLS reaches the target. An HTTP 401 or 405 means the endpoint responded, not that an authenticated session or WebSocket connection works.

If IPv4 works but IPv6 HTTPS closes immediately, check the server's IPv6 outbound path and resolver implementation. This can affect browsers that choose IPv6 even when a command-line request succeeds over IPv4. With a custom resolver, IPv6 literals must be recognized as IP addresses rather than queried as domain names.

The app also classifies failed TCP targets in `198.18.0.0/15` as a possible cached-address conflict with another proxy. It reports only the range and category, not the exact destination or raw error. This is a diagnostic hint, not proof of a DNS-cache problem.

## Tests

```sh
swift test
python3 -m unittest discover -s Tests/NetworkDiagnostics
Scripts/test-helper-installer.sh
Scripts/test-server-library.sh
Scripts/test-server-latency.sh
Scripts/test-dashboard.sh
Scripts/test-core-process.sh
Scripts/test-local-tun.sh
Scripts/test-local-tun-service.sh
python3 Scripts/prepare-core.py
cargo test --locked --manifest-path Native/Cargo.toml -p hy2-bridge
```

Installer tests inject an authorization runner to cover install, uninstall, cancellation, failure, duplicate actions, and stale checks. AppleScript is compiled for syntax checks but is not run with administrator authorization.

Swift tests cover configuration encoding, address validation, proxy ownership, cancellation, stale callbacks, server ordering, and connection lifecycles with mock services. Configuration or Keychain errors must not block recovery, and failed recovery must not discard resource ownership. Process tests use mock workers to check stdin delivery, startup exits, and repeated stops.

Rust tests cover ABI arguments, worker input limits, and local Hysteria packet round trips. The latency smoke test uses a mock core to check QUIC metric selection and cancellation. A Rust integration test verifies real metric frames against an ephemeral loopback Hysteria server. Network tests use loopback only; they do not create TUN interfaces or change system proxies, DNS, or routes.

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

## PAC and application bypass

Settings supports three system proxy modes: fixed local proxies, an automatic PAC script, and an external HTTP(S) PAC URL. Automatic PAC runs on a random loopback-only URL for the connection lifetime. It bypasses configured domain suffixes and, optionally, local names and literal private IPv4/IPv6 addresses. It does not resolve public domain names to guess whether their address is private. Other traffic uses the configured local HTTP proxy without a `DIRECT` fallback. External PAC scripts must name the current local proxy endpoint themselves. PAC works only in applications that honor the system PAC setting; it does not configure shell proxy environment variables.

PAC and Enhanced Mode cannot run together in this implementation: a PAC `DIRECT` decision would still be captured by TUN. The proxy recovery journal restores PAC enable, URL and inline script as one owned group. Changes made by another application are preserved.

Application bypass is available only with local Enhanced Mode and System Proxy disabled. Rules accept case-sensitive executable names, `*` and `?` globs, absolute paths, and trailing-slash application bundle prefixes such as `/Applications/Example.app/`. This is a supported subset of Surge-style process patterns, not a full Surge configuration importer. Rules are stored separately from server credentials and apply on reconnect.

The worker captures physical interface indices before installing TUN routes. The C adapter uses public SDK `libproc` socket structures to identify TCP and UDP owners, and only matched outbound sockets receive `IP_BOUND_IF` or `IPV6_BOUND_IF`. No extra global routes are installed for application bypass. Unknown, inaccessible, ambiguous or timed-out ownership stays proxied. A selected direct connection that fails does not silently switch to the proxy. Interface changes require reconnecting. Protected processes may not expose enough metadata, even to the helper.

Ownership lookups run on a blocking pool with four permits. A shared in-memory five-tuple index holds immutable snapshots for up to 250 ms. Hits revalidate PID start time, executable path, socket identity and the socket tuple with targeted SDK calls; they do not enumerate all processes. Cold misses share a serialized full snapshot refresh with a 20 ms minimum refresh interval. Each full scan has a 150 ms work budget and a 32,768-record limit. Partial, oversized and failed scans are discarded. The scan cannot be atomic with application socket creation, so ambiguous or unobserved ownership stays proxied. There is no process scan when rules are empty. This is an attribution mechanism, not a security boundary or a complete per-process VPN exclusion API. QUIC traffic totals exclude direct sockets; the Network Activity page remains system-wide activity.

The narrow macOS adapter in `Patches/desktop-routing.rs` and `Patches/desktop-process-owners.rs` documents each unsafe call to the SDK shim. `core-unsafe-adapter.patch` changes the generated workspace lint from `forbid` to `deny`, keeping unsafe code denied elsewhere while permitting this explicit adapter. The pinned submodule is unchanged.

Run `Scripts/test-routing.sh`, `python3 Scripts/test-process-routing.py`, `swift test`, and `cargo test --locked --manifest-path Native/Cargo.toml -p hy2-bridge`. These checks use loopback sockets and fake proxy controllers. They do not install a helper or change system proxies, TUN, DNS, or routes. Real privileged routing and protected application attribution require a separate manual test.

Network Activity offers a per-process context menu for `DIRECT` or default rules. It saves the complete executable path through `ProcessRoutingPolicy`, reusing the same configuration as Settings and the TUN matcher. PID and process start time are checked before saving; missing metadata disables the shortcut. The rule column shows saved configuration, not live flow attribution. Changes apply on the next connection, including edits made during an active connection. `DIRECT` is available only for local Enhanced Mode without System Proxy. Returning to default removes the exact-path shortcut; shared name, wildcard or app-bundle rules must be edited in Settings to avoid changing other processes.


## Rule indexes and storage

Transient process ownership stays in memory, not SQLite or RocksDB: process and socket identities must be rediscovered after restart. Existing validated rule preferences remain persisted separately. No background scan runs while the worker is idle, and an empty rule configuration does not initialize the ownership index. Every reconnect creates a new worker and fresh indexes, so rule changes cannot reuse old decisions.

The compiled process rule index uses exact-name and exact-path hash sets, directory-prefix keys checked against path ancestors, and pre-parsed wildcard patterns. Matching repeated executable paths is memoized within each snapshot. The flow index has separate keys for TCP/UDP and IPv4/IPv6; unconnected UDP uses a local-port index and requires an unambiguous visible owner. A cached shared UDP owner is observational metadata, not a security boundary: another socket may appear between snapshot collection and lookup. Unknown owners remain proxied.

Automatic PAC compiles its domain rules into an object lookup table once per script load. Each request checks the full host and successive suffix keys, with own-property checks to avoid inherited JavaScript properties. It handles duplicate domain entries and a trailing DNS dot. TUN domain-to-flow attribution remains future work; these PAC domain keys do not imply a TUN DNS index.

Cache tests cover concurrent refresh sharing, repeated hits without scans, stale owners, expiration, failed and oversized snapshots, protocol/family separation, exact-owner conflicts and ambiguous UDP. Native loopback checks cover process exit, changed process start time, changed socket identity and executable path. These tests do not change local system networking.

## Stable network activity interaction

Network Activity keeps established row positions while updating counters. The first batch is ordered by displayed process name; later discoveries append at the bottom. Column clicks sort the current snapshot once, and Re-sort applies the selected ordering to the latest values. Sampling does not continuously re-sort. Search matches displayed and reported process names, PID, and available executable paths.

Rows missing from a successful sample show zero rates and “No recent activity” for ten seconds. This label does not claim that the process exited. Selected rows remain until deselected. Native menu tracking defers membership changes while counters can continue updating. Stable UUIDs and known process start times prevent a reused PID from inheriting selection or a rate baseline. Unavailable executable metadata disables rule actions; any later action still revalidates identity.

Pause updates freezes the displayed snapshot and skips new nettop polls; it does not pause the connection. Resume discards the old rate baseline, avoiding an average over the paused period. Returning after a missing sample also establishes a fresh baseline. The view retains its native table identity, disables update animations, and reserves one status line so transient messages do not shift the table.

The context menu supports visible multi-selection, batch DIRECT/default-rule changes, and copying names, PIDs or paths. Batch rule edits validate every selected identity and persist once; a shared-rule conflict or rule limit rejects the entire edit. Only the visible context targets are affected when search hides other selected rows.

Run `Scripts/test-process-activity.sh` for deterministic table behavior checks with injected counters and times. `Scripts/test-routing.sh` also covers rejection of partially valid batch edits. These checks do not start nettop or change system networking; the existing PAC checks use loopback only.


## Prepared TUN dependencies

The generated client core pins `tun-rs 2.8.18` and adapts `netstack-smoltcp 0.2.5` with `smoltcp 0.14.0`. The netstack source archive is verified against SHA-256 `f5abcddf2ae2d1642c492c1043041548200a176a3b5c3db6e5169ab1ed8d62b8`, extracted into the immutable generation, and patched outside the Cargo registry. Source preparation can reuse a verified Cargo archive or download that exact public archive. No signing material is involved. Dependency updates also require the compatible Tokio 1.54 lockfile resolution.

`Patches/core-zz-tun-lifecycle.patch` bounds packet queues, owns TCP relay tasks, limits concurrent relays and tunnel-opening time, and emits safe error categories. The dependency adapter deduplicates SYN retransmissions, separates write-half completion from socket retirement, and resets abandoned streams. See [the investigation and regression coverage](TUN-INVESTIGATION.md) for details. Helper installation and real network changes remain user initiated.

Use `cargo test --locked --manifest-path Native/Cargo.toml -p hy2-bridge` for TCP lifecycle and loopback forwarding coverage, and `python3 Scripts/diagnose-tun-stack.py` for the standalone in-memory probe. Add `--upstream` to the latter to reproduce the unpatched behavior. The fixed tests preserve queued payload data, exercise both address families and verify tuple reuse beyond the protocol socket limit.
