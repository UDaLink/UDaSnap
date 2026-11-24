import XCTest

@testable import UDaSnapCore

final class ScreenshotStorageTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UDaSnapTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testTimestampNameMatchesManagedPattern() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let name = ScreenshotNaming.timestampName(at: date)
        XCTAssertTrue(ScreenshotNaming.isManaged(filename: name + ".png"))
        XCTAssertTrue(ScreenshotNaming.isManaged(filename: name + "-scroll.png"))
        XCTAssertTrue(ScreenshotNaming.isManaged(filename: name + "-2.png"))
    }

    func testUserFilesAreNotManaged() {
        XCTAssertFalse(ScreenshotNaming.isManaged(filename: "holiday.png"))
        XCTAssertFalse(ScreenshotNaming.isManaged(filename: "2026-01-01_120000-000-copy.png"))
        XCTAssertFalse(ScreenshotNaming.isManaged(filename: "2026-01-01_120000-000.pdf"))
    }

    func testUniqueURLDoesNotOverwrite() throws {
        let base = "2026-11-24_120000-000"
        let first = ScreenshotNaming.uniqueURL(base: base, in: directory)
        try Data().write(to: first)
        let second = ScreenshotNaming.uniqueURL(base: base, in: directory)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(second.lastPathComponent, "\(base)-2.png")
    }

    func testRetentionOnlyDeletesOldManagedFiles() throws {
        let oldManaged = directory.appendingPathComponent("2026-01-01_120000-000.png")
        let newManaged = directory.appendingPathComponent("2026-11-24_120000-000.png")
        let userFile = directory.appendingPathComponent("keep-me.png")
        for url in [oldManaged, newManaged, userFile] {
            try Data().write(to: url)
        }

        let oldDate = Date(timeIntervalSinceNow: -40 * 86_400)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: oldManaged.path)

        let removed = ScreenshotRetention.delete(olderThan: 30, in: directory)
        XCTAssertEqual(removed, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldManaged.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newManaged.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: userFile.path))
    }

    func testDeleteAllKeepsUserFiles() throws {
        let managed = directory.appendingPathComponent("2026-11-24_120000-000.png")
        let userFile = directory.appendingPathComponent("notes.png")
        try Data().write(to: managed)
        try Data().write(to: userFile)

        XCTAssertEqual(ScreenshotRetention.deleteAll(in: directory), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: managed.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: userFile.path))
    }
}
