import XCTest
@testable import PetQuotaDisplay

final class QuotaHTTPTests: XCTestCase {
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
