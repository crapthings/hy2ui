import SwiftUI

/// Keeps infrequently changed transport options and background maintenance away from the home screen.
struct AppSettingsView: View {
    @Bindable var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.sectionSpacing) {
                Text(model.localized("设置")).font(AppTheme.pageTitle)
                FormGroup(title: model.localized("语言 / Language")) {
                    FieldRow(title: model.localized("界面语言")) {
                        FormMenuPicker(title: model.localized("界面语言"), selection: $model.language,
                                       selectedTitle: model.language.title) {
                            ForEach(AppLanguage.allCases) { language in
                                Text(language.title).tag(language)
                            }
                        }
                    }
                }
                if model.hasServer {
                    VStack(spacing: AppTheme.sectionSpacing) {
                        FormGroup(title: model.localized("增强模式")) {
                            FieldRow(title: model.localized("接管后端")) {
                                FormMenuPicker(title: model.localized("接管后端"), selection: Binding(get: { model.profile.enhancedBackend }, set: { backend in
                                    guard !model.editingDisabled else { return }
                                    model.profile.enhancedBackend = backend
                                    model.save()
                                }), selectedTitle: model.localized(model.profile.enhancedBackend.title)) {
                                    ForEach(EnhancedBackend.allCases, id: \.self) { Text(model.localized($0.title)).tag($0) }
                                }
                            }
                            FieldRow(title: "MTU", help: model.localized("建议保持 1400。")) {
                                settingField(.mtu, title: "MTU", value: String(model.profile.mtu))
                            }
                            FieldRow(title: "DNS", help: model.localized("多个地址用逗号分隔，支持 IPv4 和 IPv6。")) {
                                settingField(.dns, title: "DNS", value: model.profile.dns.joined(separator: ", "))
                            }
                        }
                        FormGroup(title: model.localized("本地代理端口")) {
                            FieldRow(title: "HTTP / HTTPS", help: model.localized("仅本机使用，端口需与 SOCKS5 不同。")) {
                                settingField(.httpPort, title: "HTTP / HTTPS", value: String(model.profile.httpPort))
                            }
                            FieldRow(title: "SOCKS5") {
                                settingField(.socksPort, title: "SOCKS5", value: String(model.profile.socksPort))
                            }
                        }
                    }.disabled(model.editingDisabled)

                } else {
                    Text(model.localized("请先添加服务器"))
                        .foregroundStyle(AppTheme.muted).padding(.vertical)
                }
                HelperManagementView(model: model)
                FormGroup(title: model.localized("增强模式引导")) {
                    HStack(spacing: AppTheme.formSpacing) {
                        Text(model.localized("设置向导")).font(AppTheme.body)
                        Spacer(minLength: 16)
                        Button(model.localized("查看")) { model.showEnhancedSetup() }
                            .buttonStyle(AppActionStyle())
                            .disabled(!model.initialized || model.isManagingHelper)
                    }
                    .frame(minHeight: AppTheme.baseButtonHeight)
                }
                if let error = model.errorMessage {
                    Text(model.localized(error)).font(AppTheme.caption).foregroundStyle(AppTheme.muted).textSelection(.enabled)
                }
            }.frame(maxWidth: 680).padding(AppTheme.pagePadding).frame(maxWidth: .infinity)
        }
        .task { await model.helperInstaller.refresh() }
    }

    private func settingField(_ field: SettingsField, title: String, value: String) -> some View {
        let identity = model.profile.id
        return AutosavingSettingField(title: title, value: value, localized: model.localized) { input in
            try model.updateSetting(input, field: field, profileID: identity)
        }.id(identity)
    }

}
