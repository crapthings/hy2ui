# Remaining work

Implemented behavior is documented in [the development guide](DEVELOPMENT.md). This list contains outstanding work, not a history of shipped features.

## Upstream CLI integration

- Expose additional supported client configuration and CLI operations as needed.
- Connect additional supported routing/control and telemetry APIs; keep core changes in hysteria-rust.
- Handling physical-interface and resolver changes without requiring a reconnect.

## Lifecycle and distribution

- Clean-machine installation, update, removal and recovery checks for the administrator service.
- Developer ID / notarized distribution.
- Safe detection and recovery of orphaned official CLI proxy children after a UI crash.
- Launch at login. Remembered capture switches already restart the selected outbound when Hy2UI opens.
- Automatic recovery of system proxies after an app crash, including services added during a session.
- Long-duration real TUN throughput, memory pressure, sleep/wake and network-change validation initiated by the user.

## Product

- Subscriptions and server import workflows.
- A defined kill-switch policy and its recovery behavior.
- Native universal builds and Intel validation.

Automated checks must not install helpers or change the host's proxy, DNS, TUN or routes. Real network changes remain user initiated.
