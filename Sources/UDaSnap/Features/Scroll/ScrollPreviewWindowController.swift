import AppKit
import UDaSnapCore

/// 滚动截图完成后弹出的长图预览：滚轮/缩放查看，复制、定位文件、关闭。
@MainActor
final class ScrollPreviewWindowController: NSWindowController, NSWindowDelegate {

    static let shared = ScrollPreviewWindowController()

    private let scrollView = NSScrollView()
    private let imageView = ScrollPreviewImageView(frame: .zero)
    private var image: CGImage?
    private var fileURL: URL?
    private var escMonitor: Any?
    private let copyButton = NSButton(title: "复制", target: nil, action: nil)

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "长图预览"
        window.minSize = NSSize(width: 560, height: 360)
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // 预览窗本身绝不能出现在下一张截图里（包括它还没完全收起的那几帧）。
        window.sharingType = .none
        super.init(window: window)
        window.delegate = self
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let barHeight: CGFloat = 46
        scrollView.frame = NSRect(
            x: 0, y: barHeight, width: content.bounds.width,
            height: content.bounds.height - barHeight)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .windowBackgroundColor
        scrollView.borderType = .noBorder
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.02
        scrollView.maxMagnification = 2.0
        scrollView.documentView = imageView
        content.addSubview(scrollView)

        let bar = NSView(frame: NSRect(x: 0, y: 0, width: content.bounds.width, height: barHeight))
        bar.autoresizingMask = [.width, .maxYMargin]
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        content.addSubview(bar)

        let fit = NSButton(title: "适应宽度", target: self, action: #selector(fitWidthAction))
        fit.frame = NSRect(x: 12, y: 8, width: 84, height: 28)
        fit.bezelStyle = .rounded
        fit.controlSize = .small
        bar.addSubview(fit)

        let actual = NSButton(title: "100%", target: self, action: #selector(actualSizeAction))
        actual.frame = NSRect(x: 102, y: 8, width: 64, height: 28)
        actual.bezelStyle = .rounded
        actual.controlSize = .small
        bar.addSubview(actual)

        copyButton.frame = NSRect(x: 178, y: 8, width: 72, height: 28)
        copyButton.bezelStyle = .rounded
        copyButton.controlSize = .small
        copyButton.target = self
        copyButton.action = #selector(copyAction)
        bar.addSubview(copyButton)

        let reveal = NSButton(title: "在 Finder 显示", target: self, action: #selector(revealAction))
        reveal.frame = NSRect(x: 256, y: 8, width: 112, height: 28)
        reveal.bezelStyle = .rounded
        reveal.controlSize = .small
        bar.addSubview(reveal)

        let close = NSButton(title: "关闭", target: self, action: #selector(closeAction))
        close.frame = NSRect(x: content.bounds.width - 74, y: 8, width: 62, height: 28)
        close.autoresizingMask = [.minXMargin]
        close.bezelStyle = .rounded
        close.controlSize = .small
        close.keyEquivalent = "\r"
        bar.addSubview(close)
    }

    func show(image: CGImage, fileURL: URL) {
        self.image = image
        self.fileURL = fileURL
        imageView.image = image
        imageView.frame = NSRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height))
        scrollView.documentView = imageView
        window?.title = "长图预览 · \(image.width) × \(image.height)"
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        installEscMonitor()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.fitWidth()
            self.scrollToTop()
        }
    }

    private func installEscMonitor() {
        removeEscMonitor()
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            self?.closeAction()
            return nil
        }
    }

    private func removeEscMonitor() {
        if let escMonitor { NSEvent.removeMonitor(escMonitor) }
        escMonitor = nil
    }

    private func fitWidth() {
        guard let image else { return }
        let available = max(80, scrollView.contentSize.width - 16)
        let scale = min(1.0, available / CGFloat(image.width))
        scrollView.setMagnification(max(0.02, scale), centeredAt: .zero)
    }

    private func scrollToTop() {
        guard let image else { return }
        let documentHeight = CGFloat(image.height)
        let visibleHeight = scrollView.contentView.bounds.height
        let y = max(0, documentHeight - visibleHeight)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    @objc private func fitWidthAction() {
        fitWidth()
        scrollToTop()
    }

    @objc private func actualSizeAction() {
        scrollView.setMagnification(1.0, centeredAt: .zero)
        scrollToTop()
    }

    @objc private func copyAction() {
        guard let image else { return }
        ScreenshotStorage.copyToClipboard(image)
        copyButton.title = "已复制"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.copyButton.title = "复制"
        }
    }

    @objc private func revealAction() {
        guard let fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    @objc private func closeAction() {
        window?.close()
    }

    /// 开始新的截图前收起预览，避免浮动预览窗挡住目标区域、抢走滚动事件。
    func dismiss() {
        window?.orderOut(nil)
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        removeEscMonitor()
    }
}

/// 用 NSImage 自绘，长图预览不会额外生成一张与原始长图等大的位图。
@MainActor
final class ScrollPreviewImageView: NSView {

    var image: CGImage? {
        didSet {
            guard let image else { return }
            nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            needsDisplay = true
        }
    }

    private var nsImage: NSImage?

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.imageInterpolation = .high
        nsImage?.draw(in: bounds, from: .zero, operation: .copy, fraction: 1)
    }
}
