# Packet-flow test prototype

This directory retains the original isolated ABI, fake-flow and provider-lifecycle
test fixtures. It is not an application build input. The maintained adapter is
under `NetworkExtension/`; deployment, capture gates and remaining system acceptance
are documented in the [NE guide](../../docs/NETWORK-EXTENSION.md).

## Responsibilities

- `RustPacketCore` exercises the prebuilt experimental Packet ABI.
- `ExperimentalPacketAdapter` serializes core access, bounds packet queues and
  rejects stale callbacks after stop or restart.
- `NetworkExtensionPacketFlow` maps packet-flow operations to an injectable contract.
- `ExperimentalProviderCoordinator` exercises startup, settings installation,
  attachment and cleanup with fake platform services. Failed cleanup blocks restart.
- The experimental provider subclass rejects startup; it is not the deployed provider.

## Offline checks

The fake-flow and lifecycle scripts do not configure system networking:

```sh
bash Scripts/test-packet-flow-adapter.sh
bash Scripts/test-provider-coordinator.sh
```

The integration script verifies a separately built Rust bridge manifest/header
and runs local fixture servers with a compatible CLI:

```sh
bash Scripts/test-packet-flow-integration.sh \
  ../hysteria-rust/build/packet-bridge/<development-artifact-directory> \
  .build/cli-dev/<commit>/hysteria-rust-macos-arm64
```

A development manifest records provenance, not authenticity. Passing these checks
does not validate signed extension activation, system routing/DNS, crash recovery
or distribution readiness. See the NE guide for the current artifact selection
and acceptance procedure rather than using this prototype to enable capture.
