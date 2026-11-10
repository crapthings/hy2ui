import SwiftUI

/// Presents a paper-based connection panel with one primary action and the selected server summary.
struct ConnectionHomeView: View {
    @Bindable var model: AppModel
    var openSettings: () -> Void
    var editServer: () -> Void

    private var connected: Bool { model.state == .connected }
    private var working: Bool { model.state == .connecting || model.state == .stopping || model.isManagingHelper }
    private var actionTitle: String {
        if model.needsConnectionCleanup { return model.localized("重试清理") }
        switch model.state {
        case .connecting: return model.localized("取消连接")
        case .connected: return model.localized("断开连接")
        case .stopping: return model.localized("正在断开")
        default: return model.localized("连接")
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                Text(model.localized(model.state.title)).font(AppTheme.pageTitle)
                VStack(alignment: .leading, spacing: 24) {
                    HStack(spacing: 12) {
                        Image(systemName: "server.rack").font(.system(size: 21, weight: .regular))
                            .frame(width: 44, height: 44)
                            .background(AppTheme.cloud, in: RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 6) {
                            Text(model.hasServer ? model.profile.name : model.localized("还没有服务器"))
                                .font(AppTheme.sectionTitle).lineLimit(2)
                            if model.hasServer {
                                Text(model.profile.serverAddress)
                                    .font(AppTheme.caption).foregroundStyle(AppTheme.muted).textSelection(.enabled)
                            }
                        }
                        Spacer(minLength: 8)
                        Button(model.hasServer ? model.localized("编辑") : model.localized("添加"), action: editServer)
                            .buttonStyle(AppActionStyle()).disabled(model.editingDisabled)
                    }
                    Button {
                        Task {
                            if connected || model.state == .connecting || model.needsConnectionCleanup { await model.disconnect() }
                            else { await model.connect() }
                        }
                    } label: {
                        HStack(spacing: 10) {
                            if working { ProgressView().controlSize(.small) }
                            else { Image(systemName: "power").font(.system(size: 15, weight: .medium)) }
                            Text(actionTitle)
                            Spacer(minLength: 20)
                            Image(systemName: connected ? "stop.fill" : "arrow.right").font(.system(size: 12))
                        }.frame(width: 180)
                    }
                    .buttonStyle(AppActionStyle(primary: true))
                    .disabled(model.isManagingHelper || model.state == .stopping || (!model.canConnect && !connected && model.state != .connecting && !model.needsConnectionCleanup))
                    .accessibilityLabel(actionTitle)
                }
                .padding(28)
                .background(AppTheme.cloud, in: RoundedRectangle(cornerRadius: AppTheme.cardRadius))
                VStack(alignment: .leading, spacing: 12) {
                    if model.requiresHelperInstallation {
                        Button(model.localized("前往设置安装增强模式"), action: openSettings)
                            .buttonStyle(.link)
                    }
                    if model.hasUnsavedChanges {
                        Text(model.localized("未保存"))
                            .foregroundStyle(AppTheme.muted)
                    }
                    if model.needsProxyRecovery && model.state != .connected {
                        Button(model.localized("恢复系统代理")) { Task { await model.recoverProxy() } }
                            .buttonStyle(AppActionStyle())
                            .disabled(model.state == .stopping || model.isManagingHelper)
                    }
                    if let error = model.errorMessage {
                        Text(model.localized(error)).foregroundStyle(AppTheme.warning).textSelection(.enabled)
                    }
                }.font(AppTheme.caption)
            }
            .padding(AppTheme.pagePadding)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }
}
