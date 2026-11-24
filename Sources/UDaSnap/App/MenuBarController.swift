import AppKit
import QuartzCore
import ServiceManagement
import UDaSnapCore

/// 菜单栏入口：框选截图、全屏截图、应用窗口截图、滚动截图、截图并贴图、截图并翻译、文字提取（OCR）、文字提取-AI分析、偏好设置、目录、自启、权限状态、退出。
@MainActor
final class MenuBarController: NSObject {

    /// 框选截图（只保存，不贴图）
    var onCapture: (() -> Void)?
    /// 全屏截图（截鼠标所在屏，只保存，不贴图）
    var onCaptureFullScreen: ((NSScreen) -> Void)?
    /// 应用窗口截图（只保存，不贴图）
    var onCaptureApp: (() -> Void)?
    /// 滚动截图（自动滚动拼接，完成后预览）
    var onCaptureScroll: (() -> Void)?
    /// 文字提取（OCR，框选后识别文字）
    var onCaptureOCR: (() -> Void)?
    /// 文字提取-AI分析（框选后打开左图右结果窗，不设快捷键）
    var onCaptureAI: (() -> Void)?
    /// 截图并翻译（先智能合并换行，再自动翻译，不设快捷键）
    var onCaptureTranslate: (() -> Void)?
    /// 截图并贴图
    var onPinCapture: (() -> Void)?
    /// 标注截图：框选区域
    var onAnnotateRegion: (() -> Void)?
    /// 标注截图：应用窗口
    var onAnnotateWindow: (() -> Void)?
    /// 标注截图：全屏
    var onAnnotateFullScreen: ((NSScreen) -> Void)?
    var onOpenFolder: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onQuit: (() -> Void)?

    private var pinHotkey: HotkeyConfig = .pinDefault
    private var saveHotkey: HotkeyConfig = .saveDefault
    private var appHotkey: HotkeyConfig = .appDefault
    private var scrollHotkey: HotkeyConfig = .scrollDefault
    private var ocrHotkey: HotkeyConfig = .ocrDefault
    private var annotationHotkey: HotkeyConfig = .annotationDefault
    private var pinHotkeyTitle: String { pinHotkey.display }
    private var saveHotkeyTitle: String { saveHotkey.display }
    private var appHotkeyTitle: String { appHotkey.display }
    private var scrollHotkeyTitle: String { scrollHotkey.display }
    private var ocrHotkeyTitle: String { ocrHotkey.display }
    private var annotationHotkeyTitle: String { annotationHotkey.display }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var permissionItem: NSMenuItem?
    private var launchItem: NSMenuItem?

    override init() {
        super.init()
        configureIcon()
        rebuildMenu()
    }

    private func configureIcon() {
        guard let button = statusItem.button else { return }
        button.image = BrandMark.statusImage()
        button.toolTip =
            "UDaSnap · 截图 \(saveHotkeyTitle) / 应用 \(appHotkeyTitle) / 滚动 \(scrollHotkeyTitle) / 识字 \(ocrHotkeyTitle) / 贴图 \(pinHotkeyTitle) / 标注 \(annotationHotkeyTitle)"
        button.wantsLayer = true
    }

    func rebuildMenu() {
        let menu = NSMenu()

        let annotateItem = NSMenuItem(title: "标注截图", action: nil, keyEquivalent: "")
        let annotateMenu = NSMenu(title: "标注截图")
        let annotateRegion = makeCaptureItem(
            title: "框选标注",
            config: annotationHotkey,
            action: #selector(annotateRegion))
        annotateMenu.addItem(annotateRegion)
        let annotateWindow = NSMenuItem(
            title: "窗口标注", action: #selector(annotateWindow), keyEquivalent: "")
        annotateWindow.target = self
        annotateMenu.addItem(annotateWindow)
        let annotateFullScreen = NSMenuItem(
            title: "全屏标注", action: #selector(annotateFullScreen), keyEquivalent: "")
        annotateFullScreen.target = self
        annotateMenu.addItem(annotateFullScreen)
        annotateItem.submenu = annotateMenu
        menu.addItem(annotateItem)

        let save = makeCaptureItem(title: "框选截图", config: saveHotkey, action: #selector(captureNow))
        menu.addItem(save)

        let full = NSMenuItem(title: "全屏截图", action: #selector(captureFullScreen), keyEquivalent: "")
        full.target = self
        menu.addItem(full)

        let app = makeCaptureItem(title: "应用窗口截图", config: appHotkey, action: #selector(captureApp))
        menu.addItem(app)

        let scroll = makeCaptureItem(title: "滚动截图", config: scrollHotkey, action: #selector(captureScroll))
        menu.addItem(scroll)

        let pin = makeCaptureItem(title: "截图并贴图", config: pinHotkey, action: #selector(capturePin))
        menu.addItem(pin)

        let translate = NSMenuItem(title: "截图并翻译", action: #selector(captureTranslate), keyEquivalent: "")
        translate.target = self
        menu.addItem(translate)

        let ocr = makeCaptureItem(title: "文字提取（OCR）", config: ocrHotkey, action: #selector(captureOCR))
        menu.addItem(ocr)

        let ai = NSMenuItem(title: "文字提取-AI分析", action: #selector(captureAI), keyEquivalent: "")
        ai.target = self
        menu.addItem(ai)

        menu.addItem(.separator())

        let folder = NSMenuItem(title: "打开保存目录", action: #selector(openFolder), keyEquivalent: "")
        folder.target = self
        menu.addItem(folder)

        let settings = NSMenuItem(title: "偏好设置", action: #selector(openHotkeyPrefs), keyEquivalent: ",")
        settings.keyEquivalentModifierMask = [.command]
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let granted = CaptureService.hasPermission
        let permissionTitle = granted ? "屏幕录制：已授权" : "⚠️ 屏幕录制：未授权（点此去开）"
        let perm = NSMenuItem(
            title: permissionTitle,
            action: granted ? nil : #selector(openPermission),
            keyEquivalent: ""
        )
        perm.target = self
        permissionItem = perm
        menu.addItem(perm)

        let launch = NSMenuItem(title: "开机自启", action: #selector(toggleLaunch), keyEquivalent: "")
        launch.target = self
        launch.state = isLaunchAtLogin ? .on : .off
        launchItem = launch
        menu.addItem(launch)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出 UDaSnap", action: #selector(quit), keyEquivalent: "q")
        quit.keyEquivalentModifierMask = [.command]
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        statusItem.button?.appearsDisabled = !granted
    }

    /// 用 NSMenuItem 原生快捷键列显示键位：AppKit 自动右对齐、统一灰色小字，
    /// 并且和 ⌘, / ⌘Q 落在同一列。录制出来的超常规键没有单字符等价物时，退回文字后缀显示。
    private func makeCaptureItem(title: String, config: HotkeyConfig, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        if let key = config.menuKeyEquivalent {
            item.keyEquivalent = key
            item.keyEquivalentModifierMask = config.menuModifiers
        } else {
            item.attributedTitle = fallbackTitle(title: title, hotkey: config.display)
        }
        return item
    }

    private func fallbackTitle(title: String, hotkey: String) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: title,
            attributes: [
                .font: NSFont.menuFont(ofSize: 0),
                .foregroundColor: NSColor.labelColor,
            ]
        )
        result.append(
            NSAttributedString(
                string: "  " + hotkey,
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
            ))
        return result
    }

    func refreshPermissionState() { rebuildMenu() }

    private var isLaunchAtLogin: Bool {
        if #available(macOS 13, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    /// 保存成功后状态栏图标闪两下，给一个“已经存了”的反馈。
    func flash() {
        guard let button = statusItem.button, let layer = button.layer else { return }
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = [1.0, 0.35, 1.0, 0.35, 1.0]
        animation.duration = 0.45
        layer.add(animation, forKey: "udasnap.flash")
    }

    @objc private func captureNow() {
        onCapture?()
        // 截图会话结束后刷新权限显示。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.refreshPermissionState()
        }
    }

    @objc private func annotateRegion() {
        onAnnotateRegion?()
    }

    @objc private func annotateWindow() {
        onAnnotateWindow?()
    }

    @objc private func annotateFullScreen() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) else { return }
        onAnnotateFullScreen?(screen)
    }

    @objc private func capturePin() {
        onPinCapture?()
    }

    @objc private func captureFullScreen() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) else { return }
        onCaptureFullScreen?(screen)
    }

    @objc private func captureApp() {
        onCaptureApp?()
    }

    @objc private func captureScroll() {
        onCaptureScroll?()
    }

    @objc private func captureOCR() {
        onCaptureOCR?()
    }

    @objc private func captureAI() {
        onCaptureAI?()
    }

    @objc private func captureTranslate() {
        onCaptureTranslate?()
    }

    @objc private func openFolder() { onOpenFolder?() }

    @objc private func openHotkeyPrefs() { onOpenSettings?() }

    /// 快捷键变更后更新菜单、提示文案与工具提示。
    func updateHotkeys(
        pin: HotkeyConfig, save: HotkeyConfig, app: HotkeyConfig, scroll: HotkeyConfig, ocr: HotkeyConfig,
        annotation: HotkeyConfig
    ) {
        pinHotkey = pin
        saveHotkey = save
        appHotkey = app
        scrollHotkey = scroll
        ocrHotkey = ocr
        annotationHotkey = annotation
        statusItem.button?.toolTip =
            "UDaSnap · 截图 \(save.display) / 应用 \(app.display) / 滚动 \(scroll.display) / 识字 \(ocr.display) / 贴图 \(pin.display) / 标注 \(annotation.display)"
        rebuildMenu()
    }

    @objc private func openPermission() {
        CaptureService.requestPermission()
        CaptureService.openPermissionSettings()
    }

    @objc private func toggleLaunch() {
        guard #available(macOS 13, *) else { return }
        do {
            if isLaunchAtLogin {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "开机自启设置失败"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
        launchItem?.state = isLaunchAtLogin ? .on : .off
    }

    @objc private func quit() { onQuit?() }
}
