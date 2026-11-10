import Foundation

/// Identifies the supported interface languages and persists a Chinese default independently of server profiles.
public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case chinese = "zh-Hans", english = "en"
    public var id: String { rawValue }
    public var title: String { self == .chinese ? "简体中文" : "English" }
    public var locale: Locale { Locale(identifier: rawValue) }
    public static let preferenceKey = "interfaceLanguage"

    public static func preferred(in defaults: UserDefaults = .standard) -> AppLanguage {
        defaults.string(forKey: preferenceKey).flatMap(Self.init(rawValue:)) ?? .chinese
    }

    public func save(in defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.preferenceKey)
    }
}

/// Resolves app-owned interface messages without translating server names, credentials or raw system diagnostics.
public enum AppLocalization {
    private static var resourceBundle: Bundle {
        #if SWIFT_PACKAGE
        Bundle.module
        #else
        Bundle.main
        #endif
    }
    private static let templates = [
        "正在连接 %@…", "启动失败：%@", "服务器 DNS 解析失败：%@", "系统代理设置失败：%@",
        "本地增强模式尚未就绪：%@", "系统扩展状态尚未加载：%@", "钥匙串：%@", "VPN：%@",
        "配置版本 %@ 不受当前应用支持，请使用兼容的应用版本。"
    ]

    public static func text(_ value: String, language: AppLanguage) -> String {
        guard language == .english,
              let path = resourceBundle.path(forResource: language.rawValue, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return value }
        if let suffix = value.range(of: " [code=") {
            return text(String(value[..<suffix.lowerBound]), language: language) + String(value[suffix.lowerBound...])
        }
        let direct = bundle.localizedString(forKey: value, value: value, table: nil)
        if direct != value { return direct }
        for template in templates {
            let parts = template.components(separatedBy: "%@")
            guard parts.count == 2, value.hasPrefix(parts[0]), value.hasSuffix(parts[1]),
                  value.count >= parts[0].count + parts[1].count else { continue }
            let argument = String(value.dropFirst(parts[0].count).dropLast(parts[1].count))
            let translated = bundle.localizedString(forKey: template, value: template, table: nil)
            return translated.replacingOccurrences(of: "%@", with: text(argument, language: language))
        }
        return value
    }
}
