import SwiftUI

/// Keeps incomplete text local and commits validated settings on blur, return or leaving the page.
struct AutosavingSettingField: View {
    let title: String
    let commit: (String) throws -> Void
    let localized: (String) -> String
    @State private var text: String
    @State private var lastSaved: String
    @State private var error: String?
    @FocusState private var focused: Bool

    init(title: String, value: String, localized: @escaping (String) -> String,
         commit: @escaping (String) throws -> Void) {
        self.title = title
        self.localized = localized
        self.commit = commit
        _text = State(initialValue: value)
        _lastSaved = State(initialValue: value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(title, text: $text).focused($focused)
                .onSubmit(save)
                .onChange(of: focused) { wasFocused, isFocused in
                    if wasFocused && !isFocused { save() }
                }
            if let error {
                Text(localized(error)).font(AppTheme.caption).foregroundStyle(AppTheme.warning)
            }
        }.onDisappear(perform: save)
    }

    private func save() {
        guard text != lastSaved else { return }
        do {
            try commit(text)
            lastSaved = text
            error = nil
        } catch is CancellationError {
            // A different server or an active connection must never receive this field's stale draft.
        } catch { self.error = error.localizedDescription }
    }
}
