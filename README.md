# Hy2UI

A macOS interface for the [hysteria-rust](https://github.com/crapthings/hysteria-rust)
client, with server management, local HTTP/SOCKS5 proxies, system proxy integration
and administrator TUN capture. Supports light/dark appearance and Chinese/English.

## Current support

System-proxy rules use Rust native routing. Exact macOS process-name/path rules
require a capable development core and apply to local HTTP/SOCKS TCP only.
macOS TUN rule routing, Fake DNS and Network Extension are not enabled. Legacy
PAC recovery remains supported, but PAC is no longer offered by the interface.

The Swift administrator helper installs separately from the on-demand utun
interface. Supporting development cores track interface ownership and route
recovery; unresolved recovery is reported rather than discarded.

## Build

Requires macOS 14+, full Xcode and Python 3:

```sh
git clone https://github.com/crapthings/hy2ui.git
cd hy2ui
python3 Scripts/setup-signing.py
Scripts/build.sh debug arm64
open .build/xcode/Build/Products/Debug/Hy2UI.app
```

Normal builds verify and bundle official v0.1.0-rc.7 binaries; no Rust compiler is
needed. Newer core features use an explicit commit/hash-pinned Debug manifest.
See the [development guide](docs/DEVELOPMENT.md),
[Fake DNS prerequisites](docs/macos-fake-dns-integration.md) and
[remaining work](docs/ROADMAP.md). Source and development capabilities can exceed
the pinned release; a source checkout alone does not update an installed backend.

## Contribute and license

Report problems through [GitHub issues](https://github.com/crapthings/hy2ui/issues).
First-party code uses the [MIT License](LICENSE). Dependencies retain their own
licenses; see [third-party notices](THIRD_PARTY_NOTICES.md).
