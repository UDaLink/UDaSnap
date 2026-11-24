import AppKit
import UDaSnapCore

/// 截图模式保存成功后的小提示：鼠标旁一闪而过，不抢焦点、不吃鼠标事件。
@MainActor
final class HUDController {

    static let shared = HUDController()

    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    private init() {}

    func show(title: String, detail: String? = nil, at point: CGPoint, success: Bool = true) {
        hide(animated: false)

        let view = HUDView(title: title, detail: detail, success: success)
        let size = view.hudSize
        let panel = NSPanel(
            contentRect: NSRect(origin: position(size: size, near: point), size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.sharingType = .none
        panel.contentView = view
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        self.panel = panel

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }

        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self, weak panel] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled, let panel else { return }
            panel.alphaValue = 0
            try? await Task.sleep(for: .seconds(0.2))
            panel.orderOut(nil)
            if self?.panel === panel { self?.panel = nil }
        }
    }

    private func hide(animated: Bool) {
        hideTask?.cancel()
        hideTask = nil
        guard let panel else { return }
        self.panel = nil
        panel.orderOut(nil)
    }

    /// 默认放在鼠标右下方；贴到屏幕边缘时翻到上方或左侧。
    private func position(size: NSSize, near point: CGPoint) -> CGPoint {
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        var x = point.x + 16
        var y = point.y - size.height - 18
        if x + size.width > visible.maxX - 8 { x = point.x - size.width - 16 }
        if y < visible.minY + 8 { y = point.y + 18 }

        x = min(max(x, visible.minX + 8), max(visible.minX + 8, visible.maxX - size.width - 8))
        y = min(max(y, visible.minY + 8), max(visible.minY + 8, visible.maxY - size.height - 8))
        return CGPoint(x: x, y: y)
    }
}

/// 两行文字的小黑板：主文案 + 尺寸（或失败原因）。
@MainActor
final class HUDView: NSView {

    let hudSize: NSSize

    private let title: String
    private let detail: String?
    private let success: Bool
    private let titleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    private let detailFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    init(title: String, detail: String?, success: Bool) {
        self.title = title
        self.detail = detail
        self.success = success

        let titleWidth = (title as NSString).size(
            withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]
        ).width
        let detailWidth =
            detail.map {
                ($0 as NSString).size(
                    withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)]
                ).width
            } ?? 0
        let width = max(96, ceil(max(titleWidth, detailWidth)) + 26)
        let height: CGFloat = detail == nil ? 32 : 50
        self.hudSize = NSSize(width: width, height: height)

        super.init(frame: NSRect(origin: .zero, size: hudSize))
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        let fill =
            success
            ? NSColor.black.withAlphaComponent(0.78)
            : NSColor(calibratedRed: 0.62, green: 0.12, blue: 0.12, alpha: 0.92)
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        fill.setFill()
        path.fill()

        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: titleFont,
            .foregroundColor: NSColor.white,
        ]
        let titleSize = (title as NSString).size(withAttributes: titleAttrs)
        let titleY = bounds.maxY - 9 - titleSize.height
        (title as NSString).draw(at: NSPoint(x: 13, y: titleY), withAttributes: titleAttrs)

        if let detail {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: detailFont,
                .foregroundColor: NSColor.white.withAlphaComponent(0.72),
            ]
            let size = (detail as NSString).size(withAttributes: attrs)
            (detail as NSString).draw(at: NSPoint(x: 13, y: titleY - 2 - size.height), withAttributes: attrs)
        }
    }
}
