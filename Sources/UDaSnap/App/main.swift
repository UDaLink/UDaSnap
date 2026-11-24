import AppKit
import UDaSnapCore

// 无界面自检：截取主屏原始像素尺寸，验证 Retina 与权限链路，不弹任何窗口。
if CommandLine.arguments.contains("--self-test") {
    let screen = NSScreen.main!
    print("screen_points=\(screen.frame.size) backing_scale=\(screen.backingScaleFactor)")
    print("screen_capture_permission=\(CaptureService.hasPermission)")
    if let img = CaptureService.capture(screen: screen) {
        print("captured_pixels=\(img.width)x\(img.height)")
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("udasnap-selftest.png")
        ScreenshotStorage.savePNG(img, to: out)
        print("saved=\(out.path)")
    } else {
        print("captured=nil（未授权时系统可能返回 nil 或壁纸）")
    }
    exit(0)
}

// 单实例：多开会让后启动的实例注册不到全局热键，表现为“F1 没反应”，直接退出自己。
if let bundleID = Bundle.main.bundleIdentifier {
    let peers = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    if peers.count > 1 {
        print("[UDaSnap] 已有实例在运行，本次启动退出")
        exit(0)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.finishLaunching()
app.run()
