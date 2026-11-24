import AppKit
import UDaSnapCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var menuBar: MenuBarController?
    private var hotkey: HotkeyManager?
    private var selection: RegionSelectionController?
    private let pinStore = PinStore()
    private var annotationCoordinator: AnnotationCoordinator?
    private var complianceObservers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installMainMenu()
        ScreenshotStorage.ensureFolder()

        let menuBar = MenuBarController()
        self.menuBar = menuBar

        let selection = RegionSelectionController(pinStore: pinStore)
        self.selection = selection
        let annotationCoordinator = AnnotationCoordinator(pinStore: pinStore)
        self.annotationCoordinator = annotationCoordinator
        // 截图模式保存成功后闪一下菜单栏图标；标注完成也复用同一个反馈。
        selection.onSaved = { [weak menuBar] success in
            guard success else { return }
            menuBar?.flash()
        }
        annotationCoordinator.onSaved = selection.onSaved
        selection.onAnnotate = { [weak annotationCoordinator] image, scale, origin, screen in
            annotationCoordinator?.present(
                image: image, contentScale: scale, screen: screen, pinOrigin: origin)
        }

        menuBar.onAnnotateRegion = { selection.begin(mode: .annotate) }
        menuBar.onAnnotateWindow = { selection.begin(mode: .annotateWindow) }
        menuBar.onAnnotateFullScreen = { [weak self] screen in
            self?.captureFullScreen(on: screen, menuBar: nil, annotate: true)
        }
        menuBar.onCapture = { selection.begin(mode: .save) }
        menuBar.onCaptureFullScreen = { [weak self, weak menuBar] screen in
            self?.captureFullScreen(on: screen, menuBar: menuBar)
        }
        menuBar.onCaptureApp = { selection.begin(mode: .app) }
        menuBar.onCaptureScroll = { selection.begin(mode: .scroll) }
        menuBar.onCaptureOCR = { selection.begin(mode: .ocr) }
        menuBar.onCaptureAI = { selection.begin(mode: .ai) }
        menuBar.onCaptureTranslate = { selection.begin(mode: .aiTranslate) }
        menuBar.onPinCapture = { selection.begin(mode: .pin) }
        menuBar.onOpenFolder = { ScreenshotStorage.revealFolder() }
        menuBar.onQuit = { NSApp.terminate(nil) }

        let hotkey = HotkeyManager(settings: SettingsFile.load())
        self.hotkey = hotkey
        hotkey.onFirePin = { selection.begin(mode: .pin) }
        hotkey.onFireSave = { selection.begin(mode: .save) }
        hotkey.onFireApp = { selection.begin(mode: .app) }
        hotkey.onFireScroll = { selection.begin(mode: .scroll) }
        hotkey.onFireOCR = { selection.begin(mode: .ocr) }
        hotkey.onFireAnnotation = { selection.begin(mode: .annotate) }
        // 配置一变就刷新菜单，录制期间（热键暂停注册）也一样，菜单显示的始终是最新键位。
        hotkey.onSettingsChange = { [weak menuBar] settings in
            menuBar?.updateHotkeys(
                pin: settings.pin, save: settings.save, app: settings.app,
                scroll: settings.scroll, ocr: settings.ocr, annotation: settings.annotation)
        }
        menuBar.onOpenSettings = { [weak self] in
            guard let self else { return }
            guard AppEnvironment.shared.compliance.isAccepted else {
                self.presentOnboarding()
                return
            }
            SettingsWindowController.shared.show(manager: hotkey, page: .ai)
        }
        selection.onOpenAISettings = { [weak self] in
            guard let self else { return }
            guard AppEnvironment.shared.compliance.isAccepted else {
                self.presentOnboarding()
                return
            }
            SettingsWindowController.shared.show(manager: hotkey, page: .ai)
        }
        menuBar.updateHotkeys(
            pin: hotkey.settings.pin,
            save: hotkey.settings.save,
            app: hotkey.settings.app,
            scroll: hotkey.settings.scroll,
            ocr: hotkey.settings.ocr,
            annotation: hotkey.settings.annotation
        )

        installComplianceObservers()

        if AppEnvironment.shared.compliance.isAccepted {
            startApplicationAfterConsent()
        } else {
            presentOnboarding()
        }

        // 便于首次配置：`open -a UDaSnap --args --settings` 直接弹出偏好设置（默认 AI 页）。
        if CommandLine.arguments.contains("--settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self else { return }
                guard AppEnvironment.shared.compliance.isAccepted else {
                    self.presentOnboarding()
                    return
                }
                SettingsWindowController.shared.show(manager: hotkey, page: .ai)
            }
        }
    }

    private func installComplianceObservers() {
        complianceObservers.append(
            NotificationCenter.default.addObserver(
                forName: .configurationCleared,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.handleConfigurationCleared() }
            })
        complianceObservers.append(
            NotificationCenter.default.addObserver(
                forName: .withdrawConsent,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.handleWithdrawConsent() }
            })
    }

    private func startApplicationAfterConsent() {
        guard AppEnvironment.shared.compliance.isAccepted else {
            presentOnboarding()
            return
        }
        hotkey?.start()
        applyRetentionPolicy()
    }

    private func applyRetentionPolicy() {
        let days = AppEnvironment.shared.compliance.settings.retentionDays
        guard days > 0 else { return }
        _ = ScreenshotStorage.deleteScreenshots(olderThan: days)
    }

    private func presentOnboarding(flushSettings: Bool = true) {
        hotkey?.stop()
        selection?.cancelAll()
        annotationCoordinator?.dismiss()
        pinStore.closeAll()
        AIResultWindowController.closeAllForConsentRevocation()
        OCRResultWindowController.closeAllForConsentRevocation()
        ScrollPreviewWindowController.shared.dismiss()
        SettingsWindowController.shared.dismissForComplianceChange(flush: flushSettings)

        OnboardingWindowController.show { [weak self] in
            AppEnvironment.shared.compliance.accept()
            self?.startApplicationAfterConsent()
        } onDecline: {
            NSApp.terminate(nil)
        }
    }

    @objc private func handleConfigurationCleared() {
        hotkey?.resetToDefaultsWithoutPersisting()
        // 配置已经从磁盘和钥匙串删掉，不要再用设置页里的旧值 flush 回去。
        presentOnboarding(flushSettings: false)
    }

    @objc private func handleWithdrawConsent() {
        AppEnvironment.shared.compliance.revoke()
        presentOnboarding()
    }

    /// 装上标准「编辑」菜单后，快捷键由主菜单转发给当前第一响应者。
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu(title: "UDaSnap")
        appMenuItem.submenu = appMenu
        appMenu.addItem(
            withTitle: "关于 UDaSnap",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "退出 UDaSnap",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "编辑")
        editMenuItem.submenu = editMenu

        editMenu.addItem(withTitle: "撤销", action: #selector(UndoManager.undo), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "重做", action: #selector(UndoManager.redo), keyEquivalent: "Z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        let copyItem = editMenu.addItem(
            withTitle: "复制",
            action: #selector(AppDelegate.copyText(_:)),
            keyEquivalent: "c"
        )
        copyItem.target = self
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        NSApp.mainMenu = mainMenu
    }

    /// 安全输入框会拒绝系统的 copy:，这里在编辑菜单层接管一次。
    /// 焦点不在 API Key 时，仍然转发给普通文本框处理。
    @objc private func copyText(_ sender: Any?) {
        if SettingsWindowController.shared.copyFocusedAIKey() {
            return
        }
        NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: sender)
    }

    /// 立即截取整块屏幕（含菜单栏与 Dock），复制并保存，不贴图。
    private func captureFullScreen(on screen: NSScreen, menuBar: MenuBarController?, annotate: Bool = false) {
        guard AppEnvironment.shared.compliance.isAccepted else {
            presentOnboarding()
            return
        }
        guard CaptureService.hasPermission else {
            CaptureService.requestPermission()
            CaptureService.openPermissionSettings()
            return
        }

        // 菜单项点击后菜单还在收起；等它完全消失再截，避免把菜单本身截进去。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self, weak menuBar] in
            guard let image = CaptureService.capture(screen: screen) else {
                NSSound.beep()
                HUDController.shared.show(
                    title: "全屏截图失败",
                    detail: "检查屏幕录制权限",
                    at: NSEvent.mouseLocation,
                    success: false
                )
                return
            }

            if annotate {
                self?.annotationCoordinator?.present(
                    image: image,
                    contentScale: screen.backingScaleFactor,
                    screen: screen,
                    pinOrigin: NSEvent.mouseLocation)
                return
            }

            ScreenshotStorage.copyToClipboard(image)
            let saved = ScreenshotStorage.savePNG(image)
            let size = "\(image.width) × \(image.height)"

            if saved != nil {
                HUDController.shared.show(
                    title: "已保存",
                    detail: "全屏・\(size)",
                    at: NSEvent.mouseLocation,
                    success: true
                )
                menuBar?.flash()
            } else {
                HUDController.shared.show(
                    title: "保存失败",
                    detail: "检查 ~/Pictures/UDaSnap 的写入权限",
                    at: NSEvent.mouseLocation,
                    success: false
                )
            }
        }
    }

    // 用户在系统设置里开了权限再切回来时，菜单栏状态要跟着变。
    func applicationDidBecomeActive(_ notification: Notification) {
        menuBar?.refreshPermissionState()
    }
}
