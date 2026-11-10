import SwiftUI

/// Edits one server identity and its Keychain credentials with explicit save and removal actions.
struct ServerEditorView: View {
    @Bindable var model: AppModel
    var removed: () -> Void
    @State private var confirmingRemoval = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.sectionSpacing) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(model.profile.name.isEmpty ? model.localized("新服务器") : model.profile.name)
                            .font(AppTheme.pageTitle)
                    }
                    Spacer()
                    if model.hasUnsavedChanges { Text(model.localized("未保存")).font(AppTheme.caption).foregroundStyle(AppTheme.warning) }
                }
                VStack(spacing: AppTheme.sectionSpacing) {
                    FormGroup(title: model.localized("连接信息")) {
                        FieldRow(title: model.localized("名称")) {
                            TextField(model.localized("名称"), text: $model.profile.name, prompt: Text(model.localized("例如：东京 · 主线路")))
                        }
                        FieldRow(title: model.localized("服务器")) {
                            TextField(model.localized("服务器"), text: $model.profile.host, prompt: Text("example.com"))
                        }
                        FieldRow(title: model.localized("端口")) {
                            TextField(model.localized("端口"), value: $model.profile.port, format: .number.grouping(.never))
                        }
                        FieldRow(title: model.localized("认证密码")) {
                            SecureField(model.localized("认证密码"), text: $model.credentials.password)
                        }
                    }
                    FormGroup(title: model.localized("传输安全")) {
                        FieldRow(title: model.localized("TLS 服务器名称")) {
                            TextField(model.localized("TLS 服务器名称"), text: $model.profile.serverName, prompt: Text(model.localized("留空时使用服务器地址")))
                        }
                        FieldRow(title: model.localized("Salamander 密码")) {
                            SecureField(model.localized("Salamander 密码"), text: $model.credentials.obfuscationPassword, prompt: Text(model.localized("可选")))
                        }
                    }
                }.disabled(model.editingDisabled)
                HStack {
                    Spacer()
                    Button(model.localized("删除服务器"), role: .destructive) { confirmingRemoval = true }
                        .buttonStyle(AppActionStyle())
                        .disabled(model.editingDisabled)
                    Button(model.localized("保存服务器")) { model.save() }
                        .buttonStyle(AppActionStyle(primary: true)).disabled(model.editingDisabled)
                }
                if let notice = model.editorNotice ?? model.errorMessage {
                    Text(model.localized(notice)).font(AppTheme.caption).foregroundStyle(AppTheme.muted).textSelection(.enabled)
                }
            }
            .frame(maxWidth: 680).padding(AppTheme.pagePadding).frame(maxWidth: .infinity)
        }
        .confirmationDialog(model.localized("删除这个服务器？"), isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button(model.localized("删除服务器"), role: .destructive) { if model.removeServer() { removed() } }
        } message: { Text(model.localized("删除服务器及其密码。")) }
    }
}
