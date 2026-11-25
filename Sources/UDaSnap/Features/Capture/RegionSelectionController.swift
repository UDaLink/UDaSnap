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
    case annotate  // 框选区域 → 打开标注编辑器，不直接保存
    case annotateWindow  // 点选窗口 → 打开标注编辑器
    case immediate  // 框选后保留选区 → 标注 / 贴图 / 取消
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
    /// 截图完成后进入标注编辑器的入口：(原图, 像素密度, 全局原点, 所在屏幕)。
    var onAnnotate: ((CGImage, CGFloat, CGPoint, NSScreen) -> Void)?

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
        case .app, .annotateWindow:
            beginAppSelection()
        case .pin, .save, .scroll, .ocr, .ai, .aiTranslate, .annotate, .immediate:
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
        ScreenshotThumbnailCenter.shared.hideForCapture()
        for screen in NSScreen.screens {
            if let img = CaptureService.capture(screen: screen) {
                captured.append((screen, img))
            }
        }
        ScreenshotThumbnailCenter.shared.restoreAfterCapture()
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
        case .annotate:
            hint = "拖拽框选 · 松手进入标注"
        case .immediate:
            hint = "拖拽框选 · 松手选择标注或贴图"
        case .annotateWindow, .app:
            return
        }

        for (screen, image) in captured {
            let overlay = OverlayWindow(
                screen: screen,
                image: image,
                hint: hint,
                showsActionBar: mode == .immediate)
            if mode == .immediate {
                overlay.selectionView.onImmediateAction = { [weak self] action, rect in
                    self?.finishImmediate(
                        action: action, rect: rect, screen: screen, image: image)
                }
            } else {
                overlay.selectionView.onFinish = { [weak self] rect in
                    self?.finish(rect: rect, screen: screen, image: image, mode: mode)
                }
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
            current.makeFirstResponder(current.selectionView)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func finish(window: WindowCandidate) {
        teardown()

        ScreenshotThumbnailCenter.shared.hideForCapture()
        let image = CaptureService.captureWindow(id: window.id)
        ScreenshotThumbnailCenter.shared.restoreAfterCapture()
        guard let image else {
            NSSound.beep()
            HUDController.shared.show(
                title: "截图失败",
                detail: "窗口已关闭或受保护",
                at: NSEvent.mouseLocation,
                success: false
            )
            return
        }

        let screen =
            NSScreen.screens.first {
                $0.frame.contains(
                    CGPoint(x: window.bounds.midX, y: window.bounds.midY))
            } ?? NSScreen.main ?? NSScreen.screens[0]
        let pixelScale = CGFloat(image.width) / max(window.bounds.width, 1)

        if mode == .annotateWindow {
            onAnnotate?(image, pixelScale, window.bounds.origin, screen)
            return
        }

        let clipboardData = ScreenshotStorage.copyToClipboard(image)
        let saved = ScreenshotStorage.savePNG(image)
        let size = "\(window.contentPixelWidth) × \(window.contentPixelHeight)"

        if saved != nil {
            HUDController.shared.show(
                title: "已保存",
                detail: "\(window.appName)・\(size)",
                at: NSEvent.mouseLocation,
                success: true
            )
            ScreenshotThumbnailCenter.shared.show(
                ScreenshotThumbnailItem(
                    image: image,
                    savedURL: saved,
                    clipboardData: clipboardData,
                    screen: screen,
                    contentScale: pixelScale,
                    pinOrigin: window.bounds.origin,
                    createdAt: Date()
                ))
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

        if mode == .annotate {
            presentAnnotator(image: cropped, rect: rect, screen: screen)
            return
        }

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

        switch mode {
        case .pin:
            commitPin(image: cropped, rect: rect, screen: screen)

        case .save:
            commitSave(image: cropped, rect: rect, screen: screen)

        case .app, .scroll, .ocr, .ai, .aiTranslate, .annotate, .annotateWindow, .immediate:
            break
        }
    }

    /// “立即截图”的保留选区操作。只有真正执行标注 / 贴图 / 保存时才裁剪并收起遮罩，
    /// 取消操作直接结束，不产生截图文件，也不碰剪贴板。
    private func finishImmediate(
        action: ImmediateSelectionAction, rect: CGRect, screen: NSScreen, image: CGImage
    ) {
        if action == .cancel {
            teardown()
            return
        }

        guard let cropped = CaptureService.crop(image: image, selection: rect, screen: screen) else {
            NSSound.beep()
            teardown()
            return
        }
        teardown()

        switch action {
        case .annotate:
            presentAnnotator(image: cropped, rect: rect, screen: screen)
        case .pin:
            commitPin(image: cropped, rect: rect, screen: screen)
        case .save:
            commitSave(image: cropped, rect: rect, screen: screen)
        case .cancel:
            break
        }
    }

    private func presentAnnotator(image: CGImage, rect: CGRect, screen: NSScreen) {
        let pixelScale = CGFloat(image.width) / max(rect.width, 1)
        let origin = CGPoint(
            x: screen.frame.minX + rect.minX,
            y: screen.frame.minY + rect.minY)
        onAnnotate?(image, pixelScale, origin, screen)
    }

    /// 和现有“截图并贴图”一致：复制、落盘，再以选区全局原点生成贴图。
    private func commitPin(image: CGImage, rect: CGRect, screen: NSScreen) {
        let clipboardData = ScreenshotStorage.copyToClipboard(image)
        let saved = ScreenshotStorage.savePNG(image)
        let globalOrigin = CGPoint(
            x: screen.frame.minX + rect.minX,
            y: screen.frame.minY + rect.minY)
        let pin = PinWindowController(
            image: image,
            savedURL: saved,
            clipboardData: clipboardData,
            origin: globalOrigin,
            onScreen: screen)
        pinStore.add(pin)
    }

    /// 和现有“框选截图”一致：复制、落盘、HUD 与右下角缩略图。
    private func commitSave(image: CGImage, rect: CGRect, screen: NSScreen) {
        let clipboardData = ScreenshotStorage.copyToClipboard(image)
        let saved = ScreenshotStorage.savePNG(image)
        if saved != nil {
            let size = "\(image.width) × \(image.height)"
            HUDController.shared.show(
                title: "已保存", detail: size, at: NSEvent.mouseLocation, success: true)
            let pixelScale = CGFloat(image.width) / max(rect.width, 1)
            let origin = CGPoint(
                x: screen.frame.minX + rect.minX,
                y: screen.frame.minY + rect.minY)
            ScreenshotThumbnailCenter.shared.show(
                ScreenshotThumbnailItem(
                    image: image,
                    savedURL: saved,
                    clipboardData: clipboardData,
                    screen: screen,
                    contentScale: pixelScale,
                    pinOrigin: origin,
                    createdAt: Date()
                ))
            onSaved?(true)
        } else {
            HUDController.shared.show(
                title: "保存失败", detail: "检查 ~/Pictures/UDaSnap 的写入权限",
                at: NSEvent.mouseLocation, success: false)
            onSaved?(false)
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

    init(screen: NSScreen, image: CGImage, hint: String, showsActionBar: Bool = false) {
        let view = SelectionView(
            frame: NSRect(origin: .zero, size: screen.frame.size),
            image: image,
            hint: hint,
            showsActionBar: showsActionBar)
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
        if event.keyCode == 53 {
            selectionView.onCancel?()
            return
        }
        if event.keyCode == 36 || event.keyCode == 76 {
            selectionView.handleReturnKey()
            return
        }
        super.keyDown(with: event)
    }
}

// MARK: - 框选绘制与交互

@MainActor
final class SelectionView: NSView {

    var onFinish: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?
    var onImmediateAction: ((ImmediateSelectionAction, CGRect) -> Void)?

    private enum DragMode: Equatable {
        case newSelection
        case move
        case resize(Handle)
    }

    private let image: CGImage
    private let hint: String
    private let showsActionBar: Bool
    private let actionBar: ImmediateSelectionBarView?
    private var dragStart: CGPoint?
    private var dragMode: DragMode?
    private var initialRect: CGRect = .zero
    private var initialPoint: CGPoint = .zero
    private var selection: CGRect = .zero
    private var selectionIsComplete = false
    private var actionBarInsideSelection = false
    private var mouse: CGPoint = .zero
    private var tracking: NSTrackingArea?

    init(frame: NSRect, image: CGImage, hint: String, showsActionBar: Bool = false) {
        self.image = image
        self.hint = hint
        self.showsActionBar = showsActionBar
        self.actionBar = showsActionBar ? ImmediateSelectionBarView(frame: .zero) : nil
        super.init(frame: frame)
        if let actionBar {
            actionBar.onAction = { [weak self] action in
                self?.handleAction(action)
            }
            actionBar.isHidden = true
            addSubview(actionBar)
        }
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

        var origin: CGPoint
        if selectionIsComplete {
            // 完成后操作条在选区外，尺寸标签收进选区左上角，避免和操作条抢位置。
            if actionBarInsideSelection {
                origin = CGPoint(x: selection.minX + 8, y: selection.minY + 8)
            } else {
                origin = CGPoint(x: selection.minX + 8, y: selection.maxY - 28)
            }
        } else {
            origin = CGPoint(x: selection.minX, y: selection.maxY + 10)
            if origin.y > bounds.height - 30 { origin.y = selection.minY - 32 }
        }
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
        updateCursor(at: mouse)
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        window?.makeFirstResponder(self)
        mouse = p

        guard showsActionBar else {
            beginNewSelection(at: p)
            return
        }

        if !actionBarInsideSelection, let actionBar, !actionBar.isHidden,
            actionBar.frame.contains(p)
        {
            return
        }

        if selectionIsComplete, selection.width >= 4, selection.height >= 4 {
            if let handle = handle(at: p) {
                dragMode = .resize(handle)
                initialRect = selection
                initialPoint = p
                dragStart = p
                NSCursor.closedHand.set()
                return
            }
            if selection.contains(p) {
                dragMode = .move
                initialRect = selection
                initialPoint = p
                dragStart = p
                NSCursor.closedHand.set()
                return
            }
        }

        // 点选区外的空白处：立即清掉旧选区，开始新一次拖拽。
        beginNewSelection(at: p)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let mode = dragMode else { return }
        var p = convert(event.locationInWindow, from: nil)
        p.x = min(max(0, p.x), bounds.width)
        p.y = min(max(0, p.y), bounds.height)
        mouse = p

        switch mode {
        case .newSelection:
            guard let start = dragStart else { return }
            selection = CGRect(
                x: min(start.x, p.x), y: min(start.y, p.y),
                width: abs(p.x - start.x), height: abs(p.y - start.y)
            )
        case .move:
            let dx = p.x - initialPoint.x
            let dy = p.y - initialPoint.y
            var rect = initialRect.offsetBy(dx: dx, dy: dy)
            rect.origin.x = min(max(0, rect.origin.x), bounds.width - rect.width)
            rect.origin.y = min(max(0, rect.origin.y), bounds.height - rect.height)
            selection = rect
        case .resize(let handle):
            selection = resized(initialRect, handle: handle, to: p)
        }

        if selectionIsComplete {
            layoutActionBar()
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let hadMode = dragMode
        dragMode = nil
        dragStart = nil

        guard showsActionBar else {
            guard selection.width >= 4, selection.height >= 4 else {
                selection = .zero
                needsDisplay = true
                return
            }
            onFinish?(selection)
            return
        }

        if hadMode == .newSelection {
            if selection.width >= 4, selection.height >= 4 {
                selectionIsComplete = true
                layoutActionBar()
                actionBar?.isHidden = false
            } else {
                resetSelection()
            }
        } else if hadMode == nil {
            // 只是点在选区内部/手柄上但没有拖动，保持原样。
        } else if selection.width >= 4, selection.height >= 4 {
            selectionIsComplete = true
            layoutActionBar()
            actionBar?.isHidden = false
        } else {
            resetSelection()
        }

        updateCursor(at: mouse)
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
            return
        }
        if event.keyCode == 36 || event.keyCode == 76 {
            handleReturnKey()
        }
    }

    func handleReturnKey() {
        guard selection.width >= 4, selection.height >= 4 else { return }
        if showsActionBar {
            guard selectionIsComplete else { return }
            handleAction(.save)
        } else {
            onFinish?(selection)
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    // MARK: 立即截图状态

    private func beginNewSelection(at point: CGPoint) {
        dragMode = .newSelection
        dragStart = point
        selection = CGRect(origin: point, size: .zero)
        selectionIsComplete = false
        actionBarInsideSelection = false
        actionBar?.isHidden = true
        needsDisplay = true
    }

    private func resetSelection() {
        selection = .zero
        selectionIsComplete = false
        dragMode = nil
        dragStart = nil
        actionBarInsideSelection = false
        actionBar?.isHidden = true
        needsDisplay = true
    }

    private func handleAction(_ action: ImmediateSelectionAction) {
        guard selection.width >= 4, selection.height >= 4 else { return }
        if action != .cancel {
            guard selectionIsComplete else { return }
        }
        onImmediateAction?(action, selection)
    }

    private func handle(at point: CGPoint) -> Handle? {
        Handle.allCases.first { handle in
            let center = handle.point(in: selection)
            return CGRect(x: center.x - 7, y: center.y - 7, width: 14, height: 14).contains(point)
        }
    }

    private func resized(_ rect: CGRect, handle: Handle, to point: CGPoint) -> CGRect {
        var minX = rect.minX
        var maxX = rect.maxX
        var minY = rect.minY
        var maxY = rect.maxY

        switch handle {
        case .nw:
            minX = point.x
            maxY = point.y
        case .n:
            maxY = point.y
        case .ne:
            maxX = point.x
            maxY = point.y
        case .e:
            maxX = point.x
        case .se:
            maxX = point.x
            minY = point.y
        case .s:
            minY = point.y
        case .sw:
            minX = point.x
            minY = point.y
        case .w:
            minX = point.x
        }

        minX = min(max(0, minX), maxX - 4)
        maxX = min(max(minX + 4, maxX), bounds.width)
        minY = min(max(0, minY), maxY - 4)
        maxY = min(max(minY + 4, maxY), bounds.height)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func layoutActionBar() {
        guard let actionBar, selectionIsComplete, selection.width >= 4, selection.height >= 4 else {
            self.actionBar?.isHidden = true
            return
        }

        let size = ImmediateSelectionBarView.preferredSize
        let gap: CGFloat = 12
        let margin: CGFloat = 8
        var origin = CGPoint.zero
        var inside = false

        let centeredX = selection.midX - size.width / 2
        let clampedX = min(
            max(margin, centeredX), max(margin, bounds.width - size.width - margin))
        let centeredY = selection.midY - size.height / 2
        let clampedY = min(
            max(margin, centeredY), max(margin, bounds.height - size.height - margin))

        // 优先上方居中；否则下方、右侧、左侧；实在四边都放不下时贴选区顶部内侧。
        if selection.maxY + gap + size.height <= bounds.maxY - margin {
            origin = CGPoint(x: clampedX, y: selection.maxY + gap)
        } else if selection.minY - gap - size.height >= margin {
            origin = CGPoint(x: clampedX, y: selection.minY - gap - size.height)
        } else if selection.maxX + gap + size.width <= bounds.maxX - margin {
            origin = CGPoint(x: selection.maxX + gap, y: clampedY)
        } else if selection.minX - gap - size.width >= margin {
            origin = CGPoint(x: selection.minX - gap - size.width, y: clampedY)
        } else {
            inside = true
            let proposedY = selection.maxY - size.height - 8
            origin = CGPoint(
                x: clampedX,
                y: min(max(margin, proposedY), max(margin, bounds.height - size.height - margin)))
        }

        actionBarInsideSelection = inside
        actionBar.frame = NSRect(origin: origin, size: size)
        actionBar.isHidden = false
    }

    private func updateCursor(at point: CGPoint) {
        guard showsActionBar, selectionIsComplete, selection.width >= 4, selection.height >= 4 else {
            NSCursor.crosshair.set()
            return
        }
        if let actionBar, !actionBar.isHidden, actionBar.frame.contains(point) {
            NSCursor.arrow.set()
            return
        }
        if let handle = handle(at: point) {
            handle.cursor.set()
        } else if selection.contains(point) {
            NSCursor.openHand.set()
        } else {
            NSCursor.crosshair.set()
        }
    }
}

/// 选区与贴图缩放共用的 8 热区定义。
enum Handle: CaseIterable, Equatable {
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
