import Foundation
import Testing
@testable import Hy2Models

/// Presents the optional introduction once and remembers a skip across application launches.
@Test @MainActor func enhancedIntroductionCanBeSkippedPermanently() throws {
    let suite = "hy2ui.onboarding-tests." + UUID().uuidString
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let introduction = EnhancedModeOnboarding(preferences: preferences)
    introduction.consider(hasInstallation: false)
    #expect(introduction.isPresented)
    introduction.finish()
    #expect(!introduction.isPresented)
    let relaunched = EnhancedModeOnboarding(preferences: preferences)
    relaunched.consider(hasInstallation: false)
    #expect(!relaunched.isPresented)
}

/// Keeps the introduction dismissed for existing installations even after a later uninstall.
@Test @MainActor func installedServiceDoesNotShowIntroduction() throws {
    let suite = "hy2ui.onboarding-tests." + UUID().uuidString
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let introduction = EnhancedModeOnboarding(preferences: preferences)
    introduction.consider(hasInstallation: true)
    #expect(!introduction.isPresented)
    let relaunched = EnhancedModeOnboarding(preferences: preferences)
    relaunched.consider(hasInstallation: false)
    #expect(!relaunched.isPresented)
}

/// Completing onboarding preserves independent interface and server preferences.
@Test @MainActor func introductionDoesNotModifyOtherPreferences() throws {
    let suite = "hy2ui.onboarding-tests." + UUID().uuidString
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    AppLanguage.english.save(in: preferences)
    preferences.set("keep-server", forKey: "server-marker")
    let introduction = EnhancedModeOnboarding(preferences: preferences)
    introduction.consider(hasInstallation: false)
    introduction.finish()
    #expect(AppLanguage.preferred(in: preferences) == .english)
    #expect(preferences.string(forKey: "server-marker") == "keep-server")
}
