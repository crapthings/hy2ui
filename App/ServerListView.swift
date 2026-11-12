import SwiftUI

/// Manages saved CLI servers and the currently selected proxy endpoint.
struct ServerListView: View {
    @Bindable var model: AppModel
    var search = ""
    var edit: (UUID) -> Void
    var add: () -> Void
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
                if let notice = model.policyNotice {
                    Text(notice).font(AppTheme.caption).foregroundStyle(AppTheme.warning).textSelection(.enabled)
                }
                if let error = model.errorMessage {
                    Text(model.localized(error)).font(AppTheme.caption).foregroundStyle(AppTheme.warning)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(AppTheme.pagePadding).frame(maxWidth: .infinity)
        }
        .confirmationDialog(model.localized("删除这个服务器？"), isPresented: Binding(
            get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }
        ), titleVisibility: .visible, presenting: pendingRemoval) { server in
            Button(model.localized("删除服务器"), role: .destructive) { _ = model.removeServer(server.id) }
        } message: { server in
            Text(server.name + "\n" + model.localized("删除服务器及其密码。"))
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
            .buttonStyle(.plain).disabled(!model.canChooseServer || (!model.isFinalDirect && model.defaultServer?.id == server.id))
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
                }.disabled(!model.canChooseServer || (!model.isFinalDirect && model.defaultServer?.id == server.id))
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
