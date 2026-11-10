# Third-party notices

Hy2UI first-party code is MIT licensed. Dependencies retain their own copyright notices and licenses.

- The protocol core is [hysteria-rust](https://github.com/crapthings/hysteria-rust), pinned as a Git submodule at `f364dab51b3908d5c158309b1eba54445628641a`. Its [license](Vendor/hysteria-rust/LICENSE) and [third-party notices](Vendor/hysteria-rust/THIRD_PARTY_NOTICES.md) remain in the submodule.
- `Patches/` contains adaptations to that core; the original copyright and license continue to apply to derived code.
- Rust dependency versions are recorded in `Native/Cargo.lock`; vendored dependency notices remain with the upstream source.
- XcodeGen is downloaded for development by `Scripts/bootstrap-tools.sh`; it is not bundled as application runtime code. See [XcodeGen's license](https://github.com/yonaskolb/XcodeGen/blob/master/LICENSE).
- Apple SDKs and system frameworks are supplied by the development environment and operating system, not redistributed in this repository.
