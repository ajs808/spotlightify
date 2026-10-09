import XCTest
@testable import Spotlightify

final class SpotifyAPIErrorTests: XCTestCase {
    func testNotFoundIsOnlyANoDeviceErrorForPlayerCommands() {
        let response = makeResponse(status: 404)

        XCTAssertEqual(SpotifyAPIClient.error(for: response, data: nil), .notFound)
        XCTAssertEqual(SpotifyAPIClient.error(for: response, data: nil, notFoundError: .noDevice), .noDevice)
    }

    func testRateLimitReadsRetryAfter() {
        let response = makeResponse(status: 429, headers: ["Retry-After": "12"])

        XCTAssertEqual(SpotifyAPIClient.error(for: response, data: nil), .rateLimited(retryAfterSeconds: 12))
    }

    func testRateLimitWithoutHeaderUsesDefaultBackoff() {
        let response = makeResponse(status: 429)

        XCTAssertEqual(SpotifyAPIClient.error(for: response, data: nil), .rateLimited(retryAfterSeconds: 5))
    }

    func testMissingScopeIsRecognised() {
        let body = Data(#"{"error":{"status":403,"message":"Insufficient client scope"}}"#.utf8)

        XCTAssertEqual(SpotifyAPIClient.error(for: makeResponse(status: 403), data: body), .insufficientScope)
    }

    func testPremiumAndRestrictionMessagesMapToTypedErrors() {
        let premium = Data(#"{"error":{"status":403,"message":"Player command failed: Premium required"}}"#.utf8)
        let restricted = Data(#"{"error":{"status":403,"message":"Device is restricted"}}"#.utf8)
        let violation = Data(#"{"error":{"status":403,"message":"Player command failed: Restriction violated"}}"#.utf8)

        XCTAssertEqual(SpotifyAPIClient.error(for: makeResponse(status: 403), data: premium), .premiumRequired)
        XCTAssertEqual(SpotifyAPIClient.error(for: makeResponse(status: 403), data: restricted), .restrictedDevice)
        XCTAssertEqual(
            SpotifyAPIClient.error(for: makeResponse(status: 403), data: violation),
            .message("Player command failed: Restriction violated"),
            "previousTrack() relies on this message to fall back to seeking"
        )
    }

    func testSuccessIsNotAnError() {
        XCTAssertNil(SpotifyAPIClient.error(for: makeResponse(status: 204), data: nil))
    }

    func testTokensSavedBeforeScopeTrackingStillDecode() throws {
        let legacy = Data(#"{"accessToken":"a","refreshToken":"r","expiryDate":0}"#.utf8)

        let token = try JSONDecoder().decode(SpotifyToken.self, from: legacy)

        XCTAssertNil(token.scope)
        XCTAssertNil(token.grants("user-library-modify"))
    }

    func testTokenScopeCheck() {
        let token = SpotifyToken(
            accessToken: "a",
            refreshToken: "r",
            expiryDate: .distantFuture,
            scope: "user-read-playback-state user-library-modify"
        )

        XCTAssertEqual(token.grants("user-library-modify"), true)
        XCTAssertEqual(token.grants("user-library-read"), false)
    }

    private func makeResponse(status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://api.spotify.com/v1/test")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: headers
        )!
    }
}
