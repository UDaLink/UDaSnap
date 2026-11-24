import AppKit
import UDaSnapCore

/// 首次启动或政策版本变化时的隐私同意窗口。
@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {

    private static var current: OnboardingWindowController?

    private let checkbox = NSButton(checkboxWithTitle: "我已阅读并同意《隐私政策》和《用户协议》", target: nil, action: nil)
    private let acceptButton = NSButton(title: "同意并继续", target: nil, action: nil)
    private var onAccept: (() -> Void)?
    private var onDecline: (() -> Void)?
    private var didFinish = false

    static func show(onAccept: @escaping () -> Void, onDecline: @escaping () -> Void) {
        if let current {
            current.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = OnboardingWindowController(onAccept: onAccept, onDecline: onDecline)
        current = controller
        controller.showWindow(nil)
        controller.window?.center()
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private init(onAccept: @escaping () -> Void, onDecline: @escaping () -> Void) {
        self.onAccept = onAccept
        self.onDecline = onDecline

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 660),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "UDaSnap · 隐私与数据"
        window.isReleasedWhenClosed = false
        window.level = .floating
        super.init(window: window)
        window.delegate = self
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let icon = NSImageView(frame: NSRect(x: 28, y: 586, width: 52, height: 52))
        icon.image = NSImage(named: NSImage.applicationIconName) ?? BrandMark.statusImage()
        icon.imageScaling = .scaleProportionallyUpOrDown
        content.addSubview(icon)

        let title = NSTextField(labelWithString: "欢迎使用 UDaSnap")
        title.font = .systemFont(ofSize: 24, weight: .semibold)
        title.frame = NSRect(x: 96, y: 606, width: 600, height: 30)
        content.addSubview(title)

        let subtitle = NSTextField(labelWithString: "先确认隐私与数据处理方式，再开始截图。")
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        subtitle.frame = NSRect(x: 96, y: 578, width: 600, height: 20)
        content.addSubview(subtitle)

        let scroll = NSScrollView(frame: NSRect(x: 28, y: 208, width: 704, height: 346))
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = false
        content.addSubview(scroll)

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 684, height: 1))
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: 684, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 684, height: CGFloat.greatestFiniteMagnitude)
        textView.textStorage?.setAttributedString(summaryAttributedText())
        textView.sizeToFit()
        scroll.documentView = textView

        let version = NSTextField(
            labelWithString: "隐私政策 v\(LegalDocuments.policyVersion) · 生效 \(LegalDocuments.effectiveDate)"
        )
        version.font = .systemFont(ofSize: 10.5)
        version.textColor = .secondaryLabelColor
        version.frame = NSRect(x: 28, y: 178, width: 704, height: 18)
        content.addSubview(version)

        checkbox.target = self
        checkbox.action = #selector(checkboxChanged)
        checkbox.font = .systemFont(ofSize: 12)
        checkbox.frame = NSRect(x: 28, y: 144, width: 704, height: 22)
        content.addSubview(checkbox)

        let privacy = NSButton(title: "查看隐私政策", target: self, action: #selector(openPrivacy))
        privacy.bezelStyle = .rounded
        privacy.frame = NSRect(x: 28, y: 100, width: 110, height: 28)
        content.addSubview(privacy)

        let terms = NSButton(title: "查看用户协议", target: self, action: #selector(openTerms))
        terms.bezelStyle = .rounded
        terms.frame = NSRect(x: 146, y: 100, width: 110, height: 28)
        content.addSubview(terms)

        let decline = NSButton(title: "不同意并退出", target: self, action: #selector(decline))
        decline.bezelStyle = .rounded
        decline.frame = NSRect(x: 412, y: 28, width: 140, height: 32)
        content.addSubview(decline)

        acceptButton.bezelStyle = .rounded
        acceptButton.keyEquivalent = "\r"
        acceptButton.isEnabled = false
        acceptButton.target = self
        acceptButton.action = #selector(accept)
        acceptButton.frame = NSRect(x: 560, y: 28, width: 172, height: 32)
        content.addSubview(acceptButton)
    }

    private func summaryAttributedText() -> NSAttributedString {
        let result = NSMutableAttributedString()
        let bodyFont = NSFont.systemFont(ofSize: 12.5)
        let titleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
        for (index, section) in LegalDocuments.onboardingSections.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: "\n", attributes: [.font: bodyFont]))
            }
            result.append(
                NSAttributedString(
                    string: "\(section.0)\n",
                    attributes: [
                        .font: titleFont,
                        .foregroundColor: NSColor.labelColor,
                    ]
                ))
            result.append(
                NSAttributedString(
                    string: "\(section.1)\n",
                    attributes: [
                        .font: bodyFont,
                        .foregroundColor: NSColor.secondaryLabelColor,
                    ]
                ))
        }
        return result
    }

    @objc private func checkboxChanged() {
        acceptButton.isEnabled = checkbox.state == .on
    }

    @objc private func openPrivacy() {
        LegalDocumentWindowController.show(.privacy)
    }

    @objc private func openTerms() {
        LegalDocumentWindowController.show(.terms)
    }

    @objc private func accept() {
        guard checkbox.state == .on else { return }
        didFinish = true
        window?.close()
        Self.current = nil
        onAccept?()
    }

    @objc private func decline() {
        didFinish = true
        window?.close()
        Self.current = nil
        onDecline?()
    }

    func windowWillClose(_ notification: Notification) {
        guard !didFinish else { return }
        didFinish = true
        Self.current = nil
        onDecline?()
    }
}
