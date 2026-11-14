# Network Extension development

`Hy2UINE` is a separate macOS host app embedding the `Hy2PacketTunnel` System
Extension in `Contents/Library/SystemExtensions`. The normal Hy2UI CLI/helper
build remains available. This path is implemented for offline Debug validation;
it has not passed signed macOS activation or live network acceptance.

## Data and lifecycle

The host selects an active wired/Wi-Fi interface, resolves one numeric server
endpoint and preserves TLS SNI. Credentials travel in bounded VPN start options;
VPN preferences contain only the provider identifier and schema version. Old
backend selections cannot automatically enable capture.

The provider configures system routes/DNS through Network Extension and exchanges
raw IPv4/IPv6 packets with the prebuilt Rust Packet ABI through bounded queues.
Rust binds its QUIC socket to the selected physical interface; settings also
exclude the exact server address. Interface loss fails the core rather than
silently selecting another path. The initial mode requires LAN bypass and rejects
custom rules, process routing, Fake-IP endpoints and unsupported configurations.
It does not enable Fake DNS. System DNS is forwarded as ordinary UDP/TCP.

The coordinator sequences core startup, settings installation, packet attachment
and cleanup. Cleanup failure retains ownership and blocks restart. The provider
bounds the system stop callback wait, but Rust destruction can still wait on a
worker join; that timeout is reported as uncertain cleanup, not clean recovery.

## Offline build

On an APFS checkout with full Xcode, build the packet library in the separate
hysteria-rust repository using `scripts/package_packet_core.py`. Select its
manifest explicitly:

```sh
HY2_NE_CORE_DEV_MANIFEST=/absolute/path/to/manifest.json \
  bash Scripts/build-network-extension.sh arm64
bash Scripts/test-network-extension.sh
# Optional real-core loopback test (requires the sibling Rust test harness):
HY2_NE_CORE_DEV_MANIFEST=/absolute/path/to/manifest.json \
  bash Scripts/test-ne-core-integration.sh /absolute/path/to/hysteria
swift test
swift test -Xswiftc -DHY2_NETWORK_EXTENSION
```

The build validates the full source commit, ABI, architecture and SHA-256 of the
header and static library. Hy2UI never invokes Cargo. This development artifact
selection is Debug-only; Release is rejected until official versioned library artifacts
are defined. The script forces `Hy2CaptureEnabled=NO`, disables signing, and never
opens the app, activates an extension, saves a VPN configuration or changes routes.
An unsigned build is an inspection artifact, not an installable VPN.

## Signed acceptance remaining

Direct/DMG distribution uses a System Extension with
`packet-tunnel-provider-systemextension`, matching host/provider Team IDs and
appropriate Developer ID signing/provisioning. See Apple's
[TN3134](https://developer.apple.com/documentation/technotes/tn3134-network-extension-provider-deployment)
and [Network Extension entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.networkextension).
Only a deliberately enabled signed test build and user action may activate it.
No signing account/profile is included in the repository.

Live acceptance must cover IPv4/IPv6 socket paths after settings and reconnect,
DNS, cancellation, interface changes, sleep/wake, stop/crash cleanup and coexistence
with other VPNs. Excluded routes and physical binding have offline checks; their
combined system behavior remains unverified. Apple's
[TN3120](https://developer.apple.com/documentation/technotes/tn3120-expected-use-cases-for-network-extension-packet-tunnel-providers)
should also guide review of this flow-forwarding provider's distribution model.

The current host supports activation and connection lifecycle; a dedicated
extension removal/preferences management interface remains to be implemented.

## Offline verification on 2026-11-14

Both model/connection test configurations passed 153 tests each. Adapter fake-flow
and provider lifecycle smoke tests passed, including bounded queues, cancellation,
failed cleanup and blocked restart. The promoted adapter linked to the real static
Rust library and passed loopback TCP/UDP, authentication failure, stale-callback
and coordinator forwarding tests. The unsigned arm64 host/provider build passed;
both bundle capture flags were checked as `NO`. These checks did not activate the
extension or validate live system routing/DNS.
