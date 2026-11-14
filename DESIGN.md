# Hy2UI product and interface design

## Product model

Follow Surge's separation of policies, routing rules and traffic capture. This
is the intended product model, not a claim that the current CLI implements all
of it. Runtime support is documented in `docs/DEVELOPMENT.md`.

- **Policy / 策略** manages proxy servers and policy groups. A server is a named
  Hysteria endpoint; a group exposes a stable policy identity and chooses among
  its members. DIRECT and REJECT are built-in actions, not editable servers.
- **Rule / 规则** manages ordered traffic routing. A rule has a matcher and a
  target policy: DIRECT, REJECT, a server or a group. First match wins; FINAL is
  the last fallback rule and references a policy. FINAL is not itself a server
  or a group and must not become a recursive outbound reference.
- **增强模式 / Enhanced Mode** means TUN/VIF capture. It determines how traffic
  enters the engine, not which policy wins. Administrator TUN and the experimental
  Network Extension are implementations of capture, not different routing modes.
- **系统代理 / System Proxy** is the other capture entry. Rule-based, global
  proxy and direct are routing modes, independent of the capture switches.

Target data flow:

```text
System proxy or Enhanced Mode (TUN)
  -> selected routing mode
  -> ordered rules and FINAL (in rule mode)
  -> policy (DIRECT / REJECT / server / group)
  -> group's selected member, where applicable
  -> outbound connection
```

A complete implementation must give both capture paths the same routing and
policy semantics. The current system-proxy path uses native Rust routing, while macOS TUN
remains proxy-only. Stored rule models must not be presented as executable
features until the selected core and capture path support them.

## Policy page

Keep the Policy name in navigation. Organize this page into **policy groups**
and **servers**, with distinct add/edit actions. Show each group's kind, members
and actual selected member. Editing a server changes its connection definition;
selecting a group member changes that group's choice, not an unrelated global
FINAL setting. Reference servers and groups by stable IDs so renaming preserves
rules and memberships.

Implement manual selection first. Add automatic testing, fallback and balancing
only with real execution and health-check support. Do not show fabricated
latencies or an automatic group that behaves as an unlabelled manual group.
Deletion must identify affected rules/groups and require a valid replacement or
explicit removal of those references. Define cycle handling before allowing
nested groups.

## Rule page

Use a compact ordered table: enabled, order, type, match value, target policy,
and comment. Put FINAL last. The policy picker offers supported built-ins,
servers and groups, rather than only DIRECT or the current FINAL endpoint.
Rule order must match actual engine order. Editing comments does not change
runtime behaviour. Separate saved configuration from applied configuration;
only report successful application after the core acknowledges it.

Unsupported matchers or target kinds cannot be silently accepted as effective
rules. Preserve previously saved records, identify unsupported entries and
prevent unsupported application. Unknown hit counts are unavailable, not zero.

## Overview and navigation

Overview answers: is the service running, how is traffic captured, which routing
mode is active, and is intervention needed? Keep capture controls and current
state together; use Policy and Rule pages for detailed management. Avoid a large
standalone FINAL card that suggests FINAL is the whole policy system.

Retain Policy and Rule as separate destinations. Put processes/connections,
logs and settings in diagnostic or maintenance destinations. Scope search to
the current searchable page; typing into search must not unexpectedly navigate
from another page. Concrete visual styling can be refined independently of
these semantics; do not treat a Surge-like workflow as a requirement to copy
Surge's visual assets.

## Implementation boundaries

The current GUI supports manual groups and capability-gated automatic FINAL
groups. Automatic policies include latency selection, priority fallback and
stable target-affinity balance. They use independently configured member lines;
they do not imply per-packet balancing or port-hopping support. Automatic groups
do not yet expose their actual selected-member telemetry.

The visible address-rule editor still supports DIRECT, REJECT and FINAL; process
shortcuts support DIRECT. Connecting every ordered rule to an explicit server or
group remains outstanding. Native routing and automatic groups are gated by the
bundled executable's capability report, not its version name. macOS TUN rule
routing remains blocked.

Keep runtime details in [the development guide](docs/DEVELOPMENT.md), outstanding
work in [the roadmap](docs/ROADMAP.md), and the promoted packet adapter's capture
and deployment limits in [the NE guide](docs/NETWORK-EXTENSION.md). The original
adapter under `Experiments/` remains a test fixture, not an application input.

## Shared interaction requirements

Use `AppTheme` and `AppIcon` consistently. Keep Chinese/English structure,
light/dark appearance, keyboard operation, focus indicators and accessibility
labels. Do not use color alone for state. Keep errors, recovery actions,
unsaved/applied-state differences and deletion confirmations visible. Show only
real measurements; system process counters and core traffic totals have different
scopes. Never activate system proxy, TUN, DNS or routes merely to preview a screen.

## References

- [Surge policies and rule execution](https://manual.nssurge.com/getting-started/how-surge-works.html)
- [Surge policy groups](https://manual.nssurge.com/policy-groups/overview.html)
- [Surge Enhanced Mode](https://manual.nssurge.com/features/enhanced-mode.html)
