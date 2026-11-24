import AppKit
import UDaSnapCore

/// 持有所有贴图，关一张释放一张。
@MainActor
final class PinStore {
    private(set) var pins: [PinWindowController] = []

    func add(_ pin: PinWindowController) {
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

    private let panel: PinPanel
    private let pinView: PinView
    private let image: CGImage
    /// 显示尺寸（point）。Retina 下图像像素是它的 2 倍，落盘不受影响。
    private let baseSize: NSSize
    private var onlyThisSpace = false
    private var pinned = true

    init(image: CGImage, origin: CGPoint, onScreen screen: NSScreen) {
        self.image = image

        // 显示尺寸 = 原始像素 / 屏的缩放比；超过屏 80% 时等比缩小显示。
        let scale = screen.backingScaleFactor
        var size = NSSize(
            width: CGFloat(image.width) / scale,
            height: CGFloat(image.height) / scale)
        let maxW = screen.frame.width * 0.8
        let maxH = screen.frame.height * 0.8
        let shrink = min(1, min(maxW / size.width, maxH / size.height))
        if shrink < 1 { size = NSSize(width: size.width * shrink, height: size.height * shrink) }
        self.baseSize = size

        let frame = NSRect(origin: origin, size: size)
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

    func show() {
        panel.orderFrontRegardless()
    }

    fileprivate func close() {
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
    }

    fileprivate var frame: NSRect { panel.frame }

    fileprivate func makeKey() {
        panel.makeKey()
        // 贴图面板是 nonactivating 的，不激活 app 的话键盘事件到不了它，
        // Delete / Backspace 删贴图就用不了。点一下贴图交给它收键。
        panel.makeFirstResponder(pinView)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - 交互代理

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
}

extension PinWindowController: PinViewDelegate {}

// MARK: - 图片视图：拖动 / 缩放 / 滚轮 / 菜单 / 键盘

@MainActor
final class PinView: NSView {

    fileprivate weak var delegate: PinViewDelegate?

    private enum Mode {
        case none, move
        case resize(Handle)
    }

    private let image: NSImage
    private var mode: Mode = .none
    private var startMouse: CGPoint = .zero
    private var startFrame: NSRect = .zero
    private var tracking: NSTrackingArea?
    private let minSide: CGFloat = 40
    private let grip: CGFloat = 7
    private var showClose = false
    private var dragged = false
    private var pressed = false

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
    /// 这里放行，保证鼠标落上去的第一下就能命中删除按钮。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
        if showClose { drawCloseButton() }
    }

    /// 右上角悬停删除按钮：鼠标进到角落附近才出现，不挡截图内容。
    private var closeRect: CGRect {
        CGRect(x: bounds.maxX - 26, y: bounds.maxY - 26, width: 18, height: 18)
    }

    private func drawCloseButton() {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = closeRect
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
        ctx.fillEllipse(in: r)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1)
        ctx.strokeEllipse(in: r)

        // 一个 ×
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(2)
        let inset: CGFloat = 5.5
        ctx.move(to: CGPoint(x: r.minX + inset, y: r.minY + inset))
        ctx.addLine(to: CGPoint(x: r.maxX - inset, y: r.maxY - inset))
        ctx.move(to: CGPoint(x: r.minX + inset, y: r.maxY - inset))
        ctx.addLine(to: CGPoint(x: r.maxX - inset, y: r.minY + inset))
        ctx.strokePath()
    }

    private func updateCloseVisibility(at p: CGPoint) {
        let shouldShow = closeRect.insetBy(dx: -4, dy: -4).contains(p)
        if shouldShow != showClose {
            showClose = shouldShow
            needsDisplay = true
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(tracking!)
    }

    // MARK: 光标

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds.insetBy(dx: grip, dy: grip), cursor: .arrow)
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        updateCloseVisibility(at: p)
        if closeRect.insetBy(dx: -4, dy: -4).contains(p) {
            NSCursor.arrow.set()
        } else if let h = handle(at: p) {
            h.cursor.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    override func mouseExited(with event: NSEvent) {
        if showClose {
            showClose = false
            needsDisplay = true
        }
    }

    private func handle(at p: CGPoint) -> Handle? {
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
        if event.clickCount == 2 {
            delegate?.close()
            return
        }

        let p = convert(event.locationInWindow, from: nil)
        if closeRect.insetBy(dx: -4, dy: -4).contains(p) {
            delegate?.close()
            return
        }
        mode = handle(at: p).map { Mode.resize($0) } ?? .move
        dragged = false
        pressed = true
        startMouse = NSEvent.mouseLocation
        startFrame = delegate?.frame ?? .zero
    }

    override func mouseDragged(with event: NSEvent) {
        guard let delegate else { return }
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
        if pressed && !dragged { delegate?.makeKey() }
        pressed = false
        dragged = false
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
