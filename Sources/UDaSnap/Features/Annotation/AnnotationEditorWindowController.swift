import AppKit
import UDaSnapCore

/// 标注编辑器。它是独立置顶窗口，不改写现有截图结果窗。
@MainActor
final class AnnotationEditorWindowController: NSWindowController, NSWindowDelegate {

    enum FinishAction {
        case done(CGImage)
        case pin(CGImage)
        case cancel
    }

    var onFinish: ((FinishAction) -> Void)?

    private let screen: NSScreen
    private let cascadeIndex: Int
    private let preferredFrame: NSRect?
    private let canvas: AnnotationCanvasView
    private let toolbar = AnnotationToolbarView()
    private let scrollView = NSScrollView()
    private let toolbarHeight: CGFloat = 92
    private var localMonitor: Any?
    private var isFinishing = false
    private var didSizeInitialWindow = false

    init(
        document: AnnotationDocument,
        screen: NSScreen,
        cascadeIndex: Int = 0,
        preferredFrame: NSRect? = nil
    ) {
        self.screen = screen
        self.cascadeIndex = cascadeIndex
        self.preferredFrame = preferredFrame
        self.canvas = AnnotationCanvasView(document: document)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = cascadeIndex == 0 ? "标注截图" : "标注截图 \(cascadeIndex + 1)"
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.backgroundColor = .windowBackgroundColor
        window.minSize = NSSize(width: 760, height: 430)
        super.init(window: window)
        window.delegate = self
        buildUI()
        installLocalMonitor()
        sizeInitialWindow()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildUI() {
        guard let window, let root = window.contentView else { return }
        root.wantsLayer = true

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor.underPageBackgroundColor
        scrollView.documentView = canvas
        root.addSubview(scrollView)

        toolbar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(toolbar)

        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolbar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: toolbarHeight),

            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: toolbar.topAnchor),
        ])

        canvas.onDocumentChange = { [weak self] in
            self?.refreshToolbar()
        }
        canvas.onSelectionChange = { [weak self] id in
            guard let self else { return }
            if let id, let object = self.canvas.document.objects.first(where: { $0.id == id }) {
                self.canvas.style = object.style
                self.toolbar.setStyle(object.style)
            }
            self.refreshToolbar()
        }
        canvas.onCropChange = { [weak self] rect in
            self?.toolbar.setCropAvailable(rect != nil)
        }
        canvas.onZoomRequest = { [weak self] proposed in
            self?.setZoom(proposed)
        }
        canvas.onCancel = { [weak self] in
            self?.cancel()
        }
        canvas.onToolChange = { [weak self] tool in
            self?.toolbar.setTool(tool)
        }

        toolbar.onToolChange = { [weak self] tool in
            self?.canvas.setTool(tool)
        }
        toolbar.onColorChange = { [weak self] color in
            self?.applyStyle { $0.color = color }
        }
        toolbar.onLineWidthChange = { [weak self] width in
            self?.applyStyle { $0.lineWidth = width }
        }
        toolbar.onFontSizeChange = { [weak self] size in
            self?.applyStyle { $0.fontSize = size }
        }
        toolbar.onUndo = { [weak self] in self?.canvas.undo() }
        toolbar.onRedo = { [weak self] in self?.canvas.redo() }
        toolbar.onApplyCrop = { [weak self] in
            self?.canvas.applyCrop()
            self?.fitCanvas()
        }
        toolbar.onRotateLeft = { [weak self] in
            self?.canvas.rotate(clockwise: false)
            self?.fitCanvas()
        }
        toolbar.onRotateRight = { [weak self] in
            self?.canvas.rotate(clockwise: true)
            self?.fitCanvas()
        }
        toolbar.onFlip = { [weak self] in
            self?.canvas.flipHorizontally()
            self?.fitCanvas()
        }
        toolbar.onCancel = { [weak self] in self?.cancel() }
        toolbar.onPin = { [weak self] in self?.finishPin() }
        toolbar.onDone = { [weak self] in self?.finishDone() }

        toolbar.setStyle(canvas.style)
        toolbar.setTool(canvas.tool)
        refreshToolbar()
    }

    private func installLocalMonitor() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.window?.isKeyWindow == true else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags.contains(.command) {
                guard !self.canvas.isTextEditing else { return event }
                let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
                if key == "z" {
                    if flags.contains(.shift) {
                        self.canvas.redo()
                    } else {
                        self.canvas.undo()
                    }
                    return nil
                }
                if key == "0" {
                    self.fitCanvas()
                    return nil
                }
                if key == "=" || key == "+" {
                    self.setZoom(self.canvas.zoom * 1.2)
                    return nil
                }
                if key == "-" {
                    self.setZoom(self.canvas.zoom / 1.2)
                    return nil
                }
            }
            if event.keyCode == 53 {
                if self.canvas.isTextEditing {
                    self.canvas.commitTextEditing()
                } else {
                    self.cancel()
                }
                return nil
            }
            return event
        }
    }

    func show() {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        fitCanvas()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
        scrollToTop()
    }

    private func scrollToTop() {
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 0))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func refreshToolbar() {
        toolbar.setHistory(canUndo: canvas.document.canUndo, canRedo: canvas.document.canRedo)
        toolbar.setCropAvailable(canvas.currentCropRect != nil)
        toolbar.setStyle(canvas.style)
    }

    private func applyStyle(_ change: (inout AnnotationStyle) -> Void) {
        var style = canvas.style
        change(&style)
        canvas.style = style
        canvas.updateStyleForSelection(style)
        toolbar.setStyle(style)
    }

    private func sizeInitialWindow() {
        guard let window else { return }
        let visible = screen.visibleFrame
        let standardSize = standardWindowSize()
        var frame = window.frame
        if let preferredFrame {
            let minSize = NSSize(width: 760, height: 430)
            let sourceSize = preferredFrame.size
            if sourceSize.width > standardSize.width || sourceSize.height > standardSize.height {
                frame.size = standardSize
            } else if sourceSize.width < minSize.width || sourceSize.height < minSize.height {
                frame.size = standardSize
            } else {
                frame.size = sourceSize
            }
            frame.origin = NSPoint(
                x: preferredFrame.midX - frame.width / 2,
                y: preferredFrame.midY - frame.height / 2)
        } else {
            frame.size = standardSize
            let stagger = CGFloat(cascadeIndex % 6) * 28
            frame.origin = NSPoint(
                x: visible.midX - frame.width / 2 + stagger,
                y: visible.midY - frame.height / 2 - stagger)
        }

        let inset = visible.insetBy(dx: 12, dy: 12)
        let maxX = max(inset.minX, inset.maxX - frame.width)
        let maxY = max(inset.minY, inset.maxY - frame.height)
        frame.origin = NSPoint(
            x: min(max(frame.origin.x, inset.minX), maxX),
            y: min(max(frame.origin.y, inset.minY), maxY))
        window.setFrame(frame, display: true)

        let contentWidth = max(240, frame.width - 24)
        let contentHeight = max(120, frame.height - toolbarHeight - 28)
        let pixelWidth = max(1, canvas.document.canvasSize.width)
        let pixelHeight = max(1, canvas.document.canvasSize.height)
        let zoom = max(
            0.03,
            min(contentWidth / pixelWidth, contentHeight / pixelHeight, 1))
        canvas.zoom = zoom
        canvas.setFrameSize(NSSize(width: pixelWidth * zoom, height: pixelHeight * zoom))
        didSizeInitialWindow = true
    }

    private func standardWindowSize() -> NSSize {
        let visible = screen.visibleFrame
        let maxCanvasWidth = max(240, visible.width * 0.84)
        let maxCanvasHeight = max(180, visible.height * 0.78 - toolbarHeight)
        let pixelWidth = max(1, canvas.document.canvasSize.width)
        let pixelHeight = max(1, canvas.document.canvasSize.height)
        let zoom = max(0.03, min(maxCanvasWidth / pixelWidth, maxCanvasHeight / pixelHeight, 1))
        let width = max(760, min(visible.width * 0.94, pixelWidth * zoom + 24))
        let height = max(430, min(visible.height * 0.92, pixelHeight * zoom + toolbarHeight + 24))
        return NSSize(width: width, height: height)
    }

    /// 适配当前窗口，不改变窗口位置或尺寸；裁剪、旋转、翻转后窗口保持稳定。
    private func fitCanvas() {
        guard let window else { return }
        if !didSizeInitialWindow {
            sizeInitialWindow()
            return
        }
        let pixelWidth = max(1, canvas.document.canvasSize.width)
        let pixelHeight = max(1, canvas.document.canvasSize.height)
        let content = scrollView.contentSize
        let availableWidth = max(240, content.width > 10 ? content.width : window.contentLayoutRect.width)
        let availableHeight = max(
            180, content.height > 10 ? content.height : window.contentLayoutRect.height - toolbarHeight)
        let zoom = max(0.03, min(availableWidth / pixelWidth, availableHeight / pixelHeight, 1))
        canvas.zoom = zoom
        canvas.setFrameSize(NSSize(width: pixelWidth * zoom, height: pixelHeight * zoom))
        scrollToTop()
    }

    private func setZoom(_ proposed: CGFloat) {
        let clamped = min(4, max(0.03, proposed))
        guard abs(clamped - canvas.zoom) > 0.001 else { return }
        canvas.commitTextEditing()
        canvas.zoom = clamped
        canvas.setFrameSize(
            NSSize(
                width: canvas.document.canvasSize.width * clamped,
                height: canvas.document.canvasSize.height * clamped))
    }

    private func finishDone() {
        finish(.done)
    }

    private func finishPin() {
        finish(.pin)
    }

    private func finish(_ kind: FinishKind) {
        guard !isFinishing else { return }
        canvas.commitTextEditing()
        guard let image = AnnotationPainter.render(canvas.document) else {
            let alert = NSAlert()
            alert.messageText = "无法生成标注图"
            alert.informativeText = "请重试，或取消本次标注。"
            alert.runModal()
            return
        }
        isFinishing = true
        removeMonitor()
        switch kind {
        case .done:
            onFinish?(.done(image))
        case .pin:
            onFinish?(.pin(image))
        }
        window?.close()
    }

    private enum FinishKind {
        case done
        case pin
    }

    private func cancel() {
        guard !isFinishing else { return }
        isFinishing = true
        removeMonitor()
        onFinish?(.cancel)
        window?.close()
    }

    private func removeMonitor() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
    }

    func windowWillClose(_ notification: Notification) {
        removeMonitor()
        guard !isFinishing else { return }
        isFinishing = true
        onFinish?(.cancel)
    }
}
