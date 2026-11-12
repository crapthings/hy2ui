import SwiftUI
import AppKit

/// Keeps infrequently changed transport options and background maintenance away from the home screen.
struct AppSettingsView: View {
    @Bindable var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.sectionSpacing) {
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
                        FormGroup(title: model.localized("连接参数")) {
                            FieldRow(title: "MTU", help: model.localized("建议保持 1400。")) {
                                settingField(.mtu, title: "MTU", value: String(model.profile.mtu))
                            }
                            FieldRow(title: "DNS", help: model.localized("多个地址用逗号分隔，支持 IPv4 和 IPv6。")) {
                                settingField(.dns, title: "DNS", value: model.profile.dns.joined(separator: ", "))
                            }
                        }.disabled(model.editingDisabled)
                        FormGroup(title: model.localized("本地代理端口")) {
                            VStack(alignment: .leading, spacing: AppTheme.formSpacing) {
                                FieldRow(title: "HTTP / HTTPS", help: model.localized("仅本机使用，端口需与 SOCKS5 不同。")) {
                                    settingField(.httpPort, title: "HTTP / HTTPS", value: String(model.profile.httpPort))
                                }
                                FieldRow(title: "SOCKS5") {
                                    settingField(.socksPort, title: "SOCKS5", value: String(model.profile.socksPort))
                                }
                            }.disabled(model.editingDisabled)
                            Button(model.localized("复制终端代理命令"), action: copyShellCommand)
                                .buttonStyle(AppActionStyle()).disabled(!model.initialized || !model.systemProxyCaptureEnabled || model.isFinalDirect)
                        }
                    }

                } else {
                    Text(model.localized("请先添加服务器"))
                        .foregroundStyle(AppTheme.muted).padding(.vertical)
                }
                RoutingSettingsView(model: model)
                HelperManagementView(model: model)
                if let error = model.errorMessage {
                    Text(model.localized(error)).font(AppTheme.caption).foregroundStyle(AppTheme.warning).textSelection(.enabled)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(AppTheme.pagePadding).frame(maxWidth: .infinity)
        }
        .task { await model.helperInstaller.refresh() }
    }

    private func copyShellCommand() {
        guard model.hasServer, model.systemProxyCaptureEnabled, !model.isFinalDirect,
              let command = ShellProxyCommand.make(httpPort: model.profile.httpPort, socksPort: model.profile.socksPort) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }

    private func settingField(_ field: SettingsField, title: String, value: String) -> some View {
        let identity = model.profile.id
        return AutosavingSettingField(title: title, value: value, localized: model.localized) { input in
            try model.updateSetting(input, field: field, profileID: identity)
        }.id(identity)
    }

}
