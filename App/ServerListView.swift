import SwiftUI

/// Manages saved CLI servers and the currently selected proxy endpoint.
struct ServerListView: View {
    @Bindable var model: AppModel
    var search = ""
    var edit: (UUID) -> Void
    var add: () -> Void
    @State private var groupDraft: ServerGroup?
    @State private var removingGroup: ServerGroup?
    @State private var groupError: String?
    @State private var pendingRemoval: Profile?
    private var filteredServers: [Profile] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.sortedServers.filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.host.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.sectionSpacing) {
                HStack {
                    Spacer()
                    Button(model.localized("添加服务器组")) { groupDraft = ServerGroup() }
                        .buttonStyle(AppActionStyle()).disabled(model.editingDisabled || model.servers.isEmpty)
                    Button(model.localized("添加服务器"), action: add)
                        .buttonStyle(AppActionStyle(primary: true)).disabled(model.editingDisabled)
                }
                if model.isSwitchingServer {
                    HStack { ProgressView().controlSize(.small); Text(model.localized("正在切换出口")) }
                        .font(AppTheme.caption).foregroundStyle(AppTheme.accent)
                }
                if model.servers.isEmpty {
                    AppEmptyState(symbol: .policies, title: model.localized("请先添加服务器"))
                        .frame(minHeight: 240).modifier(AppCardSurface())
                } else if filteredServers.isEmpty {
                    AppEmptyState(symbol: .policies, title: model.localized("无匹配策略"))
                        .frame(minHeight: 240).modifier(AppCardSurface())
                } else {
                    policies
                }
                groups
                if let groupError { Text(model.localized(groupError)).font(AppTheme.caption).foregroundStyle(AppTheme.warning) }
                if let notice = model.policyNotice {
                    Text(notice).font(AppTheme.caption).foregroundStyle(AppTheme.warning).textSelection(.enabled)
                }
                if let error = model.errorMessage {
                    Text(model.localized(error)).font(AppTheme.caption).foregroundStyle(AppTheme.warning)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(AppTheme.pagePadding).frame(maxWidth: .infinity)
        }
        .task { await model.refreshPoolCapabilities() }
        .sheet(item: $groupDraft) { group in ServerGroupEditorView(model: model, draft: group) }
        .confirmationDialog(model.localized("删除这个服务器组？"), isPresented: Binding(
            get: { removingGroup != nil }, set: { if !$0 { removingGroup = nil } }
        ), titleVisibility: .visible) {
            Button(model.localized("删除"), role: .destructive) {
                guard let group = removingGroup else { return }
                do {
                    guard model.routing.configuration.finalOutbound != .group(group.id),
                          !model.routing.configuration.rules.contains(where: { $0.outbound == .group(group.id) }) else {
                        throw ConfigurationError.invalid("服务器组正在使用或被规则引用，请先更换出口或规则。")
                    }
                    try model.routing.update { $0.groups.removeAll { $0.id == group.id } }
                    groupError = nil
                } catch { groupError = error.localizedDescription }
            }
        }
        .confirmationDialog(model.localized("删除这个服务器？"), isPresented: Binding(
            get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }
        ), titleVisibility: .visible, presenting: pendingRemoval) { server in
            Button(model.localized("删除服务器"), role: .destructive) { _ = model.removeServer(server.id) }
        } message: { server in
            Text(server.name + "\n" + model.localized("删除服务器及其密码。"))
        }
    }

    private var groups: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.localized("服务器组")).font(AppTheme.cardTitle)
            let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
            let groups = model.routing.configuration.groups.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
            if groups.isEmpty {
                Text(model.localized("将多个服务器归为一组，手动选择当前出口。"))
                    .font(AppTheme.caption).foregroundStyle(AppTheme.muted)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 16)], spacing: 16) {
                ForEach(groups) { group in
                    SectionCard {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                Text(group.name).font(AppTheme.cardTitle).lineLimit(1)
                                Spacer()
                                Menu {
                                    Button(model.localized("编辑")) { groupDraft = group }
                                        .disabled(model.editingDisabled || model.routing.configuration.finalOutbound == .group(group.id))
                                    Button(model.localized("删除"), role: .destructive) { removingGroup = group }
                                        .disabled(model.editingDisabled)
                                } label: { Image(systemName: "ellipsis") }
                                    .menuStyle(.button).menuIndicator(.hidden).buttonStyle(AppIconButtonStyle())
                            }
                            Text(model.localized(group.kind.title))
                                .font(AppTheme.caption).foregroundStyle(AppTheme.muted)
                            Menu {
                                ForEach(model.sortedServers.filter { group.members.contains($0.id) }) { server in
                                    Button(server.name) { Task { await model.useServerGroup(group.id, member: server.id) } }
                                }
                            } label: {
                                Text(group.kind == .select ? (model.servers.first { $0.id == group.selectedID }?.name ?? model.localized("请选择服务器")) : model.localized("由核心自动选择"))
                                    .lineLimit(1)
                            }.menuStyle(.button).disabled(!model.canChooseServer || group.kind != .select)
                            Button(model.localized(model.routing.configuration.finalOutbound == .group(group.id) ? "当前 FINAL" : "用于 FINAL")) {
                                Task { await model.useServerGroup(group.id) }
                            }.buttonStyle(AppActionStyle(primary: model.routing.configuration.finalOutbound == .group(group.id)))
                                .disabled(!model.canChooseServer || !model.poolCapabilities.supports(group.kind))
                        }
                    }
                }
            }
        }
    }

    private var policies: some View {
        let servers = filteredServers
        return VStack(spacing: 0) {
            HStack(spacing: 16) {
                Color.clear.frame(width: 32, height: 1).accessibilityHidden(true)
                Text(model.localized("名称"))
                Spacer()
                Color.clear.frame(width: 32, height: 1).accessibilityHidden(true)
            }
            .font(AppTheme.caption).foregroundStyle(AppTheme.muted)
            .padding(.horizontal, 16).padding(.vertical, 12)
            ForEach(servers) { server in
                row(server)
                    .padding(.horizontal, 16).padding(.vertical, 12)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.cardRadius))
        .modifier(AppCardSurface())
    }

    private func row(_ server: Profile) -> some View {
        HStack(spacing: 16) {
            Button {
                Task { await model.useServer(server.id) }
            } label: {
                Group {
                    if (!model.isFinalDirect && model.defaultServer?.id == server.id) {
                        AppIcon(symbol: .selected, size: 23).foregroundStyle(AppTheme.accent)
                    } else {
                        Circle().strokeBorder(AppTheme.muted, lineWidth: 1.25).frame(width: 18, height: 18)
                    }
                }.frame(width: 32, height: 36).contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(!model.canChooseServer)
            .accessibilityLabel(model.localized("用于 FINAL") + "：" + server.name)
            .accessibilityAddTraits((!model.isFinalDirect && model.defaultServer?.id == server.id) ? .isSelected : [])
            VStack(alignment: .leading, spacing: 4) {
                Text(server.name.isEmpty ? model.localized("未命名服务器") : server.name)
                    .font(.system(size: 14, weight: .medium)).lineLimit(1)
                Text(server.serverAddress).font(AppTheme.caption).foregroundStyle(AppTheme.muted)
                    .lineLimit(1).truncationMode(.middle)
            }
            .help(server.serverAddress)
            Spacer(minLength: 8)
            if (!model.isFinalDirect && model.defaultServer?.id == server.id) {
                Text("FINAL")
                    .font(AppTheme.caption).foregroundStyle(AppTheme.accent)
            }
            Menu {
                Button(model.localized(model.serverList.isPinned(server.id) ? "取消置顶" : "置顶"), systemImage: "pin") {
                    model.serverList.togglePin(server.id)
                }
                Button(model.localized("用于 FINAL"), systemImage: "checkmark.circle") {
                    Task { await model.useServer(server.id) }
                }.disabled(!model.canChooseServer)
                Button(model.localized("编辑"), systemImage: "pencil") { edit(server.id) }
                    .disabled(model.editingDisabled)
                Divider()
                Button(model.localized("删除"), systemImage: "trash", role: .destructive) { pendingRemoval = server }
                    .disabled(model.editingDisabled)
            } label: {
                Image(systemName: model.serverList.isPinned(server.id) ? "pin.fill" : "ellipsis")
            }
            .menuStyle(.button).menuIndicator(.hidden).buttonStyle(AppIconButtonStyle())
            .accessibilityLabel(model.localized("服务器操作"))
            .help(model.localized("服务器操作"))
        }
    }

}
