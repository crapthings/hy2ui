import SwiftUI

/// Displays selectable connection diagnostics independently from the connection and configuration screens.
struct ConnectionLogsView: View {
    @Bindable var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(model.localized("连接日志")).font(AppTheme.pageTitle)
            ScrollView {
                Text(model.logs.isEmpty ? model.localized("暂无连接记录。") : model.logs.map { model.localizedLog($0) }.joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(20)
            }
            .background(AppTheme.cloud, in: RoundedRectangle(cornerRadius: AppTheme.cardRadius))
        }.padding(AppTheme.pagePadding)
    }
}
