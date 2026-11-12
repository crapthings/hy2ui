import SwiftUI
import AppKit

/// Displays selectable connection diagnostics independently from the connection and configuration screens.
struct ConnectionLogsView: View {
    @Bindable var model: AppModel
    @State private var detailed = true

    private var logText: String { model.logs.map { model.localizedLog($0, detailed: detailed) }.joined(separator: "\n") }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                if !model.logs.isEmpty {
                    Text(logText)
                        .font(.system(size: 12, design: .monospaced)).lineSpacing(6).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(AppTheme.cardPadding)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                if model.logs.isEmpty {
                    AppEmptyState(symbol: .logs, title: model.localized("暂无连接记录。"))
                        .allowsHitTesting(false)
                }
            }
            HStack(spacing: 12) {
                Toggle(model.localized("详细信息"), isOn: $detailed).toggleStyle(.checkbox)
                Spacer()
                Button(model.localized("复制")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(logText, forType: .string)
                }.buttonStyle(AppActionStyle()).disabled(model.logs.isEmpty)
                Button(model.localized("清空"), role: .destructive) { model.clearLogs() }
                    .buttonStyle(AppActionStyle()).disabled(model.logs.isEmpty)
            }.padding(12)
        }
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.cardRadius))
        .modifier(AppCardSurface())
        .padding(AppTheme.pagePadding)
    }
}
