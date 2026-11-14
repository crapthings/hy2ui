# 项目约束

- 默认仅通过代码检查验证；只有用户明确要求时才编译构建，不在每次修改后自动 build。
- 每个第一方顶层声明都应有一句话说明职责的注释；如果无法用一句话合理说明，应先按职责拆分代码。
- 不得使用 Browser Use、Computer Use、CUA 或图片查看。只有用户明确要求时，才可启用对应功能。
- 不要为了验证而直接修改当前机器的系统代理、路由或 VPN 设置；本地回环集成测试可以运行。
- SwiftUI 主程序是官方 CLI 的 UI，支持本地管理员 TUN 后台；协议核心仅使用固定版本、固定 SHA-256 的 hysteria-rust 官方预编译二进制，不使用源码 patch，不编译 Rust。
- 管理员后台安装、卸载和真实 TUN/DNS/路由操作只由用户通过界面或终端主动发起，验证中不得自动执行 sudo、LaunchDaemon 安装或系统网络变更。
- 联调例外：Debug 可通过 `HY2_CLI_DEV_MANIFEST` 使用在独立 hysteria-rust 仓库编译的测试二进制，必须固定完整提交号、架构和 SHA-256；Release 禁用该入口。hy2ui 本身仍不编译 Rust、不使用历史源码补丁。
- `Scripts/prepare-cli.py` 是协议核心版本与校验值的唯一构建来源。旧 Vendor 子模块、源码补丁、Native 桥接和 PacketTunnel 实现已移除，不得重新用于应用构建。`Experiments/` 仅用于独立原型，不属于应用构建。
- `project.yml` 是 Xcode 项目配置源；变更后运行 XcodeGen。禁止提交签名账户配置、凭据或生成的构建文件。

## Network Extension 优先开发（用户于 2026-11-14 明确授权）

- 新增独立的 macOS System Extension 与可选 NE 应用目标；原 CLI/管理员 TUN 路径保留。
- NE 内可使用独立 hysteria-rust 仓库产出的预编译 Packet ABI 静态库；Hy2UI 不编译 Rust。
- `Scripts/prepare-ne-core.py` 是 NE 库唯一构建入口，Debug 显式校验完整提交号、ABI、架构及静态库/头文件哈希；正式库发布前拒绝 Release。
- 经审查的实验适配器可提升到 `NetworkExtension/`；应用构建不直接引用 `Experiments/`，不恢复已退役的 Vendor、Native 或源码补丁。
- 当前只做代码及离线验证。默认构建禁止真实接管；启用需显式构建开关、有效 Apple 权限/签名及用户操作。
- 不自动激活扩展、保存 VPN 配置、启动 VPN 或修改主机网络；无有效签名时不得宣称已完成系统验收。
