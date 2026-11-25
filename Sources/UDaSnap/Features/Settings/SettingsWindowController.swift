import AppKit
import Carbon.HIToolbox
import UDaSnapCore

enum PreferencesPage {
    case ai
    case shortcuts
    case privacy
}

/// 快捷键页只负责这六套全局快捷键，与 CaptureMode 的截图流程无关。
private enum ShortcutMode {
    case immediate
    case pin
    case save
    case fullScreen
    case app
    case scroll
}

/// 统一偏好设置：左侧第一项 AI 设置，第二项快捷键。
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {

    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    static let shared = SettingsWindowController()

    private weak var manager: HotkeyManager?
    private weak var activeRecorder: RecorderView?
    private let shortcutView = FlippedView()
    private let aiPane = AISettingsView(frame: NSRect(x: 0, y: 0, width: 680, height: 840))
    private let privacyPane = PrivacySettingsView(frame: NSRect(x: 0, y: 0, width: 680, height: 840))
    private let aiPageButton = NSButton(title: "AI 设置", target: nil, action: nil)
    private let shortcutPageButton = NSButton(title: "快捷键", target: nil, action: nil)
    private let privacyPageButton = NSButton(title: "隐私与数据", target: nil, action: nil)
    private var currentPage: PreferencesPage = .ai

    private let pinRecorder = RecorderView(frame: .zero)
    private let saveRecorder = RecorderView(frame: .zero)
    private let fullScreenRecorder = RecorderView(frame: .zero)
    private let appRecorder = RecorderView(frame: .zero)
    private let scrollRecorder = RecorderView(frame: .zero)
    private let immediateRecorder = RecorderView(frame: .zero)
    private let pinStatus = NSTextField(labelWithString: "")
    private let saveStatus = NSTextField(labelWithString: "")
    private let fullScreenStatus = NSTextField(labelWithString: "")
    private let appStatus = NSTextField(labelWithString: "")
    private let scrollStatus = NSTextField(labelWithString: "")
    private let immediateStatus = NSTextField(labelWithString: "")
    private let forceTapBox = NSButton(checkboxWithTitle: "强力模式（占用辅助功能权限）", target: nil, action: nil)
    private let axButton = NSButton(title: "打开辅助功能设置", target: nil, action: nil)

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 840),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "UDaSnap 偏好设置"
        window.isReleasedWhenClosed = false
        // 普通窗口层级：用户打开其他窗口时可以正常盖住偏好设置，不强制置顶。
        window.level = .normal
        super.init(window: window)
        window.delegate = self
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildUI() {
        guard let root = window?.contentView else { return }

        buildSidebar(in: root)

        shortcutView.frame = NSRect(x: 244, y: 0, width: 632, height: 840)
        root.addSubview(shortcutView)
        let content = shortcutView

        let title = NSTextField(labelWithString: "快捷键")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        title.frame = NSRect(x: 24, y: 16, width: 584, height: 28)
        content.addSubview(title)

        let subtitle = NSTextField(
            wrappingLabelWithString: "每个快捷键一行：左侧名称、中间键位、右侧用途。点键位框录制，修改后立即生效；备用键固定，不能删除。"
        )
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.frame = NSRect(x: 24, y: 46, width: 584, height: 32)
        content.addSubview(subtitle)

        for (text, x, width) in [("名称", 24.0, 110.0), ("快捷键", 140.0, 190.0), ("说明", 330.0, 278.0)] {
            let header = NSTextField(labelWithString: text)
            header.font = .systemFont(ofSize: 10)
            header.textColor = .tertiaryLabelColor
            header.frame = NSRect(x: x, y: 84, width: width, height: 14)
            content.addSubview(header)
        }

        addShortcutRow(
            name: "立即截图",
            detail: "框选后保留选区，可标注、贴图或按 Enter 复制保存",
            recorder: immediateRecorder,
            status: immediateStatus,
            mode: .immediate,
            y: 104
        )
        addShortcutRow(
            name: "截图并贴图",
            detail: "框选区域，贴成始终置顶的浮窗",
            recorder: pinRecorder,
            status: pinStatus,
            mode: .pin,
            y: 194
        )
        addShortcutRow(
            name: "框选截图",
            detail: "框选区域，复制并保存原图，不贴图",
            recorder: saveRecorder,
            status: saveStatus,
            mode: .save,
            y: 284
        )
        addShortcutRow(
            name: "全屏截图",
            detail: "截取鼠标所在屏幕，复制并保存",
            recorder: fullScreenRecorder,
            status: fullScreenStatus,
            mode: .fullScreen,
            y: 374
        )
        addShortcutRow(
            name: "应用窗口截图",
            detail: "点选一个窗口，带阴影截取，复制并保存",
            recorder: appRecorder,
            status: appStatus,
            mode: .app,
            y: 464
        )
        addShortcutRow(
            name: "滚动截图",
            detail: "框选可滚动区域，自动向下滚动拼成长图",
            recorder: scrollRecorder,
            status: scrollStatus,
            mode: .scroll,
            y: 554
        )

        forceTapBox.frame = NSRect(x: 24, y: 660, width: 584, height: 20)
        forceTapBox.target = self
        forceTapBox.action = #selector(toggleForceTap)
        content.addSubview(forceTapBox)

        let forceHint = NSTextField(
            labelWithString: "强力模式会占用辅助功能权限；滚动截图自动滚动也需要辅助功能授权。裸 F1–F6 会被系统功能键优先处理，建议始终搭配 ⌘ 等修饰键。")
        forceHint.frame = NSRect(x: 24, y: 686, width: 584, height: 30)
        forceHint.font = .systemFont(ofSize: 10.5)
        forceHint.textColor = .secondaryLabelColor
        forceHint.lineBreakMode = .byWordWrapping
        forceHint.maximumNumberOfLines = 2
        content.addSubview(forceHint)

        axButton.frame = NSRect(x: 24, y: 724, width: 150, height: 30)
        axButton.bezelStyle = .rounded
        axButton.target = self
        axButton.action = #selector(openAX)
        content.addSubview(axButton)

        let reset = NSButton(title: "恢复默认", target: self, action: #selector(resetDefault))
        reset.frame = NSRect(x: 24, y: 790, width: 100, height: 30)
        reset.bezelStyle = .rounded
        content.addSubview(reset)

        let close = NSButton(title: "完成", target: self, action: #selector(closeWindow))
        close.frame = NSRect(x: 508, y: 790, width: 100, height: 30)
        close.bezelStyle = .rounded
        close.keyEquivalent = "\r"
        content.addSubview(close)

        aiPane.frame = NSRect(x: 220, y: 0, width: 680, height: 840)
        root.addSubview(aiPane)

        privacyPane.frame = NSRect(x: 220, y: 0, width: 680, height: 840)
        root.addSubview(privacyPane)

        switchPage(.ai, refresh: false)
    }

    private func addShortcutRow(
        name: String,
        detail: String,
        recorder: RecorderView,
        status: NSTextField,
        mode: ShortcutMode,
        y: CGFloat
    ) {
        let content = shortcutView

        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        nameLabel.frame = NSRect(x: 24, y: y + 8, width: 110, height: 20)
        content.addSubview(nameLabel)

        configure(recorder, mode: mode)
        recorder.frame = NSRect(x: 140, y: y, width: 190, height: 38)
        content.addSubview(recorder)

        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.frame = NSRect(x: 330, y: y + 2, width: 278, height: 36)
        detailLabel.maximumNumberOfLines = 2
        content.addSubview(detailLabel)

        configureStatus(status)
        status.frame = NSRect(x: 140, y: y + 42, width: 468, height: 32)
        content.addSubview(status)

        let separator = NSView(frame: NSRect(x: 24, y: y + 88, width: 584, height: 1))
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
        content.addSubview(separator)
    }

    private func buildSidebar(in root: NSView) {
        let sidebar = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 840))
        sidebar.wantsLayer = true
        sidebar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        root.addSubview(sidebar)

        let separator = NSView(frame: NSRect(x: 220, y: 0, width: 1, height: 840))
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.separatorColor.cgColor
        root.addSubview(separator)

        let title = NSTextField(labelWithString: "偏好设置")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.frame = NSRect(x: 22, y: 790, width: 180, height: 24)
        sidebar.addSubview(title)

        let subtitle = NSTextField(labelWithString: "UDaSnap")
        subtitle.font = .systemFont(ofSize: 10)
        subtitle.textColor = .secondaryLabelColor
        subtitle.frame = NSRect(x: 22, y: 768, width: 180, height: 16)
        sidebar.addSubview(subtitle)

        aiPageButton.target = self
        aiPageButton.action = #selector(showAIPage)
        configureSidebarButton(aiPageButton, title: "AI 设置")
        aiPageButton.frame = NSRect(x: 12, y: 710, width: 196, height: 34)
        sidebar.addSubview(aiPageButton)

        shortcutPageButton.target = self
        shortcutPageButton.action = #selector(showShortcutPage)
        configureSidebarButton(shortcutPageButton, title: "快捷键")
        shortcutPageButton.frame = NSRect(x: 12, y: 670, width: 196, height: 34)
        sidebar.addSubview(shortcutPageButton)

        privacyPageButton.target = self
        privacyPageButton.action = #selector(showPrivacyPage)
        configureSidebarButton(privacyPageButton, title: "隐私与数据")
        privacyPageButton.frame = NSRect(x: 12, y: 630, width: 196, height: 34)
        sidebar.addSubview(privacyPageButton)

        let hint = NSTextField(
            wrappingLabelWithString: "AI 设置用于配置大模型接口、提示词和隐私告知；快捷键页用于录制六种截图按键；隐私与数据页用于查看权限、数据位置、删除数据和撤回同意。"
        )
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 22, y: 494, width: 176, height: 112)
        sidebar.addSubview(hint)

        let versionText =
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "1.2.0"
        let version = NSTextField(labelWithString: "v\(versionText)")
        version.font = .systemFont(ofSize: 10)
        version.textColor = .secondaryLabelColor
        version.frame = NSRect(x: 22, y: 18, width: 100, height: 16)
        sidebar.addSubview(version)
    }

    private func configureSidebarButton(_ button: NSButton, title: String) {
        button.title = title
        button.isBordered = false
        button.alignment = .left
        button.font = .systemFont(ofSize: 13, weight: .medium)
        button.frame = NSRect(x: 12, y: 0, width: 196, height: 34)
        button.wantsLayer = true
        button.layer?.cornerRadius = 7
    }

    private func updateSidebarSelection() {
        aiPageButton.layer?.backgroundColor =
            currentPage == .ai
            ? NSColor.controlAccentColor.withAlphaComponent(0.16).cgColor
            : NSColor.clear.cgColor
        shortcutPageButton.layer?.backgroundColor =
            currentPage == .shortcuts
            ? NSColor.controlAccentColor.withAlphaComponent(0.16).cgColor
            : NSColor.clear.cgColor
        privacyPageButton.layer?.backgroundColor =
            currentPage == .privacy
            ? NSColor.controlAccentColor.withAlphaComponent(0.16).cgColor
            : NSColor.clear.cgColor
        aiPageButton.contentTintColor = currentPage == .ai ? .controlAccentColor : .labelColor
        shortcutPageButton.contentTintColor = currentPage == .shortcuts ? .controlAccentColor : .labelColor
        privacyPageButton.contentTintColor = currentPage == .privacy ? .controlAccentColor : .labelColor
    }

    private func switchPage(_ page: PreferencesPage, refresh: Bool) {
        currentPage = page
        aiPane.isHidden = page != .ai
        shortcutView.isHidden = page != .shortcuts
        privacyPane.isHidden = page != .privacy
        updateSidebarSelection()
        if refresh {
            if page == .ai {
                aiPane.refresh()
            } else if page == .shortcuts, let manager {
                render(manager.statuses)
            } else if page == .privacy {
                privacyPane.refresh()
            }
        }
    }

    @objc private func showAIPage() {
        endRecordingIfNeeded()
        switchPage(.ai, refresh: true)
    }

    @objc private func showShortcutPage() {
        switchPage(.shortcuts, refresh: true)
    }

    @objc private func showPrivacyPage() {
        endRecordingIfNeeded()
        switchPage(.privacy, refresh: true)
    }

    private func configure(_ recorder: RecorderView, mode: ShortcutMode) {
        recorder.wantsLayer = true
        recorder.layer?.borderWidth = 1
        recorder.layer?.borderColor = NSColor.separatorColor.cgColor
        recorder.layer?.cornerRadius = 8
        recorder.onRecord = { [weak self] config in
            self?.apply(config, mode: mode)
        }
        recorder.onFocusChange = { [weak self] focused in
            self?.recorderFocusChanged(recorder, focused: focused)
        }
    }

    private func configureStatus(_ label: NSTextField) {
        label.font = .systemFont(ofSize: 11)
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 2
        label.stringValue = ""
    }

    func copyFocusedAIKey() -> Bool {
        guard let window, currentPage == .ai else { return false }
        return aiPane.copySecureKeyIfFocused(in: window)
    }

    func show(manager: HotkeyManager, page: PreferencesPage = .ai) {
        self.manager = manager
        manager.onStatusChange = { [weak self] statuses in self?.render(statuses) }

        pinRecorder.config = manager.settings.pin
        saveRecorder.config = manager.settings.save
        fullScreenRecorder.config = manager.settings.fullScreen
        appRecorder.config = manager.settings.app
        scrollRecorder.config = manager.settings.scroll
        immediateRecorder.config = manager.settings.immediate
        forceTapBox.state = manager.settings.forceTap ? .on : .off
        render(manager.statuses)
        // 先切页但不读钥匙串，等窗口显示后再刷新；否则 Keychain 授权提示可能挂在无窗口的
        // LSUIElement 进程上，窗口一直不出现。
        switchPage(page, refresh: false)

        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        // 不自动把焦点落到录制框上：否则窗口一开就处于“录制中”，热键被停用，误按还会改键位。
        window?.makeFirstResponder(nil)
        DispatchQueue.main.async { [weak self] in
            self?.switchPage(page, refresh: true)
        }
    }

    /// 撤回同意或清除配置时立即收起设置窗。清除配置时不能 flush，
    /// 否则 AI 页里的旧 Key 会被写回刚删掉的配置和钥匙串。
    func dismissForComplianceChange(flush: Bool = true) {
        if flush {
            aiPane.flush()
        } else {
            aiPane.discardAndReloadFromStore()
        }
        activeRecorder = nil
        window?.orderOut(nil)
    }

    private func endRecordingIfNeeded() {
        if activeRecorder != nil {
            window?.makeFirstResponder(nil)
        }
    }

    func windowWillClose(_ notification: Notification) {
        aiPane.flush()
        if activeRecorder != nil {
            activeRecorder = nil
            manager?.resume()
        }
    }

    // MARK: 录制焦点：录制期间临时注销全局热键

    private func recorderFocusChanged(_ recorder: RecorderView, focused: Bool) {
        if focused {
            activeRecorder = recorder
            manager?.suspend()
        } else if activeRecorder === recorder {
            activeRecorder = nil
            manager?.resume()
        }
    }

    // MARK: 应用配置

    private func apply(_ config: HotkeyConfig, mode: ShortcutMode) {
        guard let manager else { return }

        if let conflict = conflictMessage(for: config, mode: mode) {
            let recorder = recorder(for: mode)
            recorder.config = hotkey(for: mode, in: manager.settings)
            recorder.showMessage(conflict)
            return
        }

        var settings = manager.settings
        switch mode {
        case .immediate:
            settings.immediate = config
        case .pin:
            settings.pin = config
        case .save:
            settings.save = config
        case .fullScreen:
            settings.fullScreen = config
        case .app:
            settings.app = config
        case .scroll:
            settings.scroll = config
        }
        manager.update(settings)

        immediateRecorder.config = settings.immediate
        pinRecorder.config = settings.pin
        saveRecorder.config = settings.save
        fullScreenRecorder.config = settings.fullScreen
        appRecorder.config = settings.app
        scrollRecorder.config = settings.scroll
        render(manager.statuses)
    }

    private func recorder(for mode: ShortcutMode) -> RecorderView {
        switch mode {
        case .immediate: return immediateRecorder
        case .pin: return pinRecorder
        case .save: return saveRecorder
        case .fullScreen: return fullScreenRecorder
        case .app: return appRecorder
        case .scroll: return scrollRecorder
        }
    }

    private func hotkey(for mode: ShortcutMode, in settings: AppSettings) -> HotkeyConfig {
        switch mode {
        case .immediate: return settings.immediate
        case .pin: return settings.pin
        case .save: return settings.save
        case .fullScreen: return settings.fullScreen
        case .app: return settings.app
        case .scroll: return settings.scroll
        }
    }

    private func conflictMessage(for config: HotkeyConfig, mode: ShortcutMode) -> String? {
        guard let manager else { return nil }
        let settings = manager.settings
        let candidates: [(ShortcutMode, String, HotkeyConfig)] = [
            (.immediate, "立即截图", settings.immediate),
            (.pin, "截图并贴图", settings.pin),
            (.save, "框选截图", settings.save),
            (.fullScreen, "全屏截图", settings.fullScreen),
            (.app, "应用窗口截图", settings.app),
            (.scroll, "滚动截图", settings.scroll),
        ]
        for (otherMode, name, otherConfig) in candidates where otherMode != mode {
            if config == otherConfig { return "与\(name)键相同" }
        }

        if config == .immediateBackup { return "这是立即截图备用键 ⌥⇧6" }
        if config == .pinBackup { return "这是截图并贴图备用键 ⌥⇧1" }
        if config == .saveBackup { return "这是框选截图备用键 ⌥⇧2" }
        if config == .fullScreenBackup { return "这是全屏截图备用键 ⌥⇧3" }
        if config == .appBackup { return "这是应用窗口截图备用键 ⌥⇧4" }
        if config == .scrollBackup { return "这是滚动截图备用键 ⌥⇧5" }
        return nil
    }

    private func render(_ statuses: HotkeyManager.Statuses) {
        let settings = manager?.settings ?? .default
        immediateStatus.stringValue = describe(
            statuses.immediate, config: settings.immediate, alt: statuses.immediateAlt, altLabel: "⌥⇧6")
        pinStatus.stringValue = describe(statuses.pin, config: settings.pin, alt: statuses.pinAlt, altLabel: "⌥⇧1")
        saveStatus.stringValue = describe(statuses.save, config: settings.save, alt: statuses.saveAlt, altLabel: "⌥⇧2")
        fullScreenStatus.stringValue = describe(
            statuses.fullScreen, config: settings.fullScreen, alt: statuses.fullScreenAlt, altLabel: "⌥⇧3")
        appStatus.stringValue = describe(statuses.app, config: settings.app, alt: statuses.appAlt, altLabel: "⌥⇧4")
        scrollStatus.stringValue = describe(
            statuses.scroll, config: settings.scroll, alt: statuses.scrollAlt, altLabel: "⌥⇧5")
    }

    private func describe(_ status: HotkeyManager.Status, config: HotkeyConfig, alt: OSStatus, altLabel: String)
        -> String
    {
        var lines: [String] = []

        switch status {
        case .carbonOK:
            lines.append("✅ 已注册：\(config.display)（普通模式，无需额外权限）")
            if config.isSystemFunctionKey {
                lines.append("⚠️ 这是系统功能键，物理按下会被系统吃掉，请用 fn 组合。")
            }
        case .carbonFailed(let code):
            if code == -9878 {
                lines.append("⚠️ 已被别的 app 或系统占用（-9878），换一个组合或勾强力模式。")
            } else if config.isSystemFunctionKey {
                lines.append("⚠️ 这是系统功能键，macOS 会先吃掉按键，请改用 fn 组合。")
            } else {
                lines.append("⚠️ 注册失败（错误码 \(code)）。")
            }
        case .tapRunning:
            lines.append("✅ 强力模式运行中：\(config.display)（已拦截系统事件）")
        case .tapNoAccessibility:
            lines.append("⚠️ 强力模式需要「辅助功能」授权：系统设置 → 隐私与安全性 → 辅助功能，允许 UDaSnap。")
        case .tapFailed:
            lines.append("⚠️ 事件拦截创建失败，请改用其它组合键。")
        }

        lines.append(alt == 0 ? "备用键 \(altLabel) 正常。" : "备用键 \(altLabel) 注册失败（\(alt)）。")
        return lines.joined(separator: "\n")
    }

    // MARK: 动作

    @objc private func resetDefault() {
        guard let manager else { return }
        var settings = manager.settings
        settings.immediate = .immediateDefault
        settings.pin = .pinDefault
        settings.save = .saveDefault
        settings.fullScreen = .fullScreenDefault
        settings.app = .appDefault
        settings.scroll = .scrollDefault
        manager.update(settings)
        immediateRecorder.config = settings.immediate
        pinRecorder.config = settings.pin
        saveRecorder.config = settings.save
        fullScreenRecorder.config = settings.fullScreen
        appRecorder.config = settings.app
        scrollRecorder.config = settings.scroll
        render(manager.statuses)
    }

    @objc private func toggleForceTap() {
        guard let manager else { return }
        var settings = manager.settings
        settings.forceTap = forceTapBox.state == .on
        if settings.forceTap && !HotkeyManager.hasAccessibility {
            HotkeyManager.requestAccessibility()
            HotkeyManager.openAccessibilitySettings()
        }
        manager.update(settings)
        render(manager.statuses)
    }

    @objc private func openAX() {
        HotkeyManager.requestAccessibility()
        HotkeyManager.openAccessibilitySettings()
        manager?.reload()
    }

    @objc private func closeWindow() {
        aiPane.flush()
        window?.orderOut(nil)
        activeRecorder = nil
        manager?.resume()
    }
}

// MARK: - 键位录制框

@MainActor
final class RecorderView: NSView {

    var onRecord: ((HotkeyConfig) -> Void)?
    var onFocusChange: ((Bool) -> Void)?
    var config: HotkeyConfig? {
        didSet { needsDisplay = true }
    }

    private var message: String?

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func showMessage(_ text: String) {
        message = text
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if let message {
            drawText(message, color: .systemRed, size: 12, at: NSPoint(x: 12, y: bounds.midY - 8))
        } else if let config {
            drawText(config.display, color: .labelColor, size: 16, at: NSPoint(x: 12, y: bounds.midY - 10))
        }
        // 边框随焦点变蓝，提示“现在可以按键了”
        layer?.borderWidth = window?.firstResponder === self ? 2 : 1
        layer?.borderColor = (window?.firstResponder === self ? NSColor.systemBlue : NSColor.separatorColor).cgColor
    }

    private func drawText(_ text: String, color: NSColor, size: CGFloat, at point: NSPoint) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: size, weight: .medium),
            .foregroundColor: color,
        ]
        NSAttributedString(string: text, attributes: attrs).draw(at: point)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        message = nil
        needsDisplay = true
    }

    /// 纯修饰键的键码，不作为可录制的键。
    private static let modifierCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

    override func keyDown(with event: NSEvent) {
        let code = event.keyCode
        guard !Self.modifierCodes.contains(code) else { return }

        var carbon: UInt32 = 0
        let flags = event.modifierFlags
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }

        let fKeys: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]

        // 裸字母/数字会被日常输入误触，必须带修饰键；功能键允许单独使用。
        if carbon == 0 && !fKeys.contains(code) {
            message = "至少加一个修饰键：⌘ ⌥ ⌃ ⇧"
            needsDisplay = true
            return
        }

        let newConfig = HotkeyConfig(
            keyCode: UInt32(code),
            carbonModifiers: carbon
        )
        message = nil
        config = newConfig
        onRecord?(newConfig)
    }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        onFocusChange?(true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        onFocusChange?(false)
        return true
    }
}
