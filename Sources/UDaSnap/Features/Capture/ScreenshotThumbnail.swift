import AppKit
import UDaSnapCore

/// 一张已完成保存的截图，缩略图、打开、贴图和进入标注都需要这些上下文。
@MainActor
struct ScreenshotThumbnailItem {
    let image: CGImage
    let savedURL: URL?
    let clipboardData: Data?
    let screen: NSScreen
    let contentScale: CGFloat
    let pinOrigin: CGPoint
    let createdAt: Date
}

/// 系统截图的快门提示音。
@MainActor
enum ScreenshotSound {
    private static var sound: NSSound?

    static func play() {
        let path =
            "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Shutter.aif"
        if sound == nil {
            sound = NSSound(contentsOfFile: path, byReference: true)
        }
        if let sound {
            sound.stop()
            sound.play()
        } else {
            NSSound.beep()
        }
    }
}

/// 管理右下角的所有截图缩略图。
@MainActor
final class ScreenshotThumbnailCenter {
    static let shared = ScreenshotThumbnailCenter()

    var onAnnotate: ((ScreenshotThumbnailItem) -> Void)?
    var onPin: ((ScreenshotThumbnailItem) -> Void)?

    private var thumbnails: [ScreenshotThumbnailController] = []
    private var hiddenForCapture = false

    private init() {}

    func show(_ item: ScreenshotThumbnailItem) {
        let controller = ScreenshotThumbnailController(item: item)
        controller.onDelete = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.delete(item, controller: controller)
        }
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.remove(controller)
        }
        controller.onOpen = { [weak self] in
            self?.open(item)
        }
        controller.onPin = { [weak self] in
            self?.onPin?(item)
        }
        controller.onAnnotate = { [weak self] in
            self?.onAnnotate?(item)
        }
        thumbnails.append(controller)
        layout(for: item.screen)
        controller.show()
        ScreenshotSound.play()
    }

    /// 截图前先把旧缩略图藏起来，避免它们被新截图截进去。
    func hideForCapture() {
        guard !hiddenForCapture else { return }
        hiddenForCapture = true
        for controller in thumbnails {
            controller.orderOut()
        }
    }

    func restoreAfterCapture() {
        guard hiddenForCapture else { return }
        hiddenForCapture = false
        for controller in thumbnails {
            controller.orderFront()
        }
    }

    func dismissAll() {
        let all = thumbnails
        thumbnails.removeAll()
        for controller in all {
            controller.closeImmediately()
        }
    }

    private func remove(_ controller: ScreenshotThumbnailController) {
        let screen = controller.item.screen
        thumbnails.removeAll { $0 === controller }
        layout(for: screen)
    }

    private func open(_ item: ScreenshotThumbnailItem) {
        guard let url = item.savedURL else {
            ScreenshotStorage.revealFolder()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func delete(_ item: ScreenshotThumbnailItem, controller: ScreenshotThumbnailController) {
        if let url = item.savedURL {
            try? FileManager.default.removeItem(at: url)
        }
        ScreenshotStorage.clearClipboard(ifMatching: item.clipboardData)
        controller.close(animated: true)
    }

    private func layout(for screen: NSScreen) {
        let sameScreen = thumbnails.filter { $0.item.screen === screen }.sorted {
            $0.item.createdAt > $1.item.createdAt
        }
        let visible = screen.visibleFrame
        var y = visible.minY + 20
        for controller in sameScreen {
            let size = controller.windowSize
            let x = max(visible.minX + 20, visible.maxX - 20 - size.width)
            controller.setFrameOrigin(NSPoint(x: x, y: y))
            y += size.height + 8
        }
    }
}

/// 单张缩略图的窗口与计时。
@MainActor
final class ScreenshotThumbnailController {
    let item: ScreenshotThumbnailItem
    let windowSize: NSSize

    var onDelete: (() -> Void)?
    var onClose: (() -> Void)?
    var onOpen: (() -> Void)?
    var onPin: (() -> Void)?
    var onAnnotate: (() -> Void)?

    private let panel: ScreenshotThumbnailPanel
    private let thumbnailView: ScreenshotThumbnailView
    private var hideWorkItem: DispatchWorkItem?
    private var remaining: TimeInterval = 5
    private var timerStartedAt: Date?
    private var isHovering = false
    private var isClosing = false

    init(item: ScreenshotThumbnailItem) {
        self.item = item
        self.windowSize = Self.size(for: item.image)
        let panel = ScreenshotThumbnailPanel(
            contentRect: NSRect(origin: .zero, size: windowSize),
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
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        self.panel = panel
        self.thumbnailView = ScreenshotThumbnailView(
            frame: NSRect(origin: .zero, size: windowSize), image: item.image)
        panel.contentView = thumbnailView
        thumbnailView.onHoverChanged = { [weak self] hovering in
            self?.setHovering(hovering)
        }
        thumbnailView.onBodyClick = { [weak self] in
            self?.onAnnotate?()
            self?.close(animated: false)
        }
        thumbnailView.onIconClick = { [weak self] icon in
            guard let self else { return }
            switch icon {
            case .delete: self.onDelete?()
            case .close: self.close(animated: true)
            case .open: self.onOpen?()
            case .pin: self.onPin?()
            }
        }
    }

    func show() {
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        startTimer()
    }

    func orderOut() {
        panel.orderOut(nil)
    }

    func orderFront() {
        guard !isClosing else { return }
        panel.orderFrontRegardless()
    }

    func setFrameOrigin(_ origin: NSPoint) {
        panel.setFrameOrigin(origin)
    }

    private static func size(for image: CGImage) -> NSSize {
        let maxWidth: CGFloat = 180
        let maxHeight: CGFloat = 120
        let pixelWidth = max(1, CGFloat(image.width))
        let pixelHeight = max(1, CGFloat(image.height))
        let scale = min(1, min(maxWidth / pixelWidth, maxHeight / pixelHeight))
        return NSSize(
            width: max(1, pixelWidth * scale),
            height: max(1, pixelHeight * scale))
    }

    private func startTimer() {
        scheduleHide(after: remaining)
    }

    private func scheduleHide(after delay: TimeInterval) {
        hideWorkItem?.cancel()
        timerStartedAt = Date()
        let work = DispatchWorkItem { [weak self] in
            self?.close(animated: true)
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.05, delay), execute: work)
    }

    private func pauseTimer() {
        guard let timerStartedAt else { return }
        remaining = max(0.05, remaining - Date().timeIntervalSince(timerStartedAt))
        self.timerStartedAt = nil
        hideWorkItem?.cancel()
        hideWorkItem = nil
    }

    private func resumeTimer() {
        guard !isClosing else { return }
        scheduleHide(after: remaining)
    }

    private func setHovering(_ hovering: Bool) {
        guard hovering != isHovering else { return }
        isHovering = hovering
        if hovering {
            pauseTimer()
        } else {
            resumeTimer()
        }
    }

    func close(animated: Bool) {
        guard !isClosing else { return }
        isClosing = true
        hideWorkItem?.cancel()
        hideWorkItem = nil
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                panel.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                Task { @MainActor in
                    self?.closeImmediately()
                }
            }
        } else {
            closeImmediately()
        }
    }

    func closeImmediately() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        panel.close()
        onClose?()
    }
}

private final class ScreenshotThumbnailPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private enum ThumbnailIcon {
    case delete
    case close
    case open
    case pin
}

private final class ScreenshotThumbnailView: NSView {
    var onHoverChanged: ((Bool) -> Void)?
    var onBodyClick: (() -> Void)?
    var onIconClick: ((ThumbnailIcon) -> Void)?

    private let image: NSImage
    private var tracking: NSTrackingArea?
    private var hovering = false
    private var pressedIcon: ThumbnailIcon?
    private var pressedPoint: NSPoint?

    private let iconSize: CGFloat = 24
    private let iconInset: CGFloat = 6

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { false }

    init(frame: NSRect, image cg: CGImage) {
        self.image = NSImage(
            cgImage: cg,
            size: NSSize(width: CGFloat(cg.width), height: CGFloat(cg.height)))
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.black.withAlphaComponent(0.18).cgColor
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
        guard hovering else { return }
        drawIcon(.delete, in: deleteRect, symbol: "trash")
        drawIcon(.close, in: closeRect, symbol: "xmark")
        drawIcon(.open, in: openRect, symbol: "folder")
        drawIcon(.pin, in: pinRect, symbol: "pin.fill")
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
    private var pinRect: NSRect {
        NSRect(x: iconInset, y: iconInset, width: iconSize, height: iconSize)
    }

    private func drawIcon(_ icon: ThumbnailIcon, in rect: NSRect, symbol: String) {
        let background = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        NSColor.black.withAlphaComponent(0.58).setFill()
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
        let glyphRect = rect.insetBy(dx: 5, dy: 5)
        tinted.draw(in: glyphRect, from: .zero, operation: .sourceOver, fraction: 1)
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

    override func mouseEntered(with event: NSEvent) {
        setHovering(true)
    }

    override func mouseMoved(with event: NSEvent) {
        if !hovering { setHovering(true) }
    }

    override func mouseExited(with event: NSEvent) {
        setHovering(false)
    }

    private func setHovering(_ value: Bool) {
        guard hovering != value else { return }
        hovering = value
        needsDisplay = true
        onHoverChanged?(value)
    }

    private func icon(at point: NSPoint) -> ThumbnailIcon? {
        if deleteRect.contains(point) { return .delete }
        if closeRect.contains(point) { return .close }
        if openRect.contains(point) { return .open }
        if pinRect.contains(point) { return .pin }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        pressedIcon = hovering ? icon(at: point) : nil
        pressedPoint = point
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let pressedIcon, icon(at: point) == pressedIcon {
            onIconClick?(pressedIcon)
        } else if pressedIcon == nil, let pressedPoint,
            hypot(point.x - pressedPoint.x, point.y - pressedPoint.y) < 4
        {
            onBodyClick?()
        }
        pressedIcon = nil
        pressedPoint = nil
    }
}
