import AppKit
import Carbon.HIToolbox
import UDaSnapCore

/// 一套热键：虚拟键码 + Carbon 修饰位。
struct HotkeyConfig: Codable, Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    /// 贴图键默认值：⌃⇧4
    static let pinDefault = HotkeyConfig(
        keyCode: UInt32(kVK_ANSI_4),
        carbonModifiers: UInt32(controlKey | shiftKey)
    )

    /// 截图键默认值：⌃⇧5（只保存，不贴图）
    static let saveDefault = HotkeyConfig(
        keyCode: UInt32(kVK_ANSI_5),
        carbonModifiers: UInt32(controlKey | shiftKey)
    )

    /// 应用窗口截图键默认值：⌃⇧3
    static let appDefault = HotkeyConfig(
        keyCode: UInt32(kVK_ANSI_3),
        carbonModifiers: UInt32(controlKey | shiftKey)
    )

    /// 滚动截图键默认值：⌘F4
    static let scrollDefault = HotkeyConfig(
        keyCode: UInt32(kVK_F4),
        carbonModifiers: UInt32(cmdKey)
    )

    /// 文字提取（OCR）键默认值：⌃⇧2
    static let ocrDefault = HotkeyConfig(
        keyCode: UInt32(kVK_ANSI_2),
        carbonModifiers: UInt32(controlKey | shiftKey)
    )

    /// 固定备用键，不可录制：⌥⇧2 / ⌥⇧3 / ⌥⇧4 / ⌥⇧5 / ⌥⇧6
    static let appBackup = HotkeyConfig(
        keyCode: UInt32(kVK_ANSI_3),
        carbonModifiers: UInt32(optionKey | shiftKey)
    )

    static let pinBackup = HotkeyConfig(
        keyCode: UInt32(kVK_ANSI_4),
        carbonModifiers: UInt32(optionKey | shiftKey)
    )

    static let saveBackup = HotkeyConfig(
        keyCode: UInt32(kVK_ANSI_5),
        carbonModifiers: UInt32(optionKey | shiftKey)
    )

    static let scrollBackup = HotkeyConfig(
        keyCode: UInt32(kVK_ANSI_6),
        carbonModifiers: UInt32(optionKey | shiftKey)
    )

    static let ocrBackup = HotkeyConfig(
        keyCode: UInt32(kVK_ANSI_2),
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

/// App 配置。为了兼容老版本，贴图键仍落在 keyCode / carbonModifiers 上，
/// 截图键新增 saveKeyCode / saveCarbonModifiers，应用窗口键新增
/// appKeyCode / appCarbonModifiers；识字键新增 ocrKeyCode / ocrCarbonModifiers，
/// 老文件缺字段时自动补默认值。
struct AppSettings: Codable, Equatable {
    var pin: HotkeyConfig
    var save: HotkeyConfig
    var app: HotkeyConfig
    var scroll: HotkeyConfig
    var ocr: HotkeyConfig
    var forceTap: Bool

    static let `default` = AppSettings(
        pin: .pinDefault,
        save: .saveDefault,
        app: .appDefault,
        scroll: .scrollDefault,
        ocr: .ocrDefault,
        forceTap: false
    )

    init(
        pin: HotkeyConfig, save: HotkeyConfig, app: HotkeyConfig, scroll: HotkeyConfig, ocr: HotkeyConfig,
        forceTap: Bool
    ) {
        self.pin = pin
        self.save = save
        self.app = app
        self.scroll = scroll
        self.ocr = ocr
        self.forceTap = forceTap
    }

    private enum CodingKeys: String, CodingKey {
        case keyCode
        case carbonModifiers
        case saveKeyCode
        case saveCarbonModifiers
        case appKeyCode
        case appCarbonModifiers
        case scrollKeyCode
        case scrollCarbonModifiers
        case ocrKeyCode
        case ocrCarbonModifiers
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

        let appKey = try c.decodeIfPresent(UInt32.self, forKey: .appKeyCode) ?? HotkeyConfig.appDefault.keyCode
        let appMods =
            try c.decodeIfPresent(UInt32.self, forKey: .appCarbonModifiers) ?? HotkeyConfig.appDefault.carbonModifiers
        self.app = HotkeyConfig(keyCode: appKey, carbonModifiers: appMods)

        let scrollKey = try c.decodeIfPresent(UInt32.self, forKey: .scrollKeyCode) ?? HotkeyConfig.scrollDefault.keyCode
        let scrollMods =
            try c.decodeIfPresent(UInt32.self, forKey: .scrollCarbonModifiers)
            ?? HotkeyConfig.scrollDefault.carbonModifiers
        self.scroll = HotkeyConfig(keyCode: scrollKey, carbonModifiers: scrollMods)

        let ocrKey = try c.decodeIfPresent(UInt32.self, forKey: .ocrKeyCode) ?? HotkeyConfig.ocrDefault.keyCode
        let ocrMods =
            try c.decodeIfPresent(UInt32.self, forKey: .ocrCarbonModifiers) ?? HotkeyConfig.ocrDefault.carbonModifiers
        self.ocr = HotkeyConfig(keyCode: ocrKey, carbonModifiers: ocrMods)

        self.forceTap = try c.decodeIfPresent(Bool.self, forKey: .forceTap) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pin.keyCode, forKey: .keyCode)
        try c.encode(pin.carbonModifiers, forKey: .carbonModifiers)
        try c.encode(save.keyCode, forKey: .saveKeyCode)
        try c.encode(save.carbonModifiers, forKey: .saveCarbonModifiers)
        try c.encode(app.keyCode, forKey: .appKeyCode)
        try c.encode(app.carbonModifiers, forKey: .appCarbonModifiers)
        try c.encode(scroll.keyCode, forKey: .scrollKeyCode)
        try c.encode(scroll.carbonModifiers, forKey: .scrollCarbonModifiers)
        try c.encode(ocr.keyCode, forKey: .ocrKeyCode)
        try c.encode(ocr.carbonModifiers, forKey: .ocrCarbonModifiers)
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
            let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
        else {
            return .default
        }
        // 旧版把标注热键写进配置；这里直接物理删除，不保留废弃字段。
        if var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let removedKey = object.removeValue(forKey: "annotationKeyCode") != nil
            let removedModifiers = object.removeValue(forKey: "annotationCarbonModifiers") != nil
            if removedKey || removedModifiers,
                let clean = try? JSONSerialization.data(
                    withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            {
                try? clean.write(to: url, options: .atomic)
            }
        }
        return settings
    }

    static func save(_ settings: AppSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func delete() {
        try? FileManager.default.removeItem(at: url)
    }
}
