import XCTest
@testable import Spotlightify

final class ResponseCacheTests: XCTestCase {
    func testExpiredEntriesAreDropped() {
        var now = Date(timeIntervalSince1970: 0)
        var cache = ResponseCache<String, Int>(capacity: 10, timeToLive: 60, now: { now })
        cache.insert(1, for: "a")

        now = now.addingTimeInterval(59)
        XCTAssertEqual(cache.value(for: "a"), 1)

        now = now.addingTimeInterval(2)
        XCTAssertNil(cache.value(for: "a"))
    }

    func testLeastRecentlyUsedEntryIsEvictedFirst() {
        var cache = ResponseCache<String, Int>(capacity: 2, timeToLive: 60)
        cache.insert(1, for: "a")
        cache.insert(2, for: "b")
        _ = cache.value(for: "a")
        cache.insert(3, for: "c")

        XCTAssertEqual(cache.value(for: "a"), 1)
        XCTAssertNil(cache.value(for: "b"))
        XCTAssertEqual(cache.value(for: "c"), 3)
    }

    @MainActor
    func testSearchQueriesNormalizeCaseAndWhitespace() {
        XCTAssertEqual(SearchViewModel.normalizedQuery("  Daft   Punk "), "daft punk")
    }
}
