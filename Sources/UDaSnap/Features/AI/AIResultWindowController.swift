import AppKit
import Foundation
import UDaSnapCore

/// AI 识别结果窗：左侧原图、右侧可编辑结果，小U 对话按需在右侧展开。
@MainActor
final class AIResultWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {

    private static var liveWindows: [AIResultWindowController] = []

    /// 撤回同意时关闭所有结果窗，windowWillClose 会取消识别、翻译和对话请求。
    static func closeAllForConsentRevocation() {
        let windows = liveWindows
        liveWindows.removeAll()
        for controller in windows {
            controller.window?.close()
        }
    }

    private final class EditableTextView: NSTextView {
        var onTextChange: (() -> Void)?

        override func didChangeText() {
            super.didChangeText()
            onTextChange?()
        }
    }

    private final class ModeState {
        var result: String?
        var previous: String?
        var isRecognizing = false
        var hasAttempted = false
        var recognitionError: String?
        var recognitionTask: AITask?
        var chat: [AIChatMessage] = []
        var chatStreaming = false
        var chatError: String?
        var chatTask: AITask?
        var edited = false
        var autoCopied = false
        var autoUnwrap = false
        var translation: TranslationState?
        var transientStatus: String?
    }

    private final class TranslationState {
        let baseText: String
        let baseEdited: Bool
        let sourceLines: [String]
        let source: TranslationLanguage
        let target: TranslationLanguage
        var translatedLines: [String] = []
        var renderedText: String
        var detected: TranslationLanguage?
        var task: AITask?
        var isTranslating = false
        var error: String?
        var notice: String?

        init(
            baseText: String,
            baseEdited: Bool,
            sourceLines: [String],
            source: TranslationLanguage,
            target: TranslationLanguage
        ) {
            self.baseText = baseText
            self.baseEdited = baseEdited
            self.sourceLines = sourceLines
            self.source = source
            self.target = target
            self.renderedText = baseText
        }
    }

    private let sourceImage: CGImage
    private let previewImage: NSImage
    private let savedImage: URL?
    private let anchorPoint: NSPoint
    private let openSettings: () -> Void

    private var states: [AIMode: ModeState] = [:]
    private var activeMode: AIMode
    private var translationSource: TranslationLanguage
    private var translationTarget: TranslationLanguage
    private var imageDataURL: String?
    private var imageEncoding = false
    private var imageEncodingFailed = false
    private var hasAutoCopied = false
    private var pendingAutoTranslate = false
    private var autoCopyTranslationPending = false
    private var autoCopyTranslationDone = false
    private var autoCopyOriginalDone = false
    private var chatExpanded = false
    private var previousExpanded = false
    private var collapsedWidth: CGFloat = 1040
    private var isUpdatingText = false
    private var didStart = false
    private var directionPopover: NSPopover?
    private var sourceLanguagePopup: NSPopUpButton?
    private var targetLanguagePopup: NSPopUpButton?

    private let imageBox = NSView()
    private let imageView = NSImageView()
    private let imageTitle = NSTextField(labelWithString: "原图")
    private let imageStatus = NSTextField(labelWithString: "")

    private let resultPane = NSView()
    private let modeControl = NSSegmentedControl(
        labels: ["文字提取", "内容理解"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let retryButton = NSButton(title: "重试", target: nil, action: nil)
    private let unwrapButton = NSButton(title: "智能合并换行", target: nil, action: nil)
    private let translateButton = NSButton(title: "翻译", target: nil, action: nil)
    private let directionButton = NSButton(title: "自动 → 简体中文", target: nil, action: nil)
    private let swapButton = NSButton(title: "⇄", target: nil, action: nil)
    private let chatButton = NSButton(title: "与小U对话", target: nil, action: nil)
    private let resultScroll = NSScrollView()
    private let resultTextView = EditableTextView()
    private let emptyHint = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let openSettingsButton = NSButton(title: "打开 AI 设置", target: nil, action: nil)
    private let previousButton = NSButton(title: "上一版（只读）", target: nil, action: nil)
    private let previousScroll = NSScrollView()
    private let previousTextView = NSTextView()
    private let copyButton = NSButton(title: "复制", target: nil, action: nil)
    private let copyCloseButton = NSButton(title: "复制并关闭", target: nil, action: nil)

    private let chatPane = NSView()
    private let chatTitle = NSTextField(labelWithString: "小U")
    private let chatSubtitle = NSTextField(labelWithString: "AI 助手")
    private let chatScroll = NSScrollView()
    private let chatTextView = NSTextView()
    private let quickStack = NSStackView()
    private let chatField = NSTextField()
    private let sendButton = NSButton(title: "发送", target: nil, action: nil)
    private let stopButton = NSButton(title: "停止", target: nil, action: nil)
    private let chatStatusLabel = NSTextField(labelWithString: "")

    nonisolated(unsafe) private var stateObserver: NSObjectProtocol?

    static func present(
        image: CGImage,
        preview: NSImage,
        savedImage: URL?,
        at point: NSPoint,
        autoTranslate: Bool = false,
        openSettings: @escaping () -> Void
    ) {
        let controller = AIResultWindowController(
            image: image,
            preview: preview,
            savedImage: savedImage,
            at: point,
            autoTranslate: autoTranslate,
            openSettings: openSettings
        )
        liveWindows.append(controller)
        controller.window?.orderFrontRegardless()
        controller.begin()
    }

    private init(
        image: CGImage,
        preview: NSImage,
        savedImage: URL?,
        at point: NSPoint,
        autoTranslate: Bool,
        openSettings: @escaping () -> Void
    ) {
        self.sourceImage = image
        self.previewImage = preview
        self.savedImage = savedImage
        self.anchorPoint = point
        self.openSettings = openSettings
        let config = AppEnvironment.shared.aiConfig.settings
        var source = config.translationSource
        var target = config.translationTarget
        if target == .auto { target = .simplifiedChinese }
        if source != .auto && source == target { source = .auto }
        self.translationSource = source
        self.translationTarget = target
        self.activeMode = autoTranslate ? .extract : config.mode
        self.pendingAutoTranslate = autoTranslate
        self.autoCopyTranslationPending = autoTranslate
        states[.extract] = ModeState()
        states[.understand] = ModeState()
        states[.extract]?.autoUnwrap = autoTranslate

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "小U · AI 识别"
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 900, height: 560)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = true

        super.init(window: panel)
        panel.delegate = self
        buildUI()
        positionWindow()
        layoutContent()

        stateObserver = NotificationCenter.default.addObserver(
            forName: AIConfigStore.didChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let mode = AppEnvironment.shared.aiConfig.settings.mode
                if mode != self.activeMode {
                    self.switchMode(to: mode, persist: false)
                }
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let stateObserver {
            NotificationCenter.default.removeObserver(stateObserver)
        }
    }

    private var modeState: ModeState {
        states[activeMode] ?? ModeState()
    }

    // MARK: - 构建界面

    private func buildUI() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        // 左侧原图
        imageBox.wantsLayer = true
        imageBox.layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor
        imageBox.layer?.cornerRadius = 8
        content.addSubview(imageBox)

        imageTitle.font = .systemFont(ofSize: 12, weight: .semibold)
        imageTitle.textColor = .secondaryLabelColor
        imageBox.addSubview(imageTitle)

        imageView.image = previewImage
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.02).cgColor
        imageBox.addSubview(imageView)

        imageStatus.font = .systemFont(ofSize: 10.5)
        imageStatus.textColor = .secondaryLabelColor
        imageStatus.stringValue = savedImage == nil ? "原图保存失败" : "原图已保存"
        if savedImage == nil { imageStatus.textColor = .systemRed }
        imageBox.addSubview(imageStatus)

        // 右侧结果
        content.addSubview(resultPane)
        resultPane.wantsLayer = true

        modeControl.target = self
        modeControl.action = #selector(modeChanged(_:))
        modeControl.selectedSegment = activeMode.segmentIndex
        modeControl.segmentStyle = .rounded
        resultPane.addSubview(modeControl)

        retryButton.target = self
        retryButton.action = #selector(retry)
        retryButton.bezelStyle = .rounded
        resultPane.addSubview(retryButton)

        unwrapButton.target = self
        unwrapButton.action = #selector(toggleAutoUnwrap)
        unwrapButton.setButtonType(.toggle)
        unwrapButton.bezelStyle = .rounded
        unwrapButton.font = .systemFont(ofSize: 11)
        unwrapButton.toolTip = "合并排版产生的自动换行，保留段落换行；再次点击恢复逐行输出"
        resultPane.addSubview(unwrapButton)

        translateButton.target = self
        translateButton.action = #selector(toggleTranslation)
        translateButton.bezelStyle = .rounded
        translateButton.font = .systemFont(ofSize: 12)
        translateButton.toolTip = "把当前结果逐行翻译，一段原文、一段译文交错显示"
        resultPane.addSubview(translateButton)

        directionButton.target = self
        directionButton.action = #selector(showDirectionPicker)
        directionButton.bezelStyle = .rounded
        directionButton.font = .systemFont(ofSize: 11)
        directionButton.toolTip = "选择源语言和目标语言"
        resultPane.addSubview(directionButton)

        swapButton.target = self
        swapButton.action = #selector(swapTranslationDirection)
        swapButton.bezelStyle = .rounded
        swapButton.font = .systemFont(ofSize: 15, weight: .medium)
        swapButton.toolTip = "交换源语言和目标语言"
        resultPane.addSubview(swapButton)

        chatButton.target = self
        chatButton.action = #selector(toggleChat)
        chatButton.bezelStyle = .rounded
        resultPane.addSubview(chatButton)

        configureScroll(resultScroll, textView: resultTextView, editable: true)
        resultTextView.onTextChange = { [weak self] in self?.resultTextDidChange() }
        resultTextView.font = .systemFont(ofSize: 13)
        resultTextView.textContainerInset = NSSize(width: 12, height: 12)
        resultPane.addSubview(resultScroll)

        emptyHint.font = .systemFont(ofSize: 13)
        emptyHint.textColor = .secondaryLabelColor
        emptyHint.alignment = .center
        emptyHint.lineBreakMode = .byWordWrapping
        emptyHint.maximumNumberOfLines = 4
        resultPane.addSubview(emptyHint)

        statusLabel.font = .systemFont(ofSize: 10.5)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        resultPane.addSubview(statusLabel)

        openSettingsButton.target = self
        openSettingsButton.action = #selector(openAISettings)
        openSettingsButton.bezelStyle = .rounded
        openSettingsButton.font = .systemFont(ofSize: 11)
        resultPane.addSubview(openSettingsButton)

        previousButton.target = self
        previousButton.action = #selector(togglePrevious)
        previousButton.isBordered = false
        previousButton.alignment = .left
        previousButton.font = .systemFont(ofSize: 11)
        previousButton.contentTintColor = .secondaryLabelColor
        resultPane.addSubview(previousButton)

        configureScroll(previousScroll, textView: previousTextView, editable: false)
        previousTextView.font = .systemFont(ofSize: 12)
        previousTextView.textColor = .secondaryLabelColor
        previousTextView.textContainerInset = NSSize(width: 10, height: 8)
        resultPane.addSubview(previousScroll)

        copyButton.target = self
        copyButton.action = #selector(copyOnly)
        copyButton.bezelStyle = .rounded
        resultPane.addSubview(copyButton)

        copyCloseButton.target = self
        copyCloseButton.action = #selector(copyAndClose)
        copyCloseButton.bezelStyle = .rounded
        resultPane.addSubview(copyCloseButton)

        // 右侧对话
        content.addSubview(chatPane)
        chatPane.wantsLayer = true
        chatPane.isHidden = true

        chatTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        chatPane.addSubview(chatTitle)
        chatSubtitle.font = .systemFont(ofSize: 10.5)
        chatSubtitle.textColor = .secondaryLabelColor
        chatPane.addSubview(chatSubtitle)

        configureScroll(chatScroll, textView: chatTextView, editable: false)
        chatTextView.font = .systemFont(ofSize: 12)
        chatTextView.textContainerInset = NSSize(width: 10, height: 10)
        chatPane.addSubview(chatScroll)

        quickStack.orientation = .vertical
        quickStack.alignment = .leading
        quickStack.distribution = .fillEqually
        quickStack.spacing = 4
        quickStack.addArrangedSubview(makeQuickButton(title: "总结这张图", action: #selector(quickSummarize)))
        quickStack.addArrangedSubview(makeQuickButton(title: "提取关键信息", action: #selector(quickExtract)))
        quickStack.addArrangedSubview(makeQuickButton(title: "翻译图中文字", action: #selector(quickTranslate)))
        chatPane.addSubview(quickStack)

        chatField.placeholderString = "问问小U这张图的事…"
        chatField.font = .systemFont(ofSize: 12)
        chatField.target = self
        chatField.action = #selector(sendChatAction)
        chatPane.addSubview(chatField)

        sendButton.target = self
        sendButton.action = #selector(sendChatAction)
        sendButton.bezelStyle = .rounded
        chatPane.addSubview(sendButton)

        stopButton.target = self
        stopButton.action = #selector(stopChat)
        stopButton.bezelStyle = .rounded
        stopButton.isHidden = true
        chatPane.addSubview(stopButton)

        chatStatusLabel.font = .systemFont(ofSize: 10)
        chatStatusLabel.textColor = .secondaryLabelColor
        chatStatusLabel.lineBreakMode = .byTruncatingTail
        chatPane.addSubview(chatStatusLabel)

        layoutResultPane()
        layoutChatPane()
    }

    private func makeQuickButton(title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.isBordered = false
        button.alignment = .left
        button.font = .systemFont(ofSize: 11)
        button.contentTintColor = .linkColor
        return button
    }

    private func configureScroll(_ scroll: NSScrollView, textView: NSTextView, editable: Bool) {
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor

        textView.isEditable = editable
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textColor = .textColor
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        scroll.documentView = textView
        resizeDocumentView(scroll, textView)
    }

    private func resizeDocumentView(_ scroll: NSScrollView, _ textView: NSTextView) {
        let contentSize = scroll.contentSize
        guard contentSize.width > 0 else { return }
        textView.frame = NSRect(
            x: 0,
            y: 0,
            width: contentSize.width,
            height: max(contentSize.height, 1)
        )
        textView.textContainer?.containerSize = NSSize(
            width: contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
    }

    private func positionWindow() {
        guard let window else { return }
        let visible =
            (NSScreen.screens.first { $0.frame.contains(anchorPoint) } ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(
            width: min(window.frame.width, max(900, visible.width - 32)),
            height: min(window.frame.height, max(560, visible.height - 32))
        )
        let offset = CGFloat(Self.liveWindows.count) * 22
        var origin = NSPoint(
            x: visible.midX - size.width / 2 + offset,
            y: visible.midY - size.height / 2 - offset
        )
        origin.x = min(max(origin.x, visible.minX + 8), max(visible.minX + 8, visible.maxX - size.width - 8))
        origin.y = min(max(origin.y, visible.minY + 8), max(visible.minY + 8, visible.maxY - size.height - 8))
        window.setFrame(NSRect(origin: origin, size: size), display: false)
        collapsedWidth = size.width
    }

    private func layoutContent() {
        guard let content = window?.contentView else { return }
        let width = content.bounds.width
        let height = content.bounds.height
        let margin: CGFloat = 16
        let gap: CGFloat = 14
        let imageWidth = min(380, max(300, width * 0.37))
        let chatWidth: CGFloat = chatExpanded ? 340 : 0

        imageBox.frame = NSRect(x: margin, y: margin, width: imageWidth, height: height - margin * 2)
        let resultX = margin + imageWidth + gap
        let resultWidth = width - resultX - margin - (chatExpanded ? chatWidth + gap : 0)
        resultPane.frame = NSRect(x: resultX, y: margin, width: max(200, resultWidth), height: height - margin * 2)
        chatPane.frame = NSRect(
            x: width - margin - chatWidth,
            y: margin,
            width: chatWidth,
            height: height - margin * 2
        )
        chatPane.isHidden = !chatExpanded

        layoutImagePane()
        layoutResultPane()
        layoutChatPane()
    }

    private func layoutImagePane() {
        let width = imageBox.bounds.width
        let height = imageBox.bounds.height
        imageTitle.frame = NSRect(x: 12, y: height - 24, width: width - 24, height: 16)
        imageView.frame = NSRect(x: 0, y: 28, width: width, height: max(0, height - 58))
        imageStatus.frame = NSRect(x: 12, y: 8, width: width - 24, height: 16)
    }

    private func layoutResultPane() {
        let width = resultPane.bounds.width
        let height = resultPane.bounds.height
        let state = modeState
        let hasResult = state.result != nil
        let hasText = !(state.result ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let isTranslating = state.translation?.isTranslating == true
        let showTranslationRow = activeMode == .extract
        let copyEnabled = hasText
        let hasPrevious = !(state.previous ?? "").isEmpty
        let previousVisible = hasPrevious && previousExpanded
        let editorBottom: CGFloat = previousVisible ? 206 : (hasPrevious ? 92 : 68)

        modeControl.frame = NSRect(x: 0, y: height - 38, width: 150, height: 28)
        retryButton.frame = NSRect(x: 158, y: height - 36, width: 86, height: 26)
        chatButton.frame = NSRect(x: max(0, width - 104), y: height - 36, width: 104, height: 26)

        unwrapButton.frame = NSRect(x: 0, y: height - 70, width: 110, height: 26)
        translateButton.frame = NSRect(x: 116, y: height - 70, width: 78, height: 26)
        directionButton.frame = NSRect(x: 200, y: height - 70, width: 132, height: 26)
        swapButton.frame = NSRect(x: 338, y: height - 70, width: 28, height: 26)

        let editorTop = height - (showTranslationRow ? 80 : 48)
        resultScroll.frame = NSRect(
            x: 0,
            y: editorBottom,
            width: width,
            height: max(0, editorTop - editorBottom)
        )
        if hasResult {
            resultScroll.isHidden = false
            emptyHint.isHidden = true
        } else {
            resultScroll.isHidden = true
            emptyHint.isHidden = false
            emptyHint.frame = NSRect(
                x: 20, y: editorBottom, width: max(0, width - 40), height: max(0, editorTop - editorBottom))
        }

        let settingsVisible = openSettingsButtonVisible()
        openSettingsButton.isHidden = !settingsVisible
        statusLabel.frame = NSRect(
            x: 0,
            y: 42,
            width: max(0, width - (settingsVisible ? 124 : 0)),
            height: 20
        )
        openSettingsButton.frame = NSRect(x: max(0, width - 114), y: 36, width: 114, height: 26)

        previousButton.isHidden = !hasPrevious
        previousButton.frame = NSRect(x: 0, y: 66, width: width, height: 20)
        previousButton.title = previousExpanded ? "▾ 上一版（只读）" : "▸ 上一版（只读）"
        previousScroll.isHidden = !previousVisible
        previousScroll.frame = NSRect(x: 0, y: 90, width: width, height: 108)

        copyButton.frame = NSRect(x: max(0, width - 204), y: 8, width: 78, height: 30)
        copyCloseButton.frame = NSRect(x: max(0, width - 118), y: 8, width: 110, height: 30)

        copyButton.isEnabled = copyEnabled
        copyCloseButton.isEnabled = copyEnabled
        retryButton.isEnabled = !state.isRecognizing && !isTranslating
        retryButton.title = state.isRecognizing ? "识别中" : (hasResult ? "重新识别" : "重试")
        modeControl.isEnabled = !state.isRecognizing && !isTranslating

        unwrapButton.isHidden = !showTranslationRow
        unwrapButton.state = state.autoUnwrap ? .on : .off
        unwrapButton.isEnabled = hasResult && !state.isRecognizing && !isTranslating
        translateButton.isHidden = !showTranslationRow
        translateButton.title = translationButtonTitle(for: state.translation)
        translateButton.isEnabled = (hasText || state.translation != nil) && !state.isRecognizing
        directionButton.isHidden = !showTranslationRow
        directionButton.title = "\(translationSource.compactName) → \(translationTarget.displayName)"
        directionButton.isEnabled = hasText && !state.isRecognizing && !isTranslating
        swapButton.isHidden = !showTranslationRow
        swapButton.isEnabled = hasText && !state.isRecognizing && !isTranslating
        chatButton.title = chatExpanded ? "收起对话" : "与小U对话"

        resizeDocumentView(resultScroll, resultTextView)
        resizeDocumentView(previousScroll, previousTextView)
    }

    private func translationButtonTitle(for translation: TranslationState?) -> String {
        guard let translation else { return "翻译" }
        if translation.isTranslating { return "取消翻译" }
        if translation.error != nil { return "重试翻译" }
        if !translation.translatedLines.isEmpty { return "恢复原文" }
        return "翻译"
    }

    private func layoutChatPane() {
        guard chatExpanded else { return }
        let width = chatPane.bounds.width
        let height = chatPane.bounds.height
        let quickVisible = !quickStack.isHidden

        chatTitle.frame = NSRect(x: 0, y: height - 28, width: 60, height: 18)
        chatSubtitle.frame = NSRect(x: 58, y: height - 26, width: width - 58, height: 16)
        let transcriptTop = height - 38
        let transcriptBottom: CGFloat = quickVisible ? 154 : 58
        chatScroll.frame = NSRect(
            x: 0, y: transcriptBottom, width: width, height: max(0, transcriptTop - transcriptBottom))
        quickStack.frame = NSRect(x: 0, y: 64, width: width, height: 82)
        chatField.frame = NSRect(x: 0, y: 14, width: max(0, width - 76), height: 30)
        sendButton.frame = NSRect(x: max(0, width - 68), y: 12, width: 64, height: 30)
        stopButton.frame = NSRect(x: max(0, width - 68), y: 12, width: 64, height: 30)
        chatStatusLabel.frame = NSRect(x: 0, y: 44, width: width, height: 16)
        resizeDocumentView(chatScroll, chatTextView)
    }

    // MARK: - 初始与识别

    private func begin() {
        guard !didStart else { return }
        didStart = true

        let state = modeState
        if let blocker = blockerMessage() {
            state.recognitionError = blocker
            state.hasAttempted = true
            updateUI()
        } else {
            updateUI()
        }
        prepareImageData()
    }

    private func prepareImageData() {
        guard imageDataURL == nil, !imageEncoding, !imageEncodingFailed else { return }
        imageEncoding = true
        updateUI()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let dataURL = self.map { AIImageEncoder.screenshotDataURL($0.sourceImage) } ?? nil
            DispatchQueue.main.async {
                guard let self else { return }
                self.imageEncoding = false
                if let dataURL {
                    self.imageDataURL = dataURL
                } else {
                    self.imageEncodingFailed = true
                    let state = self.modeState
                    if state.recognitionError == nil {
                        state.recognitionError = "截图编码失败，请重新截图。"
                    }
                }
                self.updateUI()
                self.maybeStartInitial()
            }
        }
    }

    private func maybeStartInitial() {
        let state = modeState
        guard state.result == nil, !state.isRecognizing, !state.hasAttempted else { return }
        guard imageDataURL != nil else {
            if imageEncodingFailed {
                state.recognitionError = "截图编码失败，请重新截图。"
                state.hasAttempted = true
                updateUI()
            }
            return
        }
        if let blocker = blockerMessage() {
            state.recognitionError = blocker
            state.hasAttempted = true
            updateUI()
            return
        }
        startRecognition(for: activeMode)
    }

    private func startRecognition(for mode: AIMode, previousOverride: String? = nil) {
        guard let imageDataURL else { return }
        guard let state = states[mode] else { return }
        if let blocker = blockerMessage() {
            state.recognitionError = blocker
            state.hasAttempted = true
            if mode == activeMode { updateUI() }
            return
        }

        state.recognitionTask?.cancel()
        state.translation?.task?.cancel()
        state.translation = nil
        state.transientStatus = nil
        state.hasAttempted = true
        state.isRecognizing = true
        state.recognitionError = nil

        let oldResult = previousOverride ?? state.result
        let settings = AppEnvironment.shared.aiConfig.settings
        let apiKey = settings.authEnabled ? KeychainStore.read() : nil

        guard
            AppEnvironment.shared.aiConsent.ensure(
                for: settings,
                dataTypes: ["当前截图", "系统提示词 / 识别模式"],
                parentWindow: window
            )
        else {
            state.isRecognizing = false
            state.recognitionError = "已取消向 AI 接口发送数据。"
            if mode == activeMode { updateUI() }
            return
        }

        if mode == activeMode { updateUI() }

        var task: AITask?
        task = AIClient.recognize(
            imageDataURL: imageDataURL,
            mode: mode,
            settings: settings,
            apiKey: apiKey,
            paragraphMode: mode == .extract && state.autoUnwrap
        ) { [weak self] result in
            guard let self, !(task?.isCancelled ?? true) else { return }
            guard let state = self.states[mode] else { return }
            state.recognitionTask = nil
            state.isRecognizing = false
            switch result {
            case .success(let text):
                if let oldResult, !oldResult.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    state.previous = oldResult
                }
                state.result = text
                state.edited = false
                state.recognitionError = nil
                state.autoCopied = false
                state.transientStatus = nil
                if mode == self.activeMode { self.updateUI() }
                if self.pendingAutoTranslate && mode == .extract && self.activeMode == .extract {
                    self.pendingAutoTranslate = false
                    self.startTranslation()
                } else {
                    self.autoCopyIfNeeded(text, state: state)
                }
                return
            case .failure(let error):
                state.recognitionError = error.localizedDescription
                state.transientStatus = nil
            }
            if mode == self.activeMode { self.updateUI() }
        }
        state.recognitionTask = task
    }

    private func autoCopyIfNeeded(_ text: String, state: ModeState) {
        guard !hasAutoCopied else { return }
        guard ScreenshotStorage.copyText(text) else { return }
        hasAutoCopied = true
        state.autoCopied = true
    }

    private func blockerMessage() -> String? {
        if !AppEnvironment.shared.compliance.isAccepted {
            return "请先完成首次隐私同意。"
        }
        let settings = AppEnvironment.shared.aiConfig.settings
        let key = settings.authEnabled ? KeychainStore.read() : nil
        if !settings.isConfigured(apiKey: key) {
            return "未读到 AI 配置。请在「偏好设置 → AI 设置」填写接口地址和模型；API Key 点「查看」授权一次（系统弹窗选「始终允许」，之后当前构建内 AI 不再弹密码）。"
        }
        return nil
    }

    private func openSettingsButtonVisible() -> Bool {
        blockerMessage() != nil
            || !(modeState.recognitionError ?? "").isEmpty
            || !(modeState.translation?.error ?? "").isEmpty
    }

    // MARK: - 状态刷新

    private func updateUI() {
        guard window != nil else { return }
        modeControl.selectedSegment = activeMode.segmentIndex
        let state = modeState
        let hasResult = state.result != nil
        let isTranslating = state.translation?.isTranslating == true

        if hasResult {
            if resultTextView.string != (state.result ?? "") {
                setResultText(state.result ?? "")
            }
            resultTextView.isEditable = !state.isRecognizing && !isTranslating
        } else {
            setResultText("")
            resultTextView.isEditable = false
            emptyHint.stringValue = emptyHintText(for: state)
        }

        if state.isRecognizing {
            let message: String
            if hasResult {
                message = state.autoUnwrap ? "正在重新识别（智能合并换行）…" : "正在重新识别…"
            } else {
                message = "小U 正在识别…"
            }
            statusLabel.stringValue = message
            statusLabel.textColor = .secondaryLabelColor
        } else if isTranslating, let translation = state.translation {
            statusLabel.stringValue = "正在翻译为\(translation.target.displayName)…"
            statusLabel.textColor = .secondaryLabelColor
        } else if let error = state.recognitionError, !error.isEmpty {
            statusLabel.stringValue = error
            statusLabel.textColor = .systemRed
        } else if let translation = state.translation, let error = translation.error, !error.isEmpty {
            let suffix = translation.notice.map { " · \($0)" } ?? ""
            statusLabel.stringValue = error + suffix
            statusLabel.textColor = .systemRed
        } else if let notice = state.transientStatus, !notice.isEmpty {
            statusLabel.stringValue = notice
            statusLabel.textColor = .secondaryLabelColor
        } else if hasResult {
            statusLabel.stringValue = resultStatusText(for: state)
            statusLabel.textColor = .secondaryLabelColor
        } else {
            statusLabel.stringValue = imageEncoding ? "正在准备截图…" : ""
            statusLabel.textColor = .secondaryLabelColor
        }

        if let previous = state.previous, !previous.isEmpty {
            previousTextView.string = previous
        } else {
            previousTextView.string = ""
            previousExpanded = false
        }

        previousButton.isHidden = (state.previous ?? "").isEmpty
        previousScroll.isHidden = previousButton.isHidden || !previousExpanded
        retryButton.isEnabled = !state.isRecognizing && !isTranslating
        retryButton.title = state.isRecognizing ? "识别中" : (hasResult ? "重新识别" : "重试")
        copyButton.isEnabled = !(state.result ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        copyCloseButton.isEnabled = !(state.result ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        emptyHint.isHidden = hasResult
        resultScroll.isHidden = !hasResult

        chatButton.title = chatExpanded ? "收起对话" : "与小U对话"
        layoutResultPane()
        layoutChatPane()
        updateChatUI()
    }

    private func emptyHintText(for state: ModeState) -> String {
        if state.isRecognizing {
            return "小U 正在识别…"
        }
        if let error = state.recognitionError, !error.isEmpty {
            return error
        }
        if imageEncoding {
            return "正在准备截图…"
        }
        if !AppEnvironment.shared.compliance.isAccepted {
            return "请先完成首次隐私同意。"
        }
        let settings = AppEnvironment.shared.aiConfig.settings
        let key = settings.authEnabled ? KeychainStore.read() : nil
        if !settings.isConfigured(apiKey: key) {
            return "未读到 AI 配置。\n请在「偏好设置 → AI 设置」填写接口地址和模型；API Key 点「查看」授权一次（系统弹窗选「始终允许」，之后当前构建内 AI 不再弹密码）。"
        }
        return "等待识别…"
    }

    private func resultStatusText(for state: ModeState) -> String {
        let text = state.result ?? ""
        let lines = text.isEmpty ? 0 : text.components(separatedBy: "\n").count
        var value = "\(text.count) 字 · \(lines) 行"
        if let translation = state.translation, !translation.translatedLines.isEmpty {
            value += " · \(translation.sourceLines.count) 组译文"
        }
        if state.autoUnwrap { value += " · 智能合并换行" }
        if state.edited { value += " · 已修改，复制后更新剪贴板" }
        if state.autoCopied && !state.edited && !state.isRecognizing { value += " · 首次结果已自动复制" }
        return value
    }

    private func setResultText(_ text: String) {
        isUpdatingText = true
        resultTextView.string = text
        isUpdatingText = false
    }

    // MARK: - 模式切换

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        let mode = AIMode.from(segment: sender.selectedSegment)
        switchMode(to: mode, persist: true)
    }

    private func switchMode(to mode: AIMode, persist: Bool) {
        guard mode != activeMode else { return }
        commitEditor()
        closeDirectionPicker()
        activeMode = mode
        previousExpanded = false
        if persist {
            AppEnvironment.shared.aiConfig.setMode(mode)
        }
        updateUI()
        maybeStartInitial()
    }

    // MARK: - 编辑与复制

    private func resultTextDidChange() {
        guard !isUpdatingText else { return }
        let state = modeState
        guard resultTextView.string != (state.result ?? "") else { return }
        state.result = resultTextView.string
        state.edited = true
        state.transientStatus = nil
        updateUI()
    }

    private func commitEditor() {
        guard resultTextView.isEditable else { return }
        let state = modeState
        if let result = state.result, resultTextView.string != result {
            state.result = resultTextView.string
            state.edited = true
        }
    }

    @objc private func copyOnly() { copyCurrent(closeAfter: false) }

    @objc private func copyAndClose() { copyCurrent(closeAfter: true) }

    private func copyCurrent(closeAfter: Bool) {
        commitEditor()
        modeState.transientStatus = nil
        let text = modeState.result ?? ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            statusLabel.stringValue = "没有可复制的文字。"
            statusLabel.textColor = .systemRed
            return
        }
        guard ScreenshotStorage.copyText(text) else {
            statusLabel.stringValue = "复制失败，请手动选择文字后复制。"
            statusLabel.textColor = .systemRed
            return
        }
        statusLabel.stringValue = "已复制 \(text.count) 字。"
        statusLabel.textColor = .secondaryLabelColor
        HUDController.shared.show(
            title: "已复制",
            detail: "AI 识别・\(text.count) 字",
            at: NSEvent.mouseLocation,
            success: true
        )
        if closeAfter { window?.close() }
    }

    @objc private func retry() {
        commitEditor()
        let state = modeState
        guard !state.isRecognizing, !(state.translation?.isTranslating ?? false) else { return }
        if imageDataURL == nil {
            if imageEncodingFailed {
                state.recognitionError = "截图编码失败，请重新截图。"
                updateUI()
                return
            }
            prepareImageData()
            return
        }
        guard let rollback = rollbackTranslationForRecognition(action: "重新识别") else { return }
        startRecognition(for: activeMode, previousOverride: rollback.previous)
    }

    @objc private func toggleAutoUnwrap() {
        guard activeMode == .extract else { return }
        let state = modeState
        guard !state.isRecognizing, !(state.translation?.isTranslating ?? false) else { return }
        commitEditor()
        guard let rollback = rollbackTranslationForRecognition(action: "重新识别") else { return }
        state.autoUnwrap.toggle()
        if state.result == nil || state.result?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            updateUI()
            return
        }
        startRecognition(for: activeMode, previousOverride: rollback.previous)
    }

    private func rollbackTranslationForRecognition(action: String) -> (previous: String?, rolledBack: Bool)? {
        commitEditor()
        let state = modeState
        guard let translation = state.translation else { return (nil, false) }
        guard !translation.isTranslating else { return nil }

        let previous = state.result ?? translation.renderedText
        if (state.result ?? "") != translation.renderedText,
            !confirmDiscardTranslation(action: action, keepsPrevious: true)
        {
            return nil
        }

        translation.task?.cancel()
        state.translation = nil
        state.result = translation.baseText
        state.edited = translation.baseEdited
        state.transientStatus = nil
        setResultText(translation.baseText)
        return (previous, true)
    }

    private func confirmDiscardTranslation(action: String, keepsPrevious: Bool) -> Bool {
        guard modeState.translation != nil else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(action)会丢弃当前译文和修改"
        alert.informativeText =
            keepsPrevious
            ? "当前交错文本会进入「上一版」；翻译前的原文会恢复并用于重新识别。"
            : "当前交错文本和手动修改会被清除；翻译前的原文会恢复。"
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: action)
        return alert.runModal() == .alertSecondButtonReturn
    }

    @objc private func toggleTranslation() {
        guard activeMode == .extract else { return }
        let state = modeState
        guard !state.isRecognizing else { return }
        if let translation = state.translation, translation.isTranslating {
            cancelTranslation()
            return
        }
        if let translation = state.translation, !translation.translatedLines.isEmpty {
            restoreOriginal()
            return
        }
        startTranslation()
    }

    private func startTranslation() {
        guard activeMode == .extract, let imageDataURL else { return }
        let state = modeState
        guard !state.isRecognizing, !(state.translation?.isTranslating ?? false) else { return }
        commitEditor()

        let base = state.result ?? ""
        guard !base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            updateUI()
            return
        }
        let baseEdited = state.edited
        let sourceLines =
            base
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let translation = TranslationState(
            baseText: base,
            baseEdited: baseEdited,
            sourceLines: sourceLines,
            source: translationSource,
            target: translationTarget
        )
        state.translation?.task?.cancel()
        state.translation = translation
        state.result = base
        state.transientStatus = nil

        guard !sourceLines.isEmpty else {
            translation.error = "没有可翻译的文字。"
            handleAutomaticTranslationFailure(translation, state: state)
            updateUI()
            return
        }
        if let blocker = blockerMessage() {
            translation.error = blocker
            handleAutomaticTranslationFailure(translation, state: state)
            updateUI()
            return
        }

        let settings = AppEnvironment.shared.aiConfig.settings
        let apiKey = settings.authEnabled ? KeychainStore.read() : nil
        guard
            AppEnvironment.shared.aiConsent.ensure(
                for: settings,
                dataTypes: ["当前截图", "OCR 提取文字", "翻译提示词 / 语言方向"],
                parentWindow: window
            )
        else {
            translation.error = "已取消向 AI 接口发送数据。"
            handleAutomaticTranslationFailure(translation, state: state)
            updateUI()
            return
        }
        translation.isTranslating = true
        updateUI()

        var task: AITask?
        task = AIClient.translate(
            imageDataURL: imageDataURL,
            lines: sourceLines,
            source: translationSource,
            target: translationTarget,
            settings: settings,
            apiKey: apiKey
        ) { [weak self] result in
            guard let self, !(task?.isCancelled ?? true) else { return }
            guard let state = self.states[.extract],
                let current = state.translation,
                current.task === task
            else { return }
            current.task = nil
            current.isTranslating = false

            switch result {
            case .success(.translated(let translatedLines, let detected)):
                current.translatedLines = translatedLines
                current.detected = detected
                current.error = nil
                current.notice = nil
                let rendered = self.renderTranslation(
                    originals: current.sourceLines,
                    translations: translatedLines
                )
                current.renderedText = rendered
                state.result = rendered
                state.edited = false
                state.transientStatus = nil
                self.setResultText(rendered)
                self.autoCopyTranslationIfNeeded(rendered, state: state)
                self.updateUI()

            case .success(.sameLanguage(let detected)):
                current.detected = detected
                current.translatedLines = []
                current.renderedText = current.baseText
                current.error = nil
                current.notice = nil
                let target = current.target
                state.result = current.baseText
                state.edited = current.baseEdited
                state.transientStatus = nil
                self.setResultText(current.baseText)
                let baseNotice = "原文已是\(target.displayName)"
                if self.autoCopyTranslationPending && !self.autoCopyOriginalDone {
                    self.autoCopyOriginalDone = true
                    self.hasAutoCopied = true
                    if ScreenshotStorage.copyText(current.baseText) {
                        state.autoCopied = true
                        state.transientStatus = baseNotice + "，已复制原文"
                    } else {
                        state.transientStatus = baseNotice + "，复制原文失败"
                    }
                } else {
                    state.transientStatus = baseNotice
                }
                self.updateUI()

            case .failure(let error):
                current.error = error.localizedDescription
                current.notice = nil
                state.result = current.baseText
                state.edited = current.baseEdited
                self.setResultText(current.baseText)
                self.handleAutomaticTranslationFailure(current, state: state)
                self.updateUI()
            }
        }
        translation.task = task
    }

    private func renderTranslation(originals: [String], translations: [String]) -> String {
        var lines: [String] = []
        lines.reserveCapacity(originals.count * 2)
        for (index, original) in originals.enumerated() where index < translations.count {
            lines.append(original)
            lines.append(translations[index])
        }
        return lines.joined(separator: "\n")
    }

    private func autoCopyTranslationIfNeeded(_ text: String, state: ModeState) {
        guard autoCopyTranslationPending, !autoCopyTranslationDone else { return }
        autoCopyTranslationDone = true
        autoCopyTranslationPending = false
        hasAutoCopied = true
        guard ScreenshotStorage.copyText(text) else {
            state.transientStatus = "翻译完成，复制失败"
            return
        }
        state.autoCopied = true
        state.transientStatus = nil
    }

    private func handleAutomaticTranslationFailure(_ translation: TranslationState, state: ModeState) {
        guard autoCopyTranslationPending, !autoCopyOriginalDone else { return }
        guard !translation.baseText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        autoCopyOriginalDone = true
        hasAutoCopied = true
        if ScreenshotStorage.copyText(translation.baseText) {
            state.autoCopied = true
            translation.notice = "已复制原文"
        } else {
            translation.notice = "复制原文失败"
        }
    }

    private func cancelTranslation() {
        let state = modeState
        guard let translation = state.translation, translation.isTranslating else { return }
        translation.task?.cancel()
        state.translation = nil
        state.result = translation.baseText
        state.edited = translation.baseEdited
        setResultText(translation.baseText)

        var notice = "已取消翻译"
        if autoCopyTranslationPending && !autoCopyOriginalDone {
            autoCopyOriginalDone = true
            hasAutoCopied = true
            if ScreenshotStorage.copyText(translation.baseText) {
                state.autoCopied = true
                notice += "，已复制原文"
            } else {
                notice += "，复制原文失败"
            }
        }
        autoCopyTranslationPending = false
        state.transientStatus = notice
        updateUI()
    }

    private func restoreOriginal() {
        let state = modeState
        guard let translation = state.translation,
            !translation.isTranslating,
            !translation.translatedLines.isEmpty
        else { return }
        commitEditor()
        if (state.result ?? "") != translation.renderedText,
            !confirmDiscardTranslation(action: "恢复原文", keepsPrevious: false)
        {
            return
        }

        translation.task?.cancel()
        state.result = translation.baseText
        state.edited = translation.baseEdited
        state.translation = nil
        state.transientStatus = "已恢复原文"
        setResultText(translation.baseText)
        updateUI()
    }

    @objc private func showDirectionPicker() {
        guard activeMode == .extract else { return }
        let state = modeState
        guard !state.isRecognizing, !(state.translation?.isTranslating ?? false) else { return }
        guard !(state.result ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let popover = directionPopover, popover.isShown {
            closeDirectionPicker()
            return
        }

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 112))
        let sourceLabel = NSTextField(labelWithString: "源语言")
        sourceLabel.font = .systemFont(ofSize: 11)
        sourceLabel.frame = NSRect(x: 12, y: 78, width: 52, height: 16)
        content.addSubview(sourceLabel)

        let targetLabel = NSTextField(labelWithString: "目标语言")
        targetLabel.font = .systemFont(ofSize: 11)
        targetLabel.frame = NSRect(x: 12, y: 42, width: 52, height: 16)
        content.addSubview(targetLabel)

        let sourcePopup = NSPopUpButton(frame: NSRect(x: 68, y: 72, width: 180, height: 26), pullsDown: false)
        sourcePopup.controlSize = .small
        sourcePopup.target = self
        sourcePopup.action = #selector(sourceLanguageChanged(_:))
        populateLanguagePopup(
            sourcePopup,
            options: TranslationLanguage.sources,
            selected: translationSource,
            disabled: translationTarget
        )
        content.addSubview(sourcePopup)

        let targetPopup = NSPopUpButton(frame: NSRect(x: 68, y: 36, width: 180, height: 26), pullsDown: false)
        targetPopup.controlSize = .small
        targetPopup.target = self
        targetPopup.action = #selector(targetLanguageChanged(_:))
        populateLanguagePopup(
            targetPopup,
            options: TranslationLanguage.targets,
            selected: translationTarget,
            disabled: translationSource
        )
        content.addSubview(targetPopup)

        let hint = NSTextField(labelWithString: "选择后立即生效")
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 12, y: 10, width: 200, height: 16)
        content.addSubview(hint)

        let controller = NSViewController()
        controller.view = content
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        directionPopover = popover
        sourceLanguagePopup = sourcePopup
        targetLanguagePopup = targetPopup
        popover.show(relativeTo: directionButton.bounds, of: directionButton, preferredEdge: .minY)
    }

    private func populateLanguagePopup(
        _ popup: NSPopUpButton,
        options: [TranslationLanguage],
        selected: TranslationLanguage,
        disabled: TranslationLanguage
    ) {
        popup.removeAllItems()
        for language in options {
            popup.addItem(withTitle: language.displayName)
            popup.lastItem?.representedObject = language.rawValue
            if language == disabled {
                popup.lastItem?.isEnabled = false
            }
        }
        if let index = options.firstIndex(of: selected) {
            popup.selectItem(at: index)
        }
    }

    @objc private func sourceLanguageChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
            let language = TranslationLanguage(rawValue: raw)
        else { return }
        closeDirectionPicker()
        requestTranslationDirection(source: language, target: translationTarget)
    }

    @objc private func targetLanguageChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
            let language = TranslationLanguage(rawValue: raw),
            language != .auto
        else { return }
        closeDirectionPicker()
        requestTranslationDirection(source: translationSource, target: language)
    }

    private func requestTranslationDirection(source: TranslationLanguage, target: TranslationLanguage) {
        guard target != .auto, source == .auto || source != target else { return }
        guard source != translationSource || target != translationTarget else { return }
        guard activeMode == .extract else { return }
        let state = modeState
        guard !state.isRecognizing, !(state.translation?.isTranslating ?? false) else { return }
        commitEditor()

        if let translation = state.translation, (state.result ?? "") != translation.renderedText,
            !confirmDiscardTranslation(action: "重新翻译", keepsPrevious: false)
        {
            updateUI()
            return
        }

        translationSource = source
        translationTarget = target
        AppEnvironment.shared.aiConfig.setTranslationDirection(source: source, target: target)

        if let translation = state.translation {
            translation.task?.cancel()
            state.translation = nil
            state.result = translation.baseText
            state.edited = translation.baseEdited
            state.transientStatus = nil
            setResultText(translation.baseText)
            startTranslation()
        } else {
            state.transientStatus = nil
            updateUI()
        }
    }

    @objc private func swapTranslationDirection() {
        guard activeMode == .extract else { return }
        let state = modeState
        guard !state.isRecognizing, !(state.translation?.isTranslating ?? false) else { return }
        guard !(state.result ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let previousSource = translationSource
        let previousTarget = translationTarget
        if previousSource == .auto {
            let source = previousTarget
            let target = previousTarget == .english ? TranslationLanguage.simplifiedChinese : .english
            requestTranslationDirection(source: source, target: target)
        } else {
            requestTranslationDirection(source: previousTarget, target: previousSource)
        }
    }

    private func closeDirectionPicker() {
        directionPopover?.close()
        directionPopover = nil
        sourceLanguagePopup = nil
        targetLanguagePopup = nil
    }

    @objc private func togglePrevious() {
        guard !(modeState.previous ?? "").isEmpty else { return }
        previousExpanded.toggle()
        layoutResultPane()
    }

    @objc private func openAISettings() {
        openSettings()
    }

    // MARK: - 对话

    @objc private func toggleChat() {
        chatExpanded.toggle()
        if chatExpanded {
            collapsedWidth = window?.frame.width ?? collapsedWidth
            let visible = window?.screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let targetWidth = min(collapsedWidth + 340, visible.width - 16)
            var frame = window?.frame ?? .zero
            frame.size.width = targetWidth
            frame.origin.x = min(frame.origin.x, visible.maxX - targetWidth - 8)
            frame.origin.x = max(visible.minX + 8, frame.origin.x)
            window?.setFrame(frame, display: true)
        } else {
            var frame = window?.frame ?? .zero
            frame.size.width = min(collapsedWidth, (window?.screen?.visibleFrame.width ?? 1440) - 16)
            window?.setFrame(frame, display: true)
        }
        layoutContent()
        updateChatUI()
    }

    private func updateChatUI() {
        guard chatExpanded else { return }
        let state = modeState
        let hasResult = !(state.result ?? "").isEmpty
        let blocked = blockerMessage() != nil

        let quickVisible = hasResult && !blocked && state.chat.isEmpty && !state.chatStreaming
        quickStack.isHidden = !quickVisible
        chatScroll.isHidden = false
        chatField.isEnabled = hasResult && !blocked && !state.chatStreaming
        sendButton.isEnabled = hasResult && !blocked && !state.chatStreaming
        sendButton.isHidden = state.chatStreaming
        stopButton.isHidden = !state.chatStreaming
        chatStatusLabel.stringValue = state.chatStreaming ? "小U 正在输入…" : (state.chatError ?? "")
        chatStatusLabel.textColor = state.chatError == nil ? .secondaryLabelColor : .systemRed
        chatSubtitle.stringValue = state.chatStreaming ? "正在回答" : "AI 助手"
        refreshChatTranscript()
        layoutChatPane()
    }

    private func refreshChatTranscript() {
        let state = modeState
        let text = NSMutableAttributedString()
        let nameAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let bodyAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.textColor,
        ]

        func appendMessage(name: String, body: String) {
            text.append(NSAttributedString(string: "\(name)\n", attributes: nameAttrs))
            text.append(NSAttributedString(string: "\(body)\n\n", attributes: bodyAttrs))
        }

        let hasResult = !(state.result ?? "").isEmpty
        if state.chat.isEmpty {
            if !hasResult {
                let message =
                    state.isRecognizing
                    ? "等识别结果出来再聊。"
                    : (blockerMessage() ?? state.recognitionError ?? "等识别结果出来再聊。")
                appendMessage(name: "系统", body: message)
            } else {
                appendMessage(name: "小U", body: "我是小U，关于这张图想问什么？")
            }
        } else {
            for message in state.chat {
                appendMessage(name: message.role == .assistant ? "小U" : "我", body: message.text)
            }
            if state.chatStreaming, let last = state.chat.last, last.text.isEmpty {
                text.append(NSAttributedString(string: "小U\n正在输入…\n\n", attributes: nameAttrs))
            }
        }

        if let error = state.chatError, !error.isEmpty {
            text.append(NSAttributedString(string: "系统\n", attributes: nameAttrs))
            text.append(
                NSAttributedString(
                    string: "\(error)\n\n",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 11),
                        .foregroundColor: NSColor.systemRed,
                    ]
                ))
        }

        isUpdatingText = true
        chatTextView.textStorage?.setAttributedString(text)
        isUpdatingText = false
        DispatchQueue.main.async { [weak self] in
            self?.chatTextView.scrollToEndOfDocument(nil)
        }
    }

    @objc private func quickSummarize() { quickSend("总结这张图") }
    @objc private func quickExtract() { quickSend("提取关键信息") }
    @objc private func quickTranslate() { quickSend("翻译图中文字") }

    private func quickSend(_ question: String) {
        chatField.stringValue = question
        sendChat()
    }

    @objc private func sendChatAction() {
        sendChat()
    }

    private func sendChat() {
        commitEditor()
        let state = modeState
        let question = chatField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, let imageDataURL else { return }
        guard !(state.result ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !state.chatStreaming else { return }
        if let blocker = blockerMessage() {
            state.chatError = blocker
            updateChatUI()
            return
        }

        let mode = activeMode
        let prior = state.chat
        let settings = AppEnvironment.shared.aiConfig.settings
        let apiKey = settings.authEnabled ? KeychainStore.read() : nil

        guard
            AppEnvironment.shared.aiConsent.ensure(
                for: settings,
                dataTypes: ["当前截图", "OCR / 识别结果", "对话历史", "本轮提问"],
                parentWindow: window
            )
        else {
            state.chatError = "已取消向 AI 接口发送数据。"
            updateChatUI()
            return
        }

        chatField.stringValue = ""
        state.chat.append(AIChatMessage(role: .user, text: question))
        state.chat.append(AIChatMessage(role: .assistant, text: ""))
        state.chatStreaming = true
        state.chatError = nil
        updateChatUI()

        var task: AITask?
        task = AIClient.chatStream(
            imageDataURL: imageDataURL,
            currentResult: state.result ?? "",
            history: prior,
            question: question,
            settings: settings,
            apiKey: apiKey,
            onDelta: { [weak self] delta in
                guard let self, !(task?.isCancelled ?? true) else { return }
                guard let state = self.states[mode], !state.chat.isEmpty else { return }
                let index = state.chat.count - 1
                state.chat[index].text += delta
                if mode == self.activeMode { self.updateChatUI() }
            },
            onDone: { [weak self] in
                guard let self, !(task?.isCancelled ?? true) else { return }
                guard let state = self.states[mode] else { return }
                state.chatStreaming = false
                state.chatTask = nil
                if state.chat.last?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
                    state.chatError = "小U 没有返回内容。"
                }
                if mode == self.activeMode { self.updateChatUI() }
            },
            onError: { [weak self] error in
                guard let self, !(task?.isCancelled ?? true) else { return }
                guard let state = self.states[mode] else { return }
                state.chatStreaming = false
                state.chatTask = nil
                state.chatError = error.localizedDescription
                if state.chat.last?.text.isEmpty == true {
                    if let index = state.chat.indices.last {
                        state.chat[index].text = "（没有收到回答）"
                    }
                }
                if mode == self.activeMode { self.updateChatUI() }
            }
        )
        state.chatTask = task
    }

    @objc private func stopChat() {
        let state = modeState
        state.chatTask?.cancel()
        state.chatTask = nil
        state.chatStreaming = false
        if let last = state.chat.indices.last,
            state.chat[last].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            state.chat[last].text = "（已停止生成）"
        }
        updateChatUI()
    }

    // MARK: - 窗口

    func windowDidResize(_ notification: Notification) {
        if !chatExpanded {
            collapsedWidth = window?.frame.width ?? collapsedWidth
        }
        layoutContent()
    }

    func windowWillClose(_ notification: Notification) {
        closeDirectionPicker()
        for state in states.values {
            state.recognitionTask?.cancel()
            state.chatTask?.cancel()
            state.translation?.task?.cancel()
        }
        Self.liveWindows.removeAll { $0 === self }
    }
}
