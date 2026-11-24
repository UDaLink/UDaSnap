import Foundation

/// Owns non-secret AI settings. The API key is deliberately kept in the Keychain.
@MainActor
package final class AIConfigStore {
    package static let didChange = Notification.Name("UDaSnap.AIConfigDidChange")
    package private(set) var settings: AISettings
    package let fileURL: URL

    package init(directory: URL = AppPaths.applicationSupportDirectory) {
        try? AppPaths.ensureDirectory(directory)
        fileURL = directory.appendingPathComponent("ai-settings.json")

        if let data = try? Data(contentsOf: fileURL),
            let decoded = try? JSONDecoder().decode(AISettings.self, from: data)
        {
            settings = decoded
        } else {
            settings = .default
        }
    }

    package var apiKey: String? {
        settings.authEnabled ? KeychainStore.read() : nil
    }

    package var isConfigured: Bool {
        settings.isConfigured(apiKey: apiKey)
    }

    package func update(_ mutate: (inout AISettings) -> Void) {
        var next = settings
        mutate(&next)
        guard next != settings else { return }
        settings = next
        save()
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    package func setMode(_ mode: AIMode) {
        update { $0.mode = mode }
    }

    package func setTranslationDirection(source: TranslationLanguage, target: TranslationLanguage) {
        guard target != .auto, source == .auto || source != target else { return }
        update {
            $0.translationSource = source
            $0.translationTarget = target
        }
    }

    package func reload() {
        guard let data = try? Data(contentsOf: fileURL),
            let decoded = try? JSONDecoder().decode(AISettings.self, from: data)
        else {
            return
        }
        settings = decoded
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    package func resetToDefaults(deleteFile: Bool) {
        settings = .default
        if deleteFile {
            try? FileManager.default.removeItem(at: fileURL)
        }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    package func saveNow() {
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
