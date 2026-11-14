import SwiftUI

/// Presents capture switches, connection errors and the supported CLI management cards.
struct ConnectionHomeView: View {
    @Bindable var model: AppModel
    var editServer: () -> Void
    var openActivity: () -> Void

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.sectionSpacing) {
                    attention
                    DashboardTrafficView(model: model, wide: geometry.size.width >= 1000,
                                         openActivity: openActivity)
                }
                .padding(AppTheme.pagePadding)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    @ViewBuilder private var attention: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.needsConnectionCleanup {
                Button(model.localized("重试清理")) { Task { await model.disconnect() } }
                    .buttonStyle(AppActionStyle()).disabled(model.isManagingHelper || model.isSwitchingServer)
            } else if model.defaultServer == nil {
                Button(model.localized("添加服务器"), action: editServer)
                    .buttonStyle(AppActionStyle(primary: true)).disabled(model.editingDisabled)
            } else if model.automaticCaptureEnabled && !model.requiresHelperInstallation && model.state == .idle {
                Button(model.localized("重试启动")) { Task { await model.connect() } }
                    .buttonStyle(AppActionStyle()).disabled(!model.canConnect || model.isSwitchingServer)
            }
            if model.needsProxyRecovery && model.state != .connected {
                Button(model.localized("恢复系统代理")) { Task { await model.recoverProxy() } }
                    .buttonStyle(AppActionStyle()).disabled(model.state == .stopping || model.isManagingHelper)
            }
            if let notice = model.policyNotice {
                Text(notice).foregroundStyle(AppTheme.warning).textSelection(.enabled)
            }
            if let error = model.errorMessage {
                Text(model.localized(error)).foregroundStyle(AppTheme.warning).textSelection(.enabled)
            }

        }.font(AppTheme.caption)
    }
}
