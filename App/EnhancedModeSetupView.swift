import SwiftUI

/// Presents a centered standalone introduction with compact skip and install actions.
struct EnhancedModeSetupView: View {
    @Bindable var model: AppModel
    private var ready: Bool { model.helperInstaller.status == .current }

    var body: some View {
        VStack(spacing: 20) {
            Text(model.localized(ready ? "增强模式已就绪" : "增强模式"))
                .font(AppTheme.pageTitle).foregroundStyle(AppTheme.ink)
                .multilineTextAlignment(.center)
            if model.isManagingHelper {
                ProgressView().controlSize(.small)
            } else if !ready, model.helperInstaller.failed, let message = model.helperInstaller.message {
                Text(model.localized(message)).font(AppTheme.caption)
                    .foregroundStyle(AppTheme.warning).textSelection(.enabled)
                    .multilineTextAlignment(.center)
            }
            HStack {
                Button { model.skipEnhancedSetup() } label: {
                    Text(model.localized("跳过")).frame(minWidth: 64)
                }
                .buttonStyle(AppActionStyle()).keyboardShortcut(.cancelAction)
                Spacer()
                Button { Task { await model.installEnhancedSetup() } } label: {
                    Text(model.localized("安装")).frame(minWidth: 64)
                }
                .buttonStyle(AppActionStyle(primary: true)).keyboardShortcut(.defaultAction)
                .disabled(ready)
            }
            .padding(.top, 8).disabled(model.isManagingHelper)
        }
        .frame(width: 360)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
