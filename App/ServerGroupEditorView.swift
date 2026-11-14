import SwiftUI

/// Edits groups with automatic policies gated by the bundled core capability report.
struct ServerGroupEditorView: View {
    @Bindable var model: AppModel
    @State var draft: ServerGroup
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(model.localized("服务器组")).font(AppTheme.dialogTitle)
            TextField(model.localized("组名称"), text: $draft.name).textFieldStyle(.roundedBorder)
            Picker(model.localized("组类型"), selection: $draft.kind) {
                ForEach(ServerGroupKind.allCases, id: \.self) { kind in
                    Text(model.localized(kind.title)).tag(kind).disabled(!model.poolCapabilities.supports(kind))
                }
            }
            Text(model.localized(draft.kind == .select ? "手动选择当前成员。" : "自动组使用系统代理；SOCKS5 UDP 按核心能力启用，增强模式暂不支持。健康探测仅验证 TCP 路径。"))
                .font(AppTheme.caption).foregroundStyle(AppTheme.muted)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(orderedServers) { server in
                        HStack {
                        Toggle(server.name, isOn: Binding(
                            get: { draft.members.contains(server.id) },
                            set: { selected in
                                if selected { draft.members.append(server.id); if draft.selectedID == nil { draft.selectedID = server.id } }
                                else { draft.members.removeAll { $0 == server.id }; if draft.selectedID == server.id { draft.selectedID = draft.members.first } }
                            }
                        ))
                        if draft.kind == .fallback, let index = draft.members.firstIndex(of: server.id) {
                            Text(String(index + 1)).font(AppTheme.caption).foregroundStyle(AppTheme.muted)
                            Button { draft.members.swapAt(index, index - 1) } label: { Image(systemName: "chevron.up") }
                                .disabled(index == 0).help(model.localized("提高优先级")).accessibilityLabel(model.localized("提高优先级"))
                            Button { draft.members.swapAt(index, index + 1) } label: { Image(systemName: "chevron.down") }
                                .disabled(index == draft.members.count - 1).help(model.localized("降低优先级")).accessibilityLabel(model.localized("降低优先级"))
                        }
                        }
                    }
                }.padding(4)
            }.frame(height: 200)
            if draft.kind == .select {
                Picker(model.localized("当前成员"), selection: $draft.selectedID) {
                    Text(model.localized("请选择服务器")).tag(nil as UUID?)
                    ForEach(model.sortedServers.filter { draft.members.contains($0.id) }) { server in
                        Text(server.name).tag(Optional(server.id))
                    }
                }
            } else {
                TextField(model.localized("探测地址"), text: Binding(
                    get: { draft.probeURL ?? "https://www.apple.com/library/test/success.html" }, set: { draft.probeURL = $0 }
                )).textFieldStyle(.roundedBorder)
                HStack {
                    parameter("检测间隔（秒）", value: $draft.probeInterval, fallback: 30, range: 5...3600)
                    parameter("超时（秒）", value: $draft.probeTimeout, fallback: 5, range: 1...30)
                }
                HStack {
                    parameter("失败阈值", value: $draft.failureThreshold, fallback: 3, range: 1...10)
                    parameter("恢复阈值", value: $draft.recoveryThreshold, fallback: 2, range: 1...10)
                }
                if draft.kind == .urlTest {
                    HStack {
                        parameter("改善阈值（毫秒）", value: $draft.toleranceMs, fallback: 50, range: 0...60000)
                        parameter("保持时间（秒）", value: $draft.holdSeconds, fallback: 60, range: 0...3600)
                    }
                }
                if draft.kind == .loadBalance {
                    Text(model.localized("按目标保持出口一致，在健康成员间分配新连接；不叠加单连接速度。"))
                        .font(AppTheme.caption).foregroundStyle(AppTheme.muted)
                }
                if draft.kind == .fallback {
                    Text(model.localized("按成员顺序确定优先级，可用箭头调整；优先使用首个健康成员。"))
                        .font(AppTheme.caption).foregroundStyle(AppTheme.muted)
                }
            }
            if let error { Text(model.localized(error)).font(AppTheme.caption).foregroundStyle(AppTheme.warning) }
            HStack {
                Spacer()
                Button(model.localized("取消")) { dismiss() }.buttonStyle(AppActionStyle()).keyboardShortcut(.cancelAction)
                Button(model.localized("保存"), action: save).buttonStyle(AppActionStyle(primary: true))
                    .keyboardShortcut(.defaultAction).disabled(model.editingDisabled || draft.members.isEmpty || (draft.kind == .select && draft.selectedID == nil) || !model.poolCapabilities.supports(draft.kind))
            }
        }.task { await model.refreshPoolCapabilities() }
            .padding(AppTheme.pagePadding).frame(width: 540).background(AppTheme.canvas).tint(AppTheme.accent)
    }

    private var orderedServers: [Profile] {
        guard draft.kind == .fallback else { return model.sortedServers }
        return draft.members.compactMap { id in model.servers.first { $0.id == id } }
            + model.sortedServers.filter { !draft.members.contains($0.id) }
    }

    private func parameter(_ title: String, value: Binding<Int?>, fallback: Int, range: ClosedRange<Int>) -> some View {
        Stepper(value: Binding(get: { value.wrappedValue ?? fallback }, set: { value.wrappedValue = $0 }), in: range) {
            Text(model.localized(title) + ": " + String(value.wrappedValue ?? fallback)).font(AppTheme.caption)
        }
    }

    private func save() {
        do {
            guard model.poolCapabilities.supports(draft.kind) else { throw ConfigurationError.invalid("当前核心不支持此服务器组类型。") }
            if draft.kind != .select && draft.selectedID == nil { draft.selectedID = draft.members.first }
            try draft.validate(serverIDs: Set(model.servers.map(\.id)))
            guard model.routing.configuration.finalOutbound != .group(draft.id) else {
                throw ConfigurationError.invalid("请先切换到其他出口，再编辑当前使用的服务器组。")
            }
            guard !model.routing.configuration.groups.contains(where: { $0.id != draft.id && $0.name == draft.name }) else {
                throw ConfigurationError.invalid("服务器组名称已存在。")
            }
            try model.routing.update { configuration in
                if let index = configuration.groups.firstIndex(where: { $0.id == draft.id }) { configuration.groups[index] = draft }
                else { configuration.groups.append(draft) }
            }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
