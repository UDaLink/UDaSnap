import AppKit
import Foundation
import UDaSnapCore

/// 偏好设置里的 AI 页：接口配置、两种识别模式提示词、小U 系统提示词和连接测试。
@MainActor
final class AISettingsView: NSView, NSTextFieldDelegate, NSTextViewDelegate {

    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    private let scroll = NSScrollView()
    private let content = FlippedView()

    private let baseField = NSTextField()
    private let modelField = NSTextField()
    private let keyField = NSSecureTextField()
    private let keyLabel = NSTextField(labelWithString: "API Key")
    private let viewKeyButton = NSButton(title: "查看", target: nil, action: nil)
    private let clearKeyButton = NSButton(title: "清除", target: nil, action: nil)
    private let keyHint = NSTextField(
        labelWithString: "API Key 存 macOS 钥匙串；AI 日常不读取。首次或升级后点「查看」，在系统弹窗选「始终允许」授权一次，之后 AI 可静默使用。")
    private let authCheck = NSButton(checkboxWithTitle: "无需鉴权（本地 / 内网接口）", target: nil, action: nil)
    private let modeControl = NSSegmentedControl(
        labels: ["文字提取", "内容理解"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )

    private let textPromptView = NSTextView()
    private let understandPromptView = NSTextView()
    private let systemPromptView = NSTextView()

    private let testButton = NSButton(title: "测试连接", target: nil, action: nil)
    private let visionButton = NSButton(title: "测试读图", target: nil, action: nil)
    private let testStatus = NSTextField(labelWithString: "")
    private let visionStatus = NSTextField(labelWithString: "")

    private let privacyBanner = NSView()
    private let privacyLabel = NSTextField(wrappingLabelWithString: "")

    private var saveWorkItem: DispatchWorkItem?
    nonisolated(unsafe) private var modeObserver: NSObjectProtocol?
    private var isUpdatingUI = false
    private var keyLoaded = false
    private var keyEditingUnlocked = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        buildUI()
        // 启动时不读 API Key：AI 页打开也只显示占位；点「查看」才允许一次授权读取。
        refreshFromStore(loadKey: false)

        modeObserver = NotificationCenter.default.addObserver(
            forName: AIConfigStore.didChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let mode = AppEnvironment.shared.aiConfig.settings.mode
                if self.modeControl.selectedSegment != mode.segmentIndex {
                    self.isUpdatingUI = true
                    self.modeControl.selectedSegment = mode.segmentIndex
                    self.isUpdatingUI = false
                }
                self.updatePrivacyBanner()
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let modeObserver {
            NotificationCenter.default.removeObserver(modeObserver)
        }
    }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        content.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 1050)
    }

    // MARK: - 构建

    private func buildUI() {
        scroll.frame = bounds
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        addSubview(scroll)

        content.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 1050)
        scroll.documentView = content

        let title = NSTextField(labelWithString: "AI 设置")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        title.frame = NSRect(x: 24, y: 16, width: 620, height: 28)
        content.addSubview(title)

        let subtitle = NSTextField(labelWithString: "配置 OpenAI 兼容的大模型接口；截图会用于识别，不会上传到其他地方。")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byWordWrapping
        subtitle.maximumNumberOfLines = 2
        subtitle.frame = NSRect(x: 24, y: 44, width: 620, height: 32)
        content.addSubview(subtitle)

        buildPrivacyBanner()

        let apiTitle = sectionLabel("接口")
        apiTitle.frame = NSRect(x: 24, y: 154, width: 620, height: 18)
        content.addSubview(apiTitle)

        let baseLabel = NSTextField(labelWithString: "接口地址（Base URL）")
        baseLabel.font = .systemFont(ofSize: 12, weight: .medium)
        baseLabel.frame = NSRect(x: 24, y: 182, width: 620, height: 18)
        content.addSubview(baseLabel)

        baseField.placeholderString = "https://api.openai.com/v1"
        baseField.font = .systemFont(ofSize: 12)
        baseField.delegate = self
        baseField.frame = NSRect(x: 24, y: 202, width: 604, height: 26)
        content.addSubview(baseField)

        let baseHint = NSTextField(labelWithString: "填到 /v1 即可，App 会自动补 /chat/completions。")
        baseHint.font = .systemFont(ofSize: 10)
        baseHint.textColor = .secondaryLabelColor
        baseHint.frame = NSRect(x: 24, y: 226, width: 604, height: 16)
        content.addSubview(baseHint)

        let modelLabel = NSTextField(labelWithString: "模型名称")
        modelLabel.font = .systemFont(ofSize: 12, weight: .medium)
        modelLabel.frame = NSRect(x: 24, y: 248, width: 620, height: 18)
        content.addSubview(modelLabel)

        modelField.placeholderString = "gpt-4o-mini（必须支持图片输入）"
        modelField.font = .systemFont(ofSize: 12)
        modelField.delegate = self
        modelField.frame = NSRect(x: 24, y: 268, width: 604, height: 26)
        content.addSubview(modelField)

        authCheck.target = self
        authCheck.action = #selector(authToggle)
        authCheck.font = .systemFont(ofSize: 11)
        authCheck.frame = NSRect(x: 24, y: 300, width: 300, height: 20)
        content.addSubview(authCheck)

        keyLabel.font = .systemFont(ofSize: 12, weight: .medium)
        keyLabel.frame = NSRect(x: 24, y: 324, width: 180, height: 18)
        content.addSubview(keyLabel)

        keyField.placeholderString = "点「查看」授权后读取 / 编辑"
        keyField.isEnabled = false
        keyField.font = .systemFont(ofSize: 12)
        keyField.delegate = self
        keyField.frame = NSRect(x: 24, y: 344, width: 386, height: 26)
        content.addSubview(keyField)

        viewKeyButton.target = self
        viewKeyButton.action = #selector(viewStoredKey)
        viewKeyButton.bezelStyle = .rounded
        viewKeyButton.font = .systemFont(ofSize: 10)
        viewKeyButton.frame = NSRect(x: 418, y: 342, width: 62, height: 28)
        content.addSubview(viewKeyButton)

        clearKeyButton.target = self
        clearKeyButton.action = #selector(clearAPIKey)
        clearKeyButton.bezelStyle = .rounded
        clearKeyButton.font = .systemFont(ofSize: 10)
        clearKeyButton.frame = NSRect(x: 486, y: 342, width: 62, height: 28)
        content.addSubview(clearKeyButton)

        keyHint.font = .systemFont(ofSize: 10)
        keyHint.textColor = .secondaryLabelColor
        keyHint.frame = NSRect(x: 24, y: 370, width: 604, height: 16)
        content.addSubview(keyHint)

        testButton.target = self
        testButton.action = #selector(testConnection)
        testButton.bezelStyle = .rounded
        testButton.font = .systemFont(ofSize: 11)
        testButton.frame = NSRect(x: 24, y: 396, width: 92, height: 28)
        content.addSubview(testButton)

        visionButton.target = self
        visionButton.action = #selector(testVision)
        visionButton.bezelStyle = .rounded
        visionButton.font = .systemFont(ofSize: 11)
        visionButton.frame = NSRect(x: 120, y: 396, width: 92, height: 28)
        content.addSubview(visionButton)

        configureStatus(testStatus)
        testStatus.frame = NSRect(x: 24, y: 428, width: 604, height: 18)
        content.addSubview(testStatus)

        configureStatus(visionStatus)
        visionStatus.frame = NSRect(x: 24, y: 448, width: 604, height: 18)
        content.addSubview(visionStatus)

        let modeTitle = sectionLabel("识别")
        modeTitle.frame = NSRect(x: 24, y: 486, width: 620, height: 18)
        content.addSubview(modeTitle)

        let modeLabel = NSTextField(labelWithString: "识别的默认模式（窗口内切换会同步记住）")
        modeLabel.font = .systemFont(ofSize: 11)
        modeLabel.textColor = .secondaryLabelColor
        modeLabel.frame = NSRect(x: 24, y: 514, width: 604, height: 16)
        content.addSubview(modeLabel)

        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        modeControl.segmentStyle = .rounded
        modeControl.frame = NSRect(x: 24, y: 536, width: 190, height: 28)
        content.addSubview(modeControl)

        addPrompt(
            title: "文字提取提示词",
            textView: textPromptView,
            y: 574,
            resetAction: #selector(resetTextPrompt)
        )
        addPrompt(
            title: "内容理解提示词",
            textView: understandPromptView,
            y: 692,
            resetAction: #selector(resetUnderstandPrompt)
        )
        addPrompt(
            title: "小U 系统提示词",
            textView: systemPromptView,
            y: 810,
            resetAction: #selector(resetSystemPrompt)
        )

        let autoLabel = NSTextField(labelWithString: "所有修改自动保存")
        autoLabel.font = .systemFont(ofSize: 10)
        autoLabel.textColor = .secondaryLabelColor
        autoLabel.frame = NSRect(x: 24, y: 938, width: 604, height: 16)
        content.addSubview(autoLabel)

        let footer = NSTextField(
            wrappingLabelWithString: "提示：模型必须支持图片输入（vision）。截图可能包含聊天、文档等敏感内容，请只使用你信任的接口。"
        )
        footer.font = .systemFont(ofSize: 10)
        footer.textColor = .secondaryLabelColor
        footer.frame = NSRect(x: 24, y: 960, width: 604, height: 32)
        content.addSubview(footer)
    }

    private func sectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        return label
    }

    private func buildPrivacyBanner() {
        privacyBanner.frame = NSRect(x: 24, y: 82, width: 604, height: 62)
        privacyBanner.wantsLayer = true
        privacyBanner.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.08).cgColor
        privacyBanner.layer?.cornerRadius = 7
        content.addSubview(privacyBanner)

        privacyLabel.font = .systemFont(ofSize: 11)
        privacyLabel.textColor = .labelColor
        privacyLabel.frame = NSRect(x: 12, y: 8, width: 580, height: 46)
        privacyBanner.addSubview(privacyLabel)
    }

    private func addPrompt(title: String, textView: NSTextView, y: CGFloat, resetAction: Selector) {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.frame = NSRect(x: 24, y: y, width: 400, height: 18)
        content.addSubview(label)

        let reset = NSButton(title: "恢复默认", target: self, action: resetAction)
        reset.isBordered = false
        reset.font = .systemFont(ofSize: 10)
        reset.contentTintColor = .linkColor
        reset.frame = NSRect(x: 540, y: y - 2, width: 88, height: 22)
        content.addSubview(reset)

        let promptScroll = NSScrollView(frame: NSRect(x: 24, y: y + 22, width: 604, height: 88))
        promptScroll.borderType = .bezelBorder
        promptScroll.hasVerticalScroller = true
        promptScroll.autohidesScrollers = true
        promptScroll.drawsBackground = true
        promptScroll.backgroundColor = .textBackgroundColor

        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.font = .systemFont(ofSize: 11)
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 8, height: 6)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = NSSize(width: 0, height: 88)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        promptScroll.documentView = textView
        textView.frame = NSRect(x: 0, y: 0, width: 604, height: 88)
        textView.textContainer?.containerSize = NSSize(width: 588, height: CGFloat.greatestFiniteMagnitude)
        textView.delegate = self
        content.addSubview(promptScroll)
    }

    private func configureStatus(_ label: NSTextField) {
        label.font = .systemFont(ofSize: 10)
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 2
    }

    // MARK: - 加载与保存

    func refresh() {
        // 打开 AI 页只读普通配置，不主动读 API Key。
        refreshFromStore(loadKey: false)
        updateTestButtons()
    }

    func flush() {
        saveWorkItem?.cancel()
        saveFromUI()
        AppEnvironment.shared.aiConfig.saveNow()
    }

    /// 清除应用配置时丢弃尚未落盘的编辑，并从已经重置的存储重新读入（不碰钥匙串）。
    func discardAndReloadFromStore() {
        saveWorkItem?.cancel()
        refreshFromStore(loadKey: false)
        updateTestButtons()
    }

    /// NSSecureTextField 默认拒绝 ⌘C；当焦点在 API Key 输入框时由编辑菜单显式接管。
    func copySecureKeyIfFocused(in window: NSWindow) -> Bool {
        guard let editor = window.firstResponder as? NSTextView,
            let field = editor.delegate as? NSTextField,
            field === keyField,
            !keyField.stringValue.isEmpty
        else {
            return false
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(keyField.stringValue, forType: .string)
    }

    private func refreshFromStore(loadKey: Bool) {
        isUpdatingUI = true
        let settings = AppEnvironment.shared.aiConfig.settings
        baseField.stringValue = settings.baseURL
        modelField.stringValue = settings.model
        modeControl.selectedSegment = settings.mode.segmentIndex
        authCheck.state = settings.authEnabled ? .off : .on
        textPromptView.string = settings.textPrompt
        understandPromptView.string = settings.understandPrompt
        systemPromptView.string = settings.systemPrompt
        keyLoaded = false
        keyEditingUnlocked = false
        keyField.isEnabled = false
        if loadKey && settings.authEnabled {
            if let key = KeychainStore.read() {
                keyField.stringValue = key
                keyLoaded = true
            } else {
                keyField.stringValue = ""
            }
        } else {
            keyField.stringValue = ""
        }
        keyHint.stringValue =
            settings.authEnabled
            ? "API Key 存 macOS 钥匙串；AI 日常不读取。首次或升级后点「查看」，在系统弹窗选「始终允许」授权一次，之后 AI 可静默使用。"
            : "当前使用无需鉴权的本地 / 内网接口，不读取 API Key。"
        isUpdatingUI = false
        updateAuthVisibility()
        updatePrivacyBanner()
        updateTestButtons()
    }

    private func updatePrivacyBanner() {
        let base = AppEnvironment.shared.aiConfig.settings.trimmedBaseURL
        if base.isEmpty {
            privacyLabel.stringValue = "AI 外发说明：尚未配置接口。配置后，使用 AI 识别、翻译或对话时，截图、提示词、识别文字和当前对话会发送到你填写的接口；首次向该接口发送前会再次确认。"
        } else if let url = URL(string: base), let host = url.host {
            if let warning = AIEndpointPolicy.httpRejectionMessage(for: url) {
                privacyLabel.stringValue = "⚠️ \(warning)"
                privacyBanner.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.12).cgColor
                return
            }
            let scheme = url.scheme?.lowercased() ?? ""
            let insecure = scheme == "http" ? "（仅限本机/局域网未加密连接）" : ""
            privacyLabel.stringValue =
                "AI 外发说明：使用 AI 时，截图、提示词、识别文字和当前对话会发送到 \(scheme)://\(host)\(insecure)。首次向该接口发送前会单独确认，确认后同一接口/模型不再重复弹窗；可在「隐私与数据」页撤回。"
        } else {
            privacyLabel.stringValue = "AI 外发说明：使用 AI 时，截图、提示词、识别文字和当前对话会发送到你配置的接口。请只使用你信任的服务。"
        }
        privacyBanner.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.08).cgColor
    }

    private func updateAuthVisibility() {
        let enabled = authCheck.state == .off
        keyLabel.isHidden = !enabled
        keyField.isHidden = !enabled
        keyField.isEnabled = enabled && keyEditingUnlocked
        viewKeyButton.isHidden = !enabled
        clearKeyButton.isHidden = !enabled
        updateTestButtons()
    }

    private func updateTestButtons() {
        let settings = currentSettingsFromUI()
        // Key 是否已读取不影响“能否发起测试”：测试按钮可以点，点击后再提示先查看 / 填 Key。
        // 这样打开页面时不会为了判断按钮状态去读钥匙串。
        let ready = settings.isConfigured(apiKey: settings.authEnabled ? "pending" : nil)
        testButton.isEnabled = ready
        visionButton.isEnabled = ready
    }

    private func currentSettingsFromUI() -> AISettings {
        var settings = AppEnvironment.shared.aiConfig.settings
        settings.baseURL = baseField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.model = modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.mode = AIMode.from(segment: modeControl.selectedSegment)
        settings.authEnabled = authCheck.state == .off
        settings.textPrompt = textPromptView.string
        settings.understandPrompt = understandPromptView.string
        settings.systemPrompt = systemPromptView.string
        return settings
    }

    private func scheduleSave() {
        guard !isUpdatingUI else { return }
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.saveFromUI()
        }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
    }

    private func saveFromUI() {
        guard !isUpdatingUI else { return }
        let next = currentSettingsFromUI()
        // 只有用户真正编辑过 Key 才写回钥匙串。查看现有 Key 属于只读展示，
        // 这里若写回就会把查看结果当成用户编辑，甚至把 Key 冲掉。
        if next.authEnabled && keyLoaded && keyEditingUnlocked {
            _ = KeychainStore.save(keyField.stringValue)
        }
        AppEnvironment.shared.aiConfig.update { current in
            current = next
        }
    }

    // MARK: - 控件事件

    func controlTextDidChange(_ notification: Notification) {
        guard !isUpdatingUI else { return }
        if let field = notification.object as? NSTextField, field === keyField {
            keyLoaded = true
        }
        scheduleSave()
        updateTestButtons()
    }

    func textDidChange(_ notification: Notification) {
        guard !isUpdatingUI else { return }
        scheduleSave()
    }

    @objc private func authToggle() {
        updateAuthVisibility()
        keyHint.stringValue =
            authCheck.state == .off
            ? "API Key 存 macOS 钥匙串；AI 日常不读取。首次或升级后点「查看」，在系统弹窗选「始终允许」授权一次，之后 AI 可静默使用。"
            : "当前使用无需鉴权的本地 / 内网接口，不读取 API Key。"
        // 从「无需鉴权」切回需要鉴权时也不主动读 API Key。
        scheduleSave()
    }

    @objc private func viewStoredKey() {
        guard authCheck.state == .off else { return }
        isUpdatingUI = true
        switch KeychainStore.readResult(allowInteraction: true) {
        case .value(let key):
            keyField.stringValue = key
            // 只读展示：不把这次程序化赋值当成“用户编辑”，避免 0.25s 后自动保存。
            keyLoaded = false
            keyEditingUnlocked = true
            keyField.isEnabled = true
            keyHint.stringValue = "已读取 API Key。若刚才在系统弹窗选了「始终允许」，当前构建内 AI 日常使用不会再弹密码。"
        case .notFound:
            keyField.stringValue = ""
            keyLoaded = false
            keyEditingUnlocked = true
            keyField.isEnabled = true
            keyHint.stringValue = "钥匙串中没有找到 API Key；已解锁输入框，请填写后自动保存。"
        case .denied:
            keyField.stringValue = ""
            keyLoaded = false
            keyEditingUnlocked = false
            keyField.isEnabled = false
            keyHint.stringValue = "未授权读取；已保存的 API Key 未被改动。再次点「查看」，并在系统弹窗选「始终允许」。"
        case .failure(let status):
            keyField.stringValue = ""
            keyLoaded = false
            keyEditingUnlocked = false
            keyField.isEnabled = false
            keyHint.stringValue = "读取钥匙串失败（\(status)），可重试点「查看」；授权后再填写。"
        }
        isUpdatingUI = false
        updateTestButtons()
    }

    @objc private func modeChanged() {
        scheduleSave()
    }

    @objc private func clearAPIKey() {
        keyField.stringValue = ""
        keyLoaded = false
        keyEditingUnlocked = true
        keyField.isEnabled = true
        _ = KeychainStore.delete()
        keyHint.stringValue = "API Key 已从钥匙串清除；可直接填写新的 Key。"
        scheduleSave()
    }

    @objc private func resetTextPrompt() {
        textPromptView.string = AIDefaults.textPrompt
        scheduleSave()
    }

    @objc private func resetUnderstandPrompt() {
        understandPromptView.string = AIDefaults.understandPrompt
        scheduleSave()
    }

    @objc private func resetSystemPrompt() {
        systemPromptView.string = AIDefaults.systemPrompt
        scheduleSave()
    }

    @objc private func testConnection() {
        currentTest(settings: currentSettingsFromUI(), label: testStatus, vision: false)
    }

    @objc private func testVision() {
        currentTest(settings: currentSettingsFromUI(), label: visionStatus, vision: true)
    }

    private func currentTest(settings: AISettings, label: NSTextField, vision: Bool) {
        let key = settings.authEnabled ? keyField.stringValue : nil
        if settings.authEnabled && keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            label.stringValue = "请先点「查看」授权读取已保存的 API Key，再测试；系统弹窗选「始终允许」后当前构建内 AI 不再弹密码。"
            label.textColor = .secondaryLabelColor
            return
        }
        guard settings.isConfigured(apiKey: key) else {
            label.stringValue = "请先填写完整的 Base URL、模型和 API Key；远程 HTTP 接口需要改用 HTTPS。"
            label.textColor = .systemRed
            return
        }
        let dataTypes =
            vision
            ? ["内置测试图片（不含你的截图）"]
            : ["测试提示词"]
        guard AppEnvironment.shared.aiConsent.ensure(for: settings, dataTypes: dataTypes, parentWindow: window) else {
            label.stringValue = "已取消发送；未向接口传输数据。"
            label.textColor = .secondaryLabelColor
            return
        }
        label.stringValue = "测试中…"
        label.textColor = .secondaryLabelColor
        if vision {
            _ = AIClient.testVision(settings: settings, apiKey: key) { [weak self] result in
                guard let self else { return }
                self.showTestResult(result, label: label, prefix: "读图")
                self.updateTestButtons()
            }
        } else {
            _ = AIClient.testConnection(settings: settings, apiKey: key) { [weak self] result in
                guard let self else { return }
                self.showTestResult(result, label: label, prefix: "连接")
                self.updateTestButtons()
            }
        }
    }

    private func showTestResult(_ result: Result<String, Error>, label: NSTextField, prefix: String) {
        switch result {
        case .success(let text):
            label.stringValue = "✅ \(prefix)成功：\(text.replacingOccurrences(of: "\n", with: " "))"
            label.textColor = .systemGreen
        case .failure(let error):
            label.stringValue = "❌ \(prefix)失败：\(error.localizedDescription)"
            label.textColor = .systemRed
        }
    }
}
