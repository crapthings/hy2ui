import SwiftUI
import AppKit

/// Displays selectable connection diagnostics independently from the connection and configuration screens.
struct ConnectionLogsView: View {
    @Bindable var model: AppModel
    @State private var detailed = true
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Text(model.localized("连接日志")).font(AppTheme.pageTitle)
                Spacer()
                Toggle(model.localized("详细信息"), isOn: $detailed).toggleStyle(.checkbox)
                Button(model.localized("复制")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.logs.map { model.localizedLog($0, detailed: detailed) }.joined(separator: "\n"), forType: .string)
                }.buttonStyle(AppActionStyle()).disabled(model.logs.isEmpty)
                Button(model.localized("清空")) { model.clearLogs() }.buttonStyle(AppActionStyle()).disabled(model.logs.isEmpty)
            }
            ScrollView {
                Text(model.logs.isEmpty ? model.localized("暂无连接记录。") : model.logs.map { model.localizedLog($0, detailed: detailed) }.joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(20)
            }
            .background(AppTheme.cloud, in: RoundedRectangle(cornerRadius: AppTheme.cardRadius))
        }.padding(AppTheme.pagePadding)
    }
}
