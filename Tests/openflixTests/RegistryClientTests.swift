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
}
