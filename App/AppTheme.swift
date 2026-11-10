import SwiftUI
import AppKit

/// Defines HP-inspired paper surfaces, electric-blue actions and consistent desktop typography and spacing.
enum AppTheme {
    static let accent = adaptive(0x024AD8, 0x92BAFF)
    static let action = adaptive(0x024AD8, 0x1857D8)
    static let actionPressed = adaptive(0x0E3191, 0x0E3191)
    static let canvas = adaptive(0xFFFFFF, 0x141619)
    static let paper = adaptive(0xFFFFFF, 0x1E2126)
    static let cloud = adaptive(0xF7F7F7, 0x191C20)
    static let selection = adaptive(0xE8E8E8, 0x30363F)
    static let ink = adaptive(0x1A1A1A, 0xF3F4F6)
    static let muted = adaptive(0x636363, 0xB4BAC3)
    static let controlSurface = adaptive(0xFFFFFF, 0x2A2E35)
    static let connected = adaptive(0x1B7250, 0x8CDCB8)
    static let warning = adaptive(0x8A5200, 0xFFD184)
    static let destructive = adaptive(0xB3262B, 0xFFB4AB)
    static let pageTitle = Font.system(size: 24, weight: .medium)
    static let sectionTitle = Font.system(size: 14, weight: .semibold)
    static let body = Font.system(size: 13)
    static let caption = Font.system(size: 12)
    static let pagePadding: CGFloat = 32
    static let sectionSpacing: CGFloat = 24
    static let cardPadding: CGFloat = 24
    static let formSpacing: CGFloat = 16
    static let cardRadius: CGFloat = 10
    static let controlRadius: CGFloat = 4
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

/// Restricts native translucency to the sidebar while respecting reduced-transparency preferences.
struct WindowGlass: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        if reduceTransparency { AppTheme.cloud }
        else { NativeWindowGlass() }
    }
}

/// Hosts an AppKit sidebar material behind navigation without tinting the main paper canvas.
private struct NativeWindowGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// Groups related settings on a borderless surface with consistent padding and corners.
struct SectionCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(AppTheme.cardPadding)
            .background(AppTheme.cloud, in: RoundedRectangle(cornerRadius: AppTheme.cardRadius))
    }
}

/// Renders primary and secondary actions with consistent sizing, keyboard focus and pressed feedback.
struct AppActionStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .padding(.horizontal, AppTheme.baseButtonPadding).frame(minHeight: AppTheme.baseButtonHeight)
            .foregroundStyle(primary ? Color.white : (configuration.role == .destructive ? AppTheme.destructive : AppTheme.ink))
            .background(primary ? (enabled ? (configuration.isPressed ? AppTheme.actionPressed : AppTheme.action) : AppTheme.muted) : (configuration.isPressed ? AppTheme.selection : AppTheme.controlSurface),
                        in: RoundedRectangle(cornerRadius: AppTheme.controlRadius))
            .opacity(enabled ? 1 : 0.55)
            .contentShape(Rectangle())
    }
}
