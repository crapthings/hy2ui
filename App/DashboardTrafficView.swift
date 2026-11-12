import SwiftUI

/// Presents CLI capture controls, saved servers, PAC rules and logs without unsupported core statistics.
struct DashboardTrafficView: View {
    @Bindable var model: AppModel
    let wide: Bool
    var openPolicies: () -> Void
    var openRules: () -> Void
    var openActivity: () -> Void
    var openLogs: () -> Void
    private var connected: Bool { model.state == .connected }
    private var addressCount: Int {
        let configuration = model.routing.configuration
        return Set(configuration.addressRules.map(\.target)
            + configuration.directDomains.compactMap { try? RoutingConfiguration.domain($0) }).count
    }

    var body: some View {
        Grid(horizontalSpacing: AppTheme.gridSpacing, verticalSpacing: AppTheme.gridSpacing) {
            GridRow { captureCard; policyCard }
            GridRow { serversCard.gridCellColumns(2) }
            GridRow { rulesCard; logsCard }
        }
    }

    private var captureCard: some View {
        DashboardCard(height: 264) {
            VStack(alignment: .leading, spacing: 16) {
                Text(model.localized("接管方式")).font(AppTheme.cardTitle)
                Text(model.localized(model.serviceTitle)).font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(connected ? AppTheme.connected : AppTheme.muted)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                AppIcon(symbol: .capture, size: 44)
                    .foregroundStyle(AppTheme.accent).frame(maxWidth: .infinity)
                Spacer(minLength: 0)
                Toggle(model.localized("增强模式"), isOn: Binding(
                    get: { model.enhancedCaptureEnabled },
                    set: { enabled in Task { await model.setCapture(enhanced: true, enabled: enabled) } }
                ))
                Toggle(model.localized("系统代理"), isOn: Binding(
                    get: { model.systemProxyCaptureEnabled },
                    set: { enabled in Task { await model.setCapture(enhanced: false, enabled: enabled) } }
                ))
            }.toggleStyle(.switch).controlSize(.small)
        }.disabled(!model.canChangeCapture)
    }

    private var policyCard: some View {
        DashboardCard(height: 264) {
            VStack(spacing: 14) {
                HStack {
                    Text("FINAL").font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(AppTheme.muted)
                    Spacer()
                    Button(action: openPolicies) { AppIcon(symbol: .forward, size: 16) }
                        .buttonStyle(AppIconButtonStyle()).foregroundStyle(AppTheme.muted)
                        .accessibilityLabel(model.localized("管理策略")).help(model.localized("管理策略"))
                }
                Spacer(minLength: 0)
                AppIcon(symbol: model.isFinalDirect ? .address : .server, size: 32)
                    .foregroundStyle(AppTheme.accent).frame(width: 68, height: 68)
                    .background(AppTheme.controlSurface, in: Circle())
                FinalPolicyPicker(model: model)
                if !model.isFinalDirect {
                    Text(model.defaultServer?.serverAddress ?? model.localized("请先添加策略"))
                        .font(AppTheme.caption).foregroundStyle(AppTheme.muted).lineLimit(1)
                        .truncationMode(.middle).textSelection(.enabled)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var serversCard: some View {
        DashboardCard(height: 264) {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text(model.localized("策略")).font(AppTheme.cardTitle)
                    Spacer()
                    Button(model.localized("更多"), action: openPolicies).buttonStyle(.link)
                }
                if model.servers.isEmpty {
                    Spacer()
                    Button(model.localized("添加服务器"), action: openPolicies).buttonStyle(AppActionStyle(primary: true))
                    Spacer()
                } else {
                    ForEach(Array(model.sortedServers.prefix(3))) { server in
                        Button { Task { await model.useServer(server.id) } } label: {
                            HStack(spacing: 12) {
                                AppIcon(symbol: .server, size: 21).foregroundStyle(AppTheme.accent)
                                    .frame(width: 36, height: 36).background(AppTheme.controlSurface, in: RoundedRectangle(cornerRadius: 10))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(server.name).font(.system(size: 14, weight: .medium)).lineLimit(1)
                                    Text(server.serverAddress).font(AppTheme.caption).foregroundStyle(AppTheme.muted).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                if (!model.isFinalDirect && model.defaultServer?.id == server.id) {
                                    AppIcon(symbol: .selected, size: 21).foregroundStyle(AppTheme.accent)
                                } else {
                                    Circle().strokeBorder(AppTheme.muted, lineWidth: 1.25).frame(width: 17, height: 17)
                                }
                            }.contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).disabled(!model.canChooseServer)
                        .help(model.localized("用于 FINAL"))
                        .accessibilityAddTraits((!model.isFinalDirect && model.defaultServer?.id == server.id) ? .isSelected : [])
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var rulesCard: some View {
        DashboardCard(height: 264) {
            VStack(alignment: .leading, spacing: 16) {
                Text(model.localized("规则")).font(AppTheme.cardTitle)
                DashboardValue(value: String(addressCount), size: 38)
                Text(model.localized("规则仅用于自动 PAC；不适用于全局代理或增强模式。"))
                    .font(AppTheme.caption).foregroundStyle(AppTheme.muted)
                Spacer(minLength: 0)
                Button(model.localized("管理规则"), action: openRules).buttonStyle(AppActionStyle(primary: true))
            }
        }
    }

    private var logsCard: some View {
        DashboardCard(height: 264) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(model.localized("日志")).font(AppTheme.cardTitle)
                    Spacer()
                    AppIcon(symbol: .logs, size: 22).foregroundStyle(AppTheme.accent)
                }
                DashboardValue(value: String(model.logs.count), size: 38)
                ForEach(Array(model.logs.suffix(2).enumerated()), id: \.offset) { _, entry in
                    Text(model.localizedLog(entry, detailed: false)).font(AppTheme.caption)
                        .foregroundStyle(AppTheme.muted).lineLimit(2)
                }
                Spacer(minLength: 0)
                Button(model.localized("查看日志"), action: openLogs).buttonStyle(AppActionStyle())
            }
        }
    }
}
