import XCTest
@testable import openflix

/// CLI-side registry client tests. (Moved out of RecipeBundleTests when the
/// bundle format moved to OpenFlixKit — RegistryClient stays in the CLI.)
final class RegistryClientTests: XCTestCase {

    func testRegistryTokenResolutionPrefersFlag() {
        XCTAssertEqual(RegistryClient.resolveToken(flagValue: "flag-token"), "flag-token")
        // Empty flag is treated as absent — never returns an empty string
        XCTAssertNotEqual(RegistryClient.resolveToken(flagValue: ""), "")
    }

    func testSafePathTokenRejectsTraversal() {
        // Traversal / slashes must be refused so a crafted id can't escape the
        // /api/... path (`.urlPathAllowed` alone does NOT encode `/` or `.`).
        XCTAssertNil(RegistryClient.safePathToken(".."))
        XCTAssertNil(RegistryClient.safePathToken("../secret"))
        XCTAssertNil(RegistryClient.safePathToken("a/b"))
        XCTAssertNil(RegistryClient.safePathToken("a\\b"))
        XCTAssertNil(RegistryClient.safePathToken(""))
        XCTAssertEqual(RegistryClient.safePathToken("recipe-123"), "recipe-123")
    }

    func testFetchURLSchemeIsHTTPOnly() {
        // Blocks file:// (local-file read) and other non-http schemes.
        XCTAssertTrue(RegistryClient.isHTTPURL(URL(string: "https://registry.openflix.app/x")!))
        XCTAssertTrue(RegistryClient.isHTTPURL(URL(string: "http://localhost:8000/x")!))
        XCTAssertFalse(RegistryClient.isHTTPURL(URL(string: "file:///etc/passwd")!))
        XCTAssertFalse(RegistryClient.isHTTPURL(URL(string: "ftp://host/x")!))
    }
}
