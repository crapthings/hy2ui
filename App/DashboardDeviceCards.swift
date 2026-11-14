import SwiftUI
import AppKit

/// Presents copyable LAN addresses and an explicit opt-in to unauthenticated IPv4 proxy listeners.
struct DashboardLANCard: View {
    @Bindable var model: AppModel
    let device: DashboardDeviceModel
    @State private var confirming = false

    var body: some View {
        DashboardCard(height: 232) {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text(model.localized("内网 IP")).font(AppTheme.cardTitle)
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(device.addresses.joined(separator: "\n"), forType: .string)
                    } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(AppIconButtonStyle()).disabled(device.addresses.isEmpty)
                        .help(model.localized("复制内网 IP")).accessibilityLabel(model.localized("复制内网 IP"))
                }
                Text(device.addresses.first ?? "—").font(.system(size: 26, weight: .semibold)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.7).help(device.addresses.joined(separator: "\n"))
                Spacer(minLength: 0)
                Toggle(model.localized("局域网代理"), isOn: Binding(
                    get: { model.profile.allowLAN },
                    set: { enabled in
                        if enabled { confirming = true }
                        else { Task { await model.setLANSharing(false) } }
                    }
                )).toggleStyle(.switch).disabled(model.editingDisabled)
                Text(model.localized(model.profile.allowLAN
                    ? (model.systemProxyActive ? "已开启 · HTTP / HTTPS / SOCKS5" : "已允许 · 启动系统代理后生效") : "已关闭"))
                    .font(AppTheme.caption).foregroundStyle(AppTheme.muted)
            }
        }
        .confirmationDialog(model.localized("允许局域网访问代理？"), isPresented: $confirming, titleVisibility: .visible) {
            Button(model.localized("允许")) { Task { await model.setLANSharing(true) } }
            Button(model.localized("取消"), role: .cancel) {}
        } message: {
            Text(model.localized("HTTP / HTTPS 和 SOCKS5 代理将允许其他 IPv4 设备访问，不提供代理认证。仅在可信网络开启；切换时会重新连接。"))
        }
    }
}

/// Displays measured resident memory and leaves unavailable privileged-core samples visibly unknown.
struct DashboardMemoryCard: View {
    let device: DashboardDeviceModel
    let localized: (String) -> String
    private var total: UInt64? {
        guard let app = device.appMemory, let core = device.coreMemory else { return nil }
        return app + core
    }
    var body: some View {
        DashboardCard(height: 232) {
            VStack(alignment: .leading, spacing: 18) {
                Text(localized("内存信息")).font(AppTheme.cardTitle)
                DashboardValue(value: total.map(TrafficFormatting.bytes) ?? "—", size: 30)
                Spacer(minLength: 0)
                if let total, total > 0, let app = device.appMemory {
                    GeometryReader { geometry in
                        HStack(spacing: 2) {
                            Rectangle().fill(AppTheme.accent).frame(width: max(0, geometry.size.width - 2) * CGFloat(app) / CGFloat(total))
                            Rectangle().fill(AppTheme.accent.opacity(0.3))
                        }.clipShape(Capsule())
                    }.frame(height: 8)
                }
                HStack {
                    Text(localized("应用")); Spacer()
                    Text(device.appMemory.map(TrafficFormatting.bytes) ?? "—")
                }
                HStack {
                    Text(localized("核心")); Spacer()
                    Text(device.coreMemory.map(TrafficFormatting.bytes) ?? localized("无法读取"))
                }
            }.font(AppTheme.caption)
        }.help(localized("进程驻留内存；管理员核心可能不可读。不是系统内核内存。"))
    }
}
