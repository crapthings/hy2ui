import SwiftUI

/// Selects the persisted proxy policy used by FINAL and applies changes to an already running service.
struct FinalPolicyPicker: View {
    @Bindable var model: AppModel

    var body: some View {
        Menu {
            ForEach(model.sortedServers) { server in
                Button {
                    Task { await model.useServer(server.id) }
                } label: {
                    if !model.isFinalDirect && model.defaultServer?.id == server.id {
                        Label(server.name, systemImage: "checkmark")
                    } else { Text(server.name) }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(model.finalPolicyTitle)
                    .font(.system(size: 14, weight: .medium)).lineLimit(1)
                AppIcon(symbol: .disclosure, size: 13)
            }
        }
        .menuStyle(.button).menuIndicator(.hidden)
        .buttonStyle(AppActionStyle())
        .disabled(!model.canChooseServer)
        .help(model.finalPolicyTitle)
        .accessibilityLabel(model.localized("FINAL 使用的策略"))
        .accessibilityValue(model.finalPolicyTitle)
    }
}
