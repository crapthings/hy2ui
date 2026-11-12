# Third-party notices

Hy2UI first-party code is MIT licensed. Dependencies retain their own copyright notices and licenses.

- The bundled protocol core is the unmodified [hysteria-rust v0.1.0-rc.6 CLI](https://github.com/crapthings/hysteria-rust/releases/tag/v0.1.0-rc.6), distributed under the [upstream MIT license](https://github.com/crapthings/hysteria-rust/blob/v0.1.0-rc.6/LICENSE). Copies of its license and notices are bundled under `App/Resources/hysteria-rust-*`. Its dependencies retain the [upstream third-party notices](https://github.com/crapthings/hysteria-rust/blob/v0.1.0-rc.6/THIRD_PARTY_NOTICES.md).
- XcodeGen is downloaded for development by `Scripts/bootstrap-tools.sh`; it is not bundled as application runtime code. See [XcodeGen's license](https://github.com/yonaskolb/XcodeGen/blob/master/LICENSE).
- Apple SDKs and system frameworks are supplied by the development environment and operating system, not redistributed in this repository.

- Navigation and dashboard icons are from [IconMCP](https://iconmcp.com/), Copyright (c) 2026 UI8, under the MIT License. Pinned SVG sources and their [license](Design/Icons/IconMCP/LICENSE.txt) are kept in `Design/Icons/IconMCP/`; a copy of the license is bundled with the application.
