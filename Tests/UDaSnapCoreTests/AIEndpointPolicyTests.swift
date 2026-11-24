import XCTest

@testable import UDaSnapCore

final class AIEndpointPolicyTests: XCTestCase {
    func testAllowsRemoteHTTPS() {
        XCTAssertTrue(AIEndpointPolicy.allows(URL(string: "https://api.example.com/v1")!))
    }

    func testRejectsRemoteHTTP() {
        XCTAssertFalse(AIEndpointPolicy.allows(URL(string: "http://api.example.com/v1")!))
        XCTAssertNotNil(AIEndpointPolicy.httpRejectionMessage(for: URL(string: "http://api.example.com/v1")!))
    }

    func testAllowsLoopbackAndLocalNetworkHTTP() {
        for value in [
            "http://localhost:8080",
            "http://127.0.0.1:1234",
            "http://[::1]:9000",
            "http://10.0.0.8",
            "http://172.16.1.2",
            "http://192.168.1.20",
            "http://printer.local",
        ] {
            XCTAssertTrue(AIEndpointPolicy.allows(URL(string: value)!), value)
        }
    }

    func testRejectsEmptyAndUnsupportedSchemes() {
        XCTAssertFalse(AIEndpointPolicy.allows(URL(string: "file:///tmp/a")!))
        XCTAssertFalse(AIEndpointPolicy.allows(URL(string: "ftp://example.com")!))
    }
}
