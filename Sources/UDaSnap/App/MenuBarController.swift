import AppKit
import QuartzCore
import ServiceManagement
import UDaSnapCore

/// 菜单栏入口：立即截图、截图并贴图、框选截图、全屏截图、应用窗口截图、滚动截图、截图并翻译、文字提取（OCR）、文字提取-AI分析、偏好设置、目录、自启、权限状态、退出。
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {

    /// 立即截图（框选后保留选区，标注 / 贴图 / 取消）
    var onImmediateCapture: (() -> Void)?
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
    private var fullScreenHotkey: HotkeyConfig = .fullScreenDefault
    private var appHotkey: HotkeyConfig = .appDefault
    private var scrollHotkey: HotkeyConfig = .scrollDefault
    private var immediateHotkey: HotkeyConfig = .immediateDefault
    private var pinHotkeyTitle: String { pinHotkey.display }
    private var saveHotkeyTitle: String { saveHotkey.display }
    private var fullScreenHotkeyTitle: String { fullScreenHotkey.display }
    private var appHotkeyTitle: String { appHotkey.display }
    private var scrollHotkeyTitle: String { scrollHotkey.display }
    private var immediateHotkeyTitle: String { immediateHotkey.display }

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
            "UDaSnap · 立即 \(immediateHotkeyTitle) / 贴图 \(pinHotkeyTitle) / 截图 \(saveHotkeyTitle) / 全屏 \(fullScreenHotkeyTitle) / 应用 \(appHotkeyTitle) / 滚动 \(scrollHotkeyTitle)"
        button.wantsLayer = true
    }

    func rebuildMenu() {
        let menu = NSMenu()

        let immediate = makeCaptureItem(
            title: "立即截图", config: immediateHotkey, action: #selector(captureImmediate))
        menu.addItem(immediate)

        let pin = makeCaptureItem(title: "截图并贴图", config: pinHotkey, action: #selector(capturePin))
        menu.addItem(pin)

        let save = makeCaptureItem(title: "框选截图", config: saveHotkey, action: #selector(captureNow))
        menu.addItem(save)

        let full = makeCaptureItem(
            title: "全屏截图", config: fullScreenHotkey, action: #selector(captureFullScreen))
        menu.addItem(full)

        let app = makeCaptureItem(title: "应用窗口截图", config: appHotkey, action: #selector(captureApp))
        menu.addItem(app)

        let scroll = makeCaptureItem(title: "滚动截图", config: scrollHotkey, action: #selector(captureScroll))
        menu.addItem(scroll)

        let translate = NSMenuItem(title: "截图并翻译", action: #selector(captureTranslate), keyEquivalent: "")
        translate.target = self
        menu.addItem(translate)

        let ocr = NSMenuItem(title: "文字提取（OCR）", action: #selector(captureOCR), keyEquivalent: "")
        ocr.target = self
        menu.addItem(ocr)

        let ai = NSMenuItem(title: "文字提取-AI分析", action: #selector(captureAI), keyEquivalent: "")
        ai.target = self
        menu.addItem(ai)

        let annotateItem = NSMenuItem(title: "标注截图", action: nil, keyEquivalent: "")
        let annotateMenu = NSMenu(title: "标注截图")
        let annotateRegion = NSMenuItem(
            title: "框选标注", action: #selector(annotateRegion), keyEquivalent: "")
        annotateRegion.target = self
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
        menu.delegate = self
        // 权限未授权时只把状态写进菜单，不要禁用状态栏图标本身；
        // 否则用户点不到菜单，也就没法打开系统设置补授权。
        statusItem.button?.appearsDisabled = false
    }

    /// 菜单每次打开都重新读取 TCC 状态，避免用户在系统设置里授权后
    /// 菜单仍显示旧的「未授权」。
    func menuWillOpen(_ menu: NSMenu) {
        guard menu === statusItem.menu else { return }
        let granted = CaptureService.hasPermission
        permissionItem?.title =
            granted ? "屏幕录制：已授权" : "⚠️ 屏幕录制：未授权（点此去开）"
        permissionItem?.action = granted ? nil : #selector(openPermission)
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

    @objc private func captureImmediate() {
        onImmediateCapture?()
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
        immediate: HotkeyConfig, pin: HotkeyConfig, save: HotkeyConfig,
        fullScreen: HotkeyConfig, app: HotkeyConfig, scroll: HotkeyConfig
    ) {
        immediateHotkey = immediate
        pinHotkey = pin
        saveHotkey = save
        fullScreenHotkey = fullScreen
        appHotkey = app
        scrollHotkey = scroll
        statusItem.button?.toolTip =
            "UDaSnap · 立即 \(immediate.display) / 贴图 \(pin.display) / 截图 \(save.display) / 全屏 \(fullScreen.display) / 应用 \(app.display) / 滚动 \(scroll.display)"
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
