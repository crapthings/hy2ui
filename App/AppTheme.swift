import SwiftUI
import AppKit

/// Defines shared warm surfaces, green actions, typography and spacing across navigation and content.
enum AppTheme {
    static let accent = adaptive(0x4F705F, 0xADCDB9)
    static let action = adaptive(0x4F705F, 0x4F705F)
    static let actionPressed = adaptive(0x365241, 0x365241)
    static let canvas = adaptive(0xECEBE6, 0x191C19)
    static let paper = adaptive(0xFFFFFF, 0x242824)
    static let chartGuide = adaptive(0xE8EAE5, 0x353C35)
    static let upload = adaptive(0x7E9E8B, 0xB7D0BF)
    static let download = adaptive(0x4B6E5B, 0x95BDA3)
    static let selection = adaptive(0xE4EBE5, 0x374137)
    static let ink = adaptive(0x202420, 0xF0F3ED)
    static let muted = adaptive(0x656C61, 0xB5BEB2)
    static let controlSurface = adaptive(0xF0F4EF, 0x303830)
    static let connected = adaptive(0x4F705F, 0xADCDB9)
    static let warning = adaptive(0x8A5200, 0xFFD184)
    static let destructive = adaptive(0xB3262B, 0xFFB4AB)
    static let highlightStart = Color(red: 0.55, green: 0.66, blue: 0.59)
    static let highlightEnd = Color(red: 0.28, green: 0.43, blue: 0.35)
    static let pageTitle = Font.system(size: 26, weight: .semibold)
    static let dialogTitle = Font.system(size: 20, weight: .semibold)
    static let cardTitle = Font.system(size: 18, weight: .semibold)
    static let sectionTitle = Font.system(size: 14, weight: .semibold)
    static let body = Font.system(size: 13)
    static let caption = Font.system(size: 12)
    static let pagePadding: CGFloat = 24
    static let sectionSpacing: CGFloat = 20
    static let cardPadding: CGFloat = 20
    static let gridSpacing: CGFloat = 20
    static let formSpacing: CGFloat = 16
    static let cardRadius: CGFloat = 20
    static let controlRadius: CGFloat = 8
    static let baseButtonHeight: CGFloat = 36
    static let baseButtonPadding: CGFloat = 16

    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        })
    }
}

/// Gives content cards one consistent borderless surface and subtle elevation in both appearances.
struct AppCardSurface: ViewModifier {
    var emphasized = false
    func body(content: Content) -> some View {
        content
            .background {
                let shape = RoundedRectangle(cornerRadius: AppTheme.cardRadius)
                if emphasized {
                    shape.fill(LinearGradient(colors: [AppTheme.highlightStart, AppTheme.highlightEnd],
                                              startPoint: .topLeading, endPoint: .bottomTrailing))
                } else { shape.fill(AppTheme.paper) }
            }
            .shadow(color: .black.opacity(0.025), radius: 8, x: 0, y: 3)
    }
}

/// Groups related settings on a borderless surface with consistent padding and corners.
struct SectionCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(AppTheme.cardPadding)
            .modifier(AppCardSurface())
    }
}

/// Renders primary and secondary actions with consistent sizing, keyboard focus and pressed feedback.
struct AppActionStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .padding(.horizontal, AppTheme.baseButtonPadding).frame(minHeight: AppTheme.baseButtonHeight)
            .foregroundStyle(primary ? Color.white : (configuration.role == .destructive ? AppTheme.destructive : AppTheme.ink))
            .background(primary ? (enabled ? (configuration.isPressed ? AppTheme.actionPressed : AppTheme.action) : AppTheme.muted) : (configuration.isPressed ? AppTheme.selection : AppTheme.controlSurface),
                        in: RoundedRectangle(cornerRadius: AppTheme.controlRadius))
            .overlay(RoundedRectangle(cornerRadius: AppTheme.controlRadius)
                .strokeBorder(focused ? (primary ? AppTheme.ink : AppTheme.accent) : .clear, lineWidth: 1.5))
            .opacity(enabled ? 1 : 0.55)
            .contentShape(Rectangle())
    }
}

/// Gives compact icon actions a consistent hit area and visible hover, pressed and keyboard-focus feedback.
struct AppIconButtonStyle: ButtonStyle {
    var size: CGFloat = 32

    func makeBody(configuration: Configuration) -> some View {
        IconButtonLabel(configuration: configuration, size: size)
    }

    /// Draws the interactive surface behind an icon without changing its accessible button label.
    private struct IconButtonLabel: View {
        let configuration: ButtonStyleConfiguration
        let size: CGFloat
        @Environment(\.isEnabled) private var enabled
        @Environment(\.isFocused) private var focused
        @State private var hovering = false

        var body: some View {
            configuration.label
                .frame(width: size, height: size)
                .background(configuration.isPressed ? AppTheme.selection : hovering && enabled ? AppTheme.controlSurface : .clear,
                            in: RoundedRectangle(cornerRadius: AppTheme.controlRadius))
                .overlay(RoundedRectangle(cornerRadius: AppTheme.controlRadius)
                    .strokeBorder(focused ? AppTheme.accent : .clear, lineWidth: 1.5))
                .contentShape(RoundedRectangle(cornerRadius: AppTheme.controlRadius))
                .opacity(enabled ? 1 : 0.45)
                .onHover { hovering = $0 }
        }
    }
}
