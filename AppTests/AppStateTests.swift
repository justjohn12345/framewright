import CoreMedia
import VidEditEngine
import XCTest
@testable import VidEdit

/// Small pieces of app state: speed formatting and parsing, cache failure expiry, the HUD text.
@MainActor
final class AppStateTests: XCTestCase {
    func testSpeedFormattingAndParsing() {
        XCTAssertEqual(SpeedFormat.multiplier(numerator: 2, denominator: 1), "2")
        XCTAssertEqual(SpeedFormat.multiplier(numerator: 1, denominator: 2), "0.5")
        XCTAssertEqual(SpeedFormat.multiplier(numerator: 3, denominator: 8), "0.375")
        XCTAssertEqual(SpeedFormat.multiplier(numerator: 1, denominator: 3), "1/3")
        XCTAssertEqual(SpeedFormat.percent(0.5), "50%")
        XCTAssertEqual(SpeedFormat.percent(1.0 / 3.0), "33.33%")
        XCTAssertEqual(SpeedFormat.parseMultiplier("1/3"), .fraction(1, 3))
        XCTAssertEqual(SpeedFormat.parseMultiplier(" 2 / 5 "), .fraction(2, 5))
        XCTAssertEqual(SpeedFormat.parseMultiplier("0,5"), .decimal(0.5))
        XCTAssertNil(SpeedFormat.parseMultiplier("0"))
        XCTAssertNil(SpeedFormat.parseMultiplier("-1/2"))
        XCTAssertNil(SpeedFormat.parseMultiplier("fast"))
    }

    func testFailedThumbnailsAreRetriedAfterTheInterval() throws {
        let directory = try TestMediaFactory.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = VEEngine(cacheDirectory: directory)
        let cache = ThumbnailCache(engine: engine, retryInterval: 0.3)
        XCTAssertNil(cache.image(asset: 999, seconds: 0, maxDimension: 64)) // unknown asset: fails
        XCTAssertTrue(StoreFixture.spin(until: { cache.requestsStarted == 1 }, timeout: 1))
        StoreFixture.spin(until: { false }, timeout: 0.1) // the failure arrives
        XCTAssertNil(cache.image(asset: 999, seconds: 0, maxDimension: 64))
        XCTAssertEqual(cache.requestsStarted, 1, "not retried within the interval")
        StoreFixture.spin(until: { false }, timeout: 0.35)
        XCTAssertNil(cache.image(asset: 999, seconds: 0, maxDimension: 64))
        XCTAssertEqual(cache.requestsStarted, 2, "retried once the failure expired")
    }

    func testHUDTextShowsTheCounters() throws {
        let directory = try TestMediaFactory.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = VEEngine(cacheDirectory: directory)
        let text = PlaybackHUD.lines(stats: engine.playbackStats, status: engine.playbackStatus, view: nil)
        XCTAssertTrue(text.hasPrefix("stopped 1x"), text)
        XCTAssertTrue(text.contains("dropped 0"), text)
        XCTAssertTrue(text.contains("audio "), text)
    }
}
