import SwiftUI

/// Manages all servers and manually measured TCP latency while keeping the sidebar compact.
struct ServerListView: View {
    @Bindable var model: AppModel
    var edit: (UUID) -> Void
    var add: () -> Void
    @State private var pendingRemoval: Profile?
    @State private var measurementID: UUID?
    @State private var measuring = false
    @State private var latencies: [UUID: Measurement] = [:]

    /// Associates a measurement with the endpoint tested so edited servers never display stale results.
    private struct Measurement {
        let address: String
        let milliseconds: Int?
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.sectionSpacing) {
                HStack {
                    Text(model.localized("服务器")).font(AppTheme.pageTitle)
                    Spacer()
                    Button(model.localized("测试延迟")) { measurementID = UUID() }
                        .buttonStyle(AppActionStyle()).disabled(measuring || model.servers.isEmpty)
                    Button(model.localized("添加服务器"), action: add)
                        .buttonStyle(AppActionStyle(primary: true)).disabled(model.editingDisabled)
                }
                if model.servers.isEmpty {
                    Text(model.localized("请先添加服务器")).foregroundStyle(AppTheme.muted)
                } else {
                    SectionCard {
                        VStack(spacing: 16) {
                            HStack(spacing: 16) {
                                Text(model.localized("名称"))
                                Spacer()
                                Text(model.localized("QUIC 延迟")).frame(width: 100, alignment: .trailing)
                                Color.clear.frame(width: 28, height: 1).accessibilityHidden(true)
                            }.font(AppTheme.caption).foregroundStyle(AppTheme.muted)
                            ForEach(model.sortedServers) { server in row(server) }
                        }
                    }
                    Text(model.localized("通过 Hy2 握手测量连接延迟。"))
                        .font(AppTheme.caption).foregroundStyle(AppTheme.muted)
                }
                if let error = model.errorMessage {
                    Text(model.localized(error)).font(AppTheme.caption).foregroundStyle(AppTheme.warning)
                }
            }
            .frame(maxWidth: 760).padding(AppTheme.pagePadding).frame(maxWidth: .infinity)
        }
        .task(id: measurementID) {
            guard measurementID != nil else { return }
            await measure()
        }
        .confirmationDialog(model.localized("删除这个服务器？"), isPresented: Binding(
            get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }
        ), titleVisibility: .visible, presenting: pendingRemoval) { server in
            Button(model.localized("删除服务器"), role: .destructive) { _ = model.removeServer(server.id) }
        } message: { server in
            Text(server.name + "\n" + model.localized("删除服务器及其密码。"))
        }
    }

    private func row(_ server: Profile) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(server.name.isEmpty ? model.localized("未命名服务器") : server.name)
                    .font(AppTheme.body).lineLimit(1)
                Text(server.serverAddress).font(AppTheme.caption).foregroundStyle(AppTheme.muted).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(latencyTitle(server)).font(AppTheme.caption).monospacedDigit()
                .foregroundStyle(AppTheme.muted).frame(width: 100, alignment: .trailing)
            Menu {
                Button(model.localized(model.serverList.isPinned(server.id) ? "取消置顶" : "置顶"), systemImage: "pin") {
                    model.serverList.togglePin(server.id)
                }
                Button(model.localized("编辑"), systemImage: "pencil") { edit(server.id) }
                    .disabled(model.editingDisabled)
                Divider()
                Button(model.localized("删除"), systemImage: "trash", role: .destructive) { pendingRemoval = server }
                    .disabled(model.editingDisabled)
            } label: {
                Image(systemName: model.serverList.isPinned(server.id) ? "pin.fill" : "ellipsis")
                    .frame(width: 28, height: 32)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden)
            .accessibilityLabel(model.localized("服务器操作"))
        }
    }

    private func latencyTitle(_ server: Profile) -> String {
        guard let value = latencies[server.id], value.address == server.serverAddress else { return "—" }
        return value.milliseconds.map { "\($0) ms" } ?? model.localized("未响应")
    }

    private func measure() async {
        measuring = true
        defer { measuring = false }
        let servers = model.servers
        for start in stride(from: 0, to: servers.count, by: 4) {
            guard !Task.isCancelled else { return }
            let batch = Array(servers[start..<min(start + 4, servers.count)])
            await withTaskGroup(of: (UUID, String, Int?).self) { group in
                for server in batch {
                    group.addTask {
                        let value = await model.measureServer(server)
                        return (server.id, server.serverAddress, value)
                    }
                }
                for await (id, address, value) in group {
                    guard !Task.isCancelled else { continue }
                    latencies[id] = Measurement(address: address, milliseconds: value)
                }
            }
        }
    }
}
