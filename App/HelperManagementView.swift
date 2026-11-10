import SwiftUI

/// Aligns background help and maintenance actions beneath a title with a compact status badge.
struct HelperManagementView: View {
    @Bindable var model: AppModel
    @State private var confirmingRemoval = false

    private var statusColor: Color {
        model.helperInstaller.status.isInstalled ? AppTheme.connected : AppTheme.destructive
    }

    private var statusTitle: String {
        model.helperInstaller.status.isInstalled ? "已安装" : "未安装"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.formSpacing) {
            HStack(alignment: .center) {
                Text(model.localized("增强模式后台")).font(AppTheme.sectionTitle)
                Spacer()
                Text(model.localized(statusTitle))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(statusColor)
                    .help(model.localized(model.helperInstaller.status.title))
            }
            SectionCard {
                VStack(alignment: .leading, spacing: AppTheme.formSpacing) {
                    HStack(alignment: .center, spacing: 24) {
                        Text(model.localized("TUN 所需后台，更改需管理员授权。"))
                            .font(AppTheme.body).foregroundStyle(AppTheme.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        HStack(spacing: 8) {
                            Button(model.localized("卸载"), role: .destructive) { confirmingRemoval = true }
                                .buttonStyle(AppActionStyle())
                                .disabled(!model.initialized || model.isManagingHelper || !model.helperInstaller.canUninstall)
                            Button(model.localized(model.helperInstaller.installButtonTitle)) { Task { await model.manageHelper(.install) } }
                                .buttonStyle(AppActionStyle(primary: true))
                                .disabled(!model.initialized || model.isManagingHelper || model.helperInstaller.status == .checking)
                        }.fixedSize()
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
