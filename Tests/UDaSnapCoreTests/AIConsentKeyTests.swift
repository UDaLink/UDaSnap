import XCTest

@testable import UDaSnapCore

final class AIConsentKeyTests: XCTestCase {
    private func settings(baseURL: String, model: String) -> AISettings {
        AISettings(
            baseURL: baseURL,
            model: model,
            mode: .extract,
            authEnabled: true,
            textPrompt: AIDefaults.textPrompt,
            understandPrompt: AIDefaults.understandPrompt,
            systemPrompt: AIDefaults.systemPrompt
        )
    }

    func testNormalizesTrailingSlashAndCase() {
        let a = AIConsentKey.make(for: settings(baseURL: "https://API.Example.com/v1/", model: "gpt-4o"))
        let b = AIConsentKey.make(for: settings(baseURL: "https://api.example.com/v1", model: "gpt-4o"))
        XCTAssertEqual(a, b)
    }

    func testExcludesQueryParameters() {
        let a = AIConsentKey.make(for: settings(baseURL: "https://api.example.com/v1?token=one", model: "m"))
        let b = AIConsentKey.make(for: settings(baseURL: "https://api.example.com/v1?token=two", model: "m"))
        XCTAssertEqual(a, b)
    }

    func testIncludesPortAndPath() {
        let a = AIConsentKey.make(for: settings(baseURL: "https://api.example.com:8443/v1", model: "m"))
        let b = AIConsentKey.make(for: settings(baseURL: "https://api.example.com/v1", model: "m"))
        XCTAssertNotEqual(a, b)
    }

    func testDisplayHostOmitsPathAndQuery() {
        XCTAssertEqual(
            AIConsentKey.displayHost(for: "https://api.example.com:8443/v1?token=x"),
            "https://api.example.com:8443"
        )
    }
}
