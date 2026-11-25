import AppKit
import ApplicationServices
import Carbon
import UDaSnapCore

/// 全局热键。六套模式各有一个主键和一个固定备用键：
/// - 贴图：主键可改（默认 ⌘F1），备用 ⌥⇧1
/// - 框选截图：主键可改（默认 ⌘F2），备用 ⌥⇧2
/// - 全屏截图：主键可改（默认 ⌘F3），备用 ⌥⇧3
/// - 应用窗口：主键可改（默认 ⌘F4），备用 ⌥⇧4
/// - 滚动截图：主键可改（默认 ⌘F5），备用 ⌥⇧5
/// - 立即截图：主键可改（默认 ⌘F6），备用 ⌥⇧6
///
/// 主键走 Carbon `RegisterEventHotKey`，不需要额外权限。
/// 强力模式（`forceTap`）用一个 `CGEvent` tap 同时匹配六套主键，
/// 在系统分发之前把按键吞掉，代价是需要「辅助功能」授权。
/// 备用键始终走 Carbon，保证强力模式失效时还有退路。
///
/// F1~F6 裸按会被系统功能键接管；这里统一带 ⌘ 修饰，避免和系统亮度/调度中心冲突。
@MainActor
final class HotkeyManager {

    enum Status: Equatable {
        case carbonOK
        case carbonFailed(OSStatus)
        case tapRunning
        case tapNoAccessibility
        case tapFailed
    }

    struct Statuses: Equatable {
        var pin: Status = .carbonFailed(-1)
        var save: Status = .carbonFailed(-1)
        var fullScreen: Status = .carbonFailed(-1)
        var app: Status = .carbonFailed(-1)
        var scroll: Status = .carbonFailed(-1)
        var immediate: Status = .carbonFailed(-1)
        var pinAlt: OSStatus = -1
        var saveAlt: OSStatus = -1
        var fullScreenAlt: OSStatus = -1
        var appAlt: OSStatus = -1
        var scrollAlt: OSStatus = -1
        var immediateAlt: OSStatus = -1
    }

    private(set) var settings: AppSettings
    private(set) var statuses = Statuses()

    var onFirePin: (() -> Void)?
    var onFireSave: (() -> Void)?
    var onFireFullScreen: (() -> Void)?
    var onFireApp: (() -> Void)?
    var onFireScroll: (() -> Void)?
    var onFireImmediate: (() -> Void)?
    var onStatusChange: ((Statuses) -> Void)?
    /// 配置一变就通知，和注册状态无关；菜单栏用它同步显示新的键位。
    var onSettingsChange: ((AppSettings) -> Void)?

    private var pinRef: EventHotKeyRef?
    private var saveRef: EventHotKeyRef?
    private var fullScreenRef: EventHotKeyRef?
    private var appRef: EventHotKeyRef?
    private var scrollRef: EventHotKeyRef?
    private var immediateRef: EventHotKeyRef?
    private var pinAltRef: EventHotKeyRef?
    private var saveAltRef: EventHotKeyRef?
    private var fullScreenAltRef: EventHotKeyRef?
    private var appAltRef: EventHotKeyRef?
    private var scrollAltRef: EventHotKeyRef?
    private var immediateAltRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var suspended = false

    private static let signature = OSType(0x5544_534E)  // 'UDSN'
    private static let pinID: UInt32 = 3
    private static let pinAltID: UInt32 = 2
    private static let saveID: UInt32 = 4
    private static let saveAltID: UInt32 = 5
    private static let fullScreenID: UInt32 = 12
    private static let fullScreenAltID: UInt32 = 13
    private static let appID: UInt32 = 6
    private static let appAltID: UInt32 = 7
    private static let scrollID: UInt32 = 8
    private static let scrollAltID: UInt32 = 9
    private static let immediateID: UInt32 = 10
    private static let immediateAltID: UInt32 = 11

    init(settings: AppSettings = SettingsFile.load()) {
        self.settings = settings
    }

    // MARK: 启动 / 重载

    func start() {
        installCarbonHandler()
        registerAll()
    }

    /// 撤回同意或退出合规门禁时注销全部热键，避免后台还能截屏。
    func stop() {
        suspended = false
        unregisterAll()
        statuses = Statuses()
        onStatusChange?(statuses)
    }

    /// 清除应用配置时把内存恢复默认，但不写回 settings.json。
    func resetToDefaultsWithoutPersisting() {
        stop()
        settings = .default
        SettingsFile.delete()
        onSettingsChange?(settings)
    }

    private func unregisterAll() {
        unregisterPrimary()
        if let ref = pinAltRef {
            UnregisterEventHotKey(ref)
            pinAltRef = nil
        }
        if let ref = saveAltRef {
            UnregisterEventHotKey(ref)
            saveAltRef = nil
        }
        if let ref = appAltRef {
            UnregisterEventHotKey(ref)
            appAltRef = nil
        }
        if let ref = scrollAltRef {
            UnregisterEventHotKey(ref)
            scrollAltRef = nil
        }
        if let ref = fullScreenAltRef {
            UnregisterEventHotKey(ref)
            fullScreenAltRef = nil
        }
        if let ref = immediateAltRef {
            UnregisterEventHotKey(ref)
            immediateAltRef = nil
        }
        statuses.pinAlt = -1
        statuses.saveAlt = -1
        statuses.fullScreenAlt = -1
        statuses.appAlt = -1
        statuses.scrollAlt = -1
        statuses.immediateAlt = -1
        stopTap()
    }

    /// 保存新配置并重新注册。录制中（suspended）只落盘，等 resume 再注册。
    func update(_ newSettings: AppSettings) {
        settings = newSettings
        SettingsFile.save(newSettings)
        onSettingsChange?(newSettings)
        guard !suspended else { return }
        unregisterPrimary()
        registerAll()
    }

    func reload() {
        guard !suspended else { return }
        unregisterPrimary()
        registerAll()
    }

    /// 录制键位时临时停掉所有热键，避免按键先把截图触发出来。
    func suspend() {
        guard !suspended else { return }
        suspended = true
        unregisterPrimary()
        stopTap()
    }

    func resume() {
        guard suspended else { return }
        suspended = false
        registerAll()
    }

    private func registerAll() {
        guard !suspended else { return }

        registerAltKeys()

        if settings.forceTap {
            unregisterPrimary()
            stopTap()
            if startTap() {
                statuses.pin = .tapRunning
                statuses.save = .tapRunning
                statuses.fullScreen = .tapRunning
                statuses.app = .tapRunning
                statuses.scroll = .tapRunning
                statuses.immediate = .tapRunning
            } else {
                statuses.pin = .tapNoAccessibility
                statuses.save = .tapNoAccessibility
                statuses.fullScreen = .tapNoAccessibility
                statuses.app = .tapNoAccessibility
                statuses.scroll = .tapNoAccessibility
                statuses.immediate = .tapNoAccessibility
            }
        } else {
            stopTap()
            let pinStatus = registerCarbon(settings.pin, id: Self.pinID, ref: &pinRef)
            let saveStatus = registerCarbon(settings.save, id: Self.saveID, ref: &saveRef)
            let fullScreenStatus = registerCarbon(
                settings.fullScreen, id: Self.fullScreenID, ref: &fullScreenRef)
            let appStatus = registerCarbon(settings.app, id: Self.appID, ref: &appRef)
            let scrollStatus = registerCarbon(settings.scroll, id: Self.scrollID, ref: &scrollRef)
            let immediateStatus = registerCarbon(
                settings.immediate, id: Self.immediateID, ref: &immediateRef)
            statuses.pin = pinStatus == noErr ? .carbonOK : .carbonFailed(pinStatus)
            statuses.save = saveStatus == noErr ? .carbonOK : .carbonFailed(saveStatus)
            statuses.fullScreen = fullScreenStatus == noErr ? .carbonOK : .carbonFailed(fullScreenStatus)
            statuses.app = appStatus == noErr ? .carbonOK : .carbonFailed(appStatus)
            statuses.scroll = scrollStatus == noErr ? .carbonOK : .carbonFailed(scrollStatus)
            statuses.immediate = immediateStatus == noErr ? .carbonOK : .carbonFailed(immediateStatus)
        }

        onStatusChange?(statuses)
    }

    private func registerCarbon(_ config: HotkeyConfig, id: UInt32, ref: inout EventHotKeyRef?) -> OSStatus {
        guard ref == nil else { return noErr }
        let hotkeyID = EventHotKeyID(signature: Self.signature, id: id)
        return RegisterEventHotKey(
            config.keyCode,
            config.carbonModifiers,
            hotkeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
    }

    private func registerAltKeys() {
        if let ref = pinAltRef {
            UnregisterEventHotKey(ref)
            pinAltRef = nil
        }
        if let ref = saveAltRef {
            UnregisterEventHotKey(ref)
            saveAltRef = nil
        }
        if let ref = appAltRef {
            UnregisterEventHotKey(ref)
            appAltRef = nil
        }
        if let ref = scrollAltRef {
            UnregisterEventHotKey(ref)
            scrollAltRef = nil
        }
        if let ref = fullScreenAltRef {
            UnregisterEventHotKey(ref)
            fullScreenAltRef = nil
        }
        if let ref = immediateAltRef {
            UnregisterEventHotKey(ref)
            immediateAltRef = nil
        }
        statuses.pinAlt = registerCarbon(.pinBackup, id: Self.pinAltID, ref: &pinAltRef)
        statuses.saveAlt = registerCarbon(.saveBackup, id: Self.saveAltID, ref: &saveAltRef)
        statuses.fullScreenAlt = registerCarbon(
            .fullScreenBackup, id: Self.fullScreenAltID, ref: &fullScreenAltRef)
        statuses.appAlt = registerCarbon(.appBackup, id: Self.appAltID, ref: &appAltRef)
        statuses.scrollAlt = registerCarbon(.scrollBackup, id: Self.scrollAltID, ref: &scrollAltRef)
        statuses.immediateAlt = registerCarbon(
            .immediateBackup, id: Self.immediateAltID, ref: &immediateAltRef)
    }

    private func unregisterPrimary() {
        if let ref = pinRef {
            UnregisterEventHotKey(ref)
            pinRef = nil
        }
        if let ref = saveRef {
            UnregisterEventHotKey(ref)
            saveRef = nil
        }
        if let ref = appRef {
            UnregisterEventHotKey(ref)
            appRef = nil
        }
        if let ref = scrollRef {
            UnregisterEventHotKey(ref)
            scrollRef = nil
        }
        if let ref = fullScreenRef {
            UnregisterEventHotKey(ref)
            fullScreenRef = nil
        }
        if let ref = immediateRef {
            UnregisterEventHotKey(ref)
            immediateRef = nil
        }
    }

    // MARK: Carbon

    private func installCarbonHandler() {
        guard handlerRef == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, userData) -> OSStatus in
                guard let userData, let event else { return noErr }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()

                var hkID = EventHotKeyID()
                let err = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hkID
                )
                guard err == noErr else { return noErr }

                switch hkID.id {
                case HotkeyManager.pinID, HotkeyManager.pinAltID:
                    DispatchQueue.main.async { manager.onFirePin?() }
                case HotkeyManager.saveID, HotkeyManager.saveAltID:
                    DispatchQueue.main.async { manager.onFireSave?() }
                case HotkeyManager.fullScreenID, HotkeyManager.fullScreenAltID:
                    DispatchQueue.main.async { manager.onFireFullScreen?() }
                case HotkeyManager.appID, HotkeyManager.appAltID:
                    DispatchQueue.main.async { manager.onFireApp?() }
                case HotkeyManager.scrollID, HotkeyManager.scrollAltID:
                    DispatchQueue.main.async { manager.onFireScroll?() }
                case HotkeyManager.immediateID, HotkeyManager.immediateAltID:
                    DispatchQueue.main.async { manager.onFireImmediate?() }
                default:
                    break
                }
                return noErr
            },
            1, &eventType, selfPtr, &handlerRef
        )
    }

    // MARK: 强力模式（CGEvent 拦截）

    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func startTap() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let callback: CGEventTapCallBack = { _, _, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()

            if manager.suspended { return Unmanaged.passUnretained(event) }
            if manager.matches(event, config: manager.settings.pin) {
                DispatchQueue.main.async { manager.onFirePin?() }
                return nil  // 吞掉事件，别的 app 收不到
            }
            if manager.matches(event, config: manager.settings.save) {
                DispatchQueue.main.async { manager.onFireSave?() }
                return nil
            }
            if manager.matches(event, config: manager.settings.fullScreen) {
                DispatchQueue.main.async { manager.onFireFullScreen?() }
                return nil
            }
            if manager.matches(event, config: manager.settings.app) {
                DispatchQueue.main.async { manager.onFireApp?() }
                return nil
            }
            if manager.matches(event, config: manager.settings.scroll) {
                DispatchQueue.main.async { manager.onFireScroll?() }
                return nil
            }
            if manager.matches(event, config: manager.settings.immediate) {
                DispatchQueue.main.async { manager.onFireImmediate?() }
                return nil
            }
            return Unmanaged.passUnretained(event)
        }
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: callback,
                userInfo: selfPtr
            )
        else { return false }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func stopTap() {
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes) }
        eventTap = nil
        runLoopSource = nil
    }

    private func matches(_ event: CGEvent, config: HotkeyConfig) -> Bool {
        guard UInt32(event.getIntegerValueField(.keyboardEventKeycode)) == config.keyCode else { return false }
        // 长按产生的重复 keyDown 不重复触发。
        if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return false }
        let relevant: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl]
        return event.flags.intersection(relevant) == config.cgFlags
    }

}
