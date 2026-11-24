import AppKit
import ApplicationServices
import CoreGraphics
import ImageIO
import UDaSnapCore

/// 滚动截图会话：框选之后自动滚动目标 App，抓帧、拼接、保存、预览。
/// 自动滚动失败时转成手动抓帧，不丢掉已经抓到的部分。
@MainActor
final class ScrollCaptureController {

    private var session: ScrollSession?

    var isRunning: Bool { session != nil }
    var onSaved: ((Bool) -> Void)?

    func start(
        initialImage: CGImage,
        screen: NSScreen,
        selection: CGRect,
        targetPID: pid_t?,
        targetName: String?
    ) {
        guard session == nil else { return }
        let session = ScrollSession(
            initialImage: initialImage,
            screen: screen,
            selection: selection,
            targetPID: targetPID,
            targetName: targetName
        )
        self.session = session
        session.onSaved = { [weak self] success in
            self?.onSaved?(success)
        }
        session.onFinished = { [weak self] in
            self?.session = nil
        }
        session.start()
    }

    /// 撤回同意等场景直接中止，不保存半成品。
    func cancel() {
        session?.cancel()
        session = nil
    }
}

// MARK: - 单次会话

@MainActor
private final class ScrollSession {

    private let initialImage: CGImage
    private let screen: NSScreen
    private let selection: CGRect
    private let targetPID: pid_t?
    private let targetName: String?
    private let globalRect: CGRect
    private let maxHeight = ScrollStitcher.maxHeight

    private var frames: [ScrollFrame] = []
    private var panel: ScrollStatusPanel?
    private var manualTimer: Timer?
    private var originalMouseLocation: CGPoint?
    private var scrollStep: Int32 = -60
    private var axScrollBar: AXUIElement?
    private var axValueStep: Double = 0.02
    private var axLastValue: Double?
    private var axPixelsPerValue: Double?
    private var usingAXScroll = false
    private var pendingCapture: Task<Void, Never>?
    private var globalEscMonitor: Any?
    private var localEscMonitor: Any?

    private var started = false
    private var finished = false
    private var autoMode = false
    private var noProgressCount = 0
    private var estimatedHeight = 0

    var onSaved: ((Bool) -> Void)?
    var onFinished: (() -> Void)?

    init(
        initialImage: CGImage,
        screen: NSScreen,
        selection: CGRect,
        targetPID: pid_t?,
        targetName: String?
    ) {
        self.initialImage = initialImage
        self.screen = screen
        self.selection = selection
        self.targetPID = targetPID
        self.targetName = targetName
        self.globalRect = CGRect(
            x: screen.frame.minX + selection.minX,
            y: screen.frame.minY + selection.minY,
            width: selection.width,
            height: selection.height
        )
    }

    func start() {
        guard !started else { return }
        started = true

        frames = [ScrollFrame(image: initialImage, shift: 0)]
        estimatedHeight = initialImage.height

        originalMouseLocation = NSEvent.mouseLocation
        let panel = ScrollStatusPanel(screen: screen, selection: globalRect)
        panel.onStop = { [weak self] in
            self?.finish(reason: "手动结束")
        }
        self.panel = panel
        panel.update("准备滚动截图…")
        panel.show()

        installEscMonitors()

        // 等遮罩完全消失，并让目标 App 回到前台；否则滚动事件可能落在遮罩或 UDaSnap 上。
        if let targetPID, let app = NSRunningApplication(processIdentifier: targetPID) {
            _ = app.activate(options: [.activateAllWindows])
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            self?.beginCapture()
        }
    }

    private func beginCapture() {
        guard !finished else { return }
        guard HotkeyManager.hasAccessibility else {
            beginManual(reason: "需要辅助功能权限")
            return
        }
        guard targetPID != nil else {
            beginManual(reason: "没有识别到可滚动窗口")
            return
        }

        axValueStep = 0.02
        axLastValue = nil
        axPixelsPerValue = nil
        resolveAXScrollBar()
        autoMode = true
        panel?.update("自动滚动中 · 第 1 帧")
        scheduleAutoStep()
    }

    private func scheduleAutoStep() {
        guard !finished, autoMode else { return }
        if estimatedHeight >= maxHeight {
            finish(reason: "已达到 60000 px 上限")
            return
        }
        if frames.count >= 200 {
            finish(reason: "抓帧次数达到上限")
            return
        }

        postScrollEvent()
        pendingCapture?.cancel()
        // Safari/部分 App 的程序化滚动有短暂动画，抓帧要等它稳定，否则会误判到底。
        pendingCapture = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            self?.captureNextFrame(automatic: true)
        }
    }

    private func captureNextFrame(automatic: Bool) {
        guard !finished else { return }
        guard let frame = captureFrame() else {
            if automatic {
                noProgressCount += 1
                if noProgressCount >= 2 {
                    finish(reason: "抓取画面失败")
                } else {
                    retryCapture(automatic: true)
                }
            }
            return
        }

        guard let previous = frames.last?.image else {
            frames.append(ScrollFrame(image: frame, shift: 0))
            return
        }

        var shift: Int?

        // AX 滚动条值的变化是页面的真实位移。网页里重复的段落布局会让 Vision 把位移
        // 认成一整节（例如 322 px 认成 840 px），因此标定之后优先信 AX，不再逐帧配准。
        if usingAXScroll, let bar = axScrollBar, let last = axLastValue,
            let currentAX = readAXValue(bar), currentAX > last,
            let pixelsPerValue = axPixelsPerValue
        {
            let expected = Int(((currentAX - last) * pixelsPerValue).rounded())
            if expected > 4, expected < frame.height - 4 {
                shift = expected
            }
        }

        if shift == nil {
            shift = ScrollStitcher.shift(from: previous, to: frame)
        }

        if let shift, shift > 4, shift < frame.height - 4 {
            frames.append(ScrollFrame(image: frame, shift: shift))
            estimatedHeight += shift
            noProgressCount = 0
            panel?.update("自动滚动中 · \(frames.count) 帧 · \(estimatedHeight) px")
            if automatic {
                adaptScrollStep(observedShift: shift)
                // 只用第一帧标定一次“像素/滚动条值”，避免周期性版式把比例带偏。
                if usingAXScroll, axPixelsPerValue == nil, let bar = axScrollBar,
                    let last = axLastValue, let currentAX = readAXValue(bar), currentAX > last
                {
                    let valueDelta = currentAX - last
                    if valueDelta > 0 {
                        let pixelsPerValue = Double(shift) / valueDelta
                        let targetPixels = Double(selection.height) / 3.0
                        axPixelsPerValue = pixelsPerValue
                        axValueStep = min(0.15, max(0.008, targetPixels / pixelsPerValue))
                    }
                }
                scheduleAutoStep()
            }
        } else if automatic {
            noProgressCount += 1
            if frames.count <= 1 && noProgressCount >= 1 {
                beginManual(reason: "内容没有滚动")
            } else if noProgressCount >= 3 {
                finish(reason: "已到内容底部")
            } else {
                // 没抓到新内容时把步长放大一点再试，避免一次事件被系统吞掉就误判到底。
                scrollStep = max(-300, Int32(Double(scrollStep) * 1.35))
                retryCapture(automatic: true)
            }
        }
    }

    private func retryCapture(automatic: Bool) {
        // 不重复发滚动：只给滚动动画更多时间，避免两个事件叠加导致位移翻倍、步长失控。
        pendingCapture?.cancel()
        pendingCapture = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(550))
            self?.captureNextFrame(automatic: automatic)
        }
    }

    private func beginManual(reason: String) {
        guard !finished else { return }
        autoMode = false
        pendingCapture?.cancel()
        pendingCapture = nil

        panel?.update("自动滚动不可用：\(reason)\n请手动滚动，Esc 或“结束”保留已截部分")
        let timer = Timer(timeInterval: 0.35, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.captureNextFrame(automatic: false)
            }
        }
        manualTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func captureFrame() -> CGImage? {
        guard let full = CaptureService.capture(screen: screen) else { return nil }
        return CaptureService.crop(image: full, selection: selection, screen: screen)
    }

    private func adaptScrollStep(observedShift: Int) {
        let target = max(80, Int(Double(selection.height) / 3.0))
        if observedShift > target * 2 {
            scrollStep = Int32(Double(scrollStep) / 1.5)
        } else if observedShift < target / 2 {
            scrollStep = Int32(Double(scrollStep) * 1.5)
        }
        scrollStep = max(-300, min(-18, scrollStep))
    }

    private func readAXValue(_ bar: AXUIElement) -> Double? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(bar, kAXValueAttribute as CFString, &ref) == .success else { return nil }
        return (ref as? NSNumber)?.doubleValue
    }

    /// 找出目标选区下面的 AXScrollArea 的垂直滚动条。直接改滚动条比合成滚轮事件可靠，
    /// 不受目标 App 是否 key window、是否有浮层抢走滚轮的影响。
    private func resolveAXScrollBar() {
        axScrollBar = nil
        usingAXScroll = false
        guard HotkeyManager.hasAccessibility, let targetPID else { return }

        let mainTop = NSScreen.screens.first?.frame.maxY ?? 0
        let point = CGPoint(x: globalRect.midX, y: mainTop - globalRect.midY)
        let system = AXUIElementCreateSystemWide()
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success,
            let hit
        else { return }

        var current: AXUIElement? = hit
        for _ in 0..<8 {
            guard let element = current else { break }
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
            let role = roleRef as? String ?? ""
            if role == kAXScrollAreaRole as String {
                var barRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, "AXVerticalScrollBar" as CFString, &barRef) == .success,
                    let barAny = barRef
                {
                    let bar = barAny as! AXUIElement
                    var ownerPID: pid_t = 0
                    AXUIElementGetPid(bar, &ownerPID)
                    if ownerPID == targetPID {
                        axScrollBar = bar
                        usingAXScroll = true
                        axLastValue = readAXValue(bar)
                        return
                    }
                }
            }
            var parentRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parentRef) == .success,
                let parentAny = parentRef
            {
                current = (parentAny as! AXUIElement)
            } else {
                current = nil
            }
        }
    }

    private func scrollUsingAX() -> Bool {
        guard let bar = axScrollBar, let current = readAXValue(bar) else { return false }
        // 每次程序化滚动前都把目标 App 拉回前台/焦点；否则 Safari 可能只更新滚动条值却不重绘页面。
        if let targetPID, let app = NSRunningApplication(processIdentifier: targetPID) {
            _ = app.activate(options: [.activateAllWindows])
            usleep(30_000)
        }
        let target = min(1.0, current + axValueStep)
        guard target > current else {
            axLastValue = current
            return true
        }
        let error = AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, NSNumber(value: target))
        if error == .success {
            axLastValue = current
            return true
        }
        usingAXScroll = false
        return false
    }

    private func postScrollEvent() {
        if usingAXScroll, scrollUsingAX() {
            return
        }
        // 全局滚轮事件按指针所在窗口投递；先移到选区中心，结束后再恢复。
        let mainTop = NSScreen.screens.first?.frame.maxY ?? 0
        let center = CGPoint(x: globalRect.midX, y: mainTop - globalRect.midY)
        CGWarpMouseCursorPosition(center)
        // 每帧用新的 HID 事件源：连续使用同一个源时，系统在十几次事件后会静默丢弃后续滚动。
        let source = CGEventSource(stateID: .hidSystemState)
        if let moved = CGEvent(
            mouseEventSource: source, mouseType: .mouseMoved,
            mouseCursorPosition: center, mouseButton: .left)
        {
            moved.post(tap: .cghidEventTap)
        }
        usleep(30_000)

        guard
            let event = CGEvent(
                scrollWheelEvent2Source: source,
                units: .pixel,
                wheelCount: 1,
                wheel1: scrollStep,
                wheel2: 0,
                wheel3: 0
            )
        else { return }

        event.location = center
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 0)
        event.post(tap: .cghidEventTap)
    }

    private func restoreMouse() {
        guard let originalMouseLocation else { return }
        let mainTop = NSScreen.screens.first?.frame.maxY ?? 0
        CGWarpMouseCursorPosition(
            CGPoint(
                x: originalMouseLocation.x,
                y: mainTop - originalMouseLocation.y))
        self.originalMouseLocation = nil
    }

    private func installEscMonitors() {
        globalEscMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor in self?.finish(reason: "手动停止") }
        }
        localEscMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            self?.finish(reason: "手动停止")
            return nil
        }
    }

    private func removeEscMonitors() {
        if let globalEscMonitor { NSEvent.removeMonitor(globalEscMonitor) }
        if let localEscMonitor { NSEvent.removeMonitor(localEscMonitor) }
        globalEscMonitor = nil
        localEscMonitor = nil
    }

    func cancel() {
        finish(reason: nil, save: false)
    }

    private func finish(reason: String?, save: Bool = true) {
        guard !finished else { return }
        finished = true
        autoMode = false
        pendingCapture?.cancel()
        pendingCapture = nil
        manualTimer?.invalidate()
        manualTimer = nil
        removeEscMonitors()
        restoreMouse()
        panel?.hidePanel()
        panel = nil

        guard save else {
            onFinished?()
            return
        }

        guard frames.count > 1,
            let stitched = ScrollStitcher.compose(frames: frames, maxHeight: maxHeight)
        else {
            NSSound.beep()
            HUDController.shared.show(
                title: "滚动截图失败",
                detail: reason ?? "未检测到滚动内容",
                at: NSEvent.mouseLocation,
                success: false
            )
            onSaved?(false)
            onFinished?()
            return
        }

        ScreenshotStorage.copyToClipboard(stitched)
        let saved = ScreenshotStorage.savePNG(stitched, suffix: "-scroll")
        let size = "\(stitched.width) × \(stitched.height)"

        if let saved {
            HUDController.shared.show(
                title: "已保存",
                detail: "\(targetName ?? "滚动截图")・\(size)",
                at: NSEvent.mouseLocation,
                success: true
            )
            onSaved?(true)
            ScrollPreviewWindowController.shared.show(image: stitched, fileURL: saved)
        } else {
            HUDController.shared.show(
                title: "保存失败",
                detail: "检查 ~/Pictures/UDaSnap 的写入权限",
                at: NSEvent.mouseLocation,
                success: false
            )
            onSaved?(false)
        }
        onFinished?()
    }
}

// MARK: - 滚动状态条

/// 浮在屏幕上但不抢焦点的小状态条；自动滚动/手动回退/结束都从这里反馈。
@MainActor
final class ScrollStatusPanel: NSPanel {

    var onStop: (() -> Void)?

    // 状态条永远不接管键盘/焦点，滚轮事件必须继续落到下面的目标窗口。
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private let label = NSTextField(labelWithString: "")
    private let stopButton = NSButton(title: "结束", target: nil, action: nil)

    init(screen: NSScreen, selection: CGRect) {
        let size = NSSize(width: 368, height: 58)
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.level = .floating
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.hidesOnDeactivate = false
        self.isReleasedWhenClosed = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        self.sharingType = .none  // 尽量不要把状态条本身截进滚动图
        self.becomesKeyOnlyIfNeeded = true

        let content = NSView(frame: NSRect(origin: .zero, size: size))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.82).cgColor
        content.layer?.cornerRadius = 10
        self.contentView = content

        label.frame = NSRect(x: 14, y: 10, width: 276, height: 38)
        label.font = .systemFont(ofSize: 11.5)
        label.textColor = .white
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 2
        content.addSubview(label)

        stopButton.frame = NSRect(x: 298, y: 14, width: 56, height: 30)
        stopButton.bezelStyle = .rounded
        stopButton.controlSize = .small
        stopButton.target = self
        stopButton.action = #selector(stopPressed)
        content.addSubview(stopButton)

        self.setFrameOrigin(position(screen: screen, selection: selection, size: size))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ text: String) {
        label.stringValue = text
    }

    func show() {
        orderFrontRegardless()
    }

    func hidePanel() {
        orderOut(nil)
    }

    @objc private func stopPressed() {
        onStop?()
    }

    /// 优先放到选区外的屏幕边缘；四个位置都被选区挡住时退回顶部居中。
    private func position(screen: NSScreen, selection: CGRect, size: NSSize) -> NSPoint {
        let visible = screen.visibleFrame
        let gap: CGFloat = 14
        let margin: CGFloat = 10
        let candidates = [
            NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - gap),
            NSPoint(x: visible.midX - size.width / 2, y: visible.minY + gap),
            NSPoint(x: visible.minX + margin, y: visible.midY - size.height / 2),
            NSPoint(x: visible.maxX - size.width - margin, y: visible.midY - size.height / 2),
        ]

        for origin in candidates {
            let rect = NSRect(origin: origin, size: size)
            if !rect.intersects(selection) {
                return origin
            }
        }
        return candidates[0]
    }
}
