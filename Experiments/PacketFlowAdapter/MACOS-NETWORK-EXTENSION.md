# macOS Network Extension boundary

The experimental provider remains deliberately guarded. The audited adapter and
coordinator have been promoted into the separate app targets under
`NetworkExtension/` and `NetworkExtensionHost/`; the app does not compile this
experimental directory.

The core now supports verified macOS physical-interface socket binding. Earlier
Linux-only binding notes are obsolete. Implementation, offline build, capture
gates and outstanding signed system acceptance are documented in
[Network Extension development](../../docs/NETWORK-EXTENSION.md).
