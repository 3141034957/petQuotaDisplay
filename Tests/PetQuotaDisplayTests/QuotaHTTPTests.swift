import XCTest
@testable import PetQuotaDisplay

final class QuotaHTTPTests: XCTestCase {
    func testRetryAfterSupportsDelayAndAbsoluteHTTPDate() throws {
        let now = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(QuotaHTTP.retryDate(" 15 ", now: now), now.addingTimeInterval(15))
        XCTAssertEqual(QuotaHTTP.retryDate("Thu, 01 Jan 1970 00:02:00 GMT", now: now), now.addingTimeInterval(20))
        XCTAssertNil(QuotaHTTP.retryDate("Thu, 01 Jan 1970 00:01:00 GMT", now: now))
        XCTAssertNil(QuotaHTTP.retryDate("-1", now: now))
    }

    func testUsageSessionDoesNotReuseBrowserCredentialsCookiesOrCachedResponses() {
        let session = QuotaHTTP.makeSession()
        defer { session.invalidateAndCancel() }
        let configuration = session.configuration
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertNil(configuration.urlCache)
    }
}
