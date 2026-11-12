# macOS Network Extension boundary

This is a design and verification record for the isolated prototype, not a claim
that macOS capture is implemented or safe to enable.

## Provider choice and distribution

Apple describes `NEPacketTunnelProvider` as delivering IP packets to a provider
for tunnelling to a remote network, and documents full-tunnel VPN as a supported
use. Its [TN3120](https://developer.apple.com/documentation/technotes/tn3120-expected-use-cases-for-network-extension-packet-tunnel-providers)
also says not to use a packet tunnel to selectively claim traffic and proxy the
rest elsewhere; for macOS it points to `NETransparentProxyProvider` in that
scenario. TN3120 separately discourages using packet tunnels to intercept all DNS.

Our current Rust host packet interface terminates TCP/UDP from raw IP packets and
forwards the resulting flows through Hysteria; it does not send the original IP
packets for injection into a remote IP network. Whether this particular proxy-only
use fits Apple's intended packet-tunnel model is **not established** by the
loopback tests or by this document. Review it against TN3120 and, where needed,
ask Apple before treating this as a distributable product. If a transparent
proxy is selected, it exposes flow APIs rather than `NEPacketTunnelFlow`; the
current raw-IP bridge is not a drop-in transparent-proxy implementation.

For macOS distribution outside the App Store, Apple's
[TN3134](https://developer.apple.com/documentation/technotes/tn3134-network-extension-provider-deployment)
lists the packet tunnel provider as a system extension. A system extension runs
in a global context rather than the logged-in user's app context. Signing,
Network Extension entitlements, activation and access to configuration and
credentials must be designed for that context. This prototype sets up none of
those requirements and does not change Hy2UI's CLI-only app build policy.

## Server endpoint and loop avoidance

The Rust bridge's external packet mode rejects `tun.egress`; the current
protected-egress implementation and `quic.sockopts.bindInterface` are
Linux-only. Therefore, a successful connection made before installing tunnel
settings is **not proof** that packets after a route change, reconnect or network
handover will avoid the tunnel. The experimental provider consequently rejects
all starts with `protectionUnverified` and never installs settings.

A candidate for a first controlled experiment is to resolve one server address
before capture, pass that numeric address to the core, preserve the original TLS
SNI, and use a single port without Realm discovery or port hopping. This narrows
the endpoints that need protection; it does not itself protect the UDP socket,
prove a DNS policy, or establish safe behaviour when an interface disappears.
`ExperimentalEndpointCandidate` checks this narrow numeric address/one-port
shape, a nonempty TLS server name, and the corresponding /32 or /128 host prefix;
it rejects loopback, link-local, multicast, mapped IPv4 and the legacy synthetic
IPv4 range. It does not resolve names, validate the TLS identity, alter a core
configuration, install a route, or prove the actual socket path. The candidate
is not wired to the guarded provider or enabled by the prototype.

Apple's [routing documentation](https://developer.apple.com/documentation/networkextension/routing-your-vpn-network-traffic)
explains that included/excluded routes interact with system routes, interface
scoping, and `enforceRoutes`. Apple also notes in its
[NetworkExtension session](https://developer.apple.com/videos/play/wwdc2025/234/)
that `includeAllNetworks` ignores specified excluded routes. An excluded server
host route alone must not be assumed sufficient under every VPN configuration.
The intended combination of settings and the QUIC socket's actual path need
platform-specific verification on supported macOS versions, including IPv4,
IPv6, reconnect, interface handover and collisions with other VPNs. Avoid
modifying the system route table outside Network Extension merely to compensate.

## DNS, lifecycle and verification

System DNS settings, endpoint bootstrap and ordinary DNS queries entering the
packet core are separate concerns. The core currently forwards captured DNS as
ordinary TCP/UDP; it does not provide macOS Fake-IP DNS or a system DNS proxy.
Resolver behaviour, secure DNS, split DNS, local services and restoration after
failure need their own design and explicit testing. Do not infer leak protection
from successful TCP/UDP loopback forwarding.

The provider coordinator is tested with a fake system. It waits for an in-flight
settings installation before clearing and does not permit restart after failed
cleanup until a later explicit stop retries it. It cannot guarantee cleanup if a
system callback never arrives, the provider process crashes, or macOS terminates
it. Real entitlement, route/DNS, sleep/wake, coexistence and clean-machine
installation tests remain outstanding and must be explicitly initiated by the
user. No prototype test installs a system extension or changes the host network.
