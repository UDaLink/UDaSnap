import Foundation

/// Stable paths for the product. The configuration directory follows the bundle identity so a
/// clean install never reads another app's preferences; screenshots stay in a human-friendly folder.
package enum AppPaths {
    package static let bundleIdentifier = "com.udalink.udasnap"
    package static let productName = "UDaSnap"

    package static var applicationSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(bundleIdentifier, isDirectory: true)
    }

    package static var screenshotsDirectory: URL {
        let base = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(productName, isDirectory: true)
    }

    package static func ensureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}
