# Official CLI TUN adapter

The active adapter is `Shared/CLITunConfiguration.swift`. It maps a bounded helper request to the official hysteria-rust v0.1.0-rc.6 client configuration. No Rust source is generated, compiled or patched.

The administrator helper launches the pinned upstream executable under its historical installed name `hy2-tun-worker`, using `client --config /dev/stdin --disable-update-check`. It manages DNS and process supervision while the CLI manages the TUN interface and routes.

The adapter freezes the proxy endpoint, preserves TLS SNI, selects an unused utun name, configures dual-stack tunnel addresses and split default routes, and adds a server host exclusion. Optional local-network bypass subtracts local prefixes from capture routes without installing broad physical bypass routes. Synthetic DNS (`198.18.0.0/15`) and CGNAT space remain captured.

Only upstream-supported fields are emitted. Legacy process rules, address-flow rules and DIRECT-default requests are rejected at the privileged adapter boundary. Domain and IP rules remain available in generated system PAC, with no effect on TUN forwarding.

The retired patched core and local Rust bridge have been removed; their earlier committed versions remain in Git history. Their packet lifecycle changes, metrics and per-flow routing are not present in the released CLI and are not active in this application. Old direct-route journals must be recovered by the old installed helper before updating.

See [the development guide](DEVELOPMENT.md) for distribution, migration and verification constraints.
