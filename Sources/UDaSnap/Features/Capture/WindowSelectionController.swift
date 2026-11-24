import AppKit
import CoreGraphics
import UDaSnapCore

/// 一个可点的窗口。bounds 使用 AppKit 全局坐标（原点在主屏左下）。
struct WindowCandidate {
    let id: CGWindowID
    let ownerPID: pid_t
    let appName: String
    let bounds: CGRect
    let layer: Int
    let contentPixelWidth: Int
    let contentPixelHeight: Int

    var contentPixelSize: String {
        "\(contentPixelWidth) × \(contentPixelHeight)"
    }

    var label: String {
        "\(displayName) · \(contentPixelSize)"
    }

    private var displayName: String {
        let trimmed = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未知应用" : trimmed
    }
}

/// 枚举当前屏幕上可选的窗口，并过滤掉桌面 / Dock / 菜单栏 / 通知中心等系统 UI。
enum WindowCatalog {

    private static let excludedOwners: Set<String> = [
        "Window Server", "WindowServer", "Dock", "SystemUIServer",
        "Control Center", "Notification Center", "Spotlight",
        "loginwindow", "SecurityAgent", "UserNotificationCenter",
        "CoreServicesUIAgent", "UDaSnap",
        "窗口服务器", "程序坞", "通知中心", "控制中心", "聚焦",
    ]

    static func current(excluding pid: pid_t) -> [WindowCandidate] {
        guard
            let raw = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
            ) as? [[String: Any]]
        else {
            return []
        }

        // Quartz 的窗口坐标以主屏左上角为原点；AppKit 以主屏左下角为原点。
        let mainTop = NSScreen.screens.first?.frame.maxY ?? 0
        var results: [WindowCandidate] = []

        for info in raw {
            guard let idNumber = info[kCGWindowNumber as String] as? NSNumber,
                let ownerPIDNumber = info[kCGWindowOwnerPID as String] as? NSNumber,
                let boundsDict = info[kCGWindowBounds as String] as? [String: Any]
            else {
                continue
            }

            let ownerPID = pid_t(ownerPIDNumber.int32Value)
            guard ownerPID != pid else { continue }

            // 普通窗口在 layer 0；浮动面板一般在 1...3。再高的就是菜单栏、Dock 等系统 UI。
            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            guard layer >= 0, layer <= 3 else { continue }

            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            guard alpha > 0.01 else { continue }

            let ownerName = (info[kCGWindowOwnerName as String] as? String) ?? ""
            guard !excludedOwners.contains(ownerName) else { continue }

            let x = (boundsDict["X"] as? NSNumber)?.doubleValue ?? 0
            let y = (boundsDict["Y"] as? NSNumber)?.doubleValue ?? 0
            let width = (boundsDict["Width"] as? NSNumber)?.doubleValue ?? 0
            let height = (boundsDict["Height"] as? NSNumber)?.doubleValue ?? 0
            guard width >= 40, height >= 40 else { continue }

            let cgBounds = CGRect(x: x, y: y, width: width, height: height)
            let appKitBounds = CGRect(
                x: cgBounds.minX,
                y: mainTop - cgBounds.maxY,
                width: cgBounds.width,
                height: cgBounds.height
            )

            guard let screen = bestScreen(for: appKitBounds) else { continue }
            let scale = screen.backingScaleFactor
            let pixelWidth = Int(round(appKitBounds.width * scale))
            let pixelHeight = Int(round(appKitBounds.height * scale))

            results.append(
                WindowCandidate(
                    id: CGWindowID(idNumber.uint32Value),
                    ownerPID: ownerPID,
                    appName: ownerName,
                    bounds: appKitBounds,
                    layer: layer,
                    contentPixelWidth: pixelWidth,
                    contentPixelHeight: pixelHeight
                ))
        }

        return results
    }

    private static func bestScreen(for rect: CGRect) -> NSScreen? {
        var best: NSScreen?
        var bestArea: CGFloat = 0
        for screen in NSScreen.screens {
            let intersection = rect.intersection(screen.frame)
            guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else { continue }
            let area = intersection.width * intersection.height
            if area > bestArea {
                bestArea = area
                best = screen
            }
        }
        return best
    }
}

/// 应用窗口选择会话：冻结所有屏，鼠标悬停高亮窗口，点击截取，Esc 取消。
@MainActor
final class WindowSelectionController {

    var onFinish: ((WindowCandidate) -> Void)?
    var onCancel: (() -> Void)?

    private var overlays: [WindowOverlayWindow] = []
    private var candidates: [WindowCandidate] = []
    private var active = false

    @discardableResult
    func begin() -> Bool {
        guard !active else { return false }

        var captured: [(NSScreen, CGImage)] = []
        for screen in NSScreen.screens {
            if let image = CaptureService.capture(screen: screen) {
                captured.append((screen, image))
            }
        }
        guard !captured.isEmpty else { return false }

        candidates = WindowCatalog.current(excluding: getpid())
        guard !candidates.isEmpty else { return false }

        active = true
        for (screen, image) in captured {
            let overlay = WindowOverlayWindow(screen: screen, image: image, candidates: candidates)
            overlay.overlayView.onFinish = { [weak self] candidate in
                self?.finish(candidate)
            }
            overlay.overlayView.onCancel = { [weak self] in
                self?.cancel()
            }
            overlays.append(overlay)
            overlay.orderFrontRegardless()
        }

        let mouse = NSEvent.mouseLocation
        if let current = overlays.first(where: { $0.frame.contains(mouse) }) ?? overlays.first {
            current.makeKey()
        }
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    func dismiss() {
        active = false
        for overlay in overlays { overlay.orderOut(nil) }
        overlays.removeAll()
        candidates.removeAll()
    }

    func cancel() {
        guard active else { return }
        dismiss()
        onCancel?()
    }

    private func finish(_ candidate: WindowCandidate) {
        guard active else { return }
        dismiss()
        onFinish?(candidate)
    }
}

// MARK: - 遮罩窗口

@MainActor
final class WindowOverlayWindow: NSWindow {

    let overlayView: WindowOverlayView

    init(screen: NSScreen, image: CGImage, candidates: [WindowCandidate]) {
        let view = WindowOverlayView(
            frame: NSRect(origin: .zero, size: screen.frame.size),
            screen: screen,
            image: image,
            candidates: candidates
        )
        self.overlayView = view
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
        self.isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { overlayView.onCancel?() }  // Esc
    }
}

// MARK: - 绘制与交互

@MainActor
final class WindowOverlayView: NSView {

    var onFinish: ((WindowCandidate) -> Void)?
    var onCancel: (() -> Void)?

    private let screen: NSScreen
    private let frozenImage: CGImage
    private let candidates: [WindowCandidate]
    private var hovered: WindowCandidate?
    private var mouse: CGPoint = .zero
    private var tracking: NSTrackingArea?

    init(frame: NSRect, screen: NSScreen, image: CGImage, candidates: [WindowCandidate]) {
        self.screen = screen
        self.frozenImage = image
        self.candidates = candidates
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(tracking!)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .crosshair)
    }

    // MARK: 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        ctx.draw(frozenImage, in: bounds)

        let hole = hovered.flatMap { localRect(for: $0) }

        ctx.saveGState()
        let dimPath = CGMutablePath()
        dimPath.addRect(bounds)
        if let hole, hole.width > 0, hole.height > 0 {
            dimPath.addRect(hole)
        }
        ctx.addPath(dimPath)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.4).cgColor)
        ctx.drawPath(using: .eoFill)
        ctx.restoreGState()

        if let hole, hole.width > 0, hole.height > 0 {
            ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.65).cgColor)
            ctx.setLineWidth(3)
            ctx.stroke(hole.insetBy(dx: -1, dy: -1))
            ctx.setStrokeColor(NSColor.systemBlue.cgColor)
            ctx.setLineWidth(1.5)
            ctx.stroke(hole.insetBy(dx: -0.5, dy: -0.5))
        }

        drawChip("点击窗口截图 · Esc 取消", at: CGPoint(x: 20, y: 20))

        if let hovered,
            screen.frame.contains(NSEvent.mouseLocation),
            hovered.bounds.intersects(screen.frame)
        {
            drawChip(hovered.label, near: mouse)
        }
    }

    private func localRect(for candidate: WindowCandidate) -> CGRect? {
        let clipped = candidate.bounds.intersection(screen.frame)
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return nil }
        return CGRect(
            x: clipped.minX - screen.frame.minX,
            y: clipped.minY - screen.frame.minY,
            width: clipped.width,
            height: clipped.height
        )
    }

    private func drawChip(_ text: String, near point: CGPoint) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let size = str.size()
        let pad: CGFloat = 6
        let chipWidth = size.width + pad * 2
        let chipHeight = size.height + pad * 2
        var origin = CGPoint(x: point.x + 18, y: point.y - chipHeight - 12)
        origin.x = min(max(8, origin.x), max(8, bounds.width - chipWidth - 8))
        origin.y = min(max(8, origin.y), max(8, bounds.height - chipHeight - 8))
        drawChip(text, at: origin, size: size, width: chipWidth, height: chipHeight, attributes: attrs)
    }

    private func drawChip(_ text: String, at origin: CGPoint) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        drawChip(
            text,
            at: origin,
            size: size,
            width: size.width + 12,
            height: size.height + 12,
            attributes: attrs
        )
    }

    private func drawChip(
        _ text: String,
        at origin: CGPoint,
        size: CGSize,
        width: CGFloat,
        height: CGFloat,
        attributes: [NSAttributedString.Key: Any]
    ) {
        let rect = CGRect(x: origin.x, y: origin.y, width: width, height: height)
        NSColor.black.withAlphaComponent(0.76).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        NSAttributedString(string: text, attributes: attributes).draw(
            at: CGPoint(x: origin.x + 6, y: origin.y + 6)
        )
    }

    // MARK: 交互

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        mouse = point
        let candidate = candidate(at: NSEvent.mouseLocation)
        if candidate?.id != hovered?.id {
            hovered = candidate
            needsDisplay = true
        }
        NSCursor.crosshair.set()
    }

    override func mouseEntered(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        if hovered != nil {
            hovered = nil
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        let globalPoint = NSEvent.mouseLocation
        guard let candidate = candidate(at: globalPoint) else { return }
        onFinish?(candidate)
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.crosshair.set()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() }
    }

    private func candidate(at globalPoint: CGPoint) -> WindowCandidate? {
        // 数组顺序是 front-to-back，第一个命中的就是最上层窗口。
        candidates.first { $0.bounds.contains(globalPoint) }
    }
}
