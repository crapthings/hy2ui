import SwiftUI
import AppKit

/// Displays system-wide process network activity separately from Hy2 transport accounting.
struct ProcessNetworkView: View {
    @Bindable var model: AppModel
    @State private var activity = ProcessNetworkModel()
    @State private var selection: Set<UUID> = []
    @State private var search = ""
    @State private var sortOrder = [KeyPathComparator(\ProcessNetworkModel.Row.displayName)]
    @State private var ruleNotice: String?
    @State private var ruleError = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.sectionSpacing) {
            HStack {
                Text(model.localized("网络活动")).font(AppTheme.pageTitle)
                Spacer()
                Button {
                    activity.setPaused(!activity.isPaused)
                } label: {
                    Label(model.localized(activity.isPaused ? "继续更新" : "暂停更新"), systemImage: activity.isPaused ? "play" : "pause")
                }.buttonStyle(AppActionStyle())
            }
            Text(model.localized("系统进程网络活动，包含直连、代理和本地连接。"))
                .font(AppTheme.caption).foregroundStyle(AppTheme.muted)
            Text(model.localized(activity.error ?? ruleNotice ?? " "))
                .font(AppTheme.caption).lineLimit(1)
                .foregroundStyle(activity.error != nil || ruleError ? AppTheme.warning : AppTheme.muted)
                .frame(height: 16, alignment: .leading)
                .help(model.localized(activity.error ?? ruleNotice ?? ""))
            HStack(spacing: 12) {
                TextField(model.localized("搜索进程、PID 或路径"), text: $search)
                    .textFieldStyle(FilledFieldStyle()).frame(maxWidth: 320)
                Spacer()
                Button(model.localized("重新排序"), systemImage: "arrow.up.arrow.down") { activity.sort(using: sortOrder) }
                    .buttonStyle(AppActionStyle()).disabled(activity.rows.count < 2)
                    .help(model.localized("点击列标题或重新排序，更新数据时保持顺序。"))
            }
            Table(filteredRows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn(model.localized("进程"), value: \.displayName) { row in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.displayName).lineLimit(1)
                        Text("PID \(row.sample.pid)" + (row.isPresent ? "" : " · " + model.localized("暂无活动"))).font(AppTheme.caption).foregroundStyle(AppTheme.muted)
                    }.foregroundStyle(row.isPresent ? AppTheme.ink : AppTheme.muted)
                        .help(row.identity?.target.path ?? row.sample.name)
                }.width(min: 140, ideal: 220)
                TableColumn(model.localized("规则")) { row in
                    if let target = row.identity?.target {
                        let action = ProcessRoutingPolicy.action(for: target, in: model.routing.configuration)
                        Text(action == .direct ? "DIRECT" : model.localized("默认"))
                            .foregroundStyle(action == .direct ? AppTheme.connected : AppTheme.muted)
                            .help(model.localized("下次连接生效"))
                    } else { Text("—").foregroundStyle(AppTheme.muted) }
                }.width(80)
                TableColumn(model.localized("下载"), value: \.downloadRate) { row in Text(TrafficFormatting.rate(row.downloadRate)).monospacedDigit() }
                TableColumn(model.localized("上传"), value: \.uploadRate) { row in Text(TrafficFormatting.rate(row.uploadRate)).monospacedDigit() }
                TableColumn(model.localized("已接收"), value: \.received) { row in Text(TrafficFormatting.bytes(row.sample.received)).monospacedDigit() }
                TableColumn(model.localized("已发送"), value: \.sent) { row in Text(TrafficFormatting.bytes(row.sample.sent)).monospacedDigit() }
            }
            .overlay {
                if filteredRows.isEmpty {
                    Text(model.localized(search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? (activity.isPaused ? "已暂停更新" : "暂无网络活动") : "没有匹配的进程"))
                        .font(AppTheme.body).foregroundStyle(AppTheme.muted).allowsHitTesting(false)
                }
            }
            .transaction { $0.animation = nil }
            .contextMenu(forSelectionType: UUID.self) { ids in
                let targets = filteredRows.filter { ids.contains($0.id) }
                if !targets.isEmpty {
                    processMenu(targets)
                } else {
                    Text(model.localized("请选择进程"))
                }
            }
        }
        .padding(AppTheme.pagePadding)
        .task { await activity.watch() }
        .onChange(of: selection) { _, value in activity.retain(value) }
        .onChange(of: sortOrder) { _, value in activity.sort(using: value) }
        .onChange(of: activity.rows.map(\.id)) { _, ids in selection.formIntersection(Set(ids)) }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in activity.beginInteraction() }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in activity.endInteraction() }
        .onDisappear { activity.endInteractions() }
    }

    private var filteredRows: [ProcessNetworkModel.Row] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return activity.rows }
        return activity.rows.filter {
            $0.displayName.localizedStandardContains(query) || $0.sample.name.localizedStandardContains(query) ||
            String($0.sample.pid).contains(query) || ($0.identity?.target.path.localizedStandardContains(query) ?? false)
        }
    }

    private var supportsDirect: Bool {
        model.profile.enhancedModeEnabled && model.profile.enhancedBackend == .localTun && !model.profile.systemProxyEnabled
    }

    @ViewBuilder private func processMenu(_ rows: [ProcessNetworkModel.Row]) -> some View {
        let identities = rows.compactMap(\.identity)
        if identities.count == rows.count {
            ForEach(ProcessRoutingAction.allCases, id: \.self) { value in
                let selected = identities.allSatisfy { ProcessRoutingPolicy.action(for: $0.target, in: model.routing.configuration) == value }
                Button {
                    setRules(value, identities: identities)
                } label: {
                    Label(model.localized(value.title), systemImage: selected ? "checkmark" : value == .direct ? "arrow.up.right" : "list.bullet")
                }
                .disabled(value == .direct && !supportsDirect)
            }
            Divider()
            Text(model.localized("下次连接生效"))
            if !supportsDirect { Text(model.localized("仅用于本地增强模式，请关闭系统代理。")) }
        } else {
            Text(model.localized("无法获取此进程的完整路径。"))
        }
        Divider()
        Button(model.localized("复制进程名")) { copy(rows.map(\.displayName).joined(separator: "\n")) }
        Button(model.localized("复制 PID")) { copy(rows.map { String($0.sample.pid) }.joined(separator: "\n")) }
        if identities.count == rows.count {
            Button(model.localized("复制路径")) { copy(identities.map { $0.target.path }.joined(separator: "\n")) }
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func setRules(_ action: ProcessRoutingAction, identities: [ProcessIdentity]) {
        do {
            guard !identities.isEmpty, identities.allSatisfy(\.isCurrent) else {
                throw ConfigurationError.invalid("进程已退出或发生变化，请刷新后重试。")
            }
            try model.routing.update { configuration in
                for identity in identities {
                    try ProcessRoutingPolicy.set(action, for: identity.target, in: &configuration)
                }
            }
            ruleNotice = "已保存，下次连接生效。"; ruleError = false
        } catch {
            ruleNotice = error.localizedDescription; ruleError = true
        }
    }
}
