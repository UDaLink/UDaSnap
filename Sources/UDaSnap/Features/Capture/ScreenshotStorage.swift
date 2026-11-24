import AppKit
import ImageIO
import UDaSnapCore
import UniformTypeIdentifiers

/// 落盘、剪贴板、保存目录。
enum ScreenshotStorage {

    static let folder: URL = AppPaths.screenshotsDirectory

    static var configFolder: URL {
        SettingsFile.url.deletingLastPathComponent()
    }

    /// 只返回 UDaSnap 自己命名的截图，避免误删用户手动放进目录的文件。
    static func uadasnapScreenshotURLs() -> [URL] {
        ScreenshotRetention.managedFiles(in: folder)
    }

    static func screenshotCount() -> Int {
        uadasnapScreenshotURLs().count
    }

    /// 删除超过保留期限的 UDaSnap 截图；0 表示永久保留。
    @discardableResult
    static func deleteScreenshots(olderThan days: Int) -> Int {
        ScreenshotRetention.delete(olderThan: days, in: folder)
    }

    @discardableResult
    static func deleteAllScreenshots() -> Int {
        ScreenshotRetention.deleteAll(in: folder)
    }

    static func revealConfigFolder() {
        try? FileManager.default.createDirectory(at: configFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: configFolder.path)
    }

    static func ensureFolder() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    static func timestampName() -> String {
        ScreenshotNaming.timestampName()
    }

    /// 同一毫秒也不覆盖已有文件，依次加 -2、-3。
    private static func uniqueURL(base: String) -> URL {
        ScreenshotNaming.uniqueURL(base: base, in: folder)
    }

    /// 以原始像素写 PNG，不缩不放。`suffix` 用于区分滚动截图等特殊产物。
    @discardableResult
    static func savePNG(_ image: CGImage, to url: URL? = nil, suffix: String? = nil) -> URL? {
        ensureFolder()
        let base = timestampName() + (suffix ?? "")
        let target = url ?? uniqueURL(base: base)
        guard
            let dest = CGImageDestinationCreateWithURL(
                target as CFURL, UTType.png.identifier as CFString, 1, nil
            )
        else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return target
    }

    @discardableResult
    static func copyToClipboard(_ image: CGImage) -> Data? {
        guard let data = pngData(for: image) else { return nil }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(data, forType: .png)
        return data
    }

    static func pngData(for image: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:])
    }

    /// 只在剪贴板里仍是这张图的 PNG 时才清空，避免误删用户后来复制的内容。
    static func clearClipboard(ifMatching data: Data?) {
        guard let data else { return }
        let pb = NSPasteboard.general
        guard pb.data(forType: .png) == data else { return }
        pb.clearContents()
    }

    /// 只写纯文本；识字模式不碰图片剪贴板。
    @discardableResult
    static func copyText(_ text: String) -> Bool {
        let pb = NSPasteboard.general
        pb.clearContents()
        return pb.setString(text, forType: .string)
    }

    static func revealFolder() {
        ensureFolder()
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path)
    }
}
