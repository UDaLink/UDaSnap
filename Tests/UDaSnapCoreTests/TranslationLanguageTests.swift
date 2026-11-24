import XCTest

@testable import UDaSnapCore

final class TranslationLanguageTests: XCTestCase {
    func testDetectedLanguageAliases() {
        XCTAssertEqual(TranslationLanguage.detected(from: "zh-CN"), .simplifiedChinese)
        XCTAssertEqual(TranslationLanguage.detected(from: "繁體中文"), .traditionalChinese)
        XCTAssertEqual(TranslationLanguage.detected(from: "EN"), .english)
        XCTAssertEqual(TranslationLanguage.detected(from: "ja-JP"), .japanese)
        XCTAssertEqual(TranslationLanguage.detected(from: "ko"), .korean)
    }

    func testUnknownValuesReturnNil() {
        XCTAssertNil(TranslationLanguage.detected(from: nil))
        XCTAssertNil(TranslationLanguage.detected(from: "auto"))
        XCTAssertNil(TranslationLanguage.detected(from: "unknown"))
        XCTAssertNil(TranslationLanguage.detected(from: "fr"))
    }

    func testTargetsNeverContainAuto() {
        XCTAssertFalse(TranslationLanguage.targets.contains(.auto))
        XCTAssertTrue(TranslationLanguage.sources.contains(.auto))
    }
}
