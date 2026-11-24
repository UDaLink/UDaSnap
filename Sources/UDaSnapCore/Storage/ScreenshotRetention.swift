import Foundation

/// File-system cleanup rules for screenshots owned by UDaSnap.
package enum ScreenshotRetention {
    package static func managedFiles(in directory: URL) -> [URL] {
        guard
            let items = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return []
        }

        return items.filter { url in
            guard ScreenshotNaming.isManaged(filename: url.lastPathComponent),
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            else {
                return false
            }
            return values.isRegularFile == true && values.isSymbolicLink != true
        }
    }

    @discardableResult
    package static func delete(olderThan days: Int, in directory: URL, now: Date = Date()) -> Int {
        guard days > 0 else { return 0 }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        return managedFiles(in: directory).reduce(into: 0) { count, url in
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                let modified = values.contentModificationDate,
                modified < cutoff
            else {
                return
            }
            if (try? FileManager.default.removeItem(at: url)) != nil {
                count += 1
            }
        }
    }

    @discardableResult
    package static func deleteAll(in directory: URL) -> Int {
        managedFiles(in: directory).reduce(into: 0) { count, url in
            if (try? FileManager.default.removeItem(at: url)) != nil {
                count += 1
            }
        }
    }
}
