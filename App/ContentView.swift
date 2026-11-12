import SwiftUI

/// Identifies the home, selected-server editor, settings and diagnostic destinations.
enum AppDestination: Hashable {
    case home, server(UUID), servers, rules, processes, settings, logs
}

/// Composes the navigation rail, contextual search and focused application screens.
struct ContentView: View {
    @Bindable var model: AppModel
    @State private var destination = AppDestination.home
    @State private var policySearch = ""
    @State private var processSearch = ""
    @State private var ruleSearch = ""
    @State private var lastSearchDestination = AppDestination.servers

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
        .onChange(of: destination) { _, value in
            if value == .processes || value == .servers || value == .rules { lastSearchDestination = value }
        }

    }

    private var applicationLayout: some View {
        VStack(spacing: 0) {
            header
            HStack(alignment: .top, spacing: 0) {
                sidebar.padding(.leading, AppTheme.pagePadding).padding(.bottom, AppTheme.pagePadding)
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(AppTheme.canvas.ignoresSafeArea())
    }

    private var header: some View {
        HStack(spacing: 24) {
            Color.clear.frame(width: 64, height: 1).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(pageTitle).font(AppTheme.pageTitle).lineLimit(1).minimumScaleFactor(0.8)
                    .help(pageTitle).accessibilityAddTraits(.isHeader)
                Text(pageSubtitle).font(AppTheme.caption).foregroundStyle(AppTheme.muted).lineLimit(1)
            }
            Spacer(minLength: 12)
            AppSearchField(placeholder: model.localized(searchPlaceholder),
                           clearLabel: model.localized("清除搜索"), text: searchText,
                           submit: { destination = searchDestination })
                .frame(width: 300)
            Button { destination = .logs } label: {
                AppIcon(symbol: .logs, size: 22)
                    .frame(width: 52, height: 52).background(AppTheme.paper, in: Circle())
            }.buttonStyle(.plain).help(model.localized("日志")).accessibilityLabel(model.localized("日志"))
        }
        .padding(.horizontal, AppTheme.pagePadding).padding(.top, 20).padding(.bottom, 28)
    }

    private var sidebar: some View {
        VStack(spacing: 8) {
            navigationIcon("概览", icon: AppSymbol.overview, target: .home)
            navigationIcon("进程", icon: AppSymbol.processes, target: .processes)
            navigationIcon("策略", icon: AppSymbol.policies, target: .servers)
            navigationIcon("规则", icon: AppSymbol.rules, target: .rules)
            Spacer(minLength: 28)
            navigationIcon("日志", icon: AppSymbol.logs, target: .logs)
            navigationIcon("设置", icon: AppSymbol.settings, target: .settings)
            Circle().fill(model.state == .connected ? AppTheme.connected : AppTheme.muted)
                .frame(width: 8, height: 8).padding(.vertical, 12)
                .help(model.localized(model.serviceTitle))
                .accessibilityLabel(model.localized(model.serviceTitle))
        }
        .padding(.vertical, 10).frame(width: 64).frame(maxHeight: .infinity)
        .background(AppTheme.paper, in: Capsule())
    }

    private func navigationIcon(_ title: String, icon: AppSymbol, target: AppDestination) -> some View {
        let selected = destination == target || {
            if case .server = destination { return target == .servers }
            return false
        }()
        return Button {
            destination = target
        } label: {
            AppIcon(symbol: icon, size: 23)
                .frame(width: 48, height: 48)
                .foregroundStyle(selected ? AppTheme.paper : AppTheme.ink)
                .background(selected ? AppTheme.ink : Color.clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain).help(model.localized(title)).accessibilityLabel(model.localized(title))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var detail: some View {
        switch destination {
        case .home:
            ConnectionHomeView(model: model, openSettings: { destination = .settings }, editServer: {
                if let server = model.defaultServer {
                    guard model.selectServer(server.id) else { return }
                } else { guard model.addServer() else { return } }
                destination = .server(model.profile.id)
            }, openPolicies: { destination = .servers }, openRules: { destination = .rules }, openActivity: { destination = .processes }, openLogs: { destination = .logs })
        case .server:
            ServerEditorView(model: model, removed: { destination = .home })
        case .servers:
            ServerListView(model: model, search: policySearch, edit: { id in
                if model.selectServer(id) { destination = .server(id) }
            }, add: {
                if model.addServer() { destination = .server(model.profile.id) }
            })
        case .rules: RulesView(model: model, search: ruleSearch, openSettings: { destination = .settings }, openCapture: { destination = .home })
        case .processes: ProcessNetworkView(model: model, search: processSearch)
        case .settings: AppSettingsView(model: model)
        case .logs: ConnectionLogsView(model: model)
        }
    }

    private var searchDestination: AppDestination {
        switch destination {
        case .processes: return .processes
        case .servers, .server: return .servers
        case .rules: return .rules
        default: return lastSearchDestination
        }
    }

    private var searchPlaceholder: String {
        switch searchDestination {
        case .processes: return "搜索进程、PID 或路径"
        case .rules: return "搜索规则"
        default: return "搜索策略"
        }
    }

    private var searchText: Binding<String> {
        Binding(get: {
            switch searchDestination {
            case .processes: return processSearch
            case .rules: return ruleSearch
            default: return policySearch
            }
        }, set: { value in
            let target = searchDestination
            switch target {
            case .processes: processSearch = value
            case .rules: ruleSearch = value
            default: policySearch = value
            }
            if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { destination = target }
        })
    }

    private var pageTitle: String {
        switch destination {
        case .home: return model.localized("概览")
        case .processes: return model.localized("进程")
        case .servers: return model.localized("策略")
        case .rules: return model.localized("规则")
        case .settings: return model.localized("设置")
        case .logs: return model.localized("日志")
        case .server: return model.profile.name.isEmpty ? model.localized("新服务器") : model.profile.name
        }
    }

    private var pageSubtitle: String {
        switch destination {
        case .home: return model.localized(model.serviceTitle)
        case .processes: return model.localized("实时网络活动")
        case .servers: return model.localized("服务器与出口选择")
        case .rules: return model.localized("自动 PAC 地址规则")
        case .settings: return model.localized("连接与后台服务")
        case .logs: return model.localized("最近连接记录")
        case .server: return model.profile.host.isEmpty ? model.localized("服务器配置") : model.profile.serverAddress
        }
    }

}
