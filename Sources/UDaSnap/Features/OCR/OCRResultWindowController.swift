import AppKit
import UDaSnapCore

/// 识字结果窗：可编辑的多行文本 + 复制 / 复制并关闭。
/// 每次识别新开一个窗口，互不覆盖；窗口浮在其他应用之上，但不会主动抢焦点。
@MainActor
final class OCRResultWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {

    private static var liveWindows: [OCRResultWindowController] = []

    static func closeAllForConsentRevocation() {
        let windows = liveWindows
        liveWindows.removeAll()
        for controller in windows {
            controller.window?.close()
        }
    }

    private let initialText: String
    private let savedImage: URL?
    private let anchorPoint: NSPoint
    private let textView = NSTextView()
    private var hintLabel: NSTextField!
    private var countLabel: NSTextField!

    static func present(text: String, savedImage: URL?, at point: NSPoint) {
        let controller = OCRResultWindowController(text: text, savedImage: savedImage, at: point)
        liveWindows.append(controller)

        let copied = ScreenshotStorage.copyText(text)
        controller.setHint(
            copied
                ? "初次结果已自动复制；可直接修改，再点「复制」。"
                : "初次结果未能写入剪贴板；请修改后手动点「复制」。")
        controller.window?.orderFrontRegardless()
    }

    private init(text: String, savedImage: URL?, at point: NSPoint) {
        self.initialText = text
        self.savedImage = savedImage
        self.anchorPoint = point

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "识别结果"
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 360, height: 240)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = true

        super.init(window: panel)
        panel.delegate = self
        buildUI()
        positionWindow()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let hint = NSTextField(wrappingLabelWithString: "")
        hint.frame = NSRect(x: 16, y: 380, width: 528, height: 32)
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.maximumNumberOfLines = 2
        hintLabel = hint
        content.addSubview(hint)

        let scroll = NSScrollView(frame: NSRect(x: 16, y: 54, width: 528, height: 318))
        scroll.autoresizingMask = [.width, .height]
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor

        textView.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: scroll.contentSize.height)
        textView.autoresizingMask = [.width]
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: 13)
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.delegate = self
        textView.string = initialText
        scroll.documentView = textView
        content.addSubview(scroll)

        countLabel = NSTextField(labelWithString: "")
        countLabel.frame = NSRect(x: 16, y: 20, width: 300, height: 18)
        countLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        countLabel.textColor = .secondaryLabelColor
        content.addSubview(countLabel)
        updateCounts()

        let copyClose = NSButton(title: "复制并关闭", target: self, action: #selector(copyAndClose))
        copyClose.frame = NSRect(x: 428, y: 12, width: 116, height: 30)
        copyClose.bezelStyle = .rounded
        content.addSubview(copyClose)

        let copy = NSButton(title: "复制", target: self, action: #selector(copyOnly))
        copy.frame = NSRect(x: 336, y: 12, width: 80, height: 30)
        copy.bezelStyle = .rounded
        content.addSubview(copy)
    }

    private func positionWindow() {
        guard let window else { return }
        let screen = NSScreen.screens.first { $0.frame.contains(anchorPoint) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = window.frame.size
        let offset = CGFloat(Self.liveWindows.count) * 22
        var origin = NSPoint(
            x: visible.midX - size.width / 2 + offset,
            y: visible.midY - size.height / 2 - offset)
        origin.x = min(max(origin.x, visible.minX + 8), max(visible.minX + 8, visible.maxX - size.width - 8))
        origin.y = min(max(origin.y, visible.minY + 8), max(visible.minY + 8, visible.maxY - size.height - 8))
        window.setFrameOrigin(origin)
    }

    private func updateCounts() {
        let text = textView.string
        let lines = text.isEmpty ? 0 : text.components(separatedBy: "\n").count
        var value = "\(text.count) 字 · \(lines) 行"
        if savedImage == nil { value += " · 原图保存失败" }
        countLabel.stringValue = value
    }

    private func setHint(_ text: String) {
        hintLabel.stringValue = text
        hintLabel.textColor =
            savedImage == nil && text.contains("原图保存失败")
            ? .systemRed
            : .secondaryLabelColor
    }

    func textDidChange(_ notification: Notification) {
        updateCounts()
        setHint("已修改，点「复制」更新剪贴板。")
    }

    @objc private func copyOnly() { copyCurrent(closeAfter: false) }

    @objc private func copyAndClose() { copyCurrent(closeAfter: true) }

    private func copyCurrent(closeAfter: Bool) {
        let current = textView.string
        guard !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            setHint("没有可复制的文字。")
            return
        }
        guard ScreenshotStorage.copyText(current) else {
            setHint("复制失败，请手动选择文字后复制。")
            return
        }

        setHint("已复制 \(current.count) 字。")
        HUDController.shared.show(
            title: "已复制",
            detail: "识字・\(current.count) 字",
            at: NSEvent.mouseLocation,
            success: true
        )
        if closeAfter { window?.close() }
    }

    func windowWillClose(_ notification: Notification) {
        Self.liveWindows.removeAll { $0 === self }
    }
}
