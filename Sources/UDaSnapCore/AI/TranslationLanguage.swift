import Foundation

/// Languages used by line-by-line translation. The source may be automatic; the target must be concrete.
package enum TranslationLanguage: String, Codable, CaseIterable, Equatable, Sendable {
    case auto
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case english = "en"
    case japanese = "ja"
    case korean = "ko"

    package static let targets: [TranslationLanguage] = [
        .simplifiedChinese,
        .traditionalChinese,
        .english,
        .japanese,
        .korean,
    ]

    package static let sources: [TranslationLanguage] = [.auto] + targets

    package var displayName: String {
        switch self {
        case .auto: return "自动检测"
        case .simplifiedChinese: return "简体中文"
        case .traditionalChinese: return "繁體中文"
        case .english: return "English"
        case .japanese: return "日本語"
        case .korean: return "한국어"
        }
    }

    package var compactName: String {
        self == .auto ? "自动" : displayName
    }

    package var isAuto: Bool { self == .auto }

    /// Normalizes the many language labels returned by third-party models.
    package static func detected(from raw: String?) -> TranslationLanguage? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty, value != "unknown", value != "auto" else { return nil }

        switch value {
        case "zh", "zh-cn", "zh-sg", "zh-hans", "cn", "chinese",
            "simplified chinese", "简体", "简体中文":
            return .simplifiedChinese
        case "zh-tw", "zh-hk", "zh-mo", "zh-hant", "traditional chinese",
            "繁体", "繁体中文", "繁體中文":
            return .traditionalChinese
        case "en", "en-us", "en-gb", "english", "英文":
            return .english
        case "ja", "ja-jp", "jp", "japanese", "日文", "日语", "日語":
            return .japanese
        case "ko", "ko-kr", "kr", "korean", "韩文", "韩语", "韓語":
            return .korean
        default:
            return nil
        }
    }
}

/// Result of one translation request.
package enum TranslationOutcome: Sendable {
    case translated(lines: [String], detected: TranslationLanguage?)
    case sameLanguage(detected: TranslationLanguage?)
}
