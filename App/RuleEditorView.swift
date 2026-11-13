import SwiftUI

/// Edits one supported routing rule in a compact sheet with type-specific field helpers.
struct RuleEditorView: View {
    @Bindable var model: AppModel
    @State var draft: RuleEditorDraft
    @State private var error: String?
    @FocusState private var valueFocused: Bool
    @Environment(\.dismiss) private var dismiss

    private var canSave: Bool {
        model.initialized && !draft.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.sectionSpacing) {
            Text(model.localized(draft.original == nil ? "添加标准规则" : "编辑规则"))
                .font(AppTheme.dialogTitle).accessibilityAddTraits(.isHeader)
            SectionCard {
                VStack(alignment: .leading, spacing: AppTheme.formSpacing) {
                    HStack(alignment: .top, spacing: AppTheme.formSpacing) {
                        FieldRow(title: model.localized("规则类型")) {
                            FormMenuPicker(title: model.localized("规则类型"), selection: $draft.kind, selectedTitle: draft.kind.title) {
                                ForEach(RuleEditorKind.allCases) { kind in Text(kind.title).tag(kind) }
                            }
                        }
                        FieldRow(title: model.localized("策略"), help: draft.kind.isProcess ? model.localized("进程规则仅支持 DIRECT。") : nil) {
                            FormMenuPicker(title: model.localized("策略"), selection: $draft.action,
                                           selectedTitle: draft.kind.isProcess || draft.action == .direct ? "DIRECT" : draft.action == .reject ? "REJECT" : "FINAL") {
                                Text("DIRECT").tag(AddressRuleAction.direct)
                                if !draft.kind.isProcess { Text("FINAL").tag(AddressRuleAction.proxy); Text("REJECT").tag(AddressRuleAction.reject) }
                            }.disabled(draft.kind.isProcess)
                        }
                    }
                    FieldRow(title: model.localized("匹配值"), help: model.localized(draft.kind.help)) {
                        HStack(spacing: 8) {
                            TextField(draft.kind.placeholder, text: $draft.value)
                                .focused($valueFocused).onSubmit(save)

                        }
                    }
                    FieldRow(title: model.localized("备注")) {
                        TextField(model.localized("可选"), text: $draft.preferences.comment).onSubmit(save)
                    }
                }
            }.disabled(!model.initialized)
            if let error {
                Text(model.localized(error)).font(AppTheme.caption).foregroundStyle(AppTheme.warning)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button(model.localized("取消")) { dismiss() }.buttonStyle(AppActionStyle()).keyboardShortcut(.cancelAction)
                Button(model.localized("保存"), action: save).buttonStyle(AppActionStyle(primary: true))
                    .keyboardShortcut(.defaultAction).disabled(!canSave)
            }
        }
        .padding(AppTheme.pagePadding).frame(width: 560)
        .background(AppTheme.canvas)
        .foregroundStyle(AppTheme.ink).tint(AppTheme.accent).font(AppTheme.body)
        .defaultFocus($valueFocused, true)
        .onChange(of: draft.kind) { _, kind in
            if kind.isProcess { draft.action = .direct }
            error = nil
            valueFocused = true
        }
        .onChange(of: draft.value) { _, _ in error = nil }
    }

    private func save() {
        guard canSave else { return }
        do {
            try model.routing.update { try draft.apply(to: &$0) }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }

}
