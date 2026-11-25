import AppKit

/// “立即截图”框选完成后的操作条动作。
enum ImmediateSelectionAction {
    case annotate
    case pin
    case save
    case cancel
}

/// 选区外的浅色毛玻璃操作条：标注 / 贴图 / 取消，并在右侧提示 Enter 复制保存。
@MainActor
final class ImmediateSelectionBarView: NSVisualEffectView {

    static let preferredSize = NSSize(width: 346, height: 46)

    var onAction: ((ImmediateSelectionAction) -> Void)?

    private let separator = NSView()
    private let hintLabel = NSTextField(labelWithString: "⏎ 复制并保存")
    private var hoveredButton: ImmediateBarButton?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        material = .popover
        blendingMode = .withinWindow
        state = .active
        appearance = NSAppearance(named: .aqua)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.62).cgColor

        // NSVisualEffectView 在 screenshot overlay 里会采样被压暗的冻结画面；
        // 加一层很浅的白色 tint，保证深色内容上仍然像“浅色玻璃”而不是灰块。
        let tint = PassthroughView(frame: bounds)
        tint.autoresizingMask = [.width, .height]
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.18).cgColor
        addSubview(tint)

        let annotate = makeButton(symbol: "pencil", label: "标注", action: .annotate)
        let pin = makeButton(symbol: "pin", label: "贴图", action: .pin)
        let cancel = makeButton(symbol: "xmark", label: "取消", action: .cancel)
        addSubview(annotate)
        addSubview(pin)
        addSubview(cancel)

        let buttonWidth: CGFloat = 72
        let buttonHeight: CGFloat = 32
        let padding: CGFloat = 7
        let spacing: CGFloat = 4
        annotate.frame = NSRect(x: padding, y: padding, width: buttonWidth, height: buttonHeight)
        pin.frame = NSRect(
            x: padding + buttonWidth + spacing, y: padding, width: buttonWidth, height: buttonHeight)
        cancel.frame = NSRect(
            x: padding + (buttonWidth + spacing) * 2, y: padding,
            width: buttonWidth, height: buttonHeight)

        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.16).cgColor
        separator.frame = NSRect(
            x: padding + (buttonWidth + spacing) * 3 + 4, y: 10, width: 1, height: 26)
        addSubview(separator)

        hintLabel.font = .systemFont(ofSize: 10.5, weight: .medium)
        hintLabel.textColor = NSColor(calibratedWhite: 0.15, alpha: 0.72)
        hintLabel.alignment = .center
        hintLabel.frame = NSRect(x: separator.frame.maxX + 8, y: 15, width: 92, height: 16)
        addSubview(hintLabel)

        setAccessibilityRole(.group)
        setAccessibilityLabel("立即截图操作")
    }

    private func makeButton(
        symbol: String, label: String, action: ImmediateSelectionAction
    ) -> ImmediateBarButton {
        let button = ImmediateBarButton(symbol: symbol, label: label)
        button.onClick = { [weak self] in self?.onAction?(action) }
        return button
    }
}

/// 操作条里的单个按钮。使用浅色玻璃底色上的深色图标 + 短文字，
/// hover 时只加一层很淡的系统蓝底，不改变整体玻璃的轻量感。
@MainActor
private final class ImmediateBarButton: NSButton {

    var onClick: (() -> Void)?

    private let label: String
    private var hovering = false
    private var tracking: NSTrackingArea?

    init(symbol: String, label: String) {
        self.label = label
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageLeading
        imageScaling = .scaleProportionallyDown
        font = .systemFont(ofSize: 11.5, weight: .semibold)
        alignment = .center
        focusRingType = .none
        refusesFirstResponder = true
        setButtonType(.momentaryChange)
        toolTip = label
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        {
            self.image = image
        }
        wantsLayer = true
        layer?.cornerRadius = 7
        target = self
        action = #selector(invoke)
        applyStyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func invoke() {
        onClick?()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self
        )
        addTrackingArea(tracking!)
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        applyStyle()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        applyStyle()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }

    private func applyStyle() {
        let color: NSColor
        let background: NSColor
        if hovering {
            color = .controlAccentColor
            background = NSColor.controlAccentColor.withAlphaComponent(0.13)
        } else {
            color = NSColor(calibratedWhite: 0.08, alpha: 0.94)
            background = .clear
        }
        layer?.backgroundColor = background.cgColor
        contentTintColor = color
        attributedTitle = NSAttributedString(
            string: label,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold),
                .foregroundColor: color,
            ])
    }
}

/// 玻璃底上的透明 tint 不能抢按钮的鼠标事件；空白区域则由它吞掉，
/// 避免点在操作条 padding 上被当成“点选区外”而重新框选。
@MainActor
private final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        self
    }
}
