import AppKit
import AVFoundation
import CoreMedia
import FramewrightEngine
import Metal
import SwiftUI
import XCTest
@testable import Framewright

/// A two-hour project with a few hundred clips, built and edited through the facade (`VEEngine`) with
/// the app's store observing it: memory and responsiveness. Opt-in: the StressTests scheme sets
/// FRAMEWRIGHT_STRESS=1 (the other schemes skip this class by name; without the variable it skips).
///
/// The project (1080p30, V1-V3 and A1-A3; a seeded generator, so every run builds and edits the same
/// one) uses five media files written at test time (`StressMediaFactory`), each many times: a 90 s
/// 1080p30 H.264 movie with 48 kHz audio, a 60 s 720p 29.97 fps HEVC movie with 44.1 kHz audio, a 60 s
/// 360p 25 fps H.264 movie without audio, a PNG title and a 3 min AAC music bed:
/// - V1/A1: two hours of linked clips at speeds 1, 2, 1/2 and 3/2, every ninth reversed, a cross
///   dissolve with its linked crossfade on every third cut;
/// - V2/A3: a picture in picture every 4 minutes, placed small, with a Motion span and a Fade span;
/// - V3: a title every 6 minutes with a fade in and out and a Motion span (a slow zoom);
/// - A2: the music bed end to end to exactly 2:00:00, crossfaded on every other cut, ducked by Gain
///   spans.
///
/// Phases, each followed by a footprint sample (task_vm_info.phys_footprint, as the engine tests take it):
/// 1. building it (every facade call timed);
/// 2. a thumbnail and waveform pass as the app's timeline makes it: `TimelineView` rendered with
///    ImageRenderer page by page across the whole two hours at the timeline's minimum zoom (2 pt/s: as
///    far out as the app zooms, so two hours take 9 pages of 1429 pt) and at a zoom showing 30 s (241
///    pages), waiting for each page's fetches and drawing it again with them;
/// 3. 60 s of playback from each of three positions, each started cold (caches purged, a jump, play at
///    once), rendered at 60 Hz; the play-start latency is measured as
///    `VEEnginePlaybackTests.testPlayStartLatencyThroughTheFacade` does;
/// 4. 200 scrubs to random frames of the two hours, each timed until its picture is presented;
/// 5. 100 random edits (move, trim either edge, split, ripple delete, undo), each timed through the
///    facade on the main thread. The engine posts its model notification within the call and the store
///    observes it on the main queue, so the time includes what the app does before the next draw: the
///    store's snapshot refresh and (the timeline being laid out) the timeline model's rebuild; both are
///    also timed on their own;
/// then the timeline model's build and the timeline's draw at the two zooms, and a save and reopen.
/// The bounds are generous (every number is logged, "STRESS 2H ...", so they can be tightened); a value
/// past the product's targets (an edit's p95 over 100 ms, a model build over 50 ms, memory growth past
/// the frame cache budget) is logged as a FINDING.
@MainActor
final class TwoHourProjectStressTests: XCTestCase {
    /// SplitMix64: a seeded generator, so the project and the edits are the same on every run.
    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// Durations in milliseconds, summarised as median, 95th percentile and maximum.
    private struct Timings: CustomStringConvertible {
        private(set) var values: [Double] = []

        mutating func add(_ milliseconds: Double) { values.append(milliseconds) }

        var count: Int { values.count }
        var median: Double { percentile(0.5) }
        var p95: Double { percentile(0.95) }
        var max: Double { values.max() ?? 0 }

        /// The nearest-rank percentile.
        func percentile(_ p: Double) -> Double {
            let sorted = values.sorted()
            guard !sorted.isEmpty else { return 0 }
            let rank = Int((p * Double(sorted.count)).rounded(.up)) - 1
            return sorted[Swift.min(Swift.max(rank, 0), sorted.count - 1)]
        }

        var description: String {
            String(format: "median %.1f ms, p95 %.1f ms, max %.1f ms (n = %d)", median, p95, max, count)
        }
    }

    private struct Media {
        let interview: VEAssetInfo
        let broll: VEAssetInfo
        let drone: VEAssetInfo
        let title: VEAssetInfo
        let music: VEAssetInfo

        var all: [VEAssetInfo] { [interview, broll, drone, title, music] }
    }

    private static let twoHours = CMTime(value: 7200 * 30, timescale: 30)
    /// Width of the rendered timeline (track headers included) and of its track area.
    private static let timelineWidth: CGFloat = 1600
    private static var trackAreaWidth: CGFloat { timelineWidth - TimelineView.headerWidth - 1 }

    private var findings: [String] = []

    // MARK: The test

    func testATwoHourProjectStaysBoundedAndResponsive() throws {
        guard ProcessInfo.processInfo.environment["FRAMEWRIGHT_STRESS"] == "1" else {
            throw XCTSkip("a long-running stress test: run it with the StressTests scheme "
                + "(xcodebuild -scheme StressTests -destination 'platform=macOS' test), which sets "
                + "FRAMEWRIGHT_STRESS=1")
        }
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let directory = try TestMediaFactory.scratchDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let files = try writeMedia(in: directory)

        let engine = VEEngine(cacheDirectory: directory.appendingPathComponent("Caches", isDirectory: true))
        // The mix is rendered and clocks playback as usual; only the output is silent.
        engine.isMuted = true
        let store = ProjectStore(engine: engine)
        let media = try importMedia(files, into: engine)
        // The footprint and, of it, the frame cache's decoded pictures.
        var samples: [(label: String, bytes: UInt64, cache: UInt64)] = []
        func sample(_ label: String) {
            samples.append((label, Self.footprint(), engine.playbackStats.cacheBytes))
        }
        sample("with the media imported")

        // 1. Build.
        let build = try buildProject(engine: engine, media: media)
        let clips = engine.allClips
        let tracks = engine.allTracks
        let duration = engine.sequence.duration
        Self.report(String(format: "built: %d clips (%@), %d transitions, %d effect spans, %.4f h; %d facade calls "
                + "in %.1f s (%@)",
            clips.count, perTrackCounts(clips, tracks), build.transitions, build.spans, duration.seconds / 3600,
            build.calls.count, build.seconds, build.calls.description))
        XCTAssertGreaterThanOrEqual(clips.count, 120)
        XCTAssertEqual(engine.sequence.videoTrackIDs.count, 3)
        XCTAssertEqual(engine.sequence.audioTrackIDs.count, 3)
        XCTAssertEqual(CMTimeCompare(duration, Self.twoHours), 0, "the sequence runs exactly two hours")
        XCTAssertGreaterThanOrEqual(build.transitions, 40)
        XCTAssertGreaterThanOrEqual(build.spans, 60)
        XCTAssertGreaterThanOrEqual(build.reversed, 10)
        XCTAssertEqual(store.clips.count, clips.count, "the store follows the engine")
        // The import's poster thumbnails and waveforms settle before the sample.
        for asset in media.all where asset.hasAudio {
            let loaded = StoreFixture.spin(until: { engine.cachedWaveform(forAsset: asset.assetID) != nil },
                                           timeout: 120)
            XCTAssertTrue(loaded, "the waveform of \(asset.name)")
        }
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        sample("after building")

        // 2. The timeline's thumbnails and waveforms at the two zooms.
        let pass = timelinePass(store: store, duration: duration.seconds)
        sample("after the thumbnail and waveform pass")
        XCTAssertEqual(store.thumbnails.failuresRecorded, 0, "no thumbnail failed")
        XCTAssertEqual(store.waveforms.failuresRecorded, 0, "no waveform failed")
        XCTAssertGreaterThan(pass.thumbnailRequests, 50, "the pass asked for thumbnails")
        XCTAssertGreaterThan(pass.stripsRendered, 50, "the pass drew waveform strips")

        // 3. Playback from three positions, each started cold.
        let view = try VEPreviewView(frame: NSRect(x: 0, y: 0, width: 960, height: 540), device: device)
        engine.attachProgramView(view)
        defer { engine.attachProgramView(nil) }
        let playback = play(engine: engine, view: view, from: [600, 3300, 6000], seconds: 60)
        sample("after 3 x 60 s of playback")

        // 4. Scrubs.
        var generator = SeededGenerator(state: 0x5C2B_0001)
        let scrubs = scrub(engine: engine, view: view, count: 200, frames: Int64(duration.seconds * 30),
                           generator: &generator)
        sample("after 200 scrubs")

        // 5. Edits.
        let edits = edit(engine: engine, store: store, count: 100, generator: &generator)
        sample("after 100 edits")

        // The timeline model and its drawing at the two zooms, on the project as the edits left it.
        let model = modelTimings(store: store)

        // Save and reopen (as File > Open does: into the same engine, the store following).
        let file = directory.appendingPathComponent("Two hours.framewright")
        let before = engine.projectJSON
        var started = Self.now()
        try engine.saveProject(to: file)
        let saveMs = (Self.now() - started) * 1000
        let fileBytes = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
        started = Self.now()
        try engine.openProject(at: file)
        let openMs = (Self.now() - started) * 1000
        // As for the edits: the store refreshed (and rebuilt the timeline model) within the open.
        let storeFollowedOpen = store.changeCount == engine.changeCount
        let reopened = store.timelineModel
        let roundTrips = engine.projectJSON == before
        XCTAssertTrue(roundTrips, "the project round-trips through its file")
        XCTAssertEqual(engine.missingAssetIDs.count, 0)
        XCTAssertEqual(engine.loadWarnings, [])
        XCTAssertTrue(storeFollowedOpen, "the store followed the open within the call")
        XCTAssertEqual(reopened.clips.count, engine.allClips.count, "the reopened timeline shows every clip")
        sample("after save and reopen")

        // The report.
        for sample in samples {
            Self.report(String(format: "footprint %@: %.1f MB (frame cache %.1f MB)", sample.label,
                               Self.megabytes(sample.bytes), Self.megabytes(sample.cache)))
        }
        Self.report("thumbnail and waveform pass: \(pass)")
        Self.report("playback: " + playback.description)
        Self.report("scrub to picture: \(scrubs)")
        Self.report("edits through the facade, the store's refresh and the timeline model's rebuild included (the "
            + "store followed \(edits.storeFollowed) of \(edits.all.count) within the call): \(edits.all); by kind: "
            + edits.byKind.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: "; ")
            + "; \(edits.refused) refused")
        Self.report("the store's snapshot refresh on its own: \(edits.refresh)")
        Self.report("timeline model build: at the minimum zoom \(model.build[0]); at 30 s \(model.build[1])")
        Self.report("timeline draw (TimelineView, caches warm): at the minimum zoom \(model.draw[0]); at 30 s "
            + "\(model.draw[1])")
        Self.report(String(format: "save %.1f ms (%.1f KB), open %.1f ms (the store's refresh and the timeline model "
                + "included); the project %@", saveMs, Double(fileBytes) / 1024, openMs,
            roundTrips ? "round-trips" : "DIFFERS after the round trip"))

        // Memory: from after the build to after the edits.
        let afterBuild = samples[1].bytes
        let afterEdits = samples[5].bytes
        let growth = Int64(bitPattern: afterEdits) - Int64(bitPattern: afterBuild)
        let budget = UInt64(engine.frameCacheBudgetBytes)
        // What may legitimately stay allocated after the build besides the frame cache (its budget): the
        // app's thumbnail images (600 of at most 160 x 90 pixels: 35 MB) and waveform strips (240 tiles of
        // 512 x 64: 32 MB), and the program monitor's textures, compositor scratch and audio buffers
        // (64 MB).
        let slack: UInt64 = 131 * 1_048_576
        Self.report(String(format: "footprint growth from after building to after the edits: %+.1f MB (bound: the "
                + "frame cache budget %.0f MB + %.0f MB)", Double(growth) / 1_048_576, Self.megabytes(budget),
            Self.megabytes(slack)))
        if growth > Int64(budget) {
            finding(String(format: "the footprint grew by %.1f MB, more than the frame cache budget (%.0f MB)",
                           Double(growth) / 1_048_576, Self.megabytes(budget)))
        }
        XCTAssertLessThan(growth, Int64(budget + slack),
                          "the footprint stays within the frame cache budget and the app's caches")
        // Reopening replaces the project's media services (a new media epoch): what the old one cached is
        // released or evicted under the same budget.
        let afterReopen = Int64(bitPattern: samples[6].bytes) - Int64(bitPattern: afterBuild)
        Self.report(String(format: "footprint growth from after building to after the reopen: %+.1f MB",
                           Double(afterReopen) / 1_048_576))
        XCTAssertLessThan(afterReopen, Int64(budget + slack), "reopening stays within the same bound")

        // Responsiveness.
        if edits.all.p95 > 100 {
            finding(String(format: "edits: p95 %.1f ms, over the 100 ms target", edits.all.p95))
        }
        for (index, zoom) in ["the minimum zoom", "30 s"].enumerated() where model.build[index].median > 50 {
            finding(String(format: "the timeline model build at %@ takes %.1f ms (median), over the 50 ms target", zoom,
                           model.build[index].median))
        }
        XCTAssertEqual(edits.all.count, 100)
        XCTAssertEqual(edits.storeFollowed, edits.all.count, "the timings include the store's refresh")
        XCTAssertLessThan(edits.all.p95, 1000, "edits stay interactive (p95)")
        XCTAssertLessThan(model.build[0].median, 500)
        XCTAssertLessThan(model.build[1].median, 500)
        XCTAssertLessThan(model.draw[0].median, 2000)
        XCTAssertLessThan(model.draw[1].median, 2000)
        XCTAssertEqual(playback.startMs.count, 3)
        for (index, latency) in playback.startMs.enumerated() {
            XCTAssertGreaterThanOrEqual(latency, 0, "playback \(index + 1) presented a playing frame")
            XCTAssertLessThan(latency, 2000, "playback \(index + 1) starts")
        }
        for (index, played) in playback.playedSeconds.enumerated() {
            XCTAssertGreaterThan(played, 55, "playback \(index + 1) ran: the clock advanced \(played) s in 60 s")
        }
        XCTAssertEqual(scrubs.count, 200, "every scrub was presented")
        XCTAssertLessThan(scrubs.p95, 2000)
        XCTAssertLessThan(saveMs, 10000)
        XCTAssertLessThan(openMs, 30000)
        Self.report(findings.isEmpty ? "no findings" : "\(findings.count) finding(s)")
    }

    // MARK: Media

    private struct MediaFiles {
        let interview: URL
        let broll: URL
        let drone: URL
        let title: URL
        let music: URL
    }

    private func writeMedia(in directory: URL) throws -> MediaFiles {
        let started = Self.now()
        let files = MediaFiles(interview: directory.appendingPathComponent("interview_1080p30.mov"),
                               broll: directory.appendingPathComponent("broll_720p2997.mov"),
                               drone: directory.appendingPathComponent("drone_360p25.mp4"),
                               title: directory.appendingPathComponent("title.png"),
                               music: directory.appendingPathComponent("music_48k.m4a"))
        try StressMediaFactory.writeMovie(.init(codec: .h264, fileType: .mov, width: 1920, height: 1080,
                                                frameDuration: CMTime(value: 1, timescale: 30), frames: 2700,
                                                audioRate: 48000, toneHz: 440), to: files.interview)
        try StressMediaFactory.writeMovie(.init(codec: .hevc, fileType: .mov, width: 1280, height: 720,
                                                frameDuration: CMTime(value: 1001, timescale: 30000), frames: 1800,
                                                audioRate: 44100, toneHz: 550), to: files.broll)
        try StressMediaFactory.writeMovie(.init(codec: .h264, fileType: .mp4, width: 640, height: 360,
                                                frameDuration: CMTime(value: 1, timescale: 25), frames: 1500,
                                                audioRate: nil), to: files.drone)
        try StressMediaFactory.writeStill(to: files.title, width: 1920, height: 1080)
        try StressMediaFactory.writeAudio(to: files.music, seconds: 180, rate: 48000, toneHz: 330)
        Self.report(String(format: "media written in %.1f s", Self.now() - started))
        return files
    }

    private func importMedia(_ files: MediaFiles, into engine: VEEngine) throws -> Media {
        var imported: [VEAssetInfo]?
        var errors: [Error] = []
        let urls = [files.interview, files.broll, files.drone, files.title, files.music]
        engine.importMedia(at: urls) { assets, failures in
            imported = assets
            errors = failures
        }
        XCTAssertTrue(StoreFixture.spin(until: { imported != nil }, timeout: 120), "the import finished")
        XCTAssertEqual(errors.count, 0, "\(errors)")
        func asset(_ url: URL) throws -> VEAssetInfo {
            try XCTUnwrap(imported?.first { URL(fileURLWithPath: $0.path).lastPathComponent == url.lastPathComponent },
                          "\(url.lastPathComponent) was imported")
        }
        return try Media(interview: asset(files.interview), broll: asset(files.broll), drone: asset(files.drone),
                         title: asset(files.title), music: asset(files.music))
    }

    // MARK: 1. Build

    /// A step of building the project was refused (the test fails with it).
    private struct BuildRefused: Error, CustomStringConvertible {
        let step: String
        let message: String

        var description: String { "building the stress project: \(step) was refused: \(message)" }
    }

    private struct Build {
        var calls = Timings()
        var seconds: Double = 0
        var transitions = 0
        var spans = 0
        var reversed = 0
    }

    /// Builds the project described at the top through the facade, timing every call.
    private func buildProject(engine: VEEngine, media: Media) throws -> Build {
        var build = Build()
        let started = Self.now()
        func timed(_ what: String, _ edit: () -> VEEditResult) throws -> VEEditResult {
            let t0 = Self.now()
            let result = edit()
            build.calls.add((Self.now() - t0) * 1000)
            guard result.ok else { throw BuildRefused(step: what, message: result.message) }
            return result
        }
        func videoClip(of result: VEEditResult) throws -> VEClipID {
            let ids = result.createdIDs.map(\.int64Value)
            return try XCTUnwrap(ids.first { engine.clipInfo($0)?.trackKind == .video }, "a video clip was created")
        }
        func source(_ asset: VEAssetInfo, _ seconds: Double) -> CMTime {
            engine.frameTime(forAsset: asset.assetID, at: CMTime(seconds: seconds, preferredTimescale: 600_000))
        }
        func place(_ asset: VEAssetInfo, at time: CMTime, video: VETrackID, audio: VETrackID, from start: Double,
                   length: Double) throws -> VEEditResult {
            try timed("placing \(asset.name) at \(time.seconds) s") {
                engine.overwriteAsset(asset.assetID, at: time, videoTrack: video, audioTrack: audio,
                                      sourceIn: source(asset, start), sourceOut: source(asset, start + length))
            }
        }
        func spanValues(_ set: (inout VESpanValues) -> Void) -> VESpanValues {
            var values = VESpanValuesUnchanged()
            set(&values)
            return values
        }

        _ = try timed("adding V3") { engine.addTrack(of: .video, name: nil) }
        _ = try timed("adding A3") { engine.addTrack(of: .audio, name: nil) }
        let videoTracks = engine.sequence.videoTrackIDs.map(\.int64Value)
        let audioTracks = engine.sequence.audioTrackIDs.map(\.int64Value)
        let (v1, v2, v3) = (videoTracks[0], videoTracks[1], videoTracks[2])
        let (a1, a2, a3) = (audioTracks[0], audioTracks[1], audioTracks[2])
        var generator = SeededGenerator(state: 0x2_0000_F00D)

        // V1/A1: the story, end to end.
        let speeds: [(Int64, Int64)] = [(1, 1), (1, 1), (1, 1), (2, 1), (1, 2), (3, 2)]
        let story = [media.interview, media.interview, media.broll, media.drone]
        var story1: [VEClipID] = []
        var cursor = CMTime.zero
        while CMTimeCompare(CMTimeSubtract(Self.twoHours, cursor), Self.time(1)) >= 0 {
            let asset = story[Int.random(in: 0 ..< story.count, using: &generator)]
            let (numerator, denominator) = speeds[Int.random(in: 0 ..< speeds.count, using: &generator)]
            let speed = Double(numerator) / Double(denominator)
            let available = asset.duration.seconds - 2
            let remaining = CMTimeSubtract(Self.twoHours, cursor).seconds
            let length = min(Double.random(in: 20 ... 75, using: &generator) * speed, available, remaining * speed)
            let start = Double.random(in: 1 ... (asset.duration.seconds - 1 - length), using: &generator)
            let clip = try videoClip(of: place(asset, at: cursor, video: v1, audio: asset.hasAudio ? a1 : 0,
                                               from: start, length: length))
            if numerator != denominator {
                _ = try timed("a speed of \(numerator)/\(denominator)") {
                    engine.setSpeedNumerator(numerator, denominator: denominator, forClips: [NSNumber(value: clip)],
                                             ripple: false, scope: .syncedTracks)
                }
            }
            if story1.count % 9 == 4 {
                _ = try timed("reversing a clip") { engine.setReversed(true, forClips: [NSNumber(value: clip)]) }
                build.reversed += 1
            }
            cursor = try XCTUnwrap(engine.clipInfo(clip)).timelineEnd
            story1.append(clip)
        }
        // The story ends within a second of 2:00:00; its last clip is trimmed to end there where its
        // media allows (the music bed below ends there exactly, so the sequence is two hours long).
        if let last = story1.last, CMTimeCompare(cursor, Self.twoHours) != 0 {
            let t0 = Self.now()
            _ = engine.trimClipTail(last, to: Self.twoHours, clamp: true)
            build.calls.add((Self.now() - t0) * 1000)
        }
        for index in stride(from: 2, to: story1.count - 1, by: 3) {
            let t0 = Self.now()
            let result = engine.addTransition(fromClip: story1[index], toClip: story1[index + 1],
                                              duration: Self.time(1), options: [.fitToCut, .includeLinked])
            build.calls.add((Self.now() - t0) * 1000)
            // A reversed neighbour can lack the media beyond the cut: those cuts stay cuts.
            build.transitions += result.ok ? result.createdIDs.count : 0
        }

        // V2/A3: pictures in picture.
        var at = 60.0
        var pip = 0
        while at + 45 < 7200 {
            let asset = pip % 2 == 0 ? media.broll : media.drone
            let length = Double.random(in: 20 ... 40, using: &generator)
            let start = Double.random(in: 1 ... (asset.duration.seconds - 1 - length), using: &generator)
            let clip = try videoClip(of: place(asset, at: Self.time(at), video: v2, audio: asset.hasAudio ? a3 : 0,
                                               from: start, length: length))
            let info = try XCTUnwrap(engine.clipInfo(clip))
            _ = try timed("placing a picture in picture") {
                engine.setVideoParams(VEVideoParams(x: 560, y: -300, scale: 0.35, rotationDegrees: 0, opacity: 1),
                                      forClip: clip)
            }
            let motion = try timed("a Motion span") {
                engine.addSpan(kind: .motion, lane: 1, clip: clip,
                               range: CMTimeRange(start: info.timelineStart, duration: Self.time(10)))
            }
            let motionID = try XCTUnwrap(motion.span).spanID
            _ = try timed("the Motion span's values") {
                engine.setSpanValues(motionID, start: VESpanValuesUnchanged(), end: spanValues {
                    $0.x = -200
                    $0.y = 60
                    $0.scale = 1.3
                })
            }
            let fade = try timed("a Fade span") {
                engine.addSpan(kind: .opacity, lane: 2, clip: clip,
                               range: CMTimeRange(start: CMTimeSubtract(info.timelineEnd, Self.time(3)),
                                                  duration: Self.time(3)))
            }
            let fadeID = try XCTUnwrap(fade.span).spanID
            _ = try timed("the Fade span's values") {
                engine.setSpanValues(fadeID, start: VESpanValuesUnchanged(), end: spanValues { $0.opacity = 0 })
            }
            build.spans += 2
            pip += 1
            at += 240
        }

        // V3: titles.
        at = 30
        while at + 10 < 7200 {
            let placed = try timed("placing a title") {
                engine.overwriteAsset(media.title.assetID, at: Self.time(at), videoTrack: v3, audioTrack: 0,
                                      sourceIn: .invalid, sourceOut: .invalid)
            }
            let clip = try videoClip(of: placed)
            let info = try XCTUnwrap(engine.clipInfo(clip))
            for edge in [VEClipEdge.start, .end] {
                let fade = try timed("a title fade") {
                    engine.addTransition(at: edge, of: clip, duration: Self.time(0.5), options: [])
                }
                build.transitions += fade.createdIDs.count
            }
            let zoom = try timed("a title's Motion span") {
                engine.addSpan(kind: .motion, lane: 1, clip: clip,
                               range: CMTimeRange(start: info.timelineStart, duration: info.duration))
            }
            let zoomID = try XCTUnwrap(zoom.span).spanID
            _ = try timed("the title's zoom") {
                engine.setSpanValues(zoomID, start: VESpanValuesUnchanged(), end: spanValues { $0.scale = 1.15 })
            }
            build.spans += 1
            at += 360
        }

        // A2: the music bed to exactly 2:00:00, crossfaded on every other cut, ducked now and then.
        var bed: [VEClipID] = []
        cursor = .zero
        while CMTimeCompare(cursor, Self.twoHours) < 0 {
            let remaining = CMTimeSubtract(Self.twoHours, cursor).seconds
            let placed = try place(media.music, at: cursor, video: 0, audio: a2, from: 5, length: min(170, remaining))
            let clip = try XCTUnwrap(placed.createdIDs.first).int64Value
            if bed.count % 3 == 1 {
                let start = try XCTUnwrap(engine.clipInfo(clip)).timelineStart
                let duck = try timed("a Gain span") {
                    engine.addSpan(kind: .gain, lane: 1, clip: clip,
                                   range: CMTimeRange(start: CMTimeAdd(start, Self.time(60)), duration: Self.time(20)))
                }
                let duckID = try XCTUnwrap(duck.span).spanID
                _ = try timed("the Gain span's value") {
                    engine.setSpanValues(duckID, start: VESpanValuesUnchanged(), end: spanValues { $0.gainDb = -12 })
                }
                build.spans += 1
            }
            cursor = try XCTUnwrap(engine.clipInfo(clip)).timelineEnd
            bed.append(clip)
        }
        for index in stride(from: 0, to: bed.count - 1, by: 2) {
            let crossfade = try timed("a crossfade in the bed") {
                engine.addTransition(fromClip: bed[index], toClip: bed[index + 1], duration: Self.time(2),
                                     options: [.fitToCut])
            }
            build.transitions += crossfade.createdIDs.count
        }
        build.seconds = Self.now() - started
        return build
    }

    private func perTrackCounts(_ clips: [VEClipInfo], _ tracks: [VETrackInfo]) -> String {
        tracks.map { track in "\(track.name) \(clips.filter { $0.trackID == track.trackID }.count)" }
            .joined(separator: ", ")
    }

    // MARK: 2. Thumbnails and waveforms

    private struct Pass: CustomStringConvertible {
        var pages = [0, 0]
        var seconds = [0.0, 0.0]
        var firstDraw = [Timings(), Timings()]
        var thumbnailRequests = 0
        var waveformLoads = 0
        var stripsRendered = 0

        var description: String {
            String(format: "minimum zoom (2 pt/s): %d pages in %.1f s, first draw %@; 30 s: %d pages in %.1f s, "
                + "first draw %@; %d thumbnails fetched, %d waveform loads, %d waveform strips drawn",
                pages[0], seconds[0], firstDraw[0].description, pages[1], seconds[1], firstDraw[1].description,
                thumbnailRequests, waveformLoads, stripsRendered)
        }
    }

    /// Renders `TimelineView` (what the editor window shows below the monitors) at the store's zoom and
    /// scroll, as the window draws it; returns the milliseconds taken.
    @discardableResult
    private func renderTimeline(store: ProjectStore) -> Double {
        let height = store.timelineModel.contentHeight + TimelineView.rulerHeight + 40
        let content = TimelineView(store: store)
            .frame(width: Self.timelineWidth, height: height)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        let started = Self.now()
        _ = renderer.cgImage
        return (Self.now() - started) * 1000
    }

    /// Scrolls the timeline across the whole sequence at the minimum zoom and at a zoom showing 30 s,
    /// a track area's width at a time: each page is drawn (requesting what it lacks, as the canvas does),
    /// its fetches are waited for, and it is drawn again with them.
    private func timelinePass(store: ProjectStore, duration: Double) -> Pass {
        var pass = Pass()
        let requestsBefore = store.thumbnails.requestsStarted
        let loadsBefore = store.waveforms.loadsStarted
        let stripsBefore = store.waveforms.stripsRendered
        let zooms = [TimelineViewModel.minPixelsPerSecond, Double(Self.trackAreaWidth) / 30]
        for (index, zoom) in zooms.enumerated() {
            let started = Self.now()
            store.pixelsPerSecond = zoom
            let contentWidth = CGFloat((duration + 30) * zoom)
            var scroll: CGFloat = 0
            while scroll < contentWidth {
                store.scrollX = scroll
                pass.firstDraw[index].add(renderTimeline(store: store))
                StoreFixture.spin(until: { !store.thumbnails.isFetching }, timeout: 60)
                renderTimeline(store: store)
                pass.pages[index] += 1
                scroll += Self.trackAreaWidth
            }
            pass.seconds[index] = Self.now() - started
        }
        pass.thumbnailRequests = store.thumbnails.requestsStarted - requestsBefore
        pass.waveformLoads = store.waveforms.loadsStarted - loadsBefore
        pass.stripsRendered = store.waveforms.stripsRendered - stripsBefore
        store.scrollX = 0
        return pass
    }

    // MARK: 3. Playback

    private struct Playback: CustomStringConvertible {
        var positions: [Double] = []
        var startMs: [Double] = []
        var playedSeconds: [Double] = []
        var presented: [UInt64] = []
        var dropped: [UInt64] = []
        var late: [UInt64] = []
        var underruns: [UInt64] = []
        var output = ""

        var description: String {
            positions.indices.map { index in
                String(format: "from %.0f s: cold start %.1f ms, clock +%.2f s, %llu frames presented, %llu dropped, "
                    + "%llu late, %llu audio underruns", positions[index], startMs[index], playedSeconds[index],
                    presented[index], dropped[index], late[index], underruns[index])
            }.joined(separator: "; ") + " (audio output: \(output))"
        }
    }

    /// Plays `seconds` from each position, started cold: every unpinned frame purged, a jump into media
    /// nothing has decoded, play at once. The play-start latency is `VEEnginePlaybackTests`'s: renders
    /// every millisecond until the first frame chosen by the running clock, whose host time (less the
    /// playing time the frame stands for) is the latency; then renders at 60 Hz, as a display does.
    private func play(engine: VEEngine, view: VEPreviewView, from positions: [Double], seconds: Double) -> Playback {
        var playback = Playback()
        for position in positions {
            let startFrame = Int64(position * 30)
            engine.handleMemoryPressure(true)
            engine.seek(to: CMTime(value: startFrame, timescale: 30))
            let before = engine.playbackStats
            let started = Self.now()
            engine.play()
            var latency: Double = -1
            var lastRender = 0.0
            while Self.now() - started < seconds {
                RunLoop.main.run(until: Date().addingTimeInterval(0.001))
                let now = Self.now()
                if latency < 0 || now - lastRender >= 1.0 / 60 {
                    view.renderOnce()
                    lastRender = now
                }
                if latency < 0 {
                    let stats = engine.playbackStats
                    if stats.presentedClockDriven, stats.presentedFrameIndex > startFrame {
                        latency = (stats.presentedHostTime - started) * 1000
                            - Double(stats.presentedFrameIndex - startFrame) * 1000 / 30
                    }
                }
            }
            engine.pause()
            let after = engine.playbackStats
            playback.positions.append(position)
            playback.startMs.append(latency)
            playback.playedSeconds.append(engine.currentTime.seconds - position)
            playback.presented.append(after.presentedFrames &- before.presentedFrames)
            playback.dropped.append(after.droppedFrames &- before.droppedFrames)
            playback.late.append(after.lateFrames &- before.lateFrames)
            playback.underruns.append(after.audioUnderruns &- before.audioUnderruns)
            playback.output = String(format: "%@, latency %.1f ms", after.audioOutputKind, after.outputLatency * 1000)
        }
        return playback
    }

    // MARK: 4. Scrubs

    /// Scrubs to `count` random frames, one at a time: from the scrub call until the program monitor
    /// presents that frame (the paused frame source holds a frame back until its pictures are decoded),
    /// rendering every millisecond. A scrub not presented within 10 s is left out (the count shows it).
    private func scrub(engine: VEEngine, view: VEPreviewView, count: Int, frames: Int64,
                       generator: inout SeededGenerator) -> Timings {
        var timings = Timings()
        for _ in 0 ..< count {
            var frame = Int64.random(in: 0 ..< frames, using: &generator)
            if frame == engine.playbackStats.presentedFrameIndex {
                frame = (frame + 1) % frames
            }
            let started = Self.now()
            engine.scrub(to: CMTime(value: frame, timescale: 30))
            var presented = -1.0
            while presented < 0, Self.now() - started < 10 {
                view.renderOnce()
                let stats = engine.playbackStats
                if stats.presentedFrameIndex == frame {
                    presented = (stats.presentedHostTime - started) * 1000
                } else {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.001))
                }
            }
            if presented >= 0 {
                timings.add(presented)
            }
        }
        engine.endScrub()
        return timings
    }

    // MARK: 5. Edits

    private struct Edits {
        var all = Timings()
        var byKind: [String: Timings] = [:]
        var refresh = Timings()
        var refused = 0
        /// Edits after which the store had already followed the engine when the call returned.
        var storeFollowed = 0
    }

    /// `count` random edits of random clips through the facade, each timed on the main thread (the store's
    /// refresh, which the engine's notification runs within the call, included), and for comparison the
    /// store's snapshot refresh on its own.
    private func edit(engine: VEEngine, store: ProjectStore, count: Int, generator: inout SeededGenerator) -> Edits {
        var edits = Edits()
        let kinds = ["move", "trim head", "trim tail", "split", "ripple delete", "undo"]
        for _ in 0 ..< count {
            let kind = kinds[Int.random(in: 0 ..< kinds.count, using: &generator)]
            let clips = engine.allClips.sorted { $0.clipID < $1.clipID }
            let clip = clips[Int.random(in: 0 ..< clips.count, using: &generator)]
            let ids = [NSNumber(value: clip.clipID)]
            let offset = Double.random(in: 0.5 ... 5, using: &generator)
            let started = Self.now()
            let ok: Bool
            switch kind {
            case "move":
                let delta = Double.random(in: -30 ... 30, using: &generator)
                ok = engine.moveClips(ids, by: Self.time(delta), trackOffset: 0).ok
            case "trim head":
                ok = engine.trimClipHead(clip.clipID, to: CMTimeAdd(clip.timelineStart, Self.time(offset)),
                                         clamp: true).ok
            case "trim tail":
                ok = engine.trimClipTail(clip.clipID, to: CMTimeSubtract(clip.timelineEnd, Self.time(offset)),
                                         clamp: true).ok
            case "split":
                let middle = Self.time((clip.timelineStart.seconds + clip.timelineEnd.seconds) / 2)
                ok = engine.splitClips(ids, at: middle, breakingTransitions: true).ok
            case "ripple delete":
                ok = engine.rippleDeleteClips(ids).ok
            default:
                ok = engine.undo()
            }
            let elapsed = (Self.now() - started) * 1000
            edits.all.add(elapsed)
            edits.byKind[kind, default: Timings()].add(elapsed)
            if !ok { edits.refused += 1 }
            if store.changeCount == engine.changeCount { edits.storeFollowed += 1 }
            let t0 = Self.now()
            store.refreshModel()
            edits.refresh.add((Self.now() - t0) * 1000)
        }
        return edits
    }

    // MARK: The timeline model and its drawing

    private struct ModelTimings {
        var build = [Timings(), Timings()]
        var draw = [Timings(), Timings()]
    }

    /// At the two zooms: the timeline's content model built from the store's snapshots (a rebuild forced
    /// by collapsing and expanding V1's lanes, which changes what it draws) with the visible clips, spans
    /// and rows the canvas asks it for, and the whole TimelineView drawn with warm caches.
    private func modelTimings(store: ProjectStore) -> ModelTimings {
        var timings = ModelTimings()
        let key = WindowLayoutModel.laneKey(video: true, index: 0)
        let zooms = [TimelineViewModel.minPixelsPerSecond, Double(Self.trackAreaWidth) / 30]
        let middle = store.timelineModel.sequenceEnd / 2
        for (index, zoom) in zooms.enumerated() {
            store.pixelsPerSecond = zoom
            store.scrollX = CGFloat(middle * zoom)
            let builds = store.timelineBuildCount
            for repetition in 0 ..< 20 {
                store.layout.setLanesCollapsed(repetition % 2 == 0, key: key)
                let started = Self.now()
                let model = store.timelineModel
                _ = model.clips(visibleIn: Self.trackAreaWidth)
                _ = model.spans(visibleIn: Self.trackAreaWidth)
                _ = model.trackLayouts
                timings.build[index].add((Self.now() - started) * 1000)
            }
            XCTAssertEqual(store.timelineBuildCount - builds, 20, "every repetition rebuilt the model")
            store.layout.setLanesCollapsed(false, key: key)
            renderTimeline(store: store)
            StoreFixture.spin(until: { !store.thumbnails.isFetching }, timeout: 60)
            for _ in 0 ..< 10 {
                timings.draw[index].add(renderTimeline(store: store))
            }
        }
        return timings
    }

    // MARK: Helpers

    private static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? info.phys_footprint : 0
    }

    private static func megabytes(_ bytes: UInt64) -> Double { Double(bytes) / 1_048_576 }

    private static func now() -> Double { CACurrentMediaTime() }

    /// `seconds` on the sequence's 30 fps grid.
    private static func time(_ seconds: Double) -> CMTime {
        CMTime(value: CMTimeValue((seconds * 30).rounded()), timescale: 30)
    }

    private static func report(_ line: String) {
        print("STRESS 2H " + line)
    }

    private func finding(_ line: String) {
        findings.append(line)
        Self.report("FINDING: " + line)
    }
}
