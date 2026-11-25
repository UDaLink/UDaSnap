import AppKit
import Carbon.HIToolbox
import UDaSnapCore

/// 一套热键：虚拟键码 + Carbon 修饰位。
struct HotkeyConfig: Codable, Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    /// 贴图键默认值：⌘F1
    static let pinDefault = HotkeyConfig(
        keyCode: UInt32(kVK_F1),
        carbonModifiers: UInt32(cmdKey)
    )

    /// 框选截图默认值：⌘F2（只保存，不贴图）
    static let saveDefault = HotkeyConfig(
        keyCode: UInt32(kVK_F2),
        carbonModifiers: UInt32(cmdKey)
    )

    /// 全屏截图默认值：⌘F3
    static let fullScreenDefault = HotkeyConfig(
        keyCode: UInt32(kVK_F3),
        carbonModifiers: UInt32(cmdKey)
    )

    /// 应用窗口截图默认值：⌘F4
    static let appDefault = HotkeyConfig(
        keyCode: UInt32(kVK_F4),
        carbonModifiers: UInt32(cmdKey)
    )

    /// 滚动截图默认值：⌘F5
    static let scrollDefault = HotkeyConfig(
        keyCode: UInt32(kVK_F5),
        carbonModifiers: UInt32(cmdKey)
    )

    /// 固定备用键，不可录制：⌥⇧1 / ⌥⇧2 / ⌥⇧3 / ⌥⇧4 / ⌥⇧5
    static let pinBackup = HotkeyConfig(
        keyCode: UInt32(kVK_ANSI_1),
        carbonModifiers: UInt32(optionKey | shiftKey)
    )

    static let saveBackup = HotkeyConfig(
        keyCode: UInt32(kVK_ANSI_2),
        carbonModifiers: UInt32(optionKey | shiftKey)
    )

    static let fullScreenBackup = HotkeyConfig(
        keyCode: UInt32(kVK_ANSI_3),
        carbonModifiers: UInt32(optionKey | shiftKey)
    )

    static let appBackup = HotkeyConfig(
        keyCode: UInt32(kVK_ANSI_4),
        carbonModifiers: UInt32(optionKey | shiftKey)
    )

    static let scrollBackup = HotkeyConfig(
        keyCode: UInt32(kVK_ANSI_5),
        carbonModifiers: UInt32(optionKey | shiftKey)
    )

    var display: String {
        Self.displayString(keyCode: keyCode, carbonModifiers: carbonModifiers)
    }

    var cgFlags: CGEventFlags {
        var f: CGEventFlags = []
        if carbonModifiers & UInt32(cmdKey) != 0 { f.insert(.maskCommand) }
        if carbonModifiers & UInt32(shiftKey) != 0 { f.insert(.maskShift) }
        if carbonModifiers & UInt32(optionKey) != 0 { f.insert(.maskAlternate) }
        if carbonModifiers & UInt32(controlKey) != 0 { f.insert(.maskControl) }
        return f
    }

    /// 菜单项右侧的系统快捷键列：单个字符 + 修饰位，交给 AppKit 原生右对齐。
    var menuKeyEquivalent: String? {
        Self.menuKeyTable[keyCode]
    }

    var menuModifiers: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if carbonModifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if carbonModifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if carbonModifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if carbonModifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        return flags
    }

    /// 与 keyName 表一一对应；字母用小写，显示时由修饰键决定大小写。
    private static let menuKeyTable: [UInt32: String] = [
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v",
        11: "b", 12: "q", 13: "w", 14: "e", 15: "r", 16: "y", 17: "t",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7",
        27: "-", 28: "8", 29: "0", 30: "]", 31: "o", 32: "u", 33: "[", 34: "i", 35: "p",
        37: "l", 38: "j", 39: "'", 40: "k", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "n",
        46: "m", 47: ".", 48: "\t", 49: " ", 50: "`", 51: "\u{7f}", 53: "\u{1b}",
        36: "\r", 76: "\r",
        96: "\u{F708}", 97: "\u{F709}", 98: "\u{F70A}", 99: "\u{F706}",
        100: "\u{F70B}", 101: "\u{F70C}", 103: "\u{F70E}", 109: "\u{F70D}",
        111: "\u{F70F}", 118: "\u{F707}", 120: "\u{F705}", 122: "\u{F704}",
        123: "\u{F702}", 124: "\u{F703}", 125: "\u{F701}", 126: "\u{F700}",
        115: "\u{F729}", 116: "\u{F72C}", 119: "\u{F72B}", 121: "\u{F72D}",
    ]

    /// 不带头修饰键的纯功能键（F1~F12 等）在 macOS 上属于系统功能键，物理按下会被系统先吃掉。
    var isSystemFunctionKey: Bool {
        let fKeys: Set<UInt32> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        return fKeys.contains(keyCode) && carbonModifiers == 0
    }

    static func displayString(keyCode: UInt32, carbonModifiers: UInt32) -> String {
        var s = ""
        if carbonModifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + keyName(keyCode)
    }

    static func keyName(_ code: UInt32) -> String {
        let table: [UInt32: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
            11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
            18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9",
            26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[",
            34: "I", 35: "P", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\",
            43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 48: "Tab", 49: "Space",
            50: "`", 51: "Delete", 53: "Esc", 36: "Return", 76: "Enter",
            96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9",
            103: "F11", 109: "F10", 111: "F12", 118: "F4", 120: "F2", 122: "F1",
            123: "←", 124: "→", 125: "↓", 126: "↑",
            115: "Home", 116: "PageUp", 119: "End", 121: "PageDown",
        ]
        return table[code] ?? "键码\(code)"
    }
}

/// App 配置。贴图键沿用历史字段 `keyCode` / `carbonModifiers`；
/// 框选、全屏、应用窗口、滚动截图各有自己的字段。旧配置没有
/// `fullScreenKeyCode` 时，视为升级前的配置，一次性重置为最新默认键位。
struct AppSettings: Codable, Equatable {
    var pin: HotkeyConfig
    var save: HotkeyConfig
    var fullScreen: HotkeyConfig
    var app: HotkeyConfig
    var scroll: HotkeyConfig
    var forceTap: Bool

    static let `default` = AppSettings(
        pin: .pinDefault,
        save: .saveDefault,
        fullScreen: .fullScreenDefault,
        app: .appDefault,
        scroll: .scrollDefault,
        forceTap: false
    )

    init(
        pin: HotkeyConfig, save: HotkeyConfig, fullScreen: HotkeyConfig, app: HotkeyConfig,
        scroll: HotkeyConfig, forceTap: Bool
    ) {
        self.pin = pin
        self.save = save
        self.fullScreen = fullScreen
        self.app = app
        self.scroll = scroll
        self.forceTap = forceTap
    }

    private enum CodingKeys: String, CodingKey {
        case keyCode
        case carbonModifiers
        case saveKeyCode
        case saveCarbonModifiers
        case fullScreenKeyCode
        case fullScreenCarbonModifiers
        case appKeyCode
        case appCarbonModifiers
        case scrollKeyCode
        case scrollCarbonModifiers
        case forceTap
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        // 老文件里 keyCode / carbonModifiers 就是贴图键。
        let pinKey = try c.decodeIfPresent(UInt32.self, forKey: .keyCode) ?? HotkeyConfig.pinDefault.keyCode
        let pinMods =
            try c.decodeIfPresent(UInt32.self, forKey: .carbonModifiers) ?? HotkeyConfig.pinDefault.carbonModifiers
        self.pin = HotkeyConfig(keyCode: pinKey, carbonModifiers: pinMods)

        let saveKey = try c.decodeIfPresent(UInt32.self, forKey: .saveKeyCode) ?? HotkeyConfig.saveDefault.keyCode
        let saveMods =
            try c.decodeIfPresent(UInt32.self, forKey: .saveCarbonModifiers) ?? HotkeyConfig.saveDefault.carbonModifiers
        self.save = HotkeyConfig(keyCode: saveKey, carbonModifiers: saveMods)

        let fullScreenKey =
            try c.decodeIfPresent(UInt32.self, forKey: .fullScreenKeyCode)
            ?? HotkeyConfig.fullScreenDefault.keyCode
        let fullScreenMods =
            try c.decodeIfPresent(UInt32.self, forKey: .fullScreenCarbonModifiers)
            ?? HotkeyConfig.fullScreenDefault.carbonModifiers
        self.fullScreen = HotkeyConfig(keyCode: fullScreenKey, carbonModifiers: fullScreenMods)

        let appKey = try c.decodeIfPresent(UInt32.self, forKey: .appKeyCode) ?? HotkeyConfig.appDefault.keyCode
        let appMods =
            try c.decodeIfPresent(UInt32.self, forKey: .appCarbonModifiers) ?? HotkeyConfig.appDefault.carbonModifiers
        self.app = HotkeyConfig(keyCode: appKey, carbonModifiers: appMods)

        let scrollKey = try c.decodeIfPresent(UInt32.self, forKey: .scrollKeyCode) ?? HotkeyConfig.scrollDefault.keyCode
        let scrollMods =
            try c.decodeIfPresent(UInt32.self, forKey: .scrollCarbonModifiers)
            ?? HotkeyConfig.scrollDefault.carbonModifiers
        self.scroll = HotkeyConfig(keyCode: scrollKey, carbonModifiers: scrollMods)

        self.forceTap = try c.decodeIfPresent(Bool.self, forKey: .forceTap) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pin.keyCode, forKey: .keyCode)
        try c.encode(pin.carbonModifiers, forKey: .carbonModifiers)
        try c.encode(save.keyCode, forKey: .saveKeyCode)
        try c.encode(save.carbonModifiers, forKey: .saveCarbonModifiers)
        try c.encode(fullScreen.keyCode, forKey: .fullScreenKeyCode)
        try c.encode(fullScreen.carbonModifiers, forKey: .fullScreenCarbonModifiers)
        try c.encode(app.keyCode, forKey: .appKeyCode)
        try c.encode(app.carbonModifiers, forKey: .appCarbonModifiers)
        try c.encode(scroll.keyCode, forKey: .scrollKeyCode)
        try c.encode(scroll.carbonModifiers, forKey: .scrollCarbonModifiers)
        try c.encode(forceTap, forKey: .forceTap)
    }
}

enum SettingsFile {
    static let url: URL = {
        let dir = AppPaths.applicationSupportDirectory
        try? AppPaths.ensureDirectory(dir)
        return dir.appendingPathComponent("settings.json")
    }()

    static func load() -> AppSettings {
        guard let data = try? Data(contentsOf: url),
            let stored = try? JSONDecoder().decode(AppSettings.self, from: data)
        else {
            return .default
        }

        // 这是加入全屏截图之前的旧配置：一次性重置为全新的默认键位。
        // 当前版本还没有对外推广，不存在需要保留的历史自定义键位。
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return stored
        }
        let hasFullScreen = object["fullScreenKeyCode"] != nil && object["fullScreenCarbonModifiers"] != nil
        if !hasFullScreen {
            var migrated = stored
            migrated.pin = .pinDefault
            migrated.save = .saveDefault
            migrated.fullScreen = .fullScreenDefault
            migrated.app = .appDefault
            migrated.scroll = .scrollDefault
            save(migrated)
            return migrated
        }

        // 已使用新配置，只清理废弃字段，不动用户的五组键位。
        if var cleanObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let removedAnnotationKey = cleanObject.removeValue(forKey: "annotationKeyCode") != nil
            let removedAnnotationModifiers = cleanObject.removeValue(forKey: "annotationCarbonModifiers") != nil
            let removedOCRKey = cleanObject.removeValue(forKey: "ocrKeyCode") != nil
            let removedOCRModifiers = cleanObject.removeValue(forKey: "ocrCarbonModifiers") != nil
            if removedAnnotationKey || removedAnnotationModifiers || removedOCRKey || removedOCRModifiers,
                let clean = try? JSONSerialization.data(
                    withJSONObject: cleanObject, options: [.prettyPrinted, .sortedKeys])
            {
                try? clean.write(to: url, options: .atomic)
            }
        }
        return stored
    }

    static func save(_ settings: AppSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func delete() {
        try? FileManager.default.removeItem(at: url)
    }
}
