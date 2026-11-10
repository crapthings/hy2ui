# Local TUN TCP investigation

The November 10 report describes a healthy initial connection followed by slower browsing and repeated generic TCP transfer errors. This review focuses on the client TUN path. It does not require changes to the remote server.

## Evidence and limits

`Native/Cargo.lock` selects `netstack-smoltcp 0.2.4`. Its TCP and device source files match the locally cached crate archive. The core configures this library in both the real interface path and the embedded packet path.

A new probe reproduces stream creation and close behavior using only synthetic IPv4/TCP packets in memory. It never opens an OS socket, creates an interface, changes DNS, or installs routes. Run:

```sh
python3 Scripts/diagnose-tun-stack.py
```

The script selects the stack version from the native lockfile, copies that lockfile into an ignored diagnostic workspace, and runs Cargo offline. It writes `.build/tun-stack-diagnostics/report.json`. It does not edit the project lockfile, the pinned submodule, or the Cargo registry sources.

Observed output:

```text
retransmitted SYN creates extra accepted stream: true
extra accepted streams after 10 identical SYN retransmissions: 10
original stream readable after duplicate SYN: Ok(Ok(5))
write shutdown completed after FIN acknowledged: false
write shutdown completed after both peers closed: false
shutdown completion after both FINs: Ok(Ok(())), additional wait 9.90s
```

These are client-side reproductions. They establish concrete defects or undesirable lifecycle behavior, but do not establish the exact cause of the reported throughput degradation. No long-running real TUN benchmark or fault-time resource capture was performed.

## 1. Retransmitted SYN creates duplicate streams

`netstack-smoltcp/src/tcp.rs`, `TcpListenerRunner::handle_packet`, creates a new socket, control buffers, accepted stream and creation message on every SYN without ACK. It does not first check whether the same flow already has a pending handshake. Ten identical SYN retransmissions produced ten extra accepted streams while the original stream remained readable.

The Hy2UI-prepared core immediately spawns `forward_tcp` for every accepted stream, in both `serve` and `serve_packets`. Thus retransmissions can also create unnecessary QUIC tunnel requests and relay tasks. Each library TCP socket allocates receive/send socket buffers and receive/send control buffers. The configured default is 327,660 bytes each, or approximately 1.25 MiB of buffer capacity per socket. Capacity is not a measurement of resident memory: zeroed allocations can be lazily committed by the OS.

The library scans its socket set during each runner iteration. Extra sockets therefore add both memory capacity and polling work. This gives a plausible accumulation mechanism under packet loss, independent of server correctness. Its impact during the user's session has not yet been measured.

Recommended fix: suppress duplicate stream creation by full TCP tuple while still delivering retransmitted SYN packets to the original state machine. Release ownership only when the original socket is retired. Cover retries, RST, legitimate tuple reuse, IPv4 and IPv6 with regression tests.

## 2. Write shutdown waits for full TCP closure

`TcpStream::poll_shutdown` requests write closure, but returns ready only after the control's send state becomes `Closed`. The runner sets that state when the entire smoltcp socket becomes `Closed`, rather than when the write half has completed its required flush and FIN behavior.

The probe observed pending shutdown after FIN acknowledgement and after both peers sent FIN, followed by approximately ten seconds of additional waiting. smoltcp's ten-second TIME-WAIT retention is normal protocol behavior; tying the application's write-shutdown future to full socket retirement is the problem. A peer that leaves its read/write lifecycle incomplete can extend retention further; the library configures a two-hour TCP timeout.

Hy2UI uses `tokio::io::copy_bidirectional`, which drives half-close futures. This delayed completion can retain relay tasks beyond useful transfer work. It is not proof that every logged TCP error comes from this path.

Recommended fix: separate write-half completion, receive EOF, aborted-stream cleanup and protocol-level socket retirement. Do not remove TIME-WAIT indiscriminately or return shutdown success before queued bytes are safely handled. Test remote-first FIN, local-first FIN, payload followed by FIN, unread data, RST and cancellation.

## 3. Packet-count setting is mistaken for a byte-buffer setting

Both core stack builders call `.tcp_buffer_size(64 * 1024)`. In this library, that value is passed to `tokio::sync::mpsc::channel` as an item count. The actual byte-window controls are `tcp_recv_buffer_size` and `tcp_send_buffer_size`.

The current setting allows 65,536 queued TCP packets. At 1,400 bytes per packet, their payload alone could approach 87.5 MiB when full; this is a capacity estimate, not startup allocation or an observed queue depth. Large queues can delay backpressure and increase latency under overload.

The virtual device also uses an unbounded ingress queue. Bounding only the outer stack queue therefore does not bound the entire pipeline.

Recommended fix: size packet queues explicitly in packets, keep TCP byte-window settings separate, and implement bounded backpressure throughout the device path. Queue depth and high-water marks must be observed under sustained mixed TCP/UDP traffic before selecting final capacities.

## 4. Missing resource bounds and insufficient diagnostics

The relay spawns TCP tasks without an explicit concurrency bound or a client-side deadline around opening a QUIC TCP tunnel. A peer-side limit or stalled target response can therefore leave additional startup tasks pending. UDP flow cleanup also walks the full flow map for each incoming datagram; its cost needs separate mixed-traffic measurement.

The Swift parser maps all `TUN TCP ... transfer failed:` messages to one event and discards their underlying error category. Reset, broken pipe, timeout, protocol failure and a closed QUIC connection are consequently indistinguishable in the current UI. Some failures can be ordinary application cancellation. The core also suppresses repeated errors for five seconds, and the UI does not expose the suppressed count.

Recommended diagnostics: allowlisted error kind and transfer phase, active/pending/peak TCP counts, queue occupancy and high-water marks, close-state counts, QUIC RTT/loss/reconnect counters, and worker CPU/RSS during a slow interval. Keep payloads, credentials and raw peer error messages out of user logs; expose validated destination addresses only in optional diagnostic details.

## Fix and validation order

1. Add the TCP regression coverage that is currently missing from the bridge's packet roundtrip tests; those currently test UDP packets and QUIC telemetry.
2. Fix duplicate SYN creation and half-close/aborted-stream cleanup in a reproducible client-side dependency adapter.
3. Correct packet-count configuration, bound queues and pending work, and add safe resource counters.
4. Run loopback TCP byte-integrity tests, connection churn, retransmissions, RST, stalled peers and sustained mixed traffic; check that resource use returns to baseline.
5. Build an isolated app and let the user initiate helper installation and real TUN testing, followed by a longer throughput run.

Keep `Vendor/hysteria-rust` unchanged. Any dependency adaptation must be explicit, version-pinned and prepared through the project's adapter workflow. The server does not need a redeployment for these client-side changes. The initial investigation added the probe and report without deploying changes. The following remediation is now implemented in the client adapter.

## Dependency update check

The upstream release check found `tun-rs 2.8.18`, `netstack-smoltcp 0.2.5`, and `smoltcp 0.14.0`, compared with the current lockfile's 2.7.6, 0.2.4, and 0.12.0. The [netstack changelog](https://github.com/cavivie/netstack-smoltcp/blob/main/CHANGELOG.md) describes 0.2.5 as an update to smoltcp 0.14. Its manifest raises the Rust minimum to 1.91. The [smoltcp changelog](https://github.com/smoltcp-rs/smoltcp/blob/main/CHANGELOG.md) includes zero-window probes, retransmission timer fixes, FIN retransmission fixes, ACK/window handling, MSS handling, and congestion-control improvements across 0.13 and 0.14.

The exact same probe was run in a separate ignored workspace with `netstack-smoltcp = "=0.2.5"`; its resolved lockfile confirms `smoltcp 0.14.0`. Ten repeated SYN packets still produced ten extra streams, and shutdown still waited approximately 9.90 seconds after both FINs. Thus the update does not resolve these two wrapper-level findings. It also cannot correct the application's packet-count setting.

Updating the stack remains useful for the underlying TCP improvements, but needs the wrapper fixes and regression tests as part of the same client-side work. `tun-rs` should be evaluated separately for API and platform compatibility. This check did not update the project's lockfile, submodule, installed helper, or system networking.


## Implemented remediation

The prepared dependency versions are now `tun-rs 2.8.18`, `netstack-smoltcp 0.2.5` and `smoltcp 0.14.0`. The netstack crate is extracted from its checksum-pinned release archive into the immutable prepared core, then patched using `Patches/netstack-smoltcp-0.2.5.patch`. The Cargo registry sources and Git submodule remain untouched.

Tuple leases suppress duplicate accepted streams while preserving SYN delivery to the original socket. The lease stays with the protocol socket until retirement, including TIME-WAIT. Abandoned streams request an abort and reset; ordinary half-close remains separate. Write shutdown completes once the control buffer has drained into the protocol socket and FIN closure has begun; the protocol socket retains its own queued bytes and normal close state.

The internal ingress, accepted-stream and socket-creation channels are bounded. Egress backpressure waits on queue capacity instead of spinning. Protocol socket count is capped at 1,024. The core TCP packet queue now holds 512 packets, rather than 65,536; TCP byte windows are unchanged. TCP relays are owned by a JoinSet, limited to 256 active tasks, and give tunnel creation a 15-second deadline. Excess TCP work is reset rather than queued indefinitely. UDP flow count is capped at 1,024 with 64 queued datagrams per flow, and closed-flow cleanup runs periodically rather than on every packet.

The parser now distinguishes allowlisted timeout, reset, broken pipe, early EOF, generic I/O and capacity errors without forwarding destination addresses or arbitrary upstream text. This improves diagnosis but does not make every reset an outage.

The updated probe reports zero additional streams for ten repeated SYNs and no extra TIME-WAIT wait in write shutdown. New regression tests cover both IP families, client-first and server-first half-close, a 256 KiB binary response, abandoned-stream reset, and 1,028 repeated aborted connections reusing one tuple. A separate test sends a 16 KiB binary upload and receives a 256 KiB response through the real packet engine and a certificate-pinned loopback Hy2 server for both IP families.

`python3 Scripts/diagnose-tun-stack.py` now tests the prepared client adapter by default. Add `--upstream` to compare the unpatched release in an isolated workspace. Long-duration real TUN throughput and memory-pressure testing still require a user-initiated helper update and connection.


## Detailed follow-up evidence

Subsequent failures can now be inspected by target IP/port, direct/proxy route, TCP/UDP protocol, failure phase and recognized error category. This is a diagnostic improvement rather than another presumed network fix. The log page exposes a details toggle and explicit Copy action; typed details stay in memory and do not retain raw peer messages or credentials. Unknown causes remain marked as unknown. New helper-generated details require a user-initiated helper update; old summary-only records cannot be expanded retroactively.

## DIRECT egress alongside TUN

A bound DIRECT socket still needs a route scoped to its physical interface. On a host with only an unscoped physical default, the TUN split defaults can leave an interface-bound socket without a usable route. The adapter now plans a scoped copy of the physical default for each selected, available address family. It does not add per-destination global bypasses. Pure route-plan tests cover family selection, existing scoped defaults and preservation of replacement routes. Automated checks do not install real routes; live verification requires a user-initiated helper update and reconnect.

The worker keeps an ownership journal in the protected helper directory. Normal shutdown and supervisor recovery remove only exact route identities; the next helper startup also attempts recovery after a crash. Existing scoped routes are never journaled as owned. If the host has no physical IPv6 exit, DIRECT IPv6 reports that limitation explicitly. The server can still carry IPv6 through proxied flows.

Targets in `198.18.0.0/15` receive a diagnostic hint because this reserved benchmark range is commonly used for synthetic DNS mappings. The hint does not prove which application supplied the address and does not flush caches or change DNS settings.
