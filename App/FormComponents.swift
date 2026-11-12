import SwiftUI

/// Gives every search field the same capsule, clear action, search button and keyboard focus treatment.
struct AppSearchField: View {
    let placeholder: String
    let clearLabel: String
    @Binding var text: String
    var submit: () -> Void = {}
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 12) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain).focused($focused).onSubmit(submit)
                .accessibilityLabel(placeholder)
                .onExitCommand {
                    if text.isEmpty { focused = false }
                    else { text = "" }
                }
            if !text.isEmpty {
                Button { text = ""; focused = true } label: { AppIcon(symbol: .close, size: 14) }
                    .buttonStyle(AppIconButtonStyle(size: 28))
                    .foregroundStyle(AppTheme.muted).accessibilityLabel(clearLabel).help(clearLabel)
            }
            Button(action: submit) {
                AppIcon(symbol: .search, size: 20)
                    .foregroundStyle(AppTheme.paper).frame(width: 40, height: 40)
                    .background(AppTheme.ink, in: Circle())
            }.buttonStyle(.plain).accessibilityLabel(placeholder)
        }
        .padding(.leading, 20).padding(.trailing, 6).padding(.vertical, 6)
        .frame(height: 52).background(AppTheme.paper, in: Capsule())
        .overlay(Capsule().strokeBorder(focused ? AppTheme.accent : .clear, lineWidth: 1.5))
    }
}

/// Presents a concise, consistently centered empty state inside list and diagnostic surfaces.
struct AppEmptyState: View {
    let symbol: AppSymbol
    let title: String

    var body: some View {
        VStack(spacing: 12) {
            AppIcon(symbol: symbol, size: 24)
                .foregroundStyle(AppTheme.accent)
                .frame(width: 48, height: 48)
                .background(AppTheme.controlSurface, in: Circle())
            Text(title).font(AppTheme.body).foregroundStyle(AppTheme.muted)
                .multilineTextAlignment(.center)
        }
        .padding(AppTheme.cardPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Places a section heading above its consistently padded borderless form card.
struct FormGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(AppTheme.sectionTitle).foregroundStyle(AppTheme.ink).accessibilityAddTraits(.isHeader)
            SectionCard {
                VStack(alignment: .leading, spacing: AppTheme.formSpacing) { content }
            }
        }
    }
}

/// Stacks a field label, accessible control and optional help in reading order.
struct FieldRow<Content: View>: View {
    let title: String
    var help: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(AppTheme.body).foregroundStyle(AppTheme.ink)
            content.labelsHidden().accessibilityLabel(title)
                .textFieldStyle(FilledFieldStyle()).controlSize(.regular)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let help {
                Text(help).font(AppTheme.caption).foregroundStyle(AppTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Gives editable fields a quiet fill and shows a focus ring only during keyboard editing.
struct FilledFieldStyle: TextFieldStyle {
    @Environment(\.isFocused) private var focused
    @Environment(\.isEnabled) private var enabled

    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .padding(.horizontal, 10)
            .frame(minHeight: AppTheme.baseButtonHeight)
            .background(AppTheme.controlSurface, in: RoundedRectangle(cornerRadius: AppTheme.controlRadius))
            .overlay(RoundedRectangle(cornerRadius: AppTheme.controlRadius)
                .strokeBorder(focused ? AppTheme.accent : .clear, lineWidth: 2))
            .opacity(enabled ? 1 : 0.55)
    }
}

/// Presents a native selection menu in the same filled, leading-aligned column as editable fields.
struct FormMenuPicker<Selection: Hashable, Options: View>: View {
    let title: String
    @Binding var selection: Selection
    let selectedTitle: String
    @ViewBuilder var options: Options

    var body: some View {
        Menu {
            Picker(title, selection: $selection) { options }
                .pickerStyle(.inline)
                .labelsHidden()
                .accessibilityLabel(title)
        } label: {
            HStack(spacing: 12) {
                Text(selectedTitle).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(AppTheme.muted)
            }
            .font(AppTheme.body)
            .foregroundStyle(AppTheme.ink)
        }
        .menuStyle(.button)
        .buttonStyle(FilledMenuButtonStyle())
        .menuIndicator(.hidden)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel(title)
        .accessibilityValue(selectedTitle)
    }
}

/// Makes selection-menu triggers fill the field column with the same dimensions as text inputs.
private struct FilledMenuButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: AppTheme.baseButtonHeight, alignment: .leading)
            .background(configuration.isPressed ? AppTheme.selection : AppTheme.controlSurface,
                        in: RoundedRectangle(cornerRadius: AppTheme.controlRadius))
            .contentShape(RoundedRectangle(cornerRadius: AppTheme.controlRadius))
            .opacity(enabled ? 1 : 0.55)
    }
}
