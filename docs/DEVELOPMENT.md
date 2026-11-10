# 开发指南

Hy2UI 是原生 macOS Hysteria 2 客户端，采用 SwiftUI / AppKit 与固定版本的 Rust 核心。支持系统代理、本地管理员 TUN 后台，并保留 Network Extension 后端。

下列命令均在项目根目录运行。真实后台安装、卸载和系统网络变更由用户主动发起，自动验证只运行编译、模拟服务及本地回环测试。

## 界面与服务器

默认中文，设置中可切换 English。文本设置在失焦或回车后验证保存；服务器编辑保留显式保存。侧栏最多展示三个节点，按置顶、最近成功连接、最近添加排序，“更多”进入完整列表。列表支持添加、置顶、编辑、删除与手动 TCP 延迟测试。

窗口标题栏右侧提供增强模式和系统代理菜单，状态灯区分运行、待连接与关闭；后台安装和维护在设置中完成。首次引导可以跳过。后台安装状态仅显示红色“未安装”或绿色“已安装”。密码按服务器 UUID 存入 macOS 钥匙串。

## 架构

```text
SwiftUI / AppKit 主程序
├── 系统代理：SystemConfiguration → 本地 HTTP / SOCKS5 → Rust 子进程
└── 增强模式
    ├── 本地 TUN：受限 Unix socket → root 后台 → root Rust TUN worker
    └── Network Extension：System Extension → packetFlow ↔ Rust packet engine
```

- 本地增强模式复用 Rust 的 TCP/UDP TUN 核心，由管理员后台管理 DNS、进程和恢复；Network Extension 后端则由系统管理接口、路由和 DNS。
- 扩展使用有界输入/输出队列，串行管理 Rust 句柄，在输入队列满时暂停读取并重试。
- 建立隧道前解析服务端地址并保持 TLS SNI；组合模式将同一冻结地址交给代理与 TUN。本地 TUN 将该地址通过物理路由排除，避免连接被送回自身。服务器 IP 变化后需要重新连接。
- 密码保存在主程序钥匙串；系统代理客户端通过有大小限制的 stdin 管道接收配置，不创建明文凭据文件；不写入持久 VPN 配置。扩展仅通过启动消息接收凭据，因此此版本不支持系统设置直接启动、按需连接或重启后自动连接。
- 系统代理启动时先确认远端已连接、两个本地监听已建立且进程仍存活，再设置代理。设置前保存恢复记录；恢复时按 HTTP / HTTPS / SOCKS 的 enable、host、port 整组判断所有权，保留其他软件新修改的整组设置。
- Rust 代理子进程检测父进程退出并结束。主程序异常退出后，系统代理需要重新打开应用点击“恢复系统代理”；当前尚无独立守护进程自动恢复设置。固定的无认证 loopback 端口在进程退出后可能被其他本地进程抢占，因此此版本仍有本地端口接管窗口。

## 环境与构建

需要 macOS 14+、完整 Xcode、Rust 工具链及 Python 3。当前在 Apple Silicon / Xcode 26.6 上通过命令行编译；Intel 构建路径已提供但未验证。

```sh
git submodule update --init --recursive
python3 Scripts/setup-signing.py
Scripts/build.sh
```

脚本会下载校验过的 XcodeGen 2.46.0 到 `.tools/`，生成 Xcode 工程，然后执行 Xcode 构建，并用固定自签名证书封装本地产物资源完整性；Xcode 的前置构建阶段负责检查并编译 Rust 静态库、客户端、TUN worker 和 Swift 本地后台。构建产物保存在项目内部，私有签名材料保存在仓库外。首次构建会下载 Cargo 依赖。

产物：`.build/xcode/Build/Products/Debug/Hy2UI.app`。

Release / 指定 CPU 架构：

```sh
Scripts/build.sh release arm64
# Intel 需要先安装对应 Rust target：
rustup target add x86_64-apple-darwin
Scripts/build.sh release x86_64
```

目前每次生成单一架构应用，不自动生成 Universal Binary。

也可打开生成的 `Hy2UI.xcodeproj` 进行开发，Xcode 每次构建都会让 Cargo 检查完整依赖图。原生产物按配置和架构保存到 `.build/native/{debug,release}/{arm64,x86_64}/`，避免 Debug / Release 混用。`project.yml` 是工程配置源。

## 本机自用的本地增强模式

此后端不使用 Network Extension，无需 Apple Developer 账号、App Store 发布或关闭 SIP；创建 TUN、修改路由和 DNS 的权限来自你显式安装的管理员后台。主程序始终以普通用户运行。

开发者先用普通用户构建并打开应用：

```sh
Scripts/build.sh
open .build/xcode/Build/Products/Debug/Hy2UI.app
```

分发时只需携带完整的 `Hy2UI.app`，两个后台程序与安装逻辑都已内置，无需额外分发脚本。用户在应用中打开“增强模式（TUN）”，后端选择“本地 TUN（管理员授权）”，点击“安装后台”，在 macOS 的管理员授权窗口中确认，然后连接。应用不收集或保存管理员密码。后台区域提供安装、更新、修复与卸载操作，进入设置时自动检查状态；升级或卸载前先断开连接并确认资源清理完成。可以同时开启“系统代理”；连接期间锁定设置，断开后可重新选择。测试时先关闭 Surge 等其他软件的增强模式，避免多套 TUN 同时争抢路由。

经用户授权后，内置安装程序会将两个后台可执行文件复制到固定的 `/Library/PrivilegedHelperTools/dev.hy2ui/`，归 root 所有，并注册 `/Library/LaunchDaemons/dev.hy2ui.local-tun.plist`。后台只允许安装时的普通用户 UID 连接，应用校验后台 UID 必须为 root；IPC 不允许指定程序路径、文件路径或任意核心配置。凭据只经 Unix socket 和 stdin 在内存传递，后台不记录原始 worker 日志。

系统代理通过 macOS 网络设置授权修改偏好，应用运行期间复用授权对象；授权是否继续有效由系统决定。已安装的本地 TUN 后台连接不走该授权流程，仅使用 TUN 时可关闭“系统代理”。未修改的已保存节点在连接时不重复读写钥匙串。

后台空闲时不创建 TUN。连接后才应用 DNS 与路由，停止、客户端断开和服务重启时尝试恢复；DNS 有独立的 root-owned 恢复日志。未收到停止确认时，应用保留资源所有权并提供“重试清理”。若需要手动恢复：

```sh
sudo /Library/PrivilegedHelperTools/dev.hy2ui/hy2-local-tun-helper --recover-dns
```

该命令需要服务已停止；运行中的后台持有独占锁时，恢复命令会拒绝并发修改。正常情况下优先在应用中断开，或使用下方卸载脚本停止服务并恢复。

应用重新构建后，已安装的 root 副本不会自动更新；应用会比较后台摘要并显示更新入口，用户点击“更新”完成更新。安装前验证当前应用与内置程序签名，授权后的 root 暂存副本必须匹配授权前记录的 SHA-256，避免授权等待期间替换程序。

开发时重新构建正在运行的应用后，请先退出并重新打开新版，再安装或更新后台；运行进程和磁盘代码不一致时，安装前校验会拒绝继续。

本机开发请使用 `Scripts/build.sh` 完成资源签名，直接关闭签名的 Xcode 构建可能无法通过安装前校验。固定自签名版本可自行分发，但不具备 Developer ID 信任与公证；首次启动可能需要用户在系统设置的“隐私与安全性”中选择“仍要打开”。无需安装根证书或关闭 Gatekeeper。Developer ID 签名与公证仍是减少分发阻力的方式，无需上架 App Store。当前安装入口通过系统管理员授权执行内置安装程序，未采用 SMAppService。

以下终端脚本保留为高级恢复入口，正常安装、更新、卸载均可在界面完成。手动安装 Release 时可传入应用路径：

```sh
sudo Scripts/install-local-tun-helper.sh .build/xcode/Build/Products/Release/Hy2UI.app
```

卸载后台并恢复 DNS：

```sh
sudo Scripts/uninstall-local-tun-helper.sh
```

升级和卸载都先停止旧服务并尝试恢复 DNS；恢复失败就保留已安装文件供重试。不会删除节点配置或钥匙串凭据。本轮开发验证没有执行这些管理员命令。

## 固定自签名身份

首次构建前运行一次：

```sh
python3 Scripts/setup-signing.py
Scripts/build.sh
python3 Scripts/test-signing.py
```

证书、加密私钥备份与钥匙串密码保存在 `~/Library/Application Support/Hy2UI-Signing/`，仅当前用户可读；请安全备份整个目录，不要提交、打包进 DMG 或公开。后续构建复用同一证书，签名材料丢失或失效时会停止，不会自动换证或退回 ad-hoc。构建期间临时将专用钥匙串加入用户搜索列表，结束时恢复原列表；不安装受信任根证书。

固定证书和 Bundle ID 能保持跨版本的应用签名身份，减少钥匙串重复授权。旧 ad-hoc 版本迁移后仍可能再询问一次，可选择“始终允许”；更换证书、钥匙串权限或系统策略也可能再次触发授权。节点密码仍按服务器 UUID 更新原钥匙串条目，不因构建增加副本。

此方式用于本地 TUN 后端，不授予 Network Extension 权限。`HY2_SIGN=1` 继续使用 Xcode 配置的 Apple 签名流程。自签名 DMG 的干净机器首次安装与升级流程仍需人工验证。

## Network Extension 签名与联调

采用 Developer ID 直接分发的 System Extension 结构。签名前需要自己的 Apple Developer Team、App ID 与匹配的 Network Extension provisioning profile。

1. 复制 `Config/Local.xcconfig.example` 为 `Config/Local.xcconfig`，填写 Team ID 和 Bundle ID 前缀。
2. 为主程序和 VPN 扩展配置相应签名能力。主程序需要 Network Extension 和安装 System Extension 权限；扩展需要 Packet Tunnel System Extension 和匹配的 App Group，用于 Mach service 命名。
3. 使用 `HY2_SIGN=1 Scripts/build.sh` 构建已签名应用。
4. 将应用安装到 `/Applications`，从应用中发起连接，按 macOS 提示允许扩展和 VPN 配置。

本节只针对 Network Extension 后端；本地 TUN 后端使用上一节的界面安装入口。Developer ID 签名、系统扩展启用、特权后台安装及系统网络设置变更都没有在自动验证中执行。未签名产物不能用于验证 Network Extension。发布还需要正确的 Developer ID 签名、公证和干净机器安装测试。

Apple 参考：[Packet Tunnel](https://developer.apple.com/documentation/networkextension/nepackettunnelprovider)、[扩展部署要求](https://developer.apple.com/documentation/technotes/tn3134-network-extension-provider-deployment)、[支持的使用方式](https://developer.apple.com/documentation/technotes/tn3120-expected-use-cases-for-network-extension-packet-tunnel-providers)。

## 本地后台故障诊断

本地 TUN 的 IPC 中断后，应用显示“需要恢复”并保留资源所有权，不再将其显示为正在重连；确认后台停止前仍需“重试清理”。真实的 Network Extension 重连状态不受影响。

后台通过固定错误类别区分核心启动失败、启动超时、运行中退出、DNS 失败和清理失败；核心退出时附带数字退出码及是否由信号终止。界面日志保留这些信息，后台日志 `/private/var/log/dev.hy2ui.local-tun.log` 记录带时间戳的结构化故障。未知错误不转发原文，凭据、原始配置、Rust stderr 与具体目标地址不会被诊断日志透传。观察到 rc5 的 QUIC 断开日志时，应用显示需要恢复并保留资源状态；只有后续真实的连接成功事件才恢复连接状态。核心仍在新请求到来时连接，不启动额外的后台重连循环；已有 TCP 流仍需由调用方重试。TCP/UDP 单条流错误只记录固定类别，不将整个 TUN 判定为断开。

这些诊断不等同于端到端健康检查：核心进程存活且未报告状态时，仍无法立即判定 QUIC 或某条 TCP/UDP 流是否已经失效。升级此版本后需从应用界面更新后台，已安装的旧 root 副本不会自动替换。内嵌客户端已升级至 rc5，PacketTunnel 适配复用上游 TCP/UDP 转发与错误限流逻辑，不复制或改写上游 UDP 会话、IPv6 转发和重连算法。

## 验证

```sh
swift test
Scripts/test-helper-installer.sh
Scripts/test-server-library.sh
Scripts/test-core-process.sh
Scripts/test-local-tun.sh
Scripts/test-local-tun-service.sh
python3 Scripts/prepare-core.py
cargo test --locked --manifest-path Native/Cargo.toml -p hy2-bridge
```

安装器测试使用注入的授权执行器覆盖安装、卸载、取消、失败、重复操作及过期检查；仅编译 AppleScript 以检查语法，不执行管理员授权或服务变更。

Swift 测试覆盖配置转义、地址校验、整组代理所有权、取消安全等待、过期会话回调和可注入服务的连接生命周期；配置与钥匙串失败不会阻断恢复，恢复失败也不会丢失资源所有权。独立进程测试使用不打开网络端口的模拟 worker，验证 stdin 传递、启动时退出和重复停止。Rust 测试覆盖 ABI 参数、worker 输入边界和本地 Hysteria 数据包往返；只使用 loopback，不创建网络接口、不修改系统代理或路由。

## 代码职责与配置升级

`Connection/` 将资源生命周期、配置编辑和初始化拆开，并通过协议注入 worker、代理恢复、VPN 和持久化服务，便于使用模拟服务测试故障和取消。`AppModel` 负责界面状态组合，错误消息独立于连接与资源所有权。VPN Provider 和数据包引擎共用串行生命周期队列，异步 DNS 和设置回调都校验会话 ID。

持久化配置和钥匙串凭据使用版本化编码，兼容旧版裸 JSON，并为旧配置缺失的新增字段提供默认值；未来未知版本拒绝覆盖。顶层声明使用一句话说明职责，复杂职责先拆分。

流量接管只使用独立的系统代理与增强模式开关；旧 `mode` 字段仅在读取缺少开关的历史配置时迁移，新配置不再写入它。增强模式后端由用户明确选择，失败时直接报错并清理资源，不会自动切换后端。恢复记录解析失败会保留记录并提示错误，不会把损坏内容视为空设置。

## 当前范围与待办

已实现：多服务器管理与旧配置迁移、Keychain、独立的系统代理与增强开关、本地 TUN 管理员后台及界面安装/更新/卸载、Network Extension 后端、DNS 恢复记录、服务端路由排除、Rust 数据包桥接、启动取消与退出清理。

后续需要验证或补齐：

- 本地后台的真实安装、升级、卸载与故障恢复验证，以及已签名 Network Extension 的授权和生命周期验证。
- 真实服务器下的 TCP/UDP、IPv6、DNS、休眠唤醒、Wi-Fi / 有线切换和故障恢复。
- 系统代理连接期间新增网络服务的自动同步；当前对启动时现有的网络服务设置代理。
- 主程序崩溃后的系统代理自动恢复；当前恢复记录会保留到下次启动。
- 订阅、规则分流、速率统计、开机启动、自动连接和 Kill Switch。
- Hysteria 承载 TCP/UDP；不提供通用 ICMP 隧道。

## 上游与许可

核心：[crapthings/hysteria-rust](https://github.com/crapthings/hysteria-rust)，通过 submodule 锁定提交 `f364dab51b3908d5c158309b1eba54445628641a`（源码版本 `0.1.0-rc.5`）。适配以 `Patches/core-*.patch` 显式补丁和 `Patches/embedded.rs` 保存；准备脚本断言上游提交与工作树状态，在干净的归档中应用补丁，并按内容摘要发布不可变源码目录，再原子切换 `.build/core` 符号链接。Cargo 缓存始终保存在 `Native/target`。

`Native/Cargo.lock` 从上游锁文件派生，必须保留。上游有定制的 Quinn / Rustls 等依赖，不能简单重新生成成最新 registry 版本。

上游采用 MIT 许可证；vendored 依赖的许可和声明见 `Vendor/hysteria-rust/LICENSE` 与 `THIRD_PARTY_NOTICES.md`。正式分发需要包含依赖声明。

## 服务器列表

侧栏最多显示 3 个服务器，按置顶优先、最近成功连接、最近添加排序；“更多”打开完整列表。列表中可添加服务器，并通过每行菜单置顶、取消置顶、编辑或删除，删除需确认。排序偏好独立保存在本机 UserDefaults，不包含凭据。

“测试延迟”手动测量服务器地址的 TCP 建连耗时，最多并发 4 个、每个超时 3 秒；不会自动连接 Hy2、读取节点密码或改变系统代理、路由。结果不是 QUIC RTT，TCP 未响应也不表示 Hy2 不可用；启用其他代理或 TUN 时结果可能受当前网络接管影响。测试仅在页面中保留，修改端点后不再显示旧结果。

本地验证：`swift test`、`Scripts/test-server-latency.sh`。后者仅使用临时回环 TCP 监听器。
