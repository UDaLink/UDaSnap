import AppKit
import Foundation
import UDaSnapCore

/// 公开法律文档的类型。文档随 App 打包，也放在仓库根目录。
enum LegalDocumentKind: String, CaseIterable {
    case privacy
    case terms

    var title: String {
        switch self {
        case .privacy: return "隐私政策"
        case .terms: return "用户协议"
        }
    }

    var resourceName: String {
        switch self {
        case .privacy: return "PRIVACY"
        case .terms: return "TERMS"
        }
    }
}

enum LegalDocuments {
    /// 修改政策正文时同步递增；版本号变化后，首次启动和设置页会要求重新同意。
    static let policyVersion = "1.0"
    static let effectiveDate = "2026-11-24"
    static let operatorName = "UDaSnap 项目维护者"
    static let contactName = "GitHub Issues / Security 私密报告"
    static let publicPrivacyURL = "https://github.com/UDaLink/UDaSnap/blob/main/PRIVACY.md"

    static let onboardingSections: [(String, String)] = [
        ("本地优先", "截图、OCR、贴图和滚动拼接默认都在这台 Mac 上完成。除非你主动使用 AI 识别、翻译或小U对话，否则截图不会离开本机。"),
        (
            "可选的 AI 外发",
            "使用 AI 时，当前截图、提示词、识别文字和当前模式的对话会发送到你填写的 OpenAI 兼容接口。首次向某个接口和模型发送前，App 会再次显示接口、模型和发送数据类型，单独确认后才发送；取消则不发。"
        ),
        ("权限用途", "屏幕录制用于截图；辅助功能只在你开启强力模式或使用滚动截图自动滚动时需要，拒绝后其他功能仍可用。"),
        ("无遥测", "App 不收集统计、不上报崩溃、不写入远程日志，也不自动检查更新。"),
        (
            "数据位置",
            "截图保存在 ~/Pictures/UDaSnap；快捷键和 AI 配置保存在 ~/Library/Application Support/com.udalink.udasnap；API Key 只保存在 macOS 钥匙串（service com.udalink.udasnap.ai / account api-key）。AI 日常不读取；首次或升级后点「查看」授权一次，选「始终允许」后当前构建内 AI 可静默使用。"
        ),
        ("你的控制", "你可以在「隐私与数据」页删除配置、清除 API Key、清理截图、设置截图保留期限，或撤回同意；撤回后逐接口 AI 同意记录也会清除。"),
        ("运营者与法律", "运营者为 UDaSnap 项目维护者；隐私请求通过 GitHub Issues 或仓库 Security 私密报告联系。本政策主要面向中国大陆用户，适用中华人民共和国法律。"),
    ]

    static func bundledText(for kind: LegalDocumentKind) -> String {
        if let url = Bundle.main.url(
            forResource: kind.resourceName,
            withExtension: "md",
            subdirectory: "Legal"
        ), let text = try? String(contentsOf: url, encoding: .utf8) {
            return text
        }
        // 开发期直接 `swift run` 时没有打包资源，给一个可读的兜底。
        return "# \(kind.title)\n\n文档未随 App 打包。请从项目根目录的 \(kind.resourceName).md 查看完整内容。"
    }

    static func attributedMarkdown(_ text: String) -> NSAttributedString {
        // Foundation 的 markdown 解析会把块级元素之间的换行折叠掉，法律文档会变成一大段。
        // 这里按行做最小渲染，保留段落、标题、列表和行内粗体 / 代码。
        let bodyFont = NSFont.systemFont(ofSize: 13)
        let bodyColor = NSColor.labelColor
        let secondaryColor = NSColor.secondaryLabelColor
        let result = NSMutableAttributedString()

        let lines = text.components(separatedBy: "\n")
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                result.append(
                    NSAttributedString(
                        string: "\n",
                        attributes: [.font: bodyFont, .foregroundColor: bodyColor]
                    ))
                continue
            }

            if line == "---" || line == "⸻" {
                result.append(
                    NSAttributedString(
                        string: "————————————————\n",
                        attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: secondaryColor]
                    ))
                continue
            }

            let headingFont: NSFont?
            let headingText: String
            if line.hasPrefix("### ") {
                headingFont = NSFont.systemFont(ofSize: 14, weight: .semibold)
                headingText = String(line.dropFirst(4))
            } else if line.hasPrefix("## ") {
                headingFont = NSFont.systemFont(ofSize: 16, weight: .semibold)
                headingText = String(line.dropFirst(3))
            } else if line.hasPrefix("# ") {
                headingFont = NSFont.systemFont(ofSize: 20, weight: .semibold)
                headingText = String(line.dropFirst(2))
            } else {
                headingFont = nil
                headingText = line
            }

            if let headingFont {
                result.append(
                    NSAttributedString(
                        string: headingText + "\n",
                        attributes: [.font: headingFont, .foregroundColor: bodyColor]
                    ))
                continue
            }

            if line.hasPrefix("- ") {
                let bullet = NSMutableAttributedString(
                    string: "•  ",
                    attributes: [
                        .font: bodyFont, .foregroundColor: bodyColor,
                    ])
                bullet.append(inlineMarkdown(String(line.dropFirst(2)), baseFont: bodyFont))
                bullet.append(
                    NSAttributedString(
                        string: "\n",
                        attributes: [
                            .font: bodyFont, .foregroundColor: bodyColor,
                        ]))
                result.append(bullet)
                continue
            }

            result.append(inlineMarkdown(line, baseFont: bodyFont))
            result.append(
                NSAttributedString(
                    string: "\n",
                    attributes: [
                        .font: bodyFont, .foregroundColor: bodyColor,
                    ]))
        }

        return result
    }

    /// 解析法律文档中用到的行内 `**粗体**` 和 `` `代码` ``。
    private static func inlineMarkdown(_ text: String, baseFont: NSFont) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var buffer = ""
        var isBold = false
        var isCode = false
        var index = text.startIndex

        func flush() {
            guard !buffer.isEmpty else { return }
            var attributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: isCode ? NSColor.secondaryLabelColor : NSColor.labelColor
            ]
            if isCode {
                attributes[.font] = NSFont.monospacedSystemFont(ofSize: baseFont.pointSize - 0.5, weight: .regular)
            } else if isBold {
                attributes[.font] = NSFontManager.shared.convert(baseFont, toHaveTrait: .boldFontMask)
            } else {
                attributes[.font] = baseFont
            }
            result.append(NSAttributedString(string: buffer, attributes: attributes))
            buffer = ""
        }

        while index < text.endIndex {
            if text[index...].hasPrefix("**") {
                flush()
                isBold.toggle()
                index = text.index(index, offsetBy: 2)
                continue
            }
            if text[index] == "`" {
                flush()
                isCode.toggle()
                index = text.index(after: index)
                continue
            }
            buffer.append(text[index])
            index = text.index(after: index)
        }
        flush()
        return result
    }

}

/// 合规状态。只保存同意版本、同意时间和截图保留期限，不保存任何截图内容。
struct ComplianceSettings: Codable, Equatable {
    var acceptedVersion: String?
    var acceptedAt: String?
    /// 0 = 永久保留；7 / 30 = 只清理 UDaSnap 截图目录中超过期限的文件。
    var retentionDays: Int

    static let `default` = ComplianceSettings(
        acceptedVersion: nil,
        acceptedAt: nil,
        retentionDays: 0
    )

    private enum CodingKeys: String, CodingKey {
        case acceptedVersion
        case acceptedAt
        case retentionDays
    }

    init(acceptedVersion: String?, acceptedAt: String?, retentionDays: Int) {
        self.acceptedVersion = acceptedVersion
        self.acceptedAt = acceptedAt
        self.retentionDays = retentionDays
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.acceptedVersion = try c.decodeIfPresent(String.self, forKey: .acceptedVersion)
        self.acceptedAt = try c.decodeIfPresent(String.self, forKey: .acceptedAt)
        let days = try c.decodeIfPresent(Int.self, forKey: .retentionDays) ?? 0
        self.retentionDays = [0, 7, 30].contains(days) ? days : 0
    }
}

@MainActor
final class ComplianceStore {
    static let didChange = Notification.Name("UDaSnap.ComplianceDidChange")

    private(set) var settings: ComplianceSettings
    let url: URL
    private let consent: AIConsentCoordinator

    init(consent: AIConsentCoordinator) {
        self.consent = consent
        let dir = AppPaths.applicationSupportDirectory
        try? AppPaths.ensureDirectory(dir)
        self.url = dir.appendingPathComponent("compliance.json")

        if let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode(ComplianceSettings.self, from: data)
        {
            self.settings = decoded
        } else {
            self.settings = .default
        }
    }

    var isAccepted: Bool {
        settings.acceptedVersion == LegalDocuments.policyVersion && settings.acceptedAt != nil
    }

    var acceptedAtDisplay: String {
        guard let value = settings.acceptedAt, !value.isEmpty else { return "未同意" }
        return value.replacingOccurrences(of: "T", with: " ")
    }

    func accept() {
        var next = settings
        next.acceptedVersion = LegalDocuments.policyVersion
        next.acceptedAt = ISO8601DateFormatter().string(from: Date())
        settings = next
        saveNow()
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// 撤回同意只删除同意状态；配置、Key 和截图都保留，便于用户重新同意后继续使用。
    func revoke() {
        var next = settings
        next.acceptedVersion = nil
        next.acceptedAt = nil
        settings = next
        consent.clearAll()
        saveNow()
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// 清除应用配置时连同意记录一起删除，截图不受影响。
    func clearAll() {
        settings = .default
        consent.clearAll()
        try? FileManager.default.removeItem(at: url)
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    func setRetentionDays(_ days: Int) {
        guard [0, 7, 30].contains(days) else { return }
        var next = settings
        next.retentionDays = days
        settings = next
        saveNow()
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    func saveNow() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
