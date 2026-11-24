import XCTest

@testable import UDaSnapCore

final class AISettingsTests: XCTestCase {
    func testDefaultsAreValid() {
        XCTAssertEqual(AISettings.default.mode, .extract)
        XCTAssertEqual(AISettings.default.translationSource, .auto)
        XCTAssertEqual(AISettings.default.translationTarget, .simplifiedChinese)
        XCTAssertTrue(AISettings.default.authEnabled)
    }

    func testCodableRoundTrip() throws {
        var original = AISettings.default
        original.baseURL = "https://api.example.com/v1"
        original.model = "gpt-4o-mini"
        original.mode = .understand
        original.translationSource = .english
        original.translationTarget = .japanese

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AISettings.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testDecodingMigratesMissingAndInvalidFields() throws {
        let json = #"{"baseURL":"https://api.example.com","model":"m","mode":"unknown","translationTarget":"auto"}"#
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(AISettings.self, from: data)
        XCTAssertEqual(decoded.mode, .extract)
        XCTAssertEqual(decoded.translationTarget, .simplifiedChinese)
        XCTAssertEqual(decoded.textPrompt, AIDefaults.textPrompt)
    }

    func testSameSourceAndTargetFallsBackToAuto() throws {
        let json = #"{"translationSource":"en","translationTarget":"en"}"#
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(AISettings.self, from: data)
        XCTAssertEqual(decoded.translationSource, .auto)
        XCTAssertEqual(decoded.translationTarget, .english)
    }
}
