import Foundation
@testable import UnfairDaemonCore
import Vapor
import XCTest

final class AppleProtocolServiceTests: XCTestCase {
    func testRateLimitTextResponseDoesNotSurfacePlistParserError() throws {
        let data = Data("Rate limit exceeded".utf8)

        do {
            _ = try AppleProtocolService.parsePlistForTesting(data)
            XCTFail("Expected rate limit error")
        } catch let error as AppleProtocolError {
            XCTAssertEqual(error.status, .tooManyRequests)
            XCTAssertEqual(error.code, "rate_limited")
            XCTAssertEqual(error.message, "Apple rate limit reached. Wait before trying again.")
        }
    }

    func testRequestHeadersIncludeUserAgentCustomHeadersAndCookies() async throws {
        let headers = try await AppleProtocolService.requestHeadersForTesting(
            url: URL(string: "https://buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/buyProduct")!,
            headers: [("Content-Type", "application/x-apple-plist")],
            cookies: [
                WebCookie(name: "itspod", value: "25", path: "/", domain: "itunes.apple.com", expiresAt: nil, httpOnly: false, secure: true),
            ]
        )

        XCTAssertEqual(headers.first?.0, "User-Agent")
        XCTAssertEqual(headers.first { $0.0 == "Content-Type" }?.1, "application/x-apple-plist")
        XCTAssertEqual(headers.first { $0.0 == "Cookie" }?.1, "itspod=25")
    }
}
