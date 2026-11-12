import SwiftUI

/// Explains when saved routing preferences apply and offers a user-initiated reconnect for pending changes.
struct RoutingChangeNotice: View {
    @Bindable var model: AppModel
    var body: some View {
        if model.hasPendingRoutingChanges {
            HStack(spacing: 12) {
                Text(model.localized("下次连接生效"))
                    .font(AppTheme.caption).foregroundStyle(AppTheme.muted)
                Spacer()
                Button(model.localized("重新连接")) { Task { await model.reconnect() } }
                    .buttonStyle(AppActionStyle()).disabled(model.isManagingHelper || model.isSwitchingServer)
            }
        }
    }
}
