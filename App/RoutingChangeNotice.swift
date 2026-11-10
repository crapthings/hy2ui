import SwiftUI

/// Explains when saved routing preferences apply and offers a user-initiated reconnect for pending changes.
struct RoutingChangeNotice: View {
    @Bindable var model: AppModel
    var body: some View {
        HStack(spacing: 12) {
            Text(model.localized(model.routing.revision > 0 ? "已保存，下次连接生效。" : "下次连接生效"))
                .font(AppTheme.caption).foregroundStyle(AppTheme.muted)
            Spacer()
            if model.hasPendingRoutingChanges {
                Button(model.localized("重新连接")) { Task { await model.reconnect() } }
                    .buttonStyle(AppActionStyle()).disabled(model.isManagingHelper)
            }
        }
    }
}
