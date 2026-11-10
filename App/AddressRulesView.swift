import SwiftUI

/// Manages domain and literal-IP decisions with visible capture-mode boundaries and canonical input previews.
struct AddressRulesView: View {
    @Bindable var model: AppModel
    let openSettings: () -> Void
    @State private var draft = ""
    @State private var editingTarget: String?
    @State private var action = AddressRuleAction.direct
    @State private var error: String?
    private var preview: AddressRule? { try? AddressRule(target: draft, action: action) }
    private var rules: [AddressRule] {
        var indexed = Dictionary(uniqueKeysWithValues: model.routing.configuration.addressRules.map { ($0.target, $0) })
        for domain in model.routing.configuration.directDomains {
            if let rule = try? AddressRule(target: domain, action: .direct), indexed[rule.target] == nil { indexed[rule.target] = rule }
        }
        return indexed.values.sorted { $0.target < $1.target }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.sectionSpacing) {
                Text(model.localized("地址规则")).font(AppTheme.pageTitle)
                HStack {
                    Text(model.localized("域名用于自动 PAC；IP 用于自动 PAC和本地增强模式。"))
                        .font(AppTheme.caption).foregroundStyle(AppTheme.muted)
                    Spacer()
                    Button(model.localized("代理设置"), action: openSettings).buttonStyle(AppActionStyle())
                }
                FormGroup(title: model.localized("规则")) {
                    if rules.isEmpty { Text(model.localized("尚无地址规则")).foregroundStyle(AppTheme.muted) }
                    ForEach(rules) { rule in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(rule.target).textSelection(.enabled)
                                Text(model.localized(scope(rule))).font(AppTheme.caption).foregroundStyle(AppTheme.muted)
                            }
                            Spacer()
                            Menu(model.localized(rule.action.title)) {
                                ForEach(AddressRuleAction.allCases, id: \.self) { value in
                                    Button(model.localized(value.title)) { save(target: rule.target, action: value) }
                                }
                                Button(model.localized("编辑")) { draft = rule.target; action = rule.action; editingTarget = rule.target }
                                Divider()
                                Button(model.localized("恢复默认")) { update { config in
                                    config.addressRules.removeAll { $0.target == rule.target }
                                    config.directDomains.removeAll { (try? RoutingConfiguration.domain($0)) == rule.target }
                                } }
                            }.fixedSize()
                        }
                    }
                }
                FormGroup(title: model.localized("添加规则")) {
                    FieldRow(title: model.localized("地址")) {
                        TextField("example.com / 192.168.50.10 / 203.0.113.0/24", text: $draft)
                            .textFieldStyle(FilledFieldStyle()).onSubmit(add)
                    }
                    FieldRow(title: model.localized("连接方式")) {
                        FormMenuPicker(title: model.localized("连接方式"), selection: $action, selectedTitle: model.localized(action.title)) {
                            ForEach(AddressRuleAction.allCases, id: \.self) { Text(model.localized($0.title)).tag($0) }
                        }
                    }
                    HStack {
                        Text(model.localized(preview.map { $0.isDomain ? "匹配此域名及其子域名。" : "匹配此 IP 或网段；较具体的 IP 规则优先。" } ?? "输入域名、IPv4、IPv6 或 CIDR 网段。"))
                            .font(AppTheme.caption).foregroundStyle(AppTheme.muted)
                        Spacer()
                        if editingTarget != nil { Button(model.localized("取消")) { editingTarget = nil; draft = "" }.buttonStyle(AppActionStyle()) }
                        Button(model.localized(editingTarget == nil ? "添加" : "更新"), action: add).buttonStyle(AppActionStyle()).disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                Text(model.localized("本地网络绕过优先；IP 规则不解析域名，也不覆盖已有局域网或 VPN 路由。"))
                    .font(AppTheme.caption).foregroundStyle(AppTheme.muted)
                RoutingChangeNotice(model: model)
                if let value = error ?? model.routing.error { Text(model.localized(value)).font(AppTheme.caption).foregroundStyle(AppTheme.warning) }
            }.frame(maxWidth: 680).padding(AppTheme.pagePadding).frame(maxWidth: .infinity)
        }.disabled(!model.initialized)
    }
    private func scope(_ rule: AddressRule) -> String {
        let config = model.routing.configuration
        if model.profile.systemProxyEnabled && config.mode == .externalPAC { return "由外部 PAC 管理" }
        if model.profile.systemProxyEnabled && config.mode == .generatedPAC { return "自动 PAC" }
        if !rule.isDomain && model.profile.enhancedModeEnabled && model.profile.enhancedBackend == .localTun { return "本地增强模式" }
        return rule.isDomain ? "仅自动 PAC · 当前未启用" : "自动 PAC / 本地增强模式 · 当前未启用"
    }
    private func update(_ change: (inout RoutingConfiguration) throws -> Void) {
        do { try model.routing.update(change); error = nil } catch { self.error = error.localizedDescription }
    }
    private func save(target: String, action: AddressRuleAction, replacing: String? = nil) {
        update { config in
            let rule = try AddressRule(target: target, action: action)
            config.addressRules.removeAll { $0.target == rule.target || $0.target == replacing }
            config.directDomains.removeAll { (try? RoutingConfiguration.domain($0)) == rule.target || (try? RoutingConfiguration.domain($0)) == replacing }
            config.addressRules.append(rule)
        }
    }
    private func add() { save(target: draft, action: action, replacing: editingTarget); if error == nil { draft = ""; editingTarget = nil } }
}
