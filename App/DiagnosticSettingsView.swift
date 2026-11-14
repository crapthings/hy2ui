import SwiftUI

/// Saves explicitly validated diagnostic targets with the first target used by the dashboard latency value.
struct DiagnosticSettingsView: View {
    let localized: (String) -> String
    @AppStorage(DiagnosticTargets.key) private var stored = DiagnosticTargets.defaults
    @State private var draft = ""
    @State private var notice: String?
    var body: some View {
        FormGroup(title: localized("网络诊断")) {
            Text(localized("测试地址，每行一个；第一个地址用于首页延迟。支持 1 至 4 个 HTTPS 地址，仅手动诊断时请求。"))
                .font(AppTheme.caption).foregroundStyle(AppTheme.muted)
            TextEditor(text: $draft).font(.system(.body, design: .monospaced)).frame(height: 95)
            HStack {
                Button(localized("保存")) {
                    do { stored = try DiagnosticTargets.parse(draft).joined(separator: "\n"); notice = "已保存" }
                    catch { notice = error.localizedDescription }
                }.buttonStyle(AppActionStyle())
                if let notice { Text(localized(notice)).font(AppTheme.caption) }
            }
        }.onAppear { draft = stored }.onChange(of: draft) { _, _ in notice = nil }
    }
}
