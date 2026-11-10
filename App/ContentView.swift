import SwiftUI

/// Identifies the home, selected-server editor, settings and diagnostic destinations.
enum AppDestination: Hashable {
    case home, server(UUID), servers, processes, settings, logs
}

/// Composes server navigation, the shared status toolbar and focused application screens.
struct ContentView: View {
    @Bindable var model: AppModel
    @State private var destination = AppDestination.home

    var body: some View {
        Group {
            if model.enhancedSetup.isPresented {
                ZStack {
                    AppTheme.canvas.ignoresSafeArea()
                    EnhancedModeSetupView(model: model)
                }
            } else { applicationLayout }
        }
        .font(AppTheme.body)
        .foregroundStyle(AppTheme.ink)
        .tint(AppTheme.accent)
        .frame(minWidth: 880, minHeight: 620)
        .task { await model.initialize() }
        .onChange(of: model.state) { _, state in
            if state == .idle || state == .recoveryRequired { model.dashboard.clearLive() }
        }
    }

    private var applicationLayout: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            ZStack {
                AppTheme.canvas.ignoresSafeArea()
                detail
            }
            .navigationTitle(title)
            .toolbar { captureToolbar }

        }
    }

    @ToolbarContentBuilder
    private var captureToolbar: some ToolbarContent {
        if #available(macOS 26.0, *) {
            captureToolbarItems.sharedBackgroundVisibility(.hidden)
        } else {
            captureToolbarItems
        }
    }

    private var captureToolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .automatic) {
            Spacer()
            ConnectionToolbar(model: model)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 24, weight: .medium)).foregroundStyle(AppTheme.ink)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Hy2UI").font(.system(size: 23, weight: .medium))
                }
            }.padding(24).padding(.top, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    navigationRow(model.localized("概览"), icon: "square.grid.2x2", destination: .home)
                    HStack {
                        Text(model.localized("服务器")).font(AppTheme.caption)
                        Spacer()
                        Button {
                            if model.addServer() { destination = .server(model.profile.id) }
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 13, weight: .medium))
                                .frame(width: 24, height: 24)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(model.editingDisabled)
                        .accessibilityLabel(model.localized("添加服务器"))
                        .help(model.localized("添加服务器"))
                    }
                    .foregroundStyle(AppTheme.muted)
                    .padding(.horizontal, 12).padding(.top, 24).padding(.bottom, 6)
                    ForEach(Array(model.sortedServers.prefix(3))) { server in
                        navigationRow(server.name.isEmpty ? model.localized("未命名服务器") : server.name,
                            icon: model.serverList.isPinned(server.id) ? "pin.fill" : "server.rack", destination: .server(server.id),
                            subtitle: server.host.isEmpty ? model.localized("待配置") : server.host)
                            .disabled(model.editingDisabled)
                    }
                    navigationRow(model.localized("更多"), icon: "ellipsis", destination: .servers)
                    Color.clear.frame(height: 24).accessibilityHidden(true)
                    navigationRow(model.localized("设置"), icon: "slider.horizontal.3", destination: .settings)
                    navigationRow(model.localized("网络活动"), icon: "chart.bar", destination: .processes)
                    navigationRow(model.localized("日志"), icon: "text.alignleft", destination: .logs)
                }.padding(.horizontal, 12)
            }
            HStack(spacing: 8) {
                Circle().fill(model.state == .connected ? AppTheme.connected : AppTheme.muted).frame(width: 6, height: 6)
                Text(model.localized(model.state.title)).font(AppTheme.caption)
                Spacer()
            }.padding(24)
        }
        .background(WindowGlass())
        .navigationSplitViewColumnWidth(min: 210, ideal: 235, max: 280)
    }

    private func navigationRow(_ title: String, icon: String, destination target: AppDestination,
                               subtitle: String? = nil) -> some View {
        let selected = destination == target
        return Button {
            if case let .server(id) = target, !model.selectServer(id) { return }
            destination = target
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 15)).frame(width: 20)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 14, weight: selected ? .medium : .regular)).lineLimit(1)
                    if let subtitle { Text(subtitle).font(AppTheme.caption).foregroundStyle(AppTheme.muted).lineLimit(1) }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? AppTheme.selection : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .leading) {
                if selected { AppTheme.ink.frame(width: 2).padding(.vertical, 12) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var detail: some View {
        switch destination {
        case .home:
            ConnectionHomeView(model: model, openSettings: { destination = .settings }, editServer: {
                if !model.hasServer { guard model.addServer() else { return } }
                destination = .server(model.profile.id)
            }, openActivity: { destination = .processes })
        case .server:
            ServerEditorView(model: model, removed: { destination = .home })
        case .servers:
            ServerListView(model: model, edit: { id in
                if model.selectServer(id) { destination = .server(id) }
            }, add: {
                if model.addServer() { destination = .server(model.profile.id) }
            })
        case .processes: ProcessNetworkView(model: model)
        case .settings: AppSettingsView(model: model)
        case .logs: ConnectionLogsView(model: model)
        }
    }

    private var title: String {
        switch destination {
        case .home: model.localized("概览")
        case .server: model.localized("服务器")
        case .servers: model.localized("服务器")
        case .processes: model.localized("网络活动")
        case .settings: model.localized("设置")
        case .logs: model.localized("日志")
        }
    }
}
