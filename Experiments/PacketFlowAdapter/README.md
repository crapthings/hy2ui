# Experimental packet-flow adapter

This directory is an isolated development prototype. It is not an Xcode target,
Network Extension, app build input, or replacement for the administrator TUN
backend. It does not use the retired `PacketTunnel/`, `Native/`, or patched core.
The current application and its pinned CLI build policy are unchanged.

The prototype splits the future macOS adapter into these boundaries:

1. `RustPacketCore` owns one experimental C ABI v1 handle from the independently
   built `hysteria-rust` library. It passes configuration from memory, polls
   versioned status, and maps packet and error results. It rejects lazy startup
   because this adapter requires an established server connection before attach.
2. `ExperimentalPacketAdapter` serializes the handle on its own worker queue.
   It reports startup only after the Rust stack reports `tun` ready and the
   connection reports `connected`. The caller may then configure the platform
   and call `attach` with a packet flow. No OS network settings are applied here.
3. `NetworkExtensionPacketFlow` adapts `NEPacketTunnelFlow` to the host flow
   contract; tests inject a fake flow instead of creating a system tunnel.
4. `ExperimentalProviderCoordinator` owns startup, settings/attach ordering,
   stop, failure and recovery with injectable system and engine interfaces.
   `ExperimentalNetworkExtensionSystem` maps those operations to Apple's API.
   The separate `ExperimentalPacketTunnelProvider` subclass always rejects
   startup until endpoint protection and deployment are validated. It is not
   currently wired to the coordinator or included in an extension target.

The caller must retain the adapter throughout a session, provide a **serial**
callback queue, and call `stop` when finished. Start, attach and stop callbacks
are asynchronous; a start timeout or stop completes an outstanding start once.
`stop` requests Rust shutdown and joins the worker on the adapter's dedicated
queue, not the provider lifecycle queue. The experimental C API has no bounded
join timeout, so a stuck core could delay completion. Generation and read IDs
make callbacks from an earlier session harmless after stop/restart. A core
worker failure after startup is delivered through `onFailure`; a failed start
is delivered through the start completion. Queued callbacks may execute after
another thread requests stop, so a provider must still identify its session.

The adapter issues only one system read at a time. If Rust returns `FULL`, it
retains the unsent portion of that batch, makes no next read, and retries on a
10 ms timer. Pending batches are limited to 256 packets and 1 MiB; a larger
callback fails the session explicitly instead of silently dropping packets.
The system has already allocated the callback batch before the adapter can
check it. Outbound packets are read in batches of at most 64 and written with
IPv4/IPv6 address families derived from the raw IP headers. A rejected system
write fails the session. Active core status is sampled every 250 ms. These
polling intervals and limits are initial choices, not performance guarantees.

## Provider lifecycle

A future provider should own one adapter per tunnel session and serialize its
own lifecycle separately from the adapter's worker queue:

1. Load and validate the selected configuration and establish a verified
   strategy for keeping the server connection outside captured traffic. The
   prototype does not implement that strategy or persist credentials.
2. Start the adapter and wait for its successful completion. Retain both the
   adapter and a session token; `connected` is a prerequisite, not proof that
   application traffic will work.
3. Apply the selected `NEPacketTunnelNetworkSettings`, wait for the system's
   completion callback, then attach a `NetworkExtensionPacketFlow`. If setup
   fails or the session changes, stop the adapter and complete startup once.
4. On stop or runtime failure, invalidate the provider session first, stop the
   adapter, and complete the provider lifecycle only after cleanup finishes.
   Discard callbacks carrying an old provider session token. Define and test
   system settings recovery rather than assuming cleanup after a crash.

The coordinator waits for an outstanding settings installation to complete
before attempting to clear settings. Stop completes only after both the engine
stop and settings clear callbacks succeed. A failed cleanup blocks subsequent
starts; an explicit later `stop` retries only the failed operations. If a system
or engine callback never arrives, cleanup can remain pending. It reports that
uncertainty instead of claiming that settings are restored.

The provider must also define what happens if an extension is restarted without
the UI and how configuration and Keychain access work in that context. The
guarded subclass has no entitlement, signing or distribution configuration.
See [the macOS platform boundary](MACOS-NETWORK-EXTENSION.md) for Apple API
constraints and the unverified server-egress problem.

Only the Rust bridge's proxy-only host-packet mode is available: no routing or
Fake-IP DNS is added. `connected` and `tun` ready do not prove that traffic can
be forwarded or that system capture is safe. Before configuring any real
Network Extension, determine and test server socket protection, IPv4/IPv6,
DNS, network changes, route restore, permissions, entitlement/signing, provider
lifetime, callback ownership, resource pressure and crash recovery. Do not
activate full capture using this prototype. Credentials passed to the core
remain sensitive and are not guaranteed to be securely erased from memory.

## Local tests

On macOS, the fake-flow tests compile only this prototype into a temporary
executable and do not access the network:

```sh
bash Scripts/test-packet-flow-adapter.sh
bash Scripts/test-provider-coordinator.sh
```

The loopback test additionally requires a locally built Rust bridge artifact,
its `manifest.json` and matching header, and a compatible Hysteria CLI. It
checks the library/header hashes and architecture, builds a temporary Swift
executable, and starts only local fixture servers. The manifest records local
provenance; it is not an authenticity attestation.

```sh
bash Scripts/test-packet-flow-integration.sh \
  ../hysteria-rust/build/packet-bridge/<development-artifact-directory> \
  .build/cli-dev/<commit>/hysteria-rust-macos-arm64
```

The bridge library remains experimental, and a working-tree build is not an
official release. Shipping or linking it into Hy2UI requires a separate
versioned distribution and integrity/signing policy and an explicit update to
the project's current CLI-only build constraints.
