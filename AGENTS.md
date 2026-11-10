# 项目约束

- 默认只通过代码检查、命令行编译和测试验证。
- 每个第一方顶层声明都应有一句话说明职责的注释；如果无法用一句话合理说明，应先按职责拆分代码。
- 不得使用 Browser Use、Computer Use、CUA 或图片查看。只有用户明确要求时，才可启用对应功能。
- 不要为了验证而直接修改当前机器的系统代理、路由或 VPN 设置；本地回环集成测试可以运行。
- SwiftUI 主程序支持本地管理员 TUN 后台，并保留 Network Extension System Extension；协议核心使用固定版本的 hysteria-rust。
- 管理员后台安装、卸载和真实 TUN/DNS/路由操作只由用户通过界面或终端主动发起，验证中不得自动执行 sudo、LaunchDaemon 安装或系统网络变更。
- `Vendor/hysteria-rust` 是固定提交的 Git submodule，不直接修改。适配代码在 `Patches/` 和 `Scripts/prepare-core.py`，生成副本在 `.build/core/`。
- `project.yml` 是 Xcode 项目配置源；变更后运行 XcodeGen。禁止提交签名账户配置、凭据或生成的构建文件。
