import Foundation
import Testing
@testable import Hy2Models

/// Keeps Chinese as the default even when the system or stored preference is unsupported.
@Test func languageDefaultsToChineseAndPersistsSelection() throws {
    let suite = "hy2ui.language-tests." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    #expect(AppLanguage.preferred(in: defaults) == .chinese)
    AppLanguage.english.save(in: defaults)
    #expect(AppLanguage.preferred(in: defaults) == .english)
    AppLanguage.chinese.save(in: defaults)
    #expect(AppLanguage.preferred(in: defaults) == .chinese)
    defaults.set("unsupported", forKey: AppLanguage.preferenceKey)
    #expect(AppLanguage.preferred(in: defaults) == .chinese)
}

/// Loads real translation resources for navigation, installation and network errors in both languages.
@Test func languageResourcesTranslateInterfaceAndErrors() {
    for (key, expected) in [("设置", "Settings"), ("系统代理", "System Proxy"),
                            ("安装后台", "Install Service"), ("服务器已不存在。", "This server no longer exists.")] {
        #expect(AppLocalization.text(key, language: .english) == expected)
        #expect(AppLocalization.text(key, language: .chinese) == key)
    }
    #expect(AppLocalization.text("系统代理 + 增强模式", language: .english) == "System Proxy + Enhanced Mode")
}

/// Preserves inserted addresses and diagnostic details when translating dynamic lifecycle messages.
@Test func dynamicLocalizedMessagesKeepArgumentsIntact() {
    #expect(AppLocalization.text("正在连接 example.com:443…", language: .english) == "Connecting to example.com:443…")
    #expect(AppLocalization.text("启动失败：服务器 DNS 解析超时。", language: .english) == "Startup failed: Server DNS resolution timed out.")
    #expect(AppLocalization.text("钥匙串：OSStatus -25293", language: .english) == "Keychain: OSStatus -25293")
    #expect(AppLocalization.text("配置版本 99 不受当前应用支持，请使用兼容的应用版本。", language: .english) == "Configuration version 99 is unsupported. Use a compatible app version.")
    #expect(AppLocalization.text("Custom diagnostic 123", language: .english) == "Custom diagnostic 123")
}
