import SwiftUI

/// Selects a saved server or manual group for FINAL through the same runtime switching lifecycle.
struct FinalPolicyPicker: View {
    @Bindable var model: AppModel

    private var selectedGroupID: UUID? {
        if case let .group(id) = model.routing.configuration.finalOutbound { return id }
        return nil
    }

    var body: some View {
        Menu {
            Section(model.localized("服务器")) {
                ForEach(model.sortedServers) { server in
                    Button {
                        Task { await model.useServer(server.id) }
                    } label: {
                        if !model.isFinalDirect && selectedGroupID == nil && model.defaultServer?.id == server.id {
                            Label(server.name, systemImage: "checkmark")
                        } else { Text(server.name) }
                    }
                }
            }
            let groups = model.routing.configuration.groups
            if !groups.isEmpty {
                Section(model.localized("服务器组")) {
                    ForEach(groups) { group in
                        Button {
                            Task { await model.useServerGroup(group.id) }
                        } label: {
                            if !model.isFinalDirect && selectedGroupID == group.id {
                                Label(group.name, systemImage: "checkmark")
                            } else { Text(group.name) }
                        }
                        .disabled(!model.poolCapabilities.supports(group.kind) || !group.members.contains(where: { id in model.servers.contains { $0.id == id } }))
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(model.finalPolicyTitle)
                    .font(.system(size: 14, weight: .medium)).lineLimit(1)
                AppIcon(symbol: .disclosure, size: 13)
            }
        }
        .task { await model.refreshPoolCapabilities() }
        .menuStyle(.button).menuIndicator(.hidden)
        .buttonStyle(AppActionStyle())
        .disabled(!model.canChooseServer)
        .help(model.finalPolicyTitle)
        .accessibilityLabel(model.localized("FINAL 使用的策略"))
        .accessibilityValue(model.finalPolicyTitle)
    }
}
