import Foundation

/// Pure naming rules for screenshots. Keeping these here makes cleanup safe and testable:
/// only files that match UDaSnap's own naming convention may be removed automatically.
package enum ScreenshotNaming {
    package static let filePattern = #"^\d{4}-\d{2}-\d{2}_\d{6}-\d{3}(?:-scroll)?(?:-\d+)?\.png$"#

    private static let managedName = try! NSRegularExpression(pattern: filePattern)

    package static func timestampName(at date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HHmmss-SSS"
        return formatter.string(from: date)
    }

    package static func isManaged(filename: String) -> Bool {
        let range = NSRange(filename.startIndex..<filename.endIndex, in: filename)
        return managedName.firstMatch(in: filename, range: range) != nil
    }

    /// Returns a non-existing URL, adding `-2`, `-3`, ... when the same millisecond is reused.
    package static func uniqueURL(base: String, in directory: URL) -> URL {
        var candidate = directory.appendingPathComponent(base + ".png")
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base)-\(index).png")
            index += 1
        }
        return candidate
    }
}
