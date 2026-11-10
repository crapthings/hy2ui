# Routing roadmap

The current release keeps System Proxy and Enhanced Mode independent. The Dashboard reports connection metrics, and Network Activity reports system process counters. Neither page changes routing behavior.

## Local network bypass

Add explicit IPv4 and IPv6 network exclusions, with a setting to bypass local networks. Cover private ranges, link-local addresses, local services, and the physical route to the server. Preserve existing route ownership and recovery rules. Test route plans without changing the developer's network.

## Domain bypass

Add domain and suffix rules with a clear default action: Direct or Proxy. TUN packets normally contain an IP address rather than the original domain, so matching needs a reliable DNS-to-flow mapping. Account for cached results, shared IPs, IPv6, and encrypted DNS before promising domain-level behavior. Do not infer a domain from an IP alone.

## Process bypass

Local Enhanced Mode now supports bounded process-path and executable-name rules through public SDK socket metadata. Unknown owners stay proxied. The `nettop` activity table remains observational. Future work includes stable application identities, better attribution coverage for protected processes, and interface-change handling.

## Rule behavior

Keep rule order visible and deterministic. Show the matched rule when diagnostics are requested. Changes during a connection need a defined apply or reconnect flow. Direct routing must not create a loop for the Hy2 server connection, and stopping must restore only settings owned by Hy2UI.

Each stage needs tests for IPv4 and IPv6, reconnects, DNS changes, local access, cleanup, and conflicts with another network client. PAC now covers domain suffixes and local literal IPs for System Proxy. TUN domain rules and global local-network exclusions remain planned.
