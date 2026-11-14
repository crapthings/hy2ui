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
                                FieldRow(title: "HTTP / HTTPS", help: model.localized("HTTP 和 HTTPS 共用此代理端口，需与 SOCKS5 端口不同。")) {
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
                DiagnosticSettingsView(localized: model.localized)
                RoutingSettingsView(model: model)
                FormGroup(title: model.localized("增强模式实现")) {
                    Picker(model.localized("模式"), selection: Binding(get: { model.profile.enhancedBackend }, set: { model.selectEnhancedBackend($0) })) {
                        ForEach(EnhancedBackend.allCases, id: \.self) { Text(model.localized($0.title)).tag($0) }
                    }.disabled(model.editingDisabled)
                    Text(model.localized("兼容模式使用管理员后台创建本地 TUN，无需 Network Extension；首次使用需安装后台并授权。"))
                        .font(AppTheme.caption).foregroundStyle(AppTheme.muted)
                    #if HY2_NETWORK_EXTENSION
                    Text(model.localized("NE 模式需要 Apple 签名和系统批准；当前离线构建未开放接管。"))
                        .font(AppTheme.caption).foregroundStyle(AppTheme.muted)
                    #else
                    Text(model.localized("当前版本提供兼容模式；NE 模式由单独的扩展版本提供。"))
                        .font(AppTheme.caption).foregroundStyle(AppTheme.muted)
                    #endif
                }
                if model.profile.enhancedBackend == .localTun { HelperManagementView(model: model) }
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
