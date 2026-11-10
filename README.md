# Hy2UI

Less noise. A little more room.

A small window for macOS, built to keep things simple and leave space to breathe.

## Made for everyday use

Light and dark, in step with your desktop. English and Chinese, at your choice. Keep your favorites close and the rest one click away.

## Build from source

You need macOS 14 or later, the full Xcode app, Rust, and Python 3.

```sh
git clone --recurse-submodules https://github.com/crapthings/hy2ui.git
cd hy2ui
python3 Scripts/setup-signing.py
Scripts/build.sh
open .build/xcode/Build/Products/Debug/Hy2UI.app
```

Setup creates a local signing identity outside the repository. Later builds reuse it. Keep the private signing files safe. The first build downloads dependencies.

Hy2UI is still taking shape and is currently available as source. See the [development guide](docs/DEVELOPMENT.md) for details about the code, tests, and signing.

## Make it better

Found a problem or have an idea? [Open an issue](https://github.com/crapthings/hy2ui/issues). Contributions are welcome.

## Thanks and license

Built with [hysteria-rust](https://github.com/crapthings/hysteria-rust) and the work of its upstream contributors.

First-party code uses the [MIT License](LICENSE). Dependencies keep their own licenses. See the [third-party notices](THIRD_PARTY_NOTICES.md).
