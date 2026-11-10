import Foundation
import Observation

/// Remembers the optional enhanced-mode introduction independently of server and network settings.
@MainActor @Observable
public final class EnhancedModeOnboarding {
    public private(set) var isPresented = false
    private let preferences: UserDefaults
    private static let completedKey = "enhancedModeIntroductionCompleted"

    public init(preferences: UserDefaults = .standard) { self.preferences = preferences }

    public func consider(hasInstallation: Bool) {
        guard !preferences.bool(forKey: Self.completedKey) else { return }
        if hasInstallation { finish() }
        else { isPresented = true }
    }

    public func show() { isPresented = true }

    public func finish() {
        preferences.set(true, forKey: Self.completedKey)
        isPresented = false
    }
}
