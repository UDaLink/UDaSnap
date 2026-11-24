import AppKit
import UDaSnapCore

/// 在 App 内离线显示随包的法律文档。
@MainActor
final class LegalDocumentWindowController: NSWindowController, NSWindowDelegate {

    private static var liveWindows: [LegalDocumentWindowController] = []
    private let kind: LegalDocumentKind

    static func show(_ kind: LegalDocumentKind) {
        let controller = LegalDocumentWindowController(kind: kind)
        liveWindows.append(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    init(kind: LegalDocumentKind) {
        self.kind = kind
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(kind.title) · v\(LegalDocuments.policyVersion)"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 620, height: 480)
        super.init(window: window)
        window.delegate = self
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let scroll = NSScrollView(frame: NSRect(x: 20, y: 58, width: 720, height: 580))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        content.addSubview(scroll)

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 1))
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: 700, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 700, height: CGFloat.greatestFiniteMagnitude)
        textView.textStorage?.setAttributedString(
            LegalDocuments.attributedMarkdown(LegalDocuments.bundledText(for: kind))
        )
        textView.textColor = .labelColor
        textView.sizeToFit()
        scroll.documentView = textView

        let close = NSButton(title: "关闭", target: self, action: #selector(closeDocument))
        close.bezelStyle = .rounded
        close.keyEquivalent = "\r"
        close.frame = NSRect(x: 640, y: 16, width: 100, height: 30)
        close.autoresizingMask = [.minXMargin, .maxYMargin]
        content.addSubview(close)
    }

    @objc private func closeDocument() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        Self.liveWindows.removeAll { $0 === self }
    }
}
