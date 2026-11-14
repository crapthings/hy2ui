import SwiftUI
import AppKit

/// Caches executable/application icons without reopening bundle metadata on each traffic sample.
@MainActor
private enum ProcessIconCache {
    static let images = NSCache<NSString, NSImage>()
    static func image(path: String) -> NSImage {
        if let cached = images.object(forKey: path as NSString) { return cached }
        let bundle = path.range(of: ".app/").map { String(path[..<$0.lowerBound]) + ".app" } ?? path
        let icon = NSWorkspace.shared.icon(forFile: bundle)
        images.countLimit = 128
        images.setObject(icon, forKey: path as NSString)
        return icon
    }
}

/// Shows one process and its share of the displayed ranking metric within a fixed-height row.
struct DashboardProcessRow: View {
    let row: ProcessNetworkModel.Row
    let cumulative: Bool
    let share: Double
    let localized: (String) -> String
    @State private var icon: NSImage?

    private var details: String {
        let upload = cumulative ? TrafficFormatting.bytes(row.sent) : TrafficFormatting.rate(row.uploadRate)
        let download = cumulative ? TrafficFormatting.bytes(row.received) : TrafficFormatting.rate(row.downloadRate)
        return "\(row.displayName) · PID \(row.sample.pid)\n\(localized(cumulative ? "已发送" : "上传")): \(upload)\n\(localized(cumulative ? "已接收" : "下载")): \(download)\n\(row.identity?.target.path ?? "")"
    }

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let icon { Image(nsImage: icon).resizable() }
                else { Image(systemName: "terminal").resizable().scaledToFit().foregroundStyle(AppTheme.muted) }
            }.frame(width: 28, height: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 10) {
                    Text(row.displayName).font(AppTheme.body).lineLimit(1).truncationMode(.tail)
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    Text(cumulative
                        ? TrafficFormatting.bytes(row.sent + row.received)
                        : TrafficFormatting.rate(row.uploadRate + row.downloadRate))
                        .font(AppTheme.caption).monospacedDigit().fixedSize()
                }
                GeometryReader { geometry in
                    Capsule().fill(AppTheme.controlSurface)
                    Capsule().fill(AppTheme.accent.opacity(0.45))
                        .frame(width: geometry.size.width * min(1, max(0, share)))
                }.frame(height: 4).accessibilityHidden(true)
            }.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }.frame(height: 56).help(details)
            .task(id: row.identity?.target.path) {
                icon = row.identity.map { ProcessIconCache.image(path: $0.target.path) }
            }
    }
}
