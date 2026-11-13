# macOS Fake DNS integration boundaries

Status: design and prerequisites; not enabled. The current macOS core advertises
`fake_dns=false` and `routing_supported=false`. Do not remove those guards merely
to let a GUI-generated configuration pass validation.

## Startup changes

A helper status request now verifies that no worker, DNS receipt, legacy route
receipt, native journal, or held native lease requires attention. It does not call
cleanup, including on its error path. A clean idle query launches no core process.
Helper startup, explicit stop, and start retain their recovery gates.

Startup logs report monotonic durations for recovery checks, capability probing,
configuration generation, interface/route readiness, server authentication,
identity verification, system DNS application, and total activation. Core readiness
observations are elapsed since process launch; they are not isolated per-stage
execution times. The connected state still requires both interface readiness and
server authentication. Record actual timings before introducing capability caches
or retaining native interfaces across sessions.

## Existing reusable components

- Rust `fake_dns.rs`: stable A/AAAA mappings, private persistent cache, exclusive
  cache lease, bounded capacity, and no address recycling to another hostname.
- Rust `tun.rs`: TCP/UDP port-53 interception when Fake DNS is enabled, fake target
  translation, and DNS-over-TCP support.
- Hy2UI `PrivilegedDNS`: journaled system resolver changes and ownership-aware
  restoration. `LocalDNSResolvers` preserves local resolver behavior.
- Native route journal and session identity remain responsible for owned routes
  and native interface release.

## Blocking core work

The protected-egress configuration validator now accepts macOS only with zero
socket marks and a non-loopback, non-capture interface. Linux retains its nonzero
mark requirement. Full routed-TUN admission has a separate Linux-only guard, so
this primitive work does not enable macOS Fake DNS or routed TUN. Route validation
still describes Linux-style full strict capture. A macOS implementation needs its
own route contract; simply removing the admission guard is insufficient.

1. Verify physical-interface binding for the Hysteria transport, protected DNS
   upstreams, and direct TCP/UDP sockets, with no recursive capture.
2. Define macOS capture/bypass routes and keep direct/bypass decisions consistent
   with fake target translation. Preserve server bypass and route receipts.
3. Interface addresses are now separated in source: GUI IPv4 is
   `100.100.100.101/30`, matching the core default, and IPv6 remains
   `fd72:6832::1/126`. The former GUI `198.18.0.1/30` collided with the core's
   synthetic DNS endpoint. Core configuration validation now rejects overlapping
   connected subnets whenever Fake DNS is configured, including supernets of
   the pools. macOS now checks both planned interface prefixes against existing non-default
   routes before creating a native device or journal. Host routes, scoped entries,
   covering supernets, IPv4 and IPv6 are included; default and disjoint routes are
   allowed. A conflict produces `tun_address_conflict`. With Fake DNS configured,
   synthetic-pool route checks also run before device creation. Full routed-TUN
   admission is still closed while the macOS capture/egress contract is unfinished.
4. Use a fixed helper-owned cache path and private permissions. Do not expose an
   arbitrary root-writable cache path through unprivileged IPC.
5. Preserve mappings across restart; never clear the cache merely to make startup
   pass. Handle exhaustion, corrupt cache and active leases explicitly.
6. Restore system DNS before stopping its synthetic responder; preserve unresolved
   DNS and route records on failure. Test crashes and ownership changes separately.

## GUI/helper contract

The core owns DNS packet handling, allocation, persistence and domain restoration.
The helper owns macOS resolver settings, installation paths, lifecycle and recovery.
The GUI exposes only bounded settings after a positive capability check. Browser
DoH traffic can bypass system DNS and will not automatically gain a domain mapping;
unknown synthetic addresses must fail safely rather than be forwarded to the server.

## Acceptance before enabling

- Offline validation and unprivileged packet tests cover A/AAAA, TCP/UDP DNS,
  cache restart/exhaustion, resolver failure, synthetic address conflicts, and
  direct/proxy/reject decisions.
- A protected macOS egress test proves the transport and DNS cannot recurse into
  the new tunnel, and physical-interface loss triggers safe shutdown.
- User-initiated native testing covers clean start/stop, crash recovery, local
  names, browser DoH, changed network service, stale cached synthetic answers,
  and DNS restoration without overwriting a new owner.
- Only then advertise macOS Fake DNS support and enable GUI configuration.

## Verification tools

Core tests cover synthetic-pool overlaps, scoped and unscoped route conflicts,
protected IPv4/IPv6 TCP/UDP sockets, DNS reply validation and mapping persistence.
These do not prove that full native capture cannot recurse into its own tunnel.

Use `Scripts/diagnose-physical-egress.py --interface en1` while the intended capture
is active to inspect ordinary/scoped routing and verified interface-bound sockets.
It writes a private report, never retries unbound and does not change routes or DNS.
A connection failure alone does not identify recursion: filtering or unavailable
IPv6 can also fail. This probes Darwin primitives; actual core/native integration
and crash recovery still require user-initiated acceptance.
