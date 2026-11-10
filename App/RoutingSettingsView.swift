import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Edits automatic proxy sources and bounded bypass rules while preserving the active session's settings.
struct RoutingSettingsView: View {
    @Bindable var model: AppModel
    @State private var error: String?
    @State private var draftPattern = ""
    private var configuration: RoutingConfiguration { model.routing.configuration }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.sectionSpacing) {
            FormGroup(title: model.localized("系统代理规则")) {
                FieldRow(title: model.localized("代理方式")) {
                    FormMenuPicker(title: model.localized("代理方式"), selection: Binding(
                        get: { configuration.mode }, set: { value in update { $0.mode = value } }
                    ), selectedTitle: model.localized(configuration.mode.title)) {
                        ForEach(SystemProxyMode.allCases) { Text(model.localized($0.title)).tag($0) }
                    }
                }
                if configuration.mode == .externalPAC {
                    FieldRow(title: "PAC URL", help: model.localized("PAC 需指向当前本地代理端口。")) {
                        AutosavingSettingField(title: "PAC URL", value: configuration.pacURL, localized: model.localized) { value in
                            try model.routing.update { $0.pacURL = value.trimmingCharacters(in: .whitespacesAndNewlines) }
                        }
                    }
                }
                if configuration.mode == .generatedPAC {
                    FieldRow(title: model.localized("直连域名"), help: model.localized("用逗号分隔，包含所填域名的子域名。")) {
                        AutosavingSettingField(title: "example.com, example.org", value: configuration.directDomains.joined(separator: ", "), localized: model.localized) { value in
                            try model.routing.update { configuration in
                                configuration.directDomains = try value.split(whereSeparator: { $0 == "," || $0.isNewline }).map { try RoutingConfiguration.domain(String($0)) }
                            }
                        }
                    }
                    Toggle(model.localized("本地域名和内网 IP 直连"), isOn: Binding(
                        get: { configuration.bypassLocalNetworks }, set: { value in update { $0.bypassLocalNetworks = value } }
                    )).toggleStyle(.switch).controlSize(.small)
                }
                if configuration.mode != .manual {
                    Text(model.localized("PAC 用于系统代理，请关闭增强模式后连接。"))
                        .font(AppTheme.caption).foregroundStyle(AppTheme.muted)
                }
            }
            FormGroup(title: model.localized("直连应用")) {
                Text(model.localized("仅用于本地增强模式，请关闭系统代理。"))
                    .font(AppTheme.caption).foregroundStyle(AppTheme.muted)
                Text(model.localized("无法识别的流量继续走代理，规则在下次连接时生效。"))
                    .font(AppTheme.caption).foregroundStyle(AppTheme.muted)
                ForEach(configuration.directProcesses, id: \.self) { pattern in
                    HStack(spacing: 12) {
                        Text(pattern).font(AppTheme.body).lineLimit(2).textSelection(.enabled)
                        Spacer()
                        Button(model.localized("删除"), systemImage: "minus.circle") {
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
            if let value = error ?? model.routing.error {
                Text(model.localized(value)).font(AppTheme.caption).foregroundStyle(AppTheme.warning)
            }
        }.disabled(model.editingDisabled)
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
