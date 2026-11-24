import Foundation

/// How the AI result window interprets a screenshot.
package enum AIMode: String, Codable, CaseIterable, Sendable {
    case extract
    case understand

    package var displayName: String {
        switch self {
        case .extract: return "文字提取"
        case .understand: return "内容理解"
        }
    }

    package var segmentIndex: Int {
        switch self {
        case .extract: return 0
        case .understand: return 1
        }
    }

    package static func from(segment: Int) -> AIMode {
        segment == 1 ? .understand : .extract
    }
}

/// Default prompts and model-facing instructions.
package enum AIDefaults {
    package static let textPrompt = """
        你是 OCR 助手。请逐字提取截图中的可见文字，按从上到下、同一行从左到右的顺序输出，尽量保留原始换行和段落。不要总结、翻译、解释或补充图中没有的内容；无法辨认的字用 [无法辨认]。只输出提取结果，不要 Markdown 代码块。
        """

    package static let understandPrompt = """
        请用简洁的简体中文说明这张截图的内容。提取关键信息、操作步骤、数据或界面要点；如果图中有文字、表格或代码，保留其关键结构和名称。不要编造看不见的内容；信息不确定时明确说明。只输出结果，不要寒暄。
        """

    package static let systemPrompt = """
        你是小U，一个专注截图的桌面 AI 助手。默认使用简体中文；回答简洁、直接，只基于当前截图、识别结果和对话内容，不编造图中没有的信息。可以解释、总结、翻译、提取信息或回答与该图相关的问题。
        """
}

/// Non-secret AI configuration. The API key lives in the macOS Keychain.
package struct AISettings: Codable, Equatable, Sendable {
    package var baseURL: String
    package var model: String
    package var mode: AIMode
    package var authEnabled: Bool
    package var textPrompt: String
    package var understandPrompt: String
    package var systemPrompt: String
    package var translationSource: TranslationLanguage
    package var translationTarget: TranslationLanguage

    package static let `default` = AISettings(
        baseURL: "",
        model: "",
        mode: .extract,
        authEnabled: true,
        textPrompt: AIDefaults.textPrompt,
        understandPrompt: AIDefaults.understandPrompt,
        systemPrompt: AIDefaults.systemPrompt,
        translationSource: .auto,
        translationTarget: .simplifiedChinese
    )

    package init(
        baseURL: String,
        model: String,
        mode: AIMode,
        authEnabled: Bool,
        textPrompt: String,
        understandPrompt: String,
        systemPrompt: String,
        translationSource: TranslationLanguage = .auto,
        translationTarget: TranslationLanguage = .simplifiedChinese
    ) {
        self.baseURL = baseURL
        self.model = model
        self.mode = mode
        self.authEnabled = authEnabled
        self.textPrompt = textPrompt
        self.understandPrompt = understandPrompt
        self.systemPrompt = systemPrompt
        self.translationSource = translationSource
        self.translationTarget = translationTarget
    }

    private enum CodingKeys: String, CodingKey {
        case baseURL
        case model
        case mode
        case authEnabled
        case textPrompt
        case understandPrompt
        case systemPrompt
        case translationSource
        case translationTarget
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? ""
        mode = AIMode(rawValue: try container.decodeIfPresent(String.self, forKey: .mode) ?? "") ?? .extract
        authEnabled = try container.decodeIfPresent(Bool.self, forKey: .authEnabled) ?? true
        textPrompt = try container.decodeIfPresent(String.self, forKey: .textPrompt) ?? AIDefaults.textPrompt
        understandPrompt =
            try container.decodeIfPresent(String.self, forKey: .understandPrompt) ?? AIDefaults.understandPrompt
        systemPrompt = try container.decodeIfPresent(String.self, forKey: .systemPrompt) ?? AIDefaults.systemPrompt

        let source =
            TranslationLanguage(
                rawValue: try container.decodeIfPresent(String.self, forKey: .translationSource) ?? ""
            ) ?? .auto
        let rawTarget =
            TranslationLanguage(
                rawValue: try container.decodeIfPresent(String.self, forKey: .translationTarget) ?? ""
            ) ?? .simplifiedChinese
        let target = rawTarget == .auto ? .simplifiedChinese : rawTarget
        translationSource = source != .auto && source == target ? .auto : source
        translationTarget = target
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(baseURL, forKey: .baseURL)
        try container.encode(model, forKey: .model)
        try container.encode(mode.rawValue, forKey: .mode)
        try container.encode(authEnabled, forKey: .authEnabled)
        try container.encode(textPrompt, forKey: .textPrompt)
        try container.encode(understandPrompt, forKey: .understandPrompt)
        try container.encode(systemPrompt, forKey: .systemPrompt)
        try container.encode(translationSource.rawValue, forKey: .translationSource)
        try container.encode(translationTarget.rawValue, forKey: .translationTarget)
    }

    package var trimmedBaseURL: String {
        baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    package var trimmedModel: String {
        model.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    package func prompt(for mode: AIMode) -> String {
        switch mode {
        case .extract:
            let value = textPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? AIDefaults.textPrompt : value
        case .understand:
            let value = understandPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? AIDefaults.understandPrompt : value
        }
    }

    package func isConfigured(apiKey: String?) -> Bool {
        guard !trimmedBaseURL.isEmpty,
            !trimmedModel.isEmpty,
            let url = URL(string: trimmedBaseURL),
            AIEndpointPolicy.allows(url)
        else {
            return false
        }

        if authEnabled {
            guard let apiKey, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return false
            }
        }
        return true
    }
}
