import SwiftUI

/// Adds exact process-name or executable-path rules while exposing only supported runtime destinations.
struct ProcessRuleSheet: View {
    @Bindable var model: AppModel
    let identities: [ProcessIdentity]
    let saved: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var byPath = true
    @State private var destination = OutboundTarget.direct
    @State private var error: String?

    private var values: [String] {
        Array(Set(identities.map { byPath ? $0.target.path : URL(fileURLWithPath: $0.target.path).lastPathComponent })).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(model.localized("添加进程规则")).font(AppTheme.dialogTitle)
            SectionCard {
                VStack(alignment: .leading, spacing: 16) {
                    Picker(model.localized("匹配方式"), selection: $byPath) {
                        Text("PROCESS-PATH").tag(true)
                        Text("PROCESS-NAME").tag(false)
                    }.pickerStyle(.segmented)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(values, id: \.self) { Text($0).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 130)
                    Picker(model.localized("策略"), selection: $destination) {
                        Text("DIRECT").tag(OutboundTarget.direct)
                        Section(model.localized("服务器")) {
                            ForEach(model.sortedServers) { server in
                                Text(server.name).tag(OutboundTarget.server(server.id)).disabled(true)
                            }
                        }
                        Section(model.localized("服务器组")) {
                            ForEach(model.routing.configuration.groups) { group in
                                Text(group.name).tag(OutboundTarget.group(group.id)).disabled(true)
                            }
                        }
                    }
                    Text(model.localized("当前仅支持进程直连；指定服务器或组尚未接通。进程规则仅作用于系统代理的本机 TCP，重新连接后生效。"))
                        .font(AppTheme.caption).foregroundStyle(AppTheme.muted)
                }
            }
            if let error { Text(model.localized(error)).foregroundStyle(AppTheme.warning).font(AppTheme.caption) }
            HStack {
                Spacer()
                Button(model.localized("取消")) { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(AppActionStyle())
                Button(model.localized("保存"), action: save).keyboardShortcut(.defaultAction)
                    .buttonStyle(AppActionStyle(primary: true)).disabled(!model.initialized || identities.isEmpty || destination != .direct)
            }
        }.padding(AppTheme.pagePadding).frame(width: 590)
            .background(AppTheme.canvas).foregroundStyle(AppTheme.ink).tint(AppTheme.accent)
    }

    private func save() {
        do {
            guard !identities.isEmpty, destination == .direct, identities.allSatisfy(\.isCurrent) else {
                throw ConfigurationError.invalid("进程已退出或身份已变化，请刷新后重试。")
            }
            try model.routing.update { configuration in
                for value in values {
                    try NativeClientRouting.validateProcess(value)
                    if !configuration.directProcesses.contains(value) { configuration.directProcesses.append(value) }
                    configuration.rulePreferences["process:" + value, default: RulePreferences()].enabled = true
                }
            }
            saved("规则已保存，重新连接后生效。进程规则适用于本机代理的 TCP 连接，需要核心支持进程分流。")
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
