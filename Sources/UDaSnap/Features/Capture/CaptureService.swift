import AppKit
import CoreGraphics
import ImageIO
import UDaSnapCore

/// 屏幕录制权限 + 每屏独立截取。
///
/// 用 CGDisplayCreateImage 而不是 screencapture CLI：
/// CLI 在多屏下用 -R 传全局矩形会遇到负坐标坑，逐屏截取再按各自 scale 换算最稳。
enum CaptureService {

    static var hasPermission: Bool {
        if #available(macOS 11, *) { return CGPreflightScreenCaptureAccess() }
        return true
    }

    /// 弹系统授权框。只能用户点，代码绕不过去。
    static func requestPermission() {
        if #available(macOS 11, *) { _ = CGRequestScreenCaptureAccess() }
    }

    /// 打开系统设置的屏幕录制面板。
    static func openPermissionSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(num.uint32Value)
    }

    /// 返回原始像素的 CGImage（Retina 是 2x）。未授权时系统返回壁纸或 nil。
    static func capture(screen: NSScreen) -> CGImage? {
        guard let id = displayID(for: screen) else { return nil }
        return CGDisplayCreateImage(id)
    }

    /// 截取单个窗口的完整内容，默认带 macOS 窗口阴影（不加 `-o`），`-x` 静音。
    /// 使用系统 `screencapture -l`：`CGWindowListCreateImage` 从 macOS 15 起已不可用。
    /// 窗口即使被别的窗口遮住，也能通过窗口 ID 拿到完整内容。
    static func captureWindow(id: CGWindowID) -> CGImage? {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("UDaSnap-window-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: temp) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-l", String(id), temp.path]
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0,
            FileManager.default.fileExists(atPath: temp.path),
            let source = CGImageSourceCreateWithURL(temp as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            return nil
        }

        // ImageIO 返回的 CGImage 可能仍引用临时文件，延后解码。临时文件在 defer 中
        // 删除后再交给保存/剪贴板，会得到只有 PNG 头的空文件。这里先画进位图，
        // 强制解码成内存像素，之后可以安全删除临时文件。
        let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard
            let context = CGContext(
                data: nil,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    /// 把屏幕点坐标下的选区裁成原始像素 CGImage。
    /// selection 使用屏幕本地 NSView 坐标（原点左下，单位 point）。
    static func crop(image: CGImage, selection: CGRect, screen: NSScreen) -> CGImage? {
        let scaleX = CGFloat(image.width) / screen.frame.width
        let scaleY = CGFloat(image.height) / screen.frame.height
        // NSView 原点在左下，CGImage 裁剪原点在左上，需要翻 y。
        let pixelRect = CGRect(
            x: selection.minX * scaleX,
            y: (screen.frame.height - selection.maxY) * scaleY,
            width: selection.width * scaleX,
            height: selection.height * scaleY
        ).integral
        guard pixelRect.width >= 1, pixelRect.height >= 1 else { return nil }
        return image.cropping(to: pixelRect)
    }
}
