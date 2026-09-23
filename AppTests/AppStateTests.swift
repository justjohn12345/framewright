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

    /// The retry interval is measured with the cache's clock (a manual one here), so the test
    /// does not depend on how long anything takes.
    func testFailedThumbnailsAreRetriedAfterTheInterval() throws {
        let directory = try TestMediaFactory.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = VEEngine(cacheDirectory: directory)
        var now = Date(timeIntervalSinceReferenceDate: 1000)
        let cache = ThumbnailCache(engine: engine, retryInterval: 30, now: { now })
        XCTAssertNil(cache.image(asset: 999, seconds: 0, maxDimension: 64)) // unknown asset: fails
        XCTAssertEqual(cache.requestsStarted, 1)
        XCTAssertTrue(StoreFixture.spin(until: { cache.failuresRecorded == 1 }, timeout: 10), "the failure arrives")
        XCTAssertNil(cache.image(asset: 999, seconds: 0, maxDimension: 64))
        XCTAssertEqual(cache.requestsStarted, 1, "not retried within the interval")
        now += 29.9
        XCTAssertNil(cache.image(asset: 999, seconds: 0, maxDimension: 64))
        XCTAssertEqual(cache.requestsStarted, 1, "not retried within the interval")
        now += 0.2
        XCTAssertNil(cache.image(asset: 999, seconds: 0, maxDimension: 64))
        XCTAssertEqual(cache.requestsStarted, 2, "retried once the failure expired")
    }

    func testFailedWaveformsAreRetriedAfterTheInterval() throws {
        let directory = try TestMediaFactory.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = VEEngine(cacheDirectory: directory)
        var now = Date(timeIntervalSinceReferenceDate: 1000)
        let cache = WaveformCache(engine: engine, retryInterval: 30, now: { now })
        XCTAssertNil(cache.waveform(asset: 999)) // unknown asset: fails
        XCTAssertEqual(cache.loadsStarted, 1)
        XCTAssertTrue(StoreFixture.spin(until: { cache.failuresRecorded == 1 }, timeout: 10), "the failure arrives")
        XCTAssertNil(cache.waveform(asset: 999))
        XCTAssertEqual(cache.loadsStarted, 1, "not retried within the interval")
        now += 30.1
        XCTAssertNil(cache.waveform(asset: 999))
        XCTAssertEqual(cache.loadsStarted, 2, "retried once the failure expired")
    }

    /// A request of a closed project completes with VEEngineErrorProjectClosed: that is not a
    /// failure of the media, so nothing is recorded (whether or not the cache was cleared).
    func testAClosedProjectsRequestIsNotAFailure() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanUp() }
        let (movie, _) = try await fixture.importMedia()
        let cache = fixture.store.thumbnails
        // The engine replaces the project behind the cache's back: same generation.
        XCTAssertNil(cache.image(asset: movie.assetID, seconds: 1, maxDimension: 77))
        fixture.store.engine.newProject(withName: "Other")
        var settled = await StoreFixture.wait(until: { !cache.isFetching }, timeout: 10)
        XCTAssertTrue(settled)
        XCTAssertEqual(cache.failuresRecorded, 0, "the closed project's answer is not a failure")
        // Through the store (the cache starts a new generation): the answer is ignored.
        XCTAssertNil(cache.image(asset: movie.assetID, seconds: 2, maxDimension: 77))
        fixture.store.newProject()
        settled = await StoreFixture.wait(until: { cache.ignoredCompletions == 1 }, timeout: 10)
        XCTAssertTrue(settled, "the closed project's request completes and is ignored")
        XCTAssertEqual(cache.failuresRecorded, 0)
    }

    func testHUDTextShowsTheCounters() throws {
        let directory = try TestMediaFactory.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = VEEngine(cacheDirectory: directory)
        let text = PlaybackHUD.lines(stats: engine.playbackStats, status: engine.playbackStatus, view: nil)
        XCTAssertTrue(text.hasPrefix("stopped 1x"), text)
        XCTAssertTrue(text.contains("dropped 0"), text)
        XCTAssertTrue(text.contains("audio "), text)
        XCTAssertTrue(text.contains("presented -  clock 0.000 s"), text)
    }
}
