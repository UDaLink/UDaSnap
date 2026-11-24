import AppKit
import UDaSnapCore

/// 一次截图要拿来做什么。
enum CaptureMode {
    case pin  // 框选区域 → 生成贴图浮窗
    case save  // 框选区域 → 只复制 + 保存，不贴图
    case app  // 点选应用窗口 → 只复制 + 保存，不贴图
    case scroll  // 框选区域 → 自动滚动拼接长图
    case ocr  // 框选区域 → 保存原图并识别文字
    case ai  // 框选区域 → 保存原图并打开 AI 识别结果窗（不复制图片）
    case aiTranslate  // 框选区域 → 保存原图，智能合并换行后自动翻译
}

// MARK: - 会话控制

/// 一次截图会话：冻结所有屏 → 铺遮罩 → 框选 / 点选窗口 → 出图。
/// 区域框选限制在单块屏内（跨屏框选是二期项）；应用模式可选跨屏窗口。
@MainActor
final class RegionSelectionController: NSObject {

    private let pinStore: PinStore
    private lazy var scrollCapture = ScrollCaptureController()
    private var overlays: [OverlayWindow] = []
    private var images: [ObjectIdentifier: CGImage] = [:]
    private var windowSelector: WindowSelectionController?
    private var active = false
    private var mode: CaptureMode = .pin

    /// 截图模式保存完成后的回调（true 表示落盘成功），用来闪一下菜单栏图标。
    var onSaved: ((Bool) -> Void)?
    /// AI 结果窗里「打开 AI 设置」的入口，由 AppDelegate 注入。
    var onOpenAISettings: (() -> Void)?

    init(pinStore: PinStore) {
        self.pinStore = pinStore
    }

    func begin(mode: CaptureMode = .pin) {
        guard AppEnvironment.shared.compliance.isAccepted else { return }
        guard !active, !scrollCapture.isRunning else { return }

        // 未授权时绝不能开遮罩：① 系统授权弹窗会被全屏遮罩挡住；
        // ② 没权限时 CGDisplayCreateImage 返回的是**全黑图而不是 nil**，截出来就是一片黑。
        // 所以这里只走系统授权流程，授权成功后再按一次热键即可。
        guard CaptureService.hasPermission else {
            CaptureService.requestPermission()
            CaptureService.openPermissionSettings()
            return
        }

        self.mode = mode
        ScrollPreviewWindowController.shared.dismiss()
        switch mode {
        case .app:
            beginAppSelection()
        case .pin, .save, .scroll, .ocr, .ai, .aiTranslate:
            beginRegionSelection(mode: mode)
        }
    }

    private func beginAppSelection() {
        let selector = WindowSelectionController()
        windowSelector = selector
        active = true
        selector.onFinish = { [weak self] window in
            self?.finish(window: window)
        }
        selector.onCancel = { [weak self] in
            self?.teardown()
        }
        if !selector.begin() {
            windowSelector = nil
            active = false
        }
    }

    private func beginRegionSelection(mode: CaptureMode) {
        var captured: [(NSScreen, CGImage)] = []
        for screen in NSScreen.screens {
            if let img = CaptureService.capture(screen: screen) {
                captured.append((screen, img))
            }
        }
        guard !captured.isEmpty else { return }
        active = true

        let hint: String
        switch mode {
        case .pin:
            hint = "拖拽框选 · 松手贴图"
        case .save:
            hint = "拖拽框选 · 松手保存"
        case .scroll:
            hint = "拖拽框选滚动区域 · 松手自动滚动"
        case .ocr:
            hint = "拖拽框选文字区域 · 松手识字"
        case .ai:
            hint = "拖拽框选 · 松手 AI 识别"
        case .aiTranslate:
            hint = "拖拽框选 · 松手 AI 翻译"
        case .app:
            return
        }

        for (screen, image) in captured {
            let overlay = OverlayWindow(screen: screen, image: image, hint: hint)
            overlay.selectionView.onFinish = { [weak self] rect in
                self?.finish(rect: rect, screen: screen, image: image, mode: mode)
            }
            overlay.selectionView.onCancel = { [weak self] in self?.teardown() }
            overlays.append(overlay)
            images[ObjectIdentifier(overlay)] = image
            overlay.orderFrontRegardless()
        }

        // 只让鼠标所在那块屏成为 key，保证 Esc 与拖拽落在正确的窗口。
        let mouse = NSEvent.mouseLocation
        if let current = overlays.first(where: { $0.frame.contains(mouse) }) ?? overlays.first {
            current.makeKey()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func finish(window: WindowCandidate) {
        teardown()

        guard let image = CaptureService.captureWindow(id: window.id) else {
            NSSound.beep()
            HUDController.shared.show(
                title: "截图失败",
                detail: "窗口已关闭或受保护",
                at: NSEvent.mouseLocation,
                success: false
            )
            return
        }

        ScreenshotStorage.copyToClipboard(image)
        let saved = ScreenshotStorage.savePNG(image)
        let size = "\(window.contentPixelWidth) × \(window.contentPixelHeight)"

        if saved != nil {
            HUDController.shared.show(
                title: "已保存",
                detail: "\(window.appName)・\(size)",
                at: NSEvent.mouseLocation,
                success: true
            )
            onSaved?(true)
        } else {
            HUDController.shared.show(
                title: "保存失败",
                detail: "检查 ~/Pictures/UDaSnap 的写入权限",
                at: NSEvent.mouseLocation,
                success: false
            )
            onSaved?(false)
        }
    }

    private func finish(rect: CGRect, screen: NSScreen, image: CGImage, mode: CaptureMode) {
        guard let cropped = CaptureService.crop(image: image, selection: rect, screen: screen) else {
            teardown()
            return
        }
        teardown()

        if mode == .scroll {
            startScrollCapture(initialImage: cropped, rect: rect, screen: screen)
            return
        }

        if mode == .ocr {
            // 识字模式不复制图片，剪贴板只留识别出的文字；原图仍按统一规则落盘。
            let saved = ScreenshotStorage.savePNG(cropped)
            let point = NSEvent.mouseLocation
            HUDController.shared.show(title: "识别中", detail: "正在读取文字…", at: point, success: true)

            OCRService.recognize(image: cropped) { [weak self] result in
                switch result {
                case .text(let text):
                    if saved != nil { self?.onSaved?(true) }
                    OCRResultWindowController.present(text: text, savedImage: saved, at: point)
                case .noText:
                    if saved != nil { self?.onSaved?(true) }
                    HUDController.shared.show(
                        title: "未识别到文字",
                        detail: saved == nil ? "原图保存失败" : "原图已保存",
                        at: point,
                        success: false
                    )
                case .failed:
                    HUDController.shared.show(
                        title: "识别失败",
                        detail: saved == nil ? "原图保存失败" : "原图已保存",
                        at: point,
                        success: false
                    )
                }
            }
            return
        }

        if mode == .ai || mode == .aiTranslate {
            // AI 识别不复制图片到剪贴板；原图仍按统一规则落盘，窗口左侧显示原图。
            let saved = ScreenshotStorage.savePNG(cropped)
            onSaved?(saved != nil)
            let preview = NSImage(
                cgImage: cropped,
                size: NSSize(width: CGFloat(cropped.width), height: CGFloat(cropped.height))
            )
            AIResultWindowController.present(
                image: cropped,
                preview: preview,
                savedImage: saved,
                at: NSEvent.mouseLocation,
                autoTranslate: mode == .aiTranslate,
                openSettings: { [weak self] in self?.onOpenAISettings?() }
            )
            return
        }

        ScreenshotStorage.copyToClipboard(cropped)
        let saved = ScreenshotStorage.savePNG(cropped)

        switch mode {
        case .pin:
            let globalOrigin = CGPoint(
                x: screen.frame.minX + rect.minX,
                y: screen.frame.minY + rect.minY)
            let pin = PinWindowController(image: cropped, origin: globalOrigin, onScreen: screen)
            pinStore.add(pin)

        case .save:
            let size = "\(cropped.width) × \(cropped.height)"
            if saved != nil {
                HUDController.shared.show(title: "已保存", detail: size, at: NSEvent.mouseLocation, success: true)
                onSaved?(true)
            } else {
                HUDController.shared.show(
                    title: "保存失败", detail: "检查 ~/Pictures/UDaSnap 的写入权限",
                    at: NSEvent.mouseLocation, success: false)
                onSaved?(false)
            }

        case .app, .scroll, .ocr, .ai, .aiTranslate:
            break
        }
    }

    private func startScrollCapture(initialImage: CGImage, rect: CGRect, screen: NSScreen) {
        let center = CGPoint(
            x: screen.frame.minX + rect.midX,
            y: screen.frame.minY + rect.midY)
        let target = WindowCatalog.current(excluding: getpid()).first {
            $0.bounds.contains(center)
        }
        scrollCapture.onSaved = onSaved
        scrollCapture.start(
            initialImage: initialImage,
            screen: screen,
            selection: rect,
            targetPID: target?.ownerPID,
            targetName: target?.appName
        )
    }

    /// 撤回同意时中止所有选区、窗口选择和滚动会话。
    func cancelAll() {
        scrollCapture.cancel()
        teardown()
    }

    private func teardown() {
        windowSelector?.dismiss()
        windowSelector = nil
        for w in overlays { w.orderOut(nil) }
        overlays.removeAll()
        images.removeAll()
        active = false
    }
}

// MARK: - 遮罩窗口

@MainActor
final class OverlayWindow: NSWindow {
    let selectionView: SelectionView

    init(screen: NSScreen, image: CGImage, hint: String) {
        let view = SelectionView(
            frame: NSRect(origin: .zero, size: screen.frame.size),
            image: image,
            hint: hint)
        self.selectionView = view
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        self.contentView = view
        self.level = .screenSaver
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.ignoresMouseEvents = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.acceptsMouseMovedEvents = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { selectionView.onCancel?() }  // Esc
    }
}

// MARK: - 框选绘制与交互

@MainActor
final class SelectionView: NSView {

    var onFinish: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    private let image: CGImage
    private let hint: String
    private var dragStart: CGPoint?
    private var selection: CGRect = .zero
    private var mouse: CGPoint = .zero
    private var tracking: NSTrackingArea?

    init(frame: NSRect, image: CGImage, hint: String) {
        self.image = image
        self.hint = hint
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
            owner: self
        )
        addTrackingArea(tracking!)
    }

    // MARK: 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // 冻结画面铺满整屏，按 point 尺寸绘制（像素密度由 CGImage 自带）。
        ctx.draw(image, in: bounds)

        let hasSelection = selection.width > 1 && selection.height > 1

        // 选区外压暗 40%，选区内保持原样。
        ctx.saveGState()
        let dimPath = CGMutablePath()
        dimPath.addRect(bounds)
        if hasSelection { dimPath.addRect(selection) }
        ctx.addPath(dimPath)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.4).cgColor)
        ctx.drawPath(using: .eoFill)
        ctx.restoreGState()

        if hasSelection {
            drawSelectionChrome(ctx)
        } else {
            drawCrosshair(ctx)
            drawHint(hint, at: CGPoint(x: mouse.x + 18, y: mouse.y - 30))
        }
    }

    private func drawSelectionChrome(_ ctx: CGContext) {
        // 白描边 + 外侧一圈深色，保证浅底深底都看得清。
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.55).cgColor)
        ctx.setLineWidth(3)
        ctx.stroke(selection)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(selection)

        for point in Handle.allCases.map({ $0.point(in: selection) }) {
            let r = CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(r)
            ctx.setStrokeColor(NSColor.systemBlue.cgColor)
            ctx.setLineWidth(1)
            ctx.stroke(r)
        }

        // 尺寸用物理像素显示，Retina 上是 point 的 2 倍。
        let scale = CGFloat(image.width) / bounds.width
        let label = "\(Int(selection.width * scale)) × \(Int(selection.height * scale))"
        var origin = CGPoint(x: selection.minX, y: selection.maxY + 10)
        if origin.y > bounds.height - 30 { origin.y = selection.minY - 32 }
        drawHint(label, at: origin)
    }

    private func drawCrosshair(_ ctx: CGContext) {
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.65).cgColor)
        ctx.setLineWidth(0.5)
        ctx.move(to: CGPoint(x: 0, y: mouse.y))
        ctx.addLine(to: CGPoint(x: bounds.width, y: mouse.y))
        ctx.move(to: CGPoint(x: mouse.x, y: 0))
        ctx.addLine(to: CGPoint(x: mouse.x, y: bounds.height))
        ctx.strokePath()
    }

    private func drawHint(_ text: String, at origin: CGPoint) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let size = str.size()
        let pad: CGFloat = 6
        let bg = CGRect(x: origin.x, y: origin.y, width: size.width + pad * 2, height: size.height + pad * 2)
        let clamped = CGRect(
            x: min(max(0, bg.minX), bounds.width - bg.width),
            y: min(max(0, bg.minY), bounds.height - bg.height),
            width: bg.width, height: bg.height
        )
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: clamped, xRadius: 5, yRadius: 5).fill()
        str.draw(at: CGPoint(x: clamped.minX + pad, y: clamped.minY + pad))
    }

    // MARK: 交互

    override func mouseMoved(with event: NSEvent) {
        mouse = convert(event.locationInWindow, from: nil)
        NSCursor.crosshair.set()
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        dragStart = p
        mouse = p
        selection = CGRect(x: p.x, y: p.y, width: 0, height: 0)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        var p = convert(event.locationInWindow, from: nil)
        p.x = min(max(0, p.x), bounds.width)
        p.y = min(max(0, p.y), bounds.height)
        mouse = p
        selection = CGRect(
            x: min(start.x, p.x), y: min(start.y, p.y),
            width: abs(p.x - start.x), height: abs(p.y - start.y)
        )
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil }
        guard selection.width >= 4, selection.height >= 4 else {
            selection = .zero  // 误点，不完成，重新框
            needsDisplay = true
            return
        }
        onFinish?(selection)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() }
        if event.keyCode == 36, selection.width >= 4, selection.height >= 4 {
            onFinish?(selection)
        }
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }
}

/// 选区与贴图缩放共用的 8 热区定义。
enum Handle: CaseIterable {
    case nw, n, ne, e, se, s, sw, w

    func point(in rect: CGRect) -> CGPoint {
        switch self {
        case .nw: return CGPoint(x: rect.minX, y: rect.maxY)
        case .n: return CGPoint(x: rect.midX, y: rect.maxY)
        case .ne: return CGPoint(x: rect.maxX, y: rect.maxY)
        case .e: return CGPoint(x: rect.maxX, y: rect.midY)
        case .se: return CGPoint(x: rect.maxX, y: rect.minY)
        case .s: return CGPoint(x: rect.midX, y: rect.minY)
        case .sw: return CGPoint(x: rect.minX, y: rect.minY)
        case .w: return CGPoint(x: rect.minX, y: rect.midY)
        }
    }

    var cursor: NSCursor {
        switch self {
        case .n, .s: return .resizeUpDown
        case .e, .w: return .resizeLeftRight
        case .nw, .se:
            return NSCursor(
                image: NSImage(
                    systemSymbolName: "arrow.up.left.and.arrow.down.right",
                    variableValue: 1.0,
                    accessibilityDescription: nil) ?? NSImage(),
                hotSpot: NSPoint(x: 8, y: 8))
        case .ne, .sw:
            return NSCursor(
                image: NSImage(
                    systemSymbolName: "arrow.up.right.and.arrow.down.left",
                    variableValue: 1.0,
                    accessibilityDescription: nil) ?? NSImage(),
                hotSpot: NSPoint(x: 8, y: 8))
        }
    }
}
