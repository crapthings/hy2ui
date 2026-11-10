import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Manages application bypass patterns independently from system proxy and domain settings.
struct AppRulesView: View {
    @Bindable var model: AppModel
    @State private var error: String?
    @State private var draftPattern = ""
    private var configuration: RoutingConfiguration { model.routing.configuration }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.sectionSpacing) {
                Text(model.localized("应用规则")).font(AppTheme.pageTitle)
                FormGroup(title: model.localized("直连应用")) {
                    Text(model.localized(model.profile.enhancedModeEnabled && model.profile.enhancedBackend == .localTun && !model.profile.systemProxyEnabled ? "本地增强模式" : "应用直连需要仅开启本地增强模式；当前未启用。"))
                        .font(AppTheme.caption).foregroundStyle(AppTheme.muted)
                    Text(model.localized("无法识别的流量继续走代理，规则在下次连接时生效。"))
                        .font(AppTheme.caption).foregroundStyle(AppTheme.muted)
                    ForEach(configuration.directProcesses, id: \.self) { pattern in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(displayName(pattern)).font(AppTheme.body).lineLimit(1)
                                if displayName(pattern) != pattern {
                                    Text(pattern).font(AppTheme.caption).foregroundStyle(AppTheme.muted).lineLimit(2).textSelection(.enabled)
                                }
                            }
                            Spacer()
                            Button(model.localized("恢复默认"), systemImage: "minus.circle") {
                                update { $0.directProcesses.removeAll { $0 == pattern } }
                            }.labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(AppTheme.muted)
                        }
                    }
                    HStack {
                        TextField(model.localized("进程名称或路径，可使用 * 和 ?"), text: $draftPattern).textFieldStyle(FilledFieldStyle())
                            .onSubmit(addPattern)
                        Button(model.localized("添加"), action: addPattern).buttonStyle(AppActionStyle()).disabled(draftPattern.isEmpty)
                        Button(model.localized("选择应用"), action: selectApplication).buttonStyle(AppActionStyle())
                    }
                }
                RoutingChangeNotice(model: model)
                if let value = error ?? model.routing.error {
                    Text(model.localized(value)).font(AppTheme.caption).foregroundStyle(AppTheme.warning)
                }
            }.frame(maxWidth: 680).padding(AppTheme.pagePadding).frame(maxWidth: .infinity)
        }.disabled(!model.initialized)
    }

    private func displayName(_ pattern: String) -> String {
        guard pattern.hasPrefix("/") else { return pattern }
        if let end = pattern.range(of: ".app/") {
            return URL(fileURLWithPath: String(pattern[..<end.lowerBound])).lastPathComponent
        }
        return URL(fileURLWithPath: pattern).lastPathComponent
    }

    private func update(_ change: (inout RoutingConfiguration) throws -> Void) {
        do { try model.routing.update(change); error = nil }
        catch { self.error = error.localizedDescription }
    }
    private func addPattern() {
        let pattern = draftPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        update { configuration in
            try ProcessRulePattern.validate(pattern)
            if !configuration.directProcesses.contains(pattern) { configuration.directProcesses.append(pattern) }
        }
        if error == nil { draftPattern = "" }
    }
    private func selectApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let pattern = url.standardizedFileURL.path + "/"
        update { if !$0.directProcesses.contains(pattern) { $0.directProcesses.append(pattern) } }
    }
}
