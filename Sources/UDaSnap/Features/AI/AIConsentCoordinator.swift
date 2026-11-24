import AppKit
import Foundation
import UDaSnapCore

/// Per-endpoint consent for sending data to third-party AI services.
///
/// The onboarding privacy consent covers local processing; it does not cover sending
/// screenshots or text to a specific third-party endpoint and model. Consent records
/// store only the normalized endpoint identity and model name, never image or prompt data.
@MainActor
final class AIConsentCoordinator {
    private let defaults: UserDefaults
    private let defaultsKey = "UDaSnap.aiConsent.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func hasConsent(for settings: AISettings) -> Bool {
        let records = defaults.dictionary(forKey: defaultsKey) as? [String: String]
        return records?[AIConsentKey.make(for: settings)] != nil
    }

    /// Returns `true` only after the user explicitly approves this endpoint + model.
    func ensure(
        for settings: AISettings,
        dataTypes: [String],
        parentWindow: NSWindow? = nil
    ) -> Bool {
        if hasConsent(for: settings) { return true }

        let host = AIConsentKey.displayHost(for: settings.trimmedBaseURL)
        let model = settings.trimmedModel
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "确认向第三方 AI 接口发送数据？"
        alert.informativeText = """
            接口：\(host)
            模型：\(model)

            本次将发送：
            \(dataTypes.map { "• \($0)" }.joined(separator: "\n"))

            这个接口由你填写，可能是第三方服务；数据可能被留存、用于其他目的或跨境传输，UDaSnap 无法控制对方的保留期限。只有点击「同意并发送」后才会发送本次数据。
            """
        alert.addButton(withTitle: "同意并发送")
        alert.addButton(withTitle: "取消")

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return false }

        var records = defaults.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
        records[AIConsentKey.make(for: settings)] = ISO8601DateFormatter().string(from: Date())
        defaults.set(records, forKey: defaultsKey)
        return true
    }

    func clearAll() {
        defaults.removeObject(forKey: defaultsKey)
    }
}
