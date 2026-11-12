import SwiftUI

/// Shares column widths between process list headings and live rows.
enum ProcessListLayout {
    static let pid: CGFloat = 56
    static let rule: CGFloat = 64
    static let rate: CGFloat = 112
    static let totals: CGFloat = 116
    static let spacing: CGFloat = 16
}

/// Provides sortable column headings, including individual upload/download and sent/received controls.
struct ProcessListHeader: View {
    let localized: (String) -> String
    let sort: ProcessListSort
    let select: (ProcessSortField) -> Void

    var body: some View {
        HStack(spacing: ProcessListLayout.spacing) {
            heading("PID", field: .pid).frame(width: ProcessListLayout.pid, alignment: .leading)
            heading(localized("进程"), field: .name).frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 4) {
                heading(localized("上传"), field: .upload, alignment: .trailing)
                heading(localized("下载"), field: .download, alignment: .trailing)
            }.frame(width: ProcessListLayout.rate, alignment: .trailing)
            VStack(alignment: .trailing, spacing: 4) {
                heading(localized("已发送"), field: .sent, alignment: .trailing)
                heading(localized("已接收"), field: .received, alignment: .trailing)
            }.frame(width: ProcessListLayout.totals, alignment: .trailing)
        }
        .font(AppTheme.caption).foregroundStyle(AppTheme.muted)
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private func heading(_ title: String, field: ProcessSortField, alignment: Alignment = .leading) -> some View {
        Button { select(field) } label: {
            HStack(spacing: 3) {
                Text(title).lineLimit(1)
                Image(systemName: sort.ascending ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .opacity(sort.field == field ? 1 : 0).accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: 20, alignment: alignment).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(sort.field == field ? AppTheme.accent : AppTheme.muted)
        .help(localized(sort.nextActionTitle(for: field)))
        .accessibilityHint(localized(sort.nextActionTitle(for: field)))
        .accessibilityValue(sort.field == field ? localized(sort.ascending ? "升序" : "降序") : "")
    }
}

/// Stacks outbound and inbound measurements in the same order for both rate and cumulative columns.
struct ProcessTransferValues: View {
    let outgoing: String
    let incoming: String
    let outgoingTitle: String
    let incomingTitle: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 5) {
                AppIcon(symbol: .upload, size: 12).foregroundStyle(AppTheme.upload)
                Text(outgoing)
            }
            HStack(spacing: 5) {
                AppIcon(symbol: .download, size: 12).foregroundStyle(AppTheme.download)
                Text(incoming)
            }
        }.font(AppTheme.caption).monospacedDigit().lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(outgoingTitle): \(outgoing), \(incomingTitle): \(incoming)"))
    }
}

/// Displays one selectable process with its PID, name, full-path preview, rule and paired transfer values.
struct ProcessListRow: View {
    let row: ProcessNetworkModel.Row
    let selected: Bool
    let localized: (String) -> String

    var body: some View {
        HStack(spacing: ProcessListLayout.spacing) {
            Text(String(row.sample.pid)).font(AppTheme.caption).monospacedDigit()
                .foregroundStyle(AppTheme.muted)
                .frame(width: ProcessListLayout.pid, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                Text(row.displayName).font(.system(size: 14, weight: .medium)).lineLimit(1)
                Text(row.identity?.target.path ?? "—")
                    .font(AppTheme.caption).foregroundStyle(AppTheme.muted)
                    .lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(row.identity?.target.path ?? row.sample.name)
            ProcessTransferValues(outgoing: TrafficFormatting.rate(row.uploadRate), incoming: TrafficFormatting.rate(row.downloadRate),
                                  outgoingTitle: localized("上传"), incomingTitle: localized("下载"))
                .frame(width: ProcessListLayout.rate, alignment: .trailing)
            ProcessTransferValues(outgoing: TrafficFormatting.bytes(row.sent), incoming: TrafficFormatting.bytes(row.received),
                                  outgoingTitle: localized("已发送"), incomingTitle: localized("已接收"))
                .frame(width: ProcessListLayout.totals, alignment: .trailing)
        }
        .foregroundStyle(row.isPresent ? AppTheme.ink : AppTheme.muted)
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(selected ? AppTheme.selection : AppTheme.paper)
        .contentShape(Rectangle())
    }
}
