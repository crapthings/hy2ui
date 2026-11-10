import SwiftUI

/// Shows core-only transfer rates and calendar totals without mixing system process counters into billing data.
struct DashboardTrafficView: View {
    @Bindable var model: AppModel
    var openActivity: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                metric("下载", value: TrafficFormatting.rate(model.state == .connected ? model.dashboard.downloadRate : 0), symbol: "arrow.down")
                metric("上传", value: TrafficFormatting.rate(model.state == .connected ? model.dashboard.uploadRate : 0), symbol: "arrow.up")
                metric("今日流量", value: TrafficFormatting.bytes(model.dashboard.today.total), symbol: "sun.max")
                metric("本月流量", value: TrafficFormatting.bytes(model.dashboard.month.total), symbol: "calendar")
            }
            Text(model.localized("仅统计 Hy2UI 连接，含协议开销。"))
                .font(AppTheme.caption).foregroundStyle(AppTheme.muted)
            if model.profile.enhancedModeEnabled && model.profile.enhancedBackend == .networkExtension && !model.profile.systemProxyEnabled {
                Text(model.localized("此后端暂不提供连接统计。"))
                    .font(AppTheme.caption).foregroundStyle(AppTheme.warning)
            }
            if let error = model.dashboard.error {
                Text(model.localized(error)).font(AppTheme.caption).foregroundStyle(AppTheme.warning)
            }
            Button(action: openActivity) {
                HStack {
                    Label(model.localized("查看进程网络活动"), systemImage: "chart.bar")
                    Spacer()
                    Image(systemName: "arrow.right")
                }
            }.buttonStyle(AppActionStyle())
        }
    }

    private func metric(_ title: String, value: String, symbol: String) -> some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 12) {
                Label(model.localized(title), systemImage: symbol).font(AppTheme.caption).foregroundStyle(AppTheme.muted)
                Text(value).font(.system(size: 23, weight: .medium)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            }
        }
    }
}
