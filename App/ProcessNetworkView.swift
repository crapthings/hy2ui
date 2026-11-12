import SwiftUI
import AppKit

/// Presents continuously sampled processes as a selectable list with an adaptive detail pane.
struct ProcessNetworkView: View {
    @Bindable var model: AppModel
    @State private var activity = ProcessNetworkModel()
    @State private var selection: Set<UUID> = []
    var search = ""
    @State private var sort = ProcessListSort()
    @State private var ruleNotice: String?
    @State private var ruleError = false

    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 16) {
                if let notice = activity.error ?? ruleNotice {
                    Text(model.localized(notice)).font(AppTheme.caption).lineLimit(1)
                        .foregroundStyle(activity.error != nil || ruleError ? AppTheme.warning : AppTheme.muted)
                        .help(model.localized(notice))
                }
                if !selection.isEmpty && geometry.size.width >= 1000 {
                    HStack(alignment: .top, spacing: AppTheme.gridSpacing) {
                        processList.frame(minWidth: 640, maxWidth: .infinity)
                        processDetails.frame(width: min(320, max(260, geometry.size.width * 0.25)))
                    }
                } else {
                    processList
                    if !selection.isEmpty { processDetails.frame(height: 230) }
                }
            }.padding(AppTheme.pagePadding)
        }
        .task { await activity.watch() }
        .onChange(of: selection) { _, value in activity.retain(value) }
        .onChange(of: filteredRows.map(\.id)) { _, ids in selection.formIntersection(Set(ids)) }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in activity.beginInteraction() }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in activity.endInteraction() }
        .onDisappear { activity.endInteractions() }
    }

    private var processList: some View {
        VStack(spacing: 0) {
            ProcessListHeader(localized: model.localized, sort: sort, select: selectSort)
            List(filteredRows, selection: $selection) { row in
                ProcessListRow(row: row,
                    selected: selection.contains(row.id), localized: model.localized)
                    .tag(row.id)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            .listStyle(.plain).scrollContentBackground(.hidden)
            .contentMargins(0, for: .scrollContent)
            .overlay {
                if filteredRows.isEmpty {
                    AppEmptyState(symbol: .processes, title: model.localized(search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "暂无网络活动" : "没有匹配的进程"))
                        .allowsHitTesting(false)
                }
            }
            .transaction { $0.animation = nil }
            .contextMenu(forSelectionType: UUID.self) { ids in
                let targets = filteredRows.filter { ids.contains($0.id) }
                if !targets.isEmpty { processMenu(targets) }
                else { Text(model.localized("请选择进程")) }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.cardRadius))
        .modifier(AppCardSurface())
    }

    private var selectedRows: [ProcessNetworkModel.Row] {
        activity.rows.filter { selection.contains($0.id) }
    }

    private var processDetails: some View {
        VStack(alignment: .leading, spacing: AppTheme.gridSpacing) {
            HStack {
                Text(model.localized("进程详情")).font(AppTheme.sectionTitle)
                Spacer()
                Button { selection.removeAll() } label: { AppIcon(symbol: .close, size: 14) }
                    .buttonStyle(AppIconButtonStyle()).foregroundStyle(AppTheme.muted)
                    .accessibilityLabel(model.localized("关闭详情")).help(model.localized("关闭详情"))
            }.padding(.horizontal, 4)
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.gridSpacing) {
                    if selectedRows.count == 1, let row = selectedRows.first {
                        SectionCard {
                            VStack(alignment: .leading, spacing: 16) {
                                Text(row.displayName).font(AppTheme.cardTitle).textSelection(.enabled)
                                HStack {
                                    Text("PID").foregroundStyle(AppTheme.muted)
                                    Spacer()
                                    Text(String(row.sample.pid)).monospacedDigit().textSelection(.enabled)
                                }
                                HStack {
                                    Text(model.localized("状态")).foregroundStyle(AppTheme.muted)
                                    Spacer()
                                    Text(model.localized(row.isPresent ? "运行中" : "暂无活动"))
                                }
                            }
                        }
                        SectionCard {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(model.localized("进程路径")).font(AppTheme.caption).foregroundStyle(AppTheme.muted)
                                Text(row.identity?.target.path ?? model.localized("无法获取此进程的完整路径。"))
                                    .font(AppTheme.caption).textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        SectionCard {
                            VStack(alignment: .leading, spacing: 14) {
                                HStack {
                                    Text(model.localized("上传 / 下载")).font(AppTheme.caption).foregroundStyle(AppTheme.muted)
                                    Spacer()
                                    ProcessTransferValues(outgoing: TrafficFormatting.rate(row.uploadRate), incoming: TrafficFormatting.rate(row.downloadRate),
                                                          outgoingTitle: model.localized("上传"), incomingTitle: model.localized("下载"))
                                }
                                HStack {
                                    Text(model.localized("发送 / 接收")).font(AppTheme.caption).foregroundStyle(AppTheme.muted)
                                    Spacer()
                                    ProcessTransferValues(outgoing: TrafficFormatting.bytes(row.sent), incoming: TrafficFormatting.bytes(row.received),
                                                          outgoingTitle: model.localized("已发送"), incomingTitle: model.localized("已接收"))
                                }
                            }
                        }
                    } else {
                        SectionCard {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(model.localized("已选择进程"))
                                DashboardValue(value: String(selectedRows.count))
                            }
                        }
                    }
                    Menu(model.localized("操作")) { processMenu(selectedRows) }
                        .menuStyle(.button).buttonStyle(AppActionStyle())
                        .disabled(selectedRows.isEmpty)
                }.padding(1)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func selectSort(_ field: ProcessSortField) {
        sort.select(field)
        activity.sort(orderedIDs: sort.orderedIDs(in: activity.rows, configuration: model.routing.configuration))
    }

    private var filteredRows: [ProcessNetworkModel.Row] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return activity.rows }
        return activity.rows.filter {
            $0.displayName.localizedStandardContains(query) || $0.sample.name.localizedStandardContains(query) ||
            String($0.sample.pid).contains(query) || ($0.identity?.target.path.localizedStandardContains(query) ?? false)
        }
    }

    @ViewBuilder private func processMenu(_ rows: [ProcessNetworkModel.Row]) -> some View {
        let identities = rows.compactMap(\.identity)
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

}
