import SwiftUI

/// Places a section heading above its consistently padded borderless form card.
struct FormGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(AppTheme.sectionTitle).foregroundStyle(AppTheme.ink)
            SectionCard {
                VStack(alignment: .leading, spacing: 20) { content }
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
private struct FilledFieldStyle: TextFieldStyle {
    @FocusState private var focused: Bool

    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .padding(.horizontal, 10)
            .frame(minHeight: AppTheme.baseButtonHeight)
            .background(AppTheme.controlSurface, in: RoundedRectangle(cornerRadius: 6))
            .focused($focused)
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(focused ? AppTheme.accent : .clear, lineWidth: 2))
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
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .opacity(enabled ? 1 : 0.55)
    }
}
