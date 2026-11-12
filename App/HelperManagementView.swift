import SwiftUI

/// Groups background maintenance actions and failures beneath a compact installation status.
struct HelperManagementView: View {
    @Bindable var model: AppModel
    @State private var confirmingRemoval = false

    private var statusColor: Color {
        switch model.helperInstaller.status {
        case .current: AppTheme.connected
        case .checking, .notInstalled: AppTheme.muted
        case .updateAvailable, .legacy, .otherUser, .damaged: AppTheme.warning
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.formSpacing) {
            HStack(alignment: .center) {
                Label { Text(model.localized("后台服务")) } icon: { AppIcon(symbol: .helper, size: 17) }
                    .font(AppTheme.sectionTitle)
                Spacer()
                if model.helperInstaller.status == .checking || model.helperInstaller.isBusy {
                    ProgressView().controlSize(.small)
                }
                Text(model.localized(model.helperInstaller.status.title))
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(statusColor)
            }
            SectionCard {
                VStack(alignment: .leading, spacing: AppTheme.formSpacing) {
                    HStack(spacing: 8) {
                        Button(model.localized("卸载"), role: .destructive) { confirmingRemoval = true }
                            .buttonStyle(AppActionStyle())
                            .disabled(!model.initialized || model.isManagingHelper || !model.helperInstaller.canUninstall)
                        Spacer(minLength: 0)
                        Button(model.localized(model.helperInstaller.installButtonTitle)) { Task { await model.manageHelper(.install) } }
                            .buttonStyle(AppActionStyle(primary: true))
                            .disabled(!model.initialized || model.isManagingHelper || model.helperInstaller.status == .checking)
                    }
                    if model.helperInstaller.failed, let message = model.helperInstaller.message {
                        Text(model.localized(message)).font(AppTheme.caption)
                            .foregroundStyle(AppTheme.warning).textSelection(.enabled)
                    }
                }
            }
        }
        .confirmationDialog(model.localized("卸载增强模式后台？"), isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button(model.localized("卸载"), role: .destructive) { Task { await model.manageHelper(.uninstall) } }
        } message: {
            Text(model.localized("断开并卸载后台，保留服务器和密码。"))
        }
    }
}
