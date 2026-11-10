import SwiftUI

/// Selects the system proxy source without mixing domain or application rules into general settings.
struct RoutingSettingsView: View {
    @Bindable var model: AppModel
    @State private var error: String?
    private var configuration: RoutingConfiguration { model.routing.configuration }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.sectionSpacing) {
            FormGroup(title: model.localized("系统代理")) {
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
                if configuration.mode != .manual {
                    Text(model.localized("PAC 用于系统代理，请关闭增强模式后连接。"))
                        .font(AppTheme.caption).foregroundStyle(AppTheme.muted)
                }
            }
            FormGroup(title: model.localized("本地网络")) {
                Toggle(model.localized("绕过本地网络"), isOn: Binding(
                    get: { configuration.bypassLocalNetworks }, set: { value in update { $0.bypassLocalNetworks = value } }
                )).toggleStyle(.switch).controlSize(.small)
                Text(model.localized(configuration.mode == .externalPAC && model.profile.systemProxyEnabled ? "系统代理由外部 PAC 管理；此选项仍用于增强模式。" : "本机、局域网设备与本地域名直接连接。"))
                    .font(AppTheme.caption).foregroundStyle(AppTheme.muted)
                DisclosureGroup(model.localized("查看范围")) {
                    Text((LocalNetworkPolicy.ipv4 + LocalNetworkPolicy.ipv6 + LocalNetworkPolicy.domains).joined(separator: "\n"))
                        .font(AppTheme.caption).foregroundStyle(AppTheme.muted).textSelection(.enabled)
                }
            }
            RoutingChangeNotice(model: model)
            if let value = error ?? model.routing.error {
                Text(model.localized(value)).font(AppTheme.caption).foregroundStyle(AppTheme.warning)
            }
        }.disabled(!model.initialized)
    }

    private func update(_ change: (inout RoutingConfiguration) throws -> Void) {
        do { try model.routing.update(change); error = nil }
        catch { self.error = error.localizedDescription }
    }
}
