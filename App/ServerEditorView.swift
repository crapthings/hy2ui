import SwiftUI

/// Edits one server identity and its Keychain credentials with explicit save and removal actions.
struct ServerEditorView: View {
    @Bindable var model: AppModel
    var removed: () -> Void
    @State private var confirmingRemoval = false

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.sectionSpacing) {
                    Group {
                        if geometry.size.width >= 1000 {
                            HStack(alignment: .top, spacing: AppTheme.gridSpacing) {
                                connectionFields
                                securityFields
                            }
                        } else {
                            connectionFields
                            securityFields
                        }
                    }.disabled(model.editingDisabled)
                    actions
                    if let error = model.errorMessage {
                        Text(model.localized(error)).font(AppTheme.caption).foregroundStyle(AppTheme.warning)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(AppTheme.pagePadding)
            }
        }
        .confirmationDialog(model.localized("删除这个服务器？"), isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button(model.localized("删除服务器"), role: .destructive) { if model.removeServer() { removed() } }
        } message: { Text(model.localized("删除服务器及其密码。")) }
    }

    private var connectionFields: some View {
        FormGroup(title: model.localized("连接信息")) {
            FieldRow(title: model.localized("名称")) {
                TextField(model.localized("名称"), text: $model.profile.name, prompt: Text(model.localized("例如：东京 · 主线路")))
            }
            HStack(alignment: .top, spacing: AppTheme.formSpacing) {
                FieldRow(title: model.localized("服务器")) {
                    TextField(model.localized("服务器"), text: $model.profile.host, prompt: Text("example.com"))
                }
                FieldRow(title: model.localized("端口")) {
                    TextField(model.localized("端口"), value: $model.profile.port, format: .number.grouping(.never))
                }.frame(width: 100)
            }
            FieldRow(title: model.localized("认证密码")) {
                SecureField(model.localized("认证密码"), text: $model.credentials.password)
            }
        }
    }

    private var securityFields: some View {
        FormGroup(title: model.localized("传输安全")) {
            FieldRow(title: model.localized("TLS 服务器名称")) {
                TextField(model.localized("TLS 服务器名称"), text: $model.profile.serverName, prompt: Text(model.localized("留空时使用服务器地址")))
            }
            FieldRow(title: model.localized("Salamander 密码")) {
                SecureField(model.localized("Salamander 密码"), text: $model.credentials.obfuscationPassword, prompt: Text(model.localized("可选")))
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button(model.localized("删除服务器"), role: .destructive) { confirmingRemoval = true }
                .buttonStyle(AppActionStyle()).disabled(model.editingDisabled)
            Spacer()
            if model.hasUnsavedChanges {
                Text(model.localized("未保存")).font(AppTheme.caption).foregroundStyle(AppTheme.warning)
            }
            Button(model.localized("保存服务器")) { model.save() }
                .buttonStyle(AppActionStyle(primary: true)).keyboardShortcut("s", modifiers: .command)
                .disabled(model.editingDisabled || !model.hasUnsavedChanges)
        }
    }
}
