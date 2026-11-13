import SwiftUI

/// Selects the system proxy source without mixing domain or application rules into general settings.
struct RoutingSettingsView: View {
    @Bindable var model: AppModel
    @State private var error: String?
    private var configuration: RoutingConfiguration { model.routing.configuration }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.sectionSpacing) {
            FormGroup(title: model.localized("代理配置")) {
                FieldRow(title: model.localized("请求模式"), help: model.localized("规则由 Rust 核心执行，修改后重新连接生效。")) {
                    FormMenuPicker(title: model.localized("请求模式"), selection: Binding(
                        get: { configuration.requestMode }, set: { value in update { $0.mode = .native; $0.requestMode = value } }
                    ), selectedTitle: model.localized(configuration.requestMode.title)) {
                        ForEach(RequestRoutingMode.allCases, id: \.self) { Text(model.localized($0.title)).tag($0) }
                    }
                }
            }
            FormGroup(title: model.localized("本地网络")) {
                Toggle(model.localized("绕过本地网络"), isOn: Binding(
                    get: { configuration.bypassLocalNetworks }, set: { value in update { $0.bypassLocalNetworks = value } }
                )).toggleStyle(.switch).controlSize(.small)
                Text(model.localized("规则模式下，显式规则优先；本地 IP 与 local、localhost、home.arpa 域名在 FINAL 前直连。IP 规则不主动解析域名。"))
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
