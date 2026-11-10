# Hy2UI

把纷扰留在窗外。
让每一次出发，都轻一点。

为 macOS 写的一扇小窗，简洁、克制，留一点呼吸的空间。

## 一点日常

浅色与深色，随昼夜更替。
中文与英文，按你的习惯。
常用的留在手边，其余的收进更多。

## 从源码开始

需要 macOS 14+、完整 Xcode、Rust 工具链与 Python 3。

```sh
git clone --recurse-submodules https://github.com/crapthings/hy2ui.git
cd hy2ui
python3 Scripts/setup-signing.py
Scripts/build.sh
open .build/xcode/Build/Products/Debug/Hy2UI.app
```

首次构建会下载依赖，并在仓库外生成固定的本地签名身份。后续构建复用同一证书；请妥善保管私有签名材料。

目前仍在打磨，提供源码构建。更多实现、测试与签名说明见[开发指南](docs/DEVELOPMENT.md)。

## 留一盏灯

遇到问题，或有一个更轻盈的想法，欢迎留下 [Issue](https://github.com/crapthings/hy2ui/issues)，也欢迎提交改进。

## 致谢与许可

感谢 [hysteria-rust](https://github.com/crapthings/hysteria-rust) 与所有上游贡献者。

第一方代码采用 [MIT License](LICENSE)。第三方代码保留各自的许可，详见[第三方说明](THIRD_PARTY_NOTICES.md)。
