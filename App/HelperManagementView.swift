import SwiftUI

/// Manages the owned virtual interface alongside privileged backend installation and recovery.
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

    private var interfaceTitle: String {
        if let session = model.interfaceSession { return session.interface.name }
        if model.needsConnectionCleanup { return model.localized("释放状态待确认") }
        if model.enhancedModeActive { return model.localized("未提供接口身份") }
        if model.state == .connecting && model.enhancedCaptureEnabled { return model.localized("创建中") }
        return model.localized("未创建")
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
                    HStack {
                        Text("Hy2UI Tunnel").font(AppTheme.body)
                        Spacer()
                        Text(interfaceTitle).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    }
                    Text(model.localized(model.needsConnectionCleanup ? "接口释放尚未确认，恢复记录已保留。" : "开启增强模式时创建虚拟接口，停止后释放；无需单独安装网卡驱动。"))
                        .font(AppTheme.caption).foregroundStyle(model.needsConnectionCleanup ? AppTheme.warning : AppTheme.muted)
                    if let session = model.interfaceSession {
                        DisclosureGroup(model.localized("会话身份")) {
                            Text("ID: \(session.id)\nPID: \(session.process.pid) · Index: \(session.interface.index)")
                                .font(AppTheme.caption).textSelection(.enabled)
                        }
                    }
                    HStack {
                        if model.needsConnectionCleanup {
                            Button(model.localized("重试释放与恢复")) { Task { await model.disconnect() } }
                                .buttonStyle(AppActionStyle()).disabled(model.isManagingHelper || model.isSwitchingServer)
                        } else {
                            Button(model.localized("停止并移除接口")) { Task { await model.setCapture(enhanced: true, enabled: false) } }
                                .buttonStyle(AppActionStyle())
                                .disabled(!model.canChangeCapture || (!model.enhancedModeActive && model.interfaceSession == nil && !(model.state == .connecting && model.enhancedCaptureEnabled)))
                            Spacer()
                            Button(model.localized("创建并连接")) { Task { await model.setCapture(enhanced: true, enabled: true) } }
                                .buttonStyle(AppActionStyle(primary: true))
                                .disabled(!model.canChangeCapture || model.helperInstaller.status != .current || model.enhancedModeActive || model.state == .connecting)
                        }
                    }
                }
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
            Text(model.localized("先停止并释放虚拟接口，再卸载后台；保留服务器和密码。"))
        }
    }
}
