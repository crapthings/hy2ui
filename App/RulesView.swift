import SwiftUI

/// Keeps rule-table headings and cells aligned while reserving readable space for each matching value.
private enum RuleTableLayout {
    static let enabled: CGFloat = 32
    static let number: CGFloat = 28
    static let type: CGFloat = 152
    static let policy: CGFloat = 180
    static let comment: CGFloat = 160
    static let actions: CGFloat = 32
    static let spacing: CGFloat = 12
    static let inset: CGFloat = 16
    static let headerHeight: CGFloat = 44
    static let minimumWidth = enabled + number + type + policy + comment + actions + 200 + spacing * 6 + inset * 2
}

/// Manages native process, domain and IP rules in one selectable list ending with the selected proxy server.
struct RulesView: View {
    @Bindable var model: AppModel
    var search = ""
    let openSettings: () -> Void
    let openCapture: () -> Void
    @State private var selection = Set<String>()
    @State private var editor: RuleEditorDraft?
    @State private var error: String?
    @State private var entries: [RuleListEntry] = []

    private var filteredEntries: [RuleListEntry] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.filter {
            query.isEmpty || $0.type.localizedCaseInsensitiveContains(query)
                || $0.value.localizedStandardContains(query) || $0.policy.localizedCaseInsensitiveContains(query)
                || model.routing.configuration.preferences(for: $0.id).comment.localizedStandardContains(query)
                || ($0.isFinal && model.finalPolicyTitle.localizedStandardContains(query))
        }
    }
    private var removableEntries: [RuleListEntry] { filteredEntries.filter { selection.contains($0.id) && !$0.isFinal } }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.sectionSpacing) {
            actions
            GeometryReader { geometry in
                ScrollView(.horizontal) {
                    table.frame(width: max(RuleTableLayout.minimumWidth, geometry.size.width),
                                height: geometry.size.height, alignment: .topLeading)
                }
                .overlay {
                    if filteredEntries.isEmpty {
                        AppEmptyState(symbol: .rules, title: model.localized("没有匹配的规则"))
                            .padding(.top, RuleTableLayout.headerHeight).allowsHitTesting(false)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.cardRadius))
            .modifier(AppCardSurface())
            if let value = error ?? model.routing.error {
                Text(model.localized(value)).font(AppTheme.caption).foregroundStyle(AppTheme.warning)
                    .textSelection(.enabled)
            }
        }
        .padding(AppTheme.pagePadding)
        .sheet(item: $editor) { RuleEditorView(model: model, draft: $0) }
        .onDeleteCommand(perform: deleteSelected)
        .onAppear { entries = RuleListEntry.entries(in: model.routing.configuration) }
        .onChange(of: model.routing.configuration) { _, configuration in entries = RuleListEntry.entries(in: configuration) }
        .onChange(of: filteredEntries.map(\.id)) { _, ids in selection.formIntersection(Set(ids)) }
    }

    private var table: some View {
        VStack(spacing: 0) {
            columns {
                Color.clear.frame(width: RuleTableLayout.enabled, height: 1).accessibilityHidden(true)
                Color.clear.frame(width: RuleTableLayout.number, height: 1).accessibilityHidden(true)
                Text(model.localized("类型")).frame(width: RuleTableLayout.type, alignment: .leading)
                Text(model.localized("匹配值")).frame(maxWidth: .infinity, alignment: .leading)
                Text(model.localized("策略")).frame(width: RuleTableLayout.policy, alignment: .leading)
                Text(model.localized("备注")).frame(width: RuleTableLayout.comment, alignment: .leading)
                Color.clear.frame(width: RuleTableLayout.actions, height: 1).accessibilityHidden(true)
            }
            .font(AppTheme.caption).foregroundStyle(AppTheme.muted)
            .padding(.horizontal, RuleTableLayout.inset)
            .frame(height: RuleTableLayout.headerHeight, alignment: .leading)
            List(filteredEntries, selection: $selection) { entry in
                ruleRow(entry)
                    .tag(entry.id)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(selection.contains(entry.id) ? AppTheme.selection : AppTheme.paper)
            }
            .listStyle(.plain).scrollContentBackground(.hidden)
            .contentMargins(0, for: .scrollContent)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .transaction { $0.animation = nil }
            .contextMenu(forSelectionType: String.self) { ids in
                let selected = filteredEntries.filter { ids.contains($0.id) && !$0.isFinal }
                if selected.count == 1, let entry = selected.first {
                    Button(model.localized("编辑")) { edit(entry) }
                }
                if !selected.isEmpty {
                    Button(model.localized("删除规则"), role: .destructive) { remove(selected) }
                }
            } primaryAction: { ids in
                guard ids.count == 1, let entry = filteredEntries.first(where: { ids.contains($0.id) }) else { return }
                edit(entry)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            RoutingChangeNotice(model: model)
            Spacer()
            Menu {
                Button(model.localized("标准规则")) { editor = RuleEditorDraft(kind: .domainExact) }
            } label: {
                Label(model.localized("添加规则"), systemImage: "plus")
            }
            .menuStyle(.button).menuIndicator(.hidden).buttonStyle(AppActionStyle(primary: true))
            .accessibilityLabel(model.localized("添加规则")).help(model.localized("添加规则"))
            .disabled(!model.initialized)
        }
    }

    private func columns<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: RuleTableLayout.spacing, content: content)
    }

    private func ruleRow(_ entry: RuleListEntry) -> some View {
        let preferences = model.routing.configuration.preferences(for: entry.id)
        return columns {
            if entry.isFinal {
                Color.clear.frame(width: RuleTableLayout.enabled, height: 32).accessibilityHidden(true)
            } else {
                Toggle(model.localized("启用规则") + ": " + entry.type + " " + entry.value, isOn: Binding(
                    get: { preferences.enabled },
                    set: { enabled in update { $0.rulePreferences[entry.id, default: RulePreferences()].enabled = enabled } }
                ))
                .labelsHidden().toggleStyle(.checkbox)
                .disabled(!model.initialized).frame(width: RuleTableLayout.enabled)
            }
            Text(String(entry.number)).monospacedDigit().foregroundStyle(AppTheme.muted)
                .frame(width: RuleTableLayout.number, alignment: .leading)
            Text(entry.type).font(.system(size: 12, weight: .medium, design: .monospaced))
                .frame(width: RuleTableLayout.type, alignment: .leading)
                .help(entry.isFinal ? model.localized("其余流量") : entry.type)
            Text(entry.value).lineLimit(1).truncationMode(.middle).help(entry.value)
                .frame(maxWidth: .infinity, alignment: .leading)
            policy(for: entry, enabled: preferences.enabled)
                .frame(width: RuleTableLayout.policy, alignment: .leading)
            Text(preferences.comment)
                .foregroundStyle(AppTheme.muted).lineLimit(1).truncationMode(.tail)
                .help(preferences.comment)
                .frame(width: RuleTableLayout.comment, alignment: .leading)
            Group {
                if !entry.isFinal {
                    Button(role: .destructive) { remove([entry]) } label: { Image(systemName: "trash") }
                        .buttonStyle(AppIconButtonStyle()).foregroundStyle(AppTheme.muted)
                        .help(model.localized("删除规则"))
                        .accessibilityLabel(model.localized("删除规则") + ": " + entry.value)
                        .disabled(!model.initialized)
                } else { Color.clear.frame(height: 32).accessibilityHidden(true) }
            }.frame(width: RuleTableLayout.actions, height: 32)
        }
        .foregroundStyle(entry.isFinal || preferences.enabled ? AppTheme.ink : AppTheme.muted)
        .padding(.horizontal, RuleTableLayout.inset).padding(.vertical, 10)
        .frame(minHeight: 52)
        .background(selection.contains(entry.id) ? AppTheme.selection : AppTheme.paper)
        .contentShape(Rectangle())
    }

    private func policy(for entry: RuleListEntry, enabled: Bool) -> some View {
        HStack(spacing: 4) {
            if !entry.isFinal && enabled && !isAvailable(entry) {
                Button { openConfiguration(entry) } label: {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(AppTheme.warning)
                }
                .buttonStyle(AppIconButtonStyle(size: 28)).help(model.localized(scope(entry)))
                .accessibilityLabel(model.localized(scope(entry)))
            }
            if entry.isFinal { FinalPolicyPicker(model: model) }
            else if case .address = entry.source {
                Menu(entry.policy) {
                    Button("DIRECT") { setPolicy(.direct, for: entry) }
                    Button("FINAL") { setPolicy(.proxy, for: entry) }
                    Button("REJECT") { setPolicy(.reject, for: entry) }
                }
                .menuStyle(.borderlessButton).fixedSize().disabled(!model.initialized)
                .accessibilityLabel(model.localized("策略") + ": " + entry.value)
            } else { Text("DIRECT").foregroundStyle(enabled ? AppTheme.connected : AppTheme.muted) }
            Spacer(minLength: 0)
        }
    }

    private func edit(_ entry: RuleListEntry) {
        guard model.initialized, !entry.isFinal else { return }
        editor = RuleEditorDraft(entry: entry, preferences: model.routing.configuration.preferences(for: entry.id))
    }

    private func update(_ change: (inout RoutingConfiguration) throws -> Void) {
        do { try model.routing.update(change); error = nil }
        catch { self.error = error.localizedDescription }
    }

    private func setPolicy(_ action: AddressRuleAction, for entry: RuleListEntry) {
        var draft = RuleEditorDraft(entry: entry, preferences: model.routing.configuration.preferences(for: entry.id))
        draft.action = action
        update { try draft.apply(to: &$0) }
    }

    private func deleteSelected() {
        guard editor == nil else { return }
        remove(removableEntries)
    }

    private func remove(_ entries: [RuleListEntry]) {
        guard model.initialized else { return }
        update { configuration in for entry in entries { entry.remove(from: &configuration) } }
    }

    private func isAvailable(_ entry: RuleListEntry) -> Bool {
        entry.isFinal || (model.systemProxyCaptureEnabled && !model.enhancedCaptureEnabled
            && model.routing.configuration.requestMode == .rules)
    }

    private func scope(_ entry: RuleListEntry) -> String {
        entry.isFinal ? "其余流量" : "仅系统代理的规则模式 · 当前未启用"
    }

    private func openConfiguration(_ entry: RuleListEntry) { openSettings() }
}
