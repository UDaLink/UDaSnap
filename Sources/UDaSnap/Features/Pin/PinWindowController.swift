import AppKit
import UDaSnapCore

/// 贴图浮窗的动作入口，由 AppDelegate 注入。
@MainActor
struct PinActions {
    let annotate: (PinWindowController) -> Void
    let ocr: (PinWindowController) -> Void
    let aiAnalyze: (PinWindowController) -> Void
    let translate: (PinWindowController) -> Void
}

/// 持有所有贴图，关一张释放一张。
@MainActor
final class PinStore {
    private(set) var pins: [PinWindowController] = []
    var actions: PinActions?

    func add(_ pin: PinWindowController) {
        pin.actions = actions
        pins.append(pin)
        pin.onClose = { [weak self, weak pin] in
            guard let pin else { return }
            self?.pins.removeAll { $0 === pin }
        }
        pin.show()
    }

    /// 撤回同意时关闭全部贴图浮窗。
    func closeAll() {
        let all = pins
        pins.removeAll()
        for pin in all {
            pin.close()
        }
    }

    var count: Int { pins.count }
}

// MARK: - 浮窗

@MainActor
final class PinPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PinWindowController: NSObject {

    var onClose: (() -> Void)?
    var actions: PinActions?

    private let panel: PinPanel
    private let pinView: PinView
    private let image: CGImage
    private let savedURL: URL?
    private let clipboardData: Data?
    private let sourceScreen: NSScreen
    private var onlyThisSpace = false
    private var pinned = true
    private var rail: PinActionRailController?
    private var railHideWorkItem: DispatchWorkItem?
    private var railHovered = false

    init(
        image: CGImage,
        savedURL: URL?,
        clipboardData: Data?,
        origin: CGPoint,
        onScreen screen: NSScreen
    ) {
        self.image = image
        self.savedURL = savedURL
        self.clipboardData = clipboardData
        self.sourceScreen = screen

        // 显示尺寸 = 原始像素 / 屏的缩放比；超过屏 80% 时等比缩小显示。
        let scale = screen.backingScaleFactor
        var size = NSSize(
            width: CGFloat(image.width) / scale,
            height: CGFloat(image.height) / scale)
        let maxW = screen.frame.width * 0.8
        let maxH = screen.frame.height * 0.8
        let shrink = min(1, min(maxW / size.width, maxH / size.height))
        if shrink < 1 { size = NSSize(width: size.width * shrink, height: size.height * shrink) }
        var frame = NSRect(origin: origin, size: size)
        let visible = screen.visibleFrame
        let maxX = max(visible.minX + 20, visible.maxX - frame.width - 20)
        let maxY = max(visible.minY + 20, visible.maxY - frame.height - 20)
        frame.origin.x = min(max(frame.origin.x, visible.minX + 20), maxX)
        frame.origin.y = min(max(frame.origin.y, visible.minY + 20), maxY)

        panel = PinPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false  // 拖动由 PinView 自己处理
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.acceptsMouseMovedEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        pinView = PinView(frame: NSRect(origin: .zero, size: size), image: image)
        panel.contentView = pinView
        super.init()

        pinView.delegate = self
    }

    var sourceImage: CGImage { image }
    var sourceScreenForAnnotation: NSScreen { panel.screen ?? sourceScreen }
    var currentFrame: NSRect { panel.frame }
    var contentScaleForAnnotation: CGFloat {
        CGFloat(image.width) / max(panel.frame.width, 1)
    }
    var savedImageURL: URL? { savedURL }

    func show() {
        panel.orderFrontRegardless()
    }

    func close() {
        rail?.hide()
        rail = nil
        panel.close()
        onClose?()
    }

    fileprivate func copy() {
        ScreenshotStorage.copyToClipboard(image)
    }

    fileprivate func saveAs() {
        NSApp.activate(ignoringOtherApps: true)
        let sp = NSSavePanel()
        sp.allowedContentTypes = [.png]
        sp.nameFieldStringValue = ScreenshotStorage.timestampName() + ".png"
        sp.directoryURL = ScreenshotStorage.folder
        if sp.runModal() == .OK, let url = sp.url {
            ScreenshotStorage.savePNG(image, to: url)
        }
    }

    fileprivate func setAlpha(_ value: CGFloat) {
        panel.alphaValue = value
    }

    fileprivate func toggleSpace() {
        onlyThisSpace.toggle()
        panel.collectionBehavior =
            onlyThisSpace
            ? [.ignoresCycle]
            : [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    }

    fileprivate func togglePinned() {
        pinned.toggle()
        panel.level = pinned ? .floating : .normal
    }

    fileprivate func setFrame(_ frame: NSRect) {
        panel.setFrame(frame, display: true)
        updateRailFrame()
    }

    fileprivate var frame: NSRect { panel.frame }

    fileprivate func makeKey() {
        panel.makeKey()
        // 贴图面板是 nonactivating 的，不激活 app 的话键盘事件到不了它，
        // Delete / Backspace 删贴图就用不了。点一下贴图交给它收键。
        panel.makeFirstResponder(pinView)
        NSApp.activate(ignoringOtherApps: true)
    }

    fileprivate func hoverChanged(_ hovering: Bool) {
        if hovering {
            showRail()
        } else {
            scheduleHideRail()
        }
    }

    fileprivate func openFile() {
        guard let savedURL else {
            ScreenshotStorage.revealFolder()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([savedURL])
    }

    fileprivate func deleteScreenshot() {
        if let savedURL {
            try? FileManager.default.removeItem(at: savedURL)
        }
        ScreenshotStorage.clearClipboard(ifMatching: clipboardData)
        close()
    }

    fileprivate func annotate() {
        actions?.annotate(self)
    }

    fileprivate func ocr() {
        actions?.ocr(self)
    }

    fileprivate func aiAnalyze() {
        actions?.aiAnalyze(self)
    }

    fileprivate func translate() {
        actions?.translate(self)
    }

    private func showRail() {
        railHideWorkItem?.cancel()
        railHideWorkItem = nil
        guard actions != nil else { return }
        if rail == nil {
            let controller = PinActionRailController(
                ocr: { [weak self] in self?.ocr() },
                aiAnalyze: { [weak self] in self?.aiAnalyze() },
                translate: { [weak self] in self?.translate() }
            )
            controller.onHoverChanged = { [weak self] hovering in
                self?.railHovered = hovering
                if hovering {
                    self?.railHideWorkItem?.cancel()
                    self?.railHideWorkItem = nil
                } else {
                    self?.scheduleHideRail()
                }
            }
            rail = controller
        }
        updateRailFrame()
        rail?.show()
    }

    private func scheduleHideRail() {
        railHideWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.railHovered else { return }
            self.rail?.hide()
        }
        railHideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func updateRailFrame() {
        guard let rail else { return }
        rail.setFrame(relativeTo: panel.frame, screen: panel.screen ?? sourceScreen)
    }
}

extension PinWindowController: PinViewDelegate {}

// MARK: - 图片视图：拖动 / 缩放 / 滚轮 / 菜单 / 键盘

@MainActor
private protocol PinViewDelegate: AnyObject {
    func close()
    func copy()
    func saveAs()
    func setAlpha(_ value: CGFloat)
    func toggleSpace()
    func togglePinned()
    func setFrame(_ frame: NSRect)
    var frame: NSRect { get }
    func makeKey()
    func openFile()
    func deleteScreenshot()
    func annotate()
    func hoverChanged(_ hovering: Bool)
}

private enum PinHandle {
    case n, s, e, w, nw, ne, sw, se

    var cursor: NSCursor {
        switch self {
        case .n, .s: return .resizeUpDown
        case .e, .w: return .resizeLeftRight
        case .nw, .se: return .crosshair
        case .ne, .sw: return .crosshair
        }
    }
}

@MainActor
final class PinView: NSView {

    fileprivate weak var delegate: PinViewDelegate?

    private enum Mode {
        case none, move
        case resize(PinHandle)
    }

    private let image: NSImage
    private var mode: Mode = .none
    private var startMouse: CGPoint = .zero
    private var startFrame: NSRect = .zero
    private var tracking: NSTrackingArea?
    private let minSide: CGFloat = 40
    private let grip: CGFloat = 7
    private var showControls = false
    private var draggingControls = false
    private var dragged = false
    private var pressed = false

    private let iconSize: CGFloat = 24
    private let iconInset: CGFloat = 6

    init(frame: NSRect, image cg: CGImage) {
        // 用像素尺寸建 NSImage；draw(in:) 会按 bounds 等比铺满，Retina 细节不丢。
        self.image = NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width), height: CGFloat(cg.height)))
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.black.withAlphaComponent(0.18).cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }

    /// 贴图是 nonactivating 浮窗，默认第一次点击只会被当成"激活窗口"吞掉。
    /// 这里放行，保证鼠标落上去的第一下就能命中角落按钮。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
        if showControls {
            drawControl(in: deleteRect, symbol: "trash")
            drawControl(in: closeRect, symbol: "xmark")
            drawControl(in: openRect, symbol: "folder")
            drawControl(in: annotateRect, symbol: "pencil")
        }
    }

    private var deleteRect: NSRect {
        NSRect(x: iconInset, y: bounds.maxY - iconInset - iconSize, width: iconSize, height: iconSize)
    }
    private var closeRect: NSRect {
        NSRect(
            x: bounds.maxX - iconInset - iconSize, y: bounds.maxY - iconInset - iconSize,
            width: iconSize, height: iconSize)
    }
    private var openRect: NSRect {
        NSRect(
            x: bounds.maxX - iconInset - iconSize, y: iconInset, width: iconSize, height: iconSize)
    }
    private var annotateRect: NSRect {
        NSRect(x: iconInset, y: iconInset, width: iconSize, height: iconSize)
    }

    private enum CornerAction {
        case delete, close, open, annotate
    }

    private func action(at point: NSPoint) -> CornerAction? {
        if deleteRect.contains(point) { return .delete }
        if closeRect.contains(point) { return .close }
        if openRect.contains(point) { return .open }
        if annotateRect.contains(point) { return .annotate }
        return nil
    }

    private func drawControl(in rect: NSRect, symbol: String) {
        let background = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
        NSColor.black.withAlphaComponent(0.6).setFill()
        background.fill()
        NSColor.white.withAlphaComponent(0.28).setStroke()
        background.lineWidth = 0.5
        background.stroke()

        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        guard
            let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
        else { return }
        let tinted = Self.tinted(base, color: .white)
        tinted.draw(in: rect.insetBy(dx: 5, dy: 5), from: .zero, operation: .sourceOver, fraction: 1)
    }

    private static func tinted(_ image: NSImage, color: NSColor) -> NSImage {
        let result = NSImage(size: image.size)
        result.lockFocus()
        let rect = NSRect(origin: .zero, size: image.size)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        color.set()
        rect.fill(using: .sourceIn)
        result.unlockFocus()
        return result
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(tracking!)
    }

    // MARK: 光标

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds.insetBy(dx: grip, dy: grip), cursor: .arrow)
    }

    private func setControlsVisible(_ visible: Bool) {
        guard showControls != visible else { return }
        showControls = visible
        needsDisplay = true
        delegate?.hoverChanged(visible)
    }

    override func mouseEntered(with event: NSEvent) {
        setControlsVisible(true)
    }

    override func mouseMoved(with event: NSEvent) {
        setControlsVisible(true)
        let p = convert(event.locationInWindow, from: nil)
        if action(at: p) != nil {
            NSCursor.arrow.set()
        } else if let h = handle(at: p) {
            h.cursor.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    override func mouseExited(with event: NSEvent) {
        setControlsVisible(false)
    }

    private func handle(at p: CGPoint) -> PinHandle? {
        let nearL = p.x <= grip
        let nearR = p.x >= bounds.width - grip
        let nearB = p.y <= grip
        let nearT = p.y >= bounds.height - grip
        switch (nearL, nearR, nearB, nearT) {
        case (true, _, true, _): return .sw
        case (true, _, _, true): return .nw
        case (_, true, true, _): return .se
        case (_, true, _, true): return .ne
        case (true, _, _, _): return .w
        case (_, true, _, _): return .e
        case (_, _, true, _): return .s
        case (_, _, _, true): return .n
        default: return nil
        }
    }

    // MARK: 移动与自由缩放

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if showControls, let action = action(at: p) {
            draggingControls = true
            switch action {
            case .delete: delegate?.deleteScreenshot()
            case .close: delegate?.close()
            case .open: delegate?.openFile()
            case .annotate: delegate?.annotate()
            }
            return
        }
        if event.clickCount == 2 {
            delegate?.close()
            return
        }

        mode = handle(at: p).map { Mode.resize($0) } ?? .move
        dragged = false
        pressed = true
        draggingControls = false
        startMouse = NSEvent.mouseLocation
        startFrame = delegate?.frame ?? .zero
    }

    override func mouseDragged(with event: NSEvent) {
        guard let delegate, !draggingControls else { return }
        dragged = true
        let now = NSEvent.mouseLocation
        let dx = now.x - startMouse.x
        let dy = now.y - startMouse.y
        var f = startFrame

        switch mode {
        case .none: return
        case .move:
            f.origin = CGPoint(x: startFrame.origin.x + dx, y: startFrame.origin.y + dy)
        case .resize(let h):
            // 只动该热区负责的边，另一条边保持不动，所以是自由比例。
            if h == .e || h == .ne || h == .se {
                f.size.width = max(minSide, startFrame.width + dx)
            }
            if h == .w || h == .nw || h == .sw {
                let w = max(minSide, startFrame.width - dx)
                f.origin.x = startFrame.maxX - w
                f.size.width = w
            }
            if h == .n || h == .nw || h == .ne {
                f.size.height = max(minSide, startFrame.height + dy)
            }
            if h == .s || h == .sw || h == .se {
                let ht = max(minSide, startFrame.height - dy)
                f.origin.y = startFrame.maxY - ht
                f.size.height = ht
            }
        }
        delegate.setFrame(f)
    }

    /// 只有"点一下没拖动"才把键盘焦点交给这张贴图，这样拖动贴图不会抢走
    /// 别的 app 的焦点，而单击之后 Delete / Backspace / Cmd+C 又能用。
    override func mouseUp(with event: NSEvent) {
        if !draggingControls && pressed && !dragged { delegate?.makeKey() }
        pressed = false
        dragged = false
        draggingControls = false
        mode = .none
    }

    // MARK: 滚轮等比缩放，锚定鼠标

    override func scrollWheel(with event: NSEvent) {
        guard let delegate else { return }
        let f = delegate.frame
        let loc = convert(event.locationInWindow, from: nil)
        let unitX = loc.x / max(f.width, 1)
        let unitY = loc.y / max(f.height, 1)

        let factor = max(0.9, min(1.1, 1 + event.scrollingDeltaY * 0.01))
        var w = f.width * factor
        var h = f.height * factor
        if w < minSide || h < minSide {
            let up = max(minSide / max(w, 1), minSide / max(h, 1))
            w *= up
            h *= up
        }
        let mouse = NSEvent.mouseLocation
        delegate.setFrame(
            NSRect(
                x: mouse.x - unitX * w,
                y: mouse.y - unitY * h,
                width: w, height: h
            ))
    }

    // MARK: 键盘

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            delegate?.close()
            return
        }  // Esc
        if event.keyCode == 51 || event.keyCode == 117 {  // Delete / Fn+Delete
            delegate?.close()
            return
        }
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "c":
                delegate?.copy()
                return
            case "s":
                delegate?.saveAs()
                return
            default: break
            }
        }
        super.keyDown(with: event)
    }

    // MARK: 右键菜单

    override func rightMouseDown(with event: NSEvent) {
        delegate?.makeKey()
        let menu = NSMenu()

        let copy = NSMenuItem(title: "复制", action: #selector(menuCopy), keyEquivalent: "c")
        copy.target = self
        menu.addItem(copy)

        let save = NSMenuItem(title: "另存为…", action: #selector(menuSave), keyEquivalent: "s")
        save.target = self
        menu.addItem(save)

        let alphaItem = NSMenuItem(title: "透明度", action: nil, keyEquivalent: "")
        let alphaMenu = NSMenu()
        for v in [100, 80, 60, 40, 20] {
            let it = NSMenuItem(title: "\(v)%", action: #selector(menuAlpha(_:)), keyEquivalent: "")
            it.tag = v
            it.target = self
            alphaMenu.addItem(it)
        }
        alphaItem.submenu = alphaMenu
        menu.addItem(alphaItem)

        let space = NSMenuItem(title: "仅当前桌面", action: #selector(menuSpace), keyEquivalent: "")
        space.target = self
        menu.addItem(space)

        let pin = NSMenuItem(title: "置顶开关", action: #selector(menuPin), keyEquivalent: "")
        pin.target = self
        menu.addItem(pin)

        menu.addItem(.separator())
        let close = NSMenuItem(title: "关闭", action: #selector(menuClose), keyEquivalent: "")
        close.target = self
        menu.addItem(close)

        menu.popUp(positioning: nil, at: convert(event.locationInWindow, from: nil), in: self)
    }

    @objc private func menuCopy() { delegate?.copy() }
    @objc private func menuSave() { delegate?.saveAs() }
    @objc private func menuClose() { delegate?.close() }
    @objc private func menuSpace() { delegate?.toggleSpace() }
    @objc private func menuPin() { delegate?.togglePinned() }
    @objc private func menuAlpha(_ item: NSMenuItem) {
        delegate?.setAlpha(CGFloat(item.tag) / 100)
    }
}

// MARK: - 贴图右侧外部动作条

@MainActor
private final class PinActionRailController {
    var onHoverChanged: ((Bool) -> Void)?

    private let panel: NSPanel
    private let content: PinActionRailView

    init(ocr: @escaping () -> Void, aiAnalyze: @escaping () -> Void, translate: @escaping () -> Void) {
        content = PinActionRailView(ocr: ocr, aiAnalyze: aiAnalyze, translate: translate)
        let size = content.intrinsicContentSize
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.contentView = content
        content.onHoverChanged = { [weak self] hovering in
            self?.onHoverChanged?(hovering)
        }
    }

    var frame: NSRect { panel.frame }

    func show() {
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    func setFrame(relativeTo pinFrame: NSRect, screen: NSScreen) {
        let visible = screen.visibleFrame
        let size = panel.frame.size
        var x = pinFrame.maxX + 8
        if x + size.width > visible.maxX - 8 {
            x = pinFrame.minX - size.width - 8
        }
        x = min(max(x, visible.minX + 8), max(visible.minX + 8, visible.maxX - size.width - 8))
        var y = pinFrame.minY
        y = min(max(y, visible.minY + 8), max(visible.minY + 8, visible.maxY - size.height - 8))
        panel.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true)
    }
}

@MainActor
private final class PinActionRailView: NSView {
    var onHoverChanged: ((Bool) -> Void)?

    private let ocrHandler: () -> Void
    private let aiHandler: () -> Void
    private let translateHandler: () -> Void
    private var tracking: NSTrackingArea?

    init(ocr: @escaping () -> Void, aiAnalyze: @escaping () -> Void, translate: @escaping () -> Void) {
        self.ocrHandler = ocr
        self.aiHandler = aiAnalyze
        self.translateHandler = translate
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.94).cgColor
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.cgColor

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 5
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let ocrButton = makeButton(title: "文字提取（OCR）", action: #selector(ocrClicked))
        ocrButton.target = self
        let aiButton = makeButton(title: "文字提取-AI分析", action: #selector(aiClicked))
        aiButton.target = self
        let translateButton = makeButton(title: "立即翻译", action: #selector(translateClicked))
        translateButton.target = self
        stack.addArrangedSubview(ocrButton)
        stack.addArrangedSubview(aiButton)
        stack.addArrangedSubview(translateButton)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 128, height: 6 + 26 + 5 + 26 + 5 + 26 + 6)
    }

    private func makeButton(title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: nil, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11, weight: .medium)
        button.alignment = .center
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return button
    }

    @objc private func ocrClicked() { ocrHandler() }
    @objc private func aiClicked() { aiHandler() }
    @objc private func translateClicked() { translateHandler() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(tracking!)
    }

    override func mouseEntered(with event: NSEvent) { onHoverChanged?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChanged?(false) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
