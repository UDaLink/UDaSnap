import AppKit
import UDaSnapCore

/// 偏好设置里的“隐私与数据”页：集中展示数据位置、AI 外发、权限和删除入口。
@MainActor
final class PrivacySettingsView: NSView {

    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    private let scroll = NSScrollView()
    private let content = FlippedView()

    private let consentLabel = NSTextField(wrappingLabelWithString: "")
    private let screenshotLabel = NSTextField(wrappingLabelWithString: "")
    private let configLabel = NSTextField(wrappingLabelWithString: "")
    private let keychainLabel = NSTextField(wrappingLabelWithString: "")
    private let noTelemetryLabel = NSTextField(wrappingLabelWithString: "")
    private let aiEndpointLabel = NSTextField(wrappingLabelWithString: "")
    private let aiDataLabel = NSTextField(wrappingLabelWithString: "")
    private let httpWarning = NSTextField(wrappingLabelWithString: "")
    private let screenPermissionLabel = NSTextField(wrappingLabelWithString: "")
    private let axPermissionLabel = NSTextField(wrappingLabelWithString: "")
    private let actionStatus = NSTextField(wrappingLabelWithString: "")
    private let retentionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let withdrawButton = NSButton(title: "撤回同意", target: nil, action: nil)

    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        buildUI()
        observers.append(
            NotificationCenter.default.addObserver(
                forName: ComplianceStore.didChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in Task { @MainActor in self?.refresh() } })
        observers.append(
            NotificationCenter.default.addObserver(
                forName: AIConfigStore.didChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in Task { @MainActor in self?.refreshAI() } })
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in Task { @MainActor in self?.refreshPermissions() } })
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        content.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 980)
    }

    // MARK: - 构建

    private func buildUI() {
        scroll.frame = bounds
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        addSubview(scroll)

        content.frame = NSRect(x: 0, y: 0, width: 680, height: 980)
        scroll.documentView = content

        let title = NSTextField(labelWithString: "隐私与数据")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        title.frame = NSRect(x: 24, y: 16, width: 604, height: 28)
        content.addSubview(title)

        let subtitle = NSTextField(
            wrappingLabelWithString: "这里说明 UDaSnap 处理哪些数据、数据放在哪里，以及你如何删除或撤回同意。"
        )
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.frame = NSRect(x: 24, y: 44, width: 604, height: 32)
        content.addSubview(subtitle)

        let consentCard = NSView(frame: NSRect(x: 24, y: 84, width: 604, height: 58))
        consentCard.wantsLayer = true
        consentCard.layer?.cornerRadius = 8
        consentCard.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.08).cgColor
        content.addSubview(consentCard)
        configureLabel(consentLabel)
        consentLabel.frame = NSRect(x: 14, y: 8, width: 576, height: 42)
        consentCard.addSubview(consentLabel)

        section("本地数据", y: 164)
        configureLabel(screenshotLabel)
        screenshotLabel.frame = NSRect(x: 24, y: 192, width: 440, height: 42)
        content.addSubview(screenshotLabel)
        addButton("打开截图目录", x: 474, y: 196, width: 154, action: #selector(openScreenshotFolder))

        configureLabel(configLabel)
        configLabel.frame = NSRect(x: 24, y: 244, width: 440, height: 32)
        content.addSubview(configLabel)
        addButton("打开配置目录", x: 474, y: 244, width: 154, action: #selector(openConfigFolder))

        configureLabel(keychainLabel)
        keychainLabel.stringValue =
            "API Key：只存放在 macOS 钥匙串（service com.udalink.udasnap.ai / account api-key），不写入 ai-settings.json；AI 日常不读取，首次或升级后点「查看」授权一次。"
        keychainLabel.frame = NSRect(x: 24, y: 288, width: 604, height: 32)
        content.addSubview(keychainLabel)

        configureLabel(noTelemetryLabel)
        noTelemetryLabel.stringValue = "无遥测：不收集统计、不上报崩溃、不写入远程日志、不自动检查更新。"
        noTelemetryLabel.textColor = .systemGreen
        noTelemetryLabel.frame = NSRect(x: 24, y: 322, width: 604, height: 22)
        content.addSubview(noTelemetryLabel)

        section("AI 外发", y: 360)
        configureLabel(aiEndpointLabel)
        aiEndpointLabel.frame = NSRect(x: 24, y: 388, width: 604, height: 22)
        content.addSubview(aiEndpointLabel)
        configureLabel(aiDataLabel)
        aiDataLabel.stringValue = "使用 AI 识别、翻译或小U对话时，当前截图、提示词、识别文字和当前模式的对话会发送到你填写的接口。第三方是否留存、是否跨境由该服务方决定；App 无法控制其留存期限。"
        aiDataLabel.frame = NSRect(x: 24, y: 414, width: 604, height: 46)
        content.addSubview(aiDataLabel)
        configureLabel(httpWarning)
        httpWarning.textColor = .systemOrange
        httpWarning.frame = NSRect(x: 24, y: 466, width: 604, height: 32)
        content.addSubview(httpWarning)

        section("权限", y: 512)
        configureLabel(screenPermissionLabel)
        screenPermissionLabel.frame = NSRect(x: 24, y: 540, width: 440, height: 32)
        content.addSubview(screenPermissionLabel)
        addButton("打开屏幕录制设置", x: 474, y: 542, width: 154, action: #selector(openScreenPermission))

        configureLabel(axPermissionLabel)
        axPermissionLabel.frame = NSRect(x: 24, y: 582, width: 440, height: 32)
        content.addSubview(axPermissionLabel)
        addButton("打开辅助功能设置", x: 474, y: 584, width: 154, action: #selector(openAXPermission))

        section("数据控制", y: 636)
        let retentionLabel = NSTextField(labelWithString: "截图保留期限")
        retentionLabel.font = .systemFont(ofSize: 12, weight: .medium)
        retentionLabel.frame = NSRect(x: 24, y: 666, width: 150, height: 18)
        content.addSubview(retentionLabel)

        retentionPopup.frame = NSRect(x: 174, y: 660, width: 136, height: 28)
        for (title, days) in [("永久保留", 0), ("30 天", 30), ("7 天", 7)] {
            retentionPopup.addItem(withTitle: title)
            retentionPopup.lastItem?.representedObject = days
        }
        retentionPopup.target = self
        retentionPopup.action = #selector(retentionChanged)
        content.addSubview(retentionPopup)

        let retentionHint = NSTextField(
            wrappingLabelWithString: "只清理 ~/Pictures/UDaSnap 中符合 UDaSnap 命名规则的 PNG，不会动其他文件。"
        )
        retentionHint.font = .systemFont(ofSize: 10)
        retentionHint.textColor = .secondaryLabelColor
        retentionHint.frame = NSRect(x: 322, y: 662, width: 306, height: 30)
        content.addSubview(retentionHint)

        addButton("清除 API Key", x: 24, y: 706, width: 156, action: #selector(clearAPIKey))
        addButton("清除应用配置", x: 198, y: 706, width: 166, action: #selector(clearConfiguration))
        addButton("清理截图目录", x: 382, y: 706, width: 166, action: #selector(cleanScreenshots))

        configureLabel(actionStatus)
        actionStatus.textColor = .secondaryLabelColor
        actionStatus.frame = NSRect(x: 24, y: 744, width: 604, height: 32)
        content.addSubview(actionStatus)

        section("协议与同意", y: 792)
        addButton("查看隐私政策", x: 24, y: 820, width: 150, action: #selector(openPrivacy))
        addButton("查看用户协议", x: 186, y: 820, width: 150, action: #selector(openTerms))
        addButton("在线隐私政策", x: 510, y: 820, width: 118, action: #selector(openOnlinePrivacy))

        withdrawButton.bezelStyle = .rounded
        withdrawButton.target = self
        withdrawButton.action = #selector(withdrawConsent)
        withdrawButton.frame = NSRect(x: 348, y: 820, width: 150, height: 30)
        content.addSubview(withdrawButton)

        let legalFootnote = NSTextField(
            wrappingLabelWithString:
                "运营者：\(LegalDocuments.operatorName)　联系：\(LegalDocuments.contactName)\n隐私政策 v\(LegalDocuments.policyVersion) · 生效 \(LegalDocuments.effectiveDate)"
        )
        legalFootnote.font = .systemFont(ofSize: 10)
        legalFootnote.textColor = .secondaryLabelColor
        legalFootnote.frame = NSRect(x: 24, y: 862, width: 604, height: 38)
        content.addSubview(legalFootnote)
    }

    private func section(_ title: String, y: CGFloat) {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: 24, y: y, width: 604, height: 18)
        content.addSubview(label)
        let line = NSView(frame: NSRect(x: 24, y: y + 22, width: 604, height: 1))
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.4).cgColor
        content.addSubview(line)
    }

    private func configureLabel(_ label: NSTextField) {
        label.font = .systemFont(ofSize: 11.5)
        label.textColor = .labelColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 3
    }

    private func addButton(_ title: String, x: CGFloat, y: CGFloat, width: CGFloat, action: Selector) {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.frame = NSRect(x: x, y: y, width: width, height: 30)
        content.addSubview(button)
    }

    // MARK: - 刷新

    func refresh() {
        let compliance = AppEnvironment.shared.compliance
        let accepted = compliance.isAccepted
        consentLabel.stringValue =
            accepted
            ? "✅ 已同意隐私政策 v\(LegalDocuments.policyVersion)\n同意时间：\(compliance.acceptedAtDisplay)"
            : "⚠️ 尚未同意隐私政策\n需要先完成首次启动同意，才能使用截图和 AI 功能。"

        let count = ScreenshotStorage.screenshotCount()
        screenshotLabel.stringValue = "截图目录：\(ScreenshotStorage.folder.path)\n当前有 \(count) 个 UDaSnap 截图。"
        configLabel.stringValue = "配置目录：\(ScreenshotStorage.configFolder.path)\n包含快捷键配置、AI 配置和隐私同意记录，不包含 API Key。"
        withdrawButton.isEnabled = accepted
        refreshAI()
        refreshPermissions()
        refreshRetention()
    }

    private func refreshAI() {
        let settings = AppEnvironment.shared.aiConfig.settings
        let base = settings.trimmedBaseURL
        guard !base.isEmpty, let url = URL(string: base), let host = url.host else {
            aiEndpointLabel.stringValue = "当前接口：尚未配置"
            httpWarning.stringValue = ""
            httpWarning.isHidden = true
            return
        }
        let scheme = url.scheme?.lowercased() ?? ""
        aiEndpointLabel.stringValue =
            "当前接口：\(scheme)://\(host)　模型：\(settings.trimmedModel.isEmpty ? "未填写" : settings.trimmedModel)"
        if let rejection = AIEndpointPolicy.httpRejectionMessage(for: url) {
            httpWarning.stringValue = "⚠️ \(rejection)"
            httpWarning.isHidden = false
        } else if scheme == "http" {
            httpWarning.stringValue = "未加密连接：HTTP 会把截图和请求内容明文传输；当前仅允许 localhost、局域网地址或 .local 主机。"
            httpWarning.isHidden = false
        } else {
            httpWarning.stringValue = ""
            httpWarning.isHidden = true
        }
    }

    private func refreshPermissions() {
        screenPermissionLabel.stringValue =
            CaptureService.hasPermission
            ? "屏幕录制：✅ 已授权（截图必需）"
            : "屏幕录制：⚠️ 未授权（截图前需要在系统设置中打开）"
        axPermissionLabel.stringValue =
            HotkeyManager.hasAccessibility
            ? "辅助功能：✅ 已授权（强力模式和滚动自动滚动可用）"
            : "辅助功能：未授权（仅强力模式和滚动自动滚动需要，可不开）"
        axPermissionLabel.textColor = HotkeyManager.hasAccessibility ? .labelColor : .secondaryLabelColor
    }

    private func refreshRetention() {
        let days = AppEnvironment.shared.compliance.settings.retentionDays
        if let index = retentionPopup.itemArray.firstIndex(where: { ($0.representedObject as? Int) == days }) {
            retentionPopup.selectItem(at: index)
        }
    }

    private func showStatus(_ text: String, success: Bool) {
        actionStatus.stringValue = text
        actionStatus.textColor = success ? .systemGreen : .systemRed
    }

    private func confirm(_ message: String, informative: String, confirmTitle: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = informative
        alert.alertStyle = .warning
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - 动作

    @objc private func openScreenshotFolder() {
        ScreenshotStorage.ensureFolder()
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: ScreenshotStorage.folder.path)
    }

    @objc private func openConfigFolder() {
        ScreenshotStorage.revealConfigFolder()
    }

    @objc private func openScreenPermission() {
        CaptureService.requestPermission()
        CaptureService.openPermissionSettings()
        refreshPermissions()
    }

    @objc private func openAXPermission() {
        HotkeyManager.requestAccessibility()
        HotkeyManager.openAccessibilitySettings()
        refreshPermissions()
    }

    @objc private func clearAPIKey() {
        guard
            confirm(
                "清除 API Key？",
                informative: "只会删除本机钥匙串里的 UDaSnap API Key，不会改动其他配置、快捷键或截图。",
                confirmTitle: "清除 Key"
            )
        else { return }
        KeychainStore.delete()
        showStatus("已清除 API Key。", success: true)
        refresh()
    }

    @objc private func clearConfiguration() {
        guard
            confirm(
                "清除应用配置？",
                informative: "会删除快捷键配置、AI 配置、API Key 和隐私同意记录，并重新显示首次同意页。截图目录不会受影响。",
                confirmTitle: "清除配置"
            )
        else { return }

        SettingsFile.delete()
        AppEnvironment.shared.aiConfig.resetToDefaults(deleteFile: true)
        KeychainStore.delete()
        AppEnvironment.shared.compliance.clearAll()
        NotificationCenter.default.post(name: .configurationCleared, object: nil)
    }

    @objc private func cleanScreenshots() {
        let count = ScreenshotStorage.screenshotCount()
        guard count > 0 else {
            showStatus("截图目录中没有 UDaSnap 命名的截图。", success: false)
            return
        }
        guard
            confirm(
                "清理截图目录？",
                informative: "将删除 \(ScreenshotStorage.folder.path) 中 \(count) 个 UDaSnap 截图，其他文件不动。此操作不可撤销。",
                confirmTitle: "删除截图"
            )
        else { return }
        let removed = ScreenshotStorage.deleteAllScreenshots()
        showStatus("已清理 \(removed) 个截图。", success: true)
        refresh()
    }

    @objc private func retentionChanged() {
        let days = retentionPopup.selectedItem?.representedObject as? Int ?? 0
        AppEnvironment.shared.compliance.setRetentionDays(days)
        if days > 0 {
            let removed = ScreenshotStorage.deleteScreenshots(olderThan: days)
            showStatus(removed > 0 ? "已按保留期限清理 \(removed) 个旧截图。" : "没有超过保留期限的截图。", success: true)
        } else {
            showStatus("截图将永久保留，直到你手动清理。", success: true)
        }
        refresh()
    }

    @objc private func withdrawConsent() {
        guard
            confirm(
                "撤回隐私同意？",
                informative: "撤回后立即停止截图和 AI 请求，关闭贴图、OCR 和 AI 结果窗；配置与截图会保留，你可以重新阅读并同意。",
                confirmTitle: "撤回同意"
            )
        else { return }
        NotificationCenter.default.post(name: .withdrawConsent, object: nil)
    }

    @objc private func openPrivacy() {
        LegalDocumentWindowController.show(.privacy)
    }

    @objc private func openOnlinePrivacy() {
        guard let url = URL(string: LegalDocuments.publicPrivacyURL) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openTerms() {
        LegalDocumentWindowController.show(.terms)
    }
}

extension Notification.Name {
    static let configurationCleared = Notification.Name("UDaSnap.ConfigurationCleared")
    static let withdrawConsent = Notification.Name("UDaSnap.WithdrawConsent")
}
