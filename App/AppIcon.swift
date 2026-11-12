import SwiftUI

/// Identifies the pinned local IconMCP assets used by navigation, dashboard cards and shared actions.
enum AppSymbol: String, CaseIterable {
    case overview, processes, policies, rules, logs, settings, helper, forward
    case server, capture, upload, download, today, month, address, application
    case search, close, selected, disclosure

    var assetName: String { "IconMCP-" + rawValue }
}

/// Renders local vector templates at an explicit size while inheriting the surrounding foreground color.
struct AppIcon: View {
    let symbol: AppSymbol
    var size: CGFloat = 20

    var body: some View {
        Image(symbol.assetName)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
