import AppKit
import UDaSnapCore

@MainActor
final class AnnotationToolbarView: NSView {

    var onToolChange: ((AnnotationTool) -> Void)?
    var onColorChange: ((AnnotationColor) -> Void)?
    var onLineWidthChange: ((CGFloat) -> Void)?
    var onFontSizeChange: ((CGFloat) -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onApplyCrop: (() -> Void)?
    var onRotateLeft: (() -> Void)?
    var onRotateRight: (() -> Void)?
    var onFlip: (() -> Void)?
    var onCancel: (() -> Void)?
    var onPin: (() -> Void)?
    var onDone: (() -> Void)?

    private let toolRow = NSStackView()
    private let actionRow = NSStackView()
    private let toolButtons = NSMutableArray()
    private var toolMap: [NSButton: AnnotationTool] = [:]
    private var toolOrder: [AnnotationTool] = [
        .select, .rectangle, .ellipse, .arrow, .line, .text, .number,
        .pen, .highlighter, .mosaic, .blur, .solid, .crop,
    ]
    private var colorViews: [ColorSwatchView] = []
    private var widthButtons: [NSButton] = []
    private var fontButtons: [NSButton] = []
    private let undoButton = NSButton()
    private let redoButton = NSButton()
    private let applyCropButton = NSButton()
    private var currentStyle = AnnotationStyle()
    private var currentTool: AnnotationTool = .arrow

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 92)
    }

    private func build() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let separator = NSView()
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        toolRow.orientation = .horizontal
        toolRow.spacing = 3
        toolRow.alignment = .centerY
        toolRow.translatesAutoresizingMaskIntoConstraints = false

        for tool in toolOrder {
            let button = makeToolButton(tool)
            toolRow.addArrangedSubview(button)
        }
        toolRow.addArrangedSubview(makeDivider())

        for color in AnnotationColor.palette {
            let view = ColorSwatchView(color: color.nsColor)
            view.onClick = { [weak self] in
                self?.currentStyle.color = color
                self?.refreshStyle()
                self?.onColorChange?(color)
            }
            colorViews.append(view)
            toolRow.addArrangedSubview(view)
        }
        toolRow.addArrangedSubview(makeDivider())

        for width in AnnotationStyle.lineWidths {
            let button = makeTextButton(title: "\(Int(width))", tag: widthButtons.count)
            button.toolTip = "线宽 \(Int(width)) pt"
            widthButtons.append(button)
            toolRow.addArrangedSubview(button)
        }
        toolRow.addArrangedSubview(makeDivider())
        for size in AnnotationStyle.fontSizes {
            let button = makeTextButton(title: "\(Int(size))", tag: fontButtons.count)
            button.toolTip = "字号 \(Int(size)) pt"
            fontButtons.append(button)
            toolRow.addArrangedSubview(button)
        }

        actionRow.orientation = .horizontal
        actionRow.spacing = 8
        actionRow.alignment = .centerY
        actionRow.translatesAutoresizingMaskIntoConstraints = false

        configureIconButton(undoButton, symbol: "arrow.uturn.backward", tooltip: "撤销 ⌘Z")
        undoButton.target = self
        undoButton.action = #selector(undoClicked)
        configureIconButton(redoButton, symbol: "arrow.uturn.forward", tooltip: "重做 ⇧⌘Z")
        redoButton.target = self
        redoButton.action = #selector(redoClicked)
        actionRow.addArrangedSubview(undoButton)
        actionRow.addArrangedSubview(redoButton)
        actionRow.addArrangedSubview(makeDivider())

        applyCropButton.title = "应用裁剪"
        applyCropButton.bezelStyle = .rounded
        applyCropButton.font = .systemFont(ofSize: 11, weight: .medium)
        applyCropButton.target = self
        applyCropButton.action = #selector(applyCropClicked)
        applyCropButton.isEnabled = false
        actionRow.addArrangedSubview(applyCropButton)

        let rotateLeft = makeActionButton(
            symbol: "rotate.left", tooltip: "向左旋转 90°", action: #selector(rotateLeftClicked))
        let rotateRight = makeActionButton(
            symbol: "rotate.right", tooltip: "向右旋转 90°", action: #selector(rotateRightClicked))
        let flip = makeActionButton(
            symbol: "arrow.left.and.right", tooltip: "水平翻转", action: #selector(flipClicked))
        actionRow.addArrangedSubview(rotateLeft)
        actionRow.addArrangedSubview(rotateRight)
        actionRow.addArrangedSubview(flip)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        actionRow.addArrangedSubview(spacer)

        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelClicked))
        cancel.bezelStyle = .rounded
        let pin = NSButton(title: "贴图", target: self, action: #selector(pinClicked))
        pin.bezelStyle = .rounded
        let done = NSButton(title: "完成", target: self, action: #selector(doneClicked))
        done.bezelStyle = .rounded
        done.keyEquivalent = ""
        done.contentTintColor = .controlAccentColor
        actionRow.addArrangedSubview(cancel)
        actionRow.addArrangedSubview(pin)
        actionRow.addArrangedSubview(done)

        let rows = NSStackView(views: [toolRow, actionRow])
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 6
        rows.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rows)

        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),

            rows.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            rows.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            rows.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            rows.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -6),
            actionRow.widthAnchor.constraint(equalTo: rows.widthAnchor),
        ])
        refreshStyle()
        setTool(.arrow)
    }

    private func makeToolButton(_ tool: AnnotationTool) -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = "\(tool.title)（\(shortcutHint(for: tool))）"
        if let image = NSImage(systemSymbolName: symbol(for: tool), accessibilityDescription: tool.title) {
            button.image = image
        } else {
            button.title = tool.title
        }
        button.tag = 0
        button.target = self
        button.action = #selector(toolClicked(_:))
        button.wantsLayer = true
        button.layer?.cornerRadius = 6
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        toolMap[button] = tool
        return button
    }

    private func symbol(for tool: AnnotationTool) -> String {
        switch tool {
        case .select: return "cursorarrow"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .arrow: return "arrow.up.right"
        case .line: return "line.diagonal"
        case .text: return "textformat"
        case .number: return "number.circle"
        case .pen: return "pencil.tip"
        case .highlighter: return "highlighter"
        case .mosaic: return "square.grid.3x3.fill"
        case .blur: return "circle.dashed"
        case .solid: return "square.fill"
        case .crop: return "crop"
        }
    }

    private func shortcutHint(for tool: AnnotationTool) -> String {
        switch tool {
        case .select: return "V"
        case .rectangle: return "R"
        case .ellipse: return "O"
        case .arrow: return "A"
        case .line: return "L"
        case .text: return "T"
        case .number: return "N"
        case .pen: return "P"
        case .highlighter: return "H"
        case .mosaic: return "M"
        case .blur: return "B"
        case .solid: return "S"
        case .crop: return "C"
        }
    }

    private func makeActionButton(symbol: String, tooltip: String, action: Selector) -> NSButton {
        let button = NSButton()
        configureIconButton(button, symbol: symbol, tooltip: tooltip)
        button.target = self
        button.action = action
        return button
    }

    private func configureIconButton(_ button: NSButton, symbol: String, tooltip: String) {
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = tooltip
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip) {
            button.image = image
        }
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        button.heightAnchor.constraint(equalToConstant: 26).isActive = true
    }

    private func makeTextButton(title: String, tag: Int) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(styleClicked(_:)))
        button.tag = tag
        button.bezelStyle = .rounded
        button.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return button
    }

    private func makeDivider() -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: 1).isActive = true
        view.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return view
    }

    // MARK: - Actions

    @objc private func toolClicked(_ sender: NSButton) {
        guard let tool = toolMap[sender] else { return }
        onToolChange?(tool)
        setTool(tool)
    }

    @objc private func styleClicked(_ sender: NSButton) {
        if let width = widthButtons.firstIndex(of: sender) {
            currentStyle.lineWidth = AnnotationStyle.lineWidths[width]
            refreshStyle()
            onLineWidthChange?(currentStyle.lineWidth)
            return
        }
        if let font = fontButtons.firstIndex(of: sender) {
            currentStyle.fontSize = AnnotationStyle.fontSizes[font]
            refreshStyle()
            onFontSizeChange?(currentStyle.fontSize)
        }
    }

    @objc private func undoClicked() { onUndo?() }
    @objc private func redoClicked() { onRedo?() }
    @objc private func applyCropClicked() { onApplyCrop?() }
    @objc private func rotateLeftClicked() { onRotateLeft?() }
    @objc private func rotateRightClicked() { onRotateRight?() }
    @objc private func flipClicked() { onFlip?() }
    @objc private func cancelClicked() { onCancel?() }
    @objc private func pinClicked() { onPin?() }
    @objc private func doneClicked() { onDone?() }

    // MARK: - State

    func setTool(_ tool: AnnotationTool) {
        currentTool = tool
        for (button, mapped) in toolMap {
            let selected = mapped == tool
            button.state = selected ? .on : .off
            button.contentTintColor = selected ? .controlAccentColor : .secondaryLabelColor
            button.layer?.backgroundColor =
                selected
                ? NSColor.controlAccentColor.withAlphaComponent(0.16).cgColor
                : NSColor.clear.cgColor
        }
    }

    func setStyle(_ style: AnnotationStyle) {
        currentStyle = style
        refreshStyle()
    }

    private func refreshStyle() {
        for (index, view) in colorViews.enumerated() {
            view.isSelected = AnnotationColor.palette[index] == currentStyle.color
        }
        for (index, button) in widthButtons.enumerated() {
            button.state = AnnotationStyle.lineWidths[index] == currentStyle.lineWidth ? .on : .off
        }
        for (index, button) in fontButtons.enumerated() {
            button.state = AnnotationStyle.fontSizes[index] == currentStyle.fontSize ? .on : .off
        }
    }

    func setHistory(canUndo: Bool, canRedo: Bool) {
        undoButton.isEnabled = canUndo
        redoButton.isEnabled = canRedo
        undoButton.alphaValue = canUndo ? 1 : 0.35
        redoButton.alphaValue = canRedo ? 1 : 0.35
    }

    func setCropAvailable(_ available: Bool) {
        applyCropButton.isEnabled = available
    }
}

@MainActor
final class ColorSwatchView: NSView {
    var onClick: (() -> Void)?
    var isSelected = false {
        didSet { needsDisplay = true }
    }
    private let color: NSColor

    init(color: NSColor) {
        self.color = color
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 18).isActive = true
        heightAnchor.constraint(equalToConstant: 18).isActive = true
        toolTip = "标注颜色"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 1.5, dy: 1.5))
        color.setFill()
        circle.fill()
        NSColor.separatorColor.withAlphaComponent(0.7).setStroke()
        circle.lineWidth = 1
        circle.stroke()
        if isSelected {
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5))
            NSColor.controlAccentColor.setStroke()
            ring.lineWidth = 2
            ring.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}
