import CoreGraphics
import CoreMedia
import Foundation
import FramewrightEngine

/// Main-thread cache of thumbnails fetched from the engine, for views that draw many of them
/// (media bin tiles, timeline thumbnail strips, source monitor).
///
/// `image(...)` returns what is cached and starts a fetch for a miss; when images arrive the
/// cache bumps `version` (coalesced to one change per run loop turn) so observing views redraw.
/// A failed fetch is not retried for `retryInterval` (a file that comes back, or a transient
/// decoder error, is picked up again afterwards). `removeAll()` (a project was closed) starts a
/// new generation: fetches still running for the previous project are ignored when they
/// complete, so they can neither fill nor poison the new project's keys (asset ids restart per
/// project). A fetch the engine reports as belonging to a closed project is not a failure.
@MainActor
final class ThumbnailCache: ObservableObject {
    struct Key: Hashable {
        let assetID: VEAssetID
        /// Source time in milliseconds (callers quantize to limit distinct requests).
        let millis: Int64
        let maxDimension: Int
    }

    @Published private(set) var version = 0

    private weak var engine: VEEngine?
    private var images: [Key: CGImage] = [:]
    private var order: [Key] = []
    private var inFlight: Set<Key> = []
    private var failed: [Key: Date] = [:]
    private var flushScheduled = false
    private var generation = 0
    private let capacity: Int
    private let retryInterval: TimeInterval
    private let now: () -> Date
    /// Fetches started (diagnostics and tests).
    private(set) var requestsStarted = 0
    /// Failures recorded, and completions of an earlier generation ignored (diagnostics and tests).
    private(set) var failuresRecorded = 0
    private(set) var ignoredCompletions = 0

    /// `now` is the clock the retry interval is measured with (tests pass a manual one).
    init(engine: VEEngine, capacity: Int = 600, retryInterval: TimeInterval = 30, now: @escaping () -> Date = Date.init) {
        self.engine = engine
        self.capacity = capacity
        self.retryInterval = retryInterval
        self.now = now
    }

    /// Whether a fetch is running (diagnostics and tests).
    var isFetching: Bool { !inFlight.isEmpty }

    /// The thumbnail if cached, else nil (and a fetch is started).
    func image(asset: VEAssetID, seconds: Double, maxDimension: Int) -> CGImage? {
        let key = Key(assetID: asset, millis: Int64((max(0, seconds) * 1000).rounded()), maxDimension: maxDimension)
        if let image = images[key] {
            return image
        }
        request(key)
        return nil
    }

    /// The closest cached image of `asset` at `maxDimension` (any time), for showing something
    /// while the exact frame loads.
    func anyImage(asset: VEAssetID, maxDimension: Int) -> CGImage? {
        for key in order.reversed() where key.assetID == asset && key.maxDimension == maxDimension {
            if let image = images[key] { return image }
        }
        return nil
    }

    /// Forgets everything (project closed); fetches still running are ignored when they finish.
    func removeAll() {
        generation &+= 1
        images.removeAll()
        order.removeAll()
        inFlight.removeAll()
        failed.removeAll()
        bump()
    }

    /// Memory pressure: drops the older half of the images (all of them when critical).
    func handleMemoryPressure(critical: Bool) {
        let drop = critical ? order.count : order.count / 2
        for key in order.prefix(drop) {
            images[key] = nil
        }
        order.removeFirst(drop)
        bump()
    }

    /// Whether `key` failed recently (an expired failure is forgotten).
    private func recentlyFailed(_ key: Key) -> Bool {
        guard let when = failed[key] else { return false }
        if now().timeIntervalSince(when) < retryInterval { return true }
        failed[key] = nil
        return false
    }

    private func request(_ key: Key) {
        guard let engine, !inFlight.contains(key), !recentlyFailed(key) else { return }
        inFlight.insert(key)
        requestsStarted += 1
        let time = CMTime(value: key.millis, timescale: 1000)
        let generation = self.generation
        engine.thumbnail(forAsset: key.assetID, at: time, maxDimension: key.maxDimension) { [weak self] image, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                // A fetch of a previous generation (another project) must not touch this one's keys.
                guard generation == self.generation else {
                    self.ignoredCompletions += 1
                    return
                }
                guard self.inFlight.remove(key) != nil else { return }
                if let image {
                    self.store(image, for: key)
                } else if !isProjectClosed(error) {
                    self.failed[key] = self.now()
                    self.failuresRecorded += 1
                }
            }
        }
    }

    private func store(_ image: CGImage, for key: Key) {
        images[key] = image
        order.append(key)
        if order.count > capacity {
            let evicted = order.removeFirst()
            images[evicted] = nil
        }
        bump()
    }

    private func bump() {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.flushScheduled = false
                self.version &+= 1
            }
        }
    }
}

/// Main-thread cache of waveform peaks per asset, and of the timeline's pre-rendered waveform
/// strips: images of an asset's peaks at a power-of-two zoom level, cut into fixed-width tiles,
/// so drawing an audio clip costs a few image draws instead of a peak query every 2 points.
/// A failed load is retried after `retryInterval`. Generations work as in `ThumbnailCache`.
@MainActor
final class WaveformCache: ObservableObject {
    @Published private(set) var version = 0

    /// Tile geometry: `tileWidth` pixels per tile, drawn `tileHeight` pixels tall.
    static let tileWidth = 512
    static let tileHeight = 64

    struct StripKey: Hashable {
        let assetID: VEAssetID
        /// Pixels per second of source time (a power of two).
        let level: Int
        let index: Int
    }

    private weak var engine: VEEngine?
    private var waveforms: [VEAssetID: VEWaveform] = [:]
    private var inFlight: Set<VEAssetID> = []
    private var failed: [VEAssetID: Date] = [:]
    private var strips: [StripKey: CGImage] = [:]
    private var stripOrder: [StripKey] = []
    private var generation = 0
    private let stripCapacity: Int
    private let retryInterval: TimeInterval
    private let now: () -> Date
    /// Tiles rendered so far (diagnostics and tests).
    private(set) var stripsRendered = 0
    /// Loads started and failures recorded (diagnostics and tests).
    private(set) var loadsStarted = 0
    private(set) var failuresRecorded = 0

    init(engine: VEEngine, stripCapacity: Int = 240, retryInterval: TimeInterval = 30,
         now: @escaping () -> Date = Date.init) {
        self.engine = engine
        self.stripCapacity = stripCapacity
        self.retryInterval = retryInterval
        self.now = now
    }

    /// The peaks if loaded, else nil (and loading starts).
    func waveform(asset: VEAssetID) -> VEWaveform? {
        if let waveform = waveforms[asset] {
            return waveform
        }
        guard let engine, !inFlight.contains(asset) else { return nil }
        if let when = failed[asset] {
            if now().timeIntervalSince(when) < retryInterval { return nil }
            failed[asset] = nil
        }
        if let cached = engine.cachedWaveform(forAsset: asset) {
            waveforms[asset] = cached
            return cached
        }
        inFlight.insert(asset)
        loadsStarted += 1
        let generation = self.generation
        engine.waveform(forAsset: asset) { [weak self] waveform, error in
            MainActor.assumeIsolated {
                guard let self, generation == self.generation, self.inFlight.remove(asset) != nil else { return }
                if let waveform {
                    self.waveforms[asset] = waveform
                    self.version &+= 1
                } else if !isProjectClosed(error) {
                    self.failed[asset] = self.now()
                    self.failuresRecorded += 1
                }
            }
        }
        return nil
    }

    /// The zoom level (source pixels per second, a power of two) for drawing at
    /// `pointsPerSourceSecond`: the next level up, so tiles are drawn at most 2x downscaled.
    static func level(forPointsPerSecond pointsPerSourceSecond: Double) -> Int {
        let clamped = min(max(pointsPerSourceSecond, 1), 65536)
        return Int(pow(2, ceil(log2(clamped))))
    }

    /// Source seconds covered by one tile at `level`.
    static func tileSeconds(level: Int) -> Double {
        Double(tileWidth) / Double(level)
    }

    /// Tile `index` of `asset`'s waveform at `level` (rendered on first use), or nil while the
    /// peaks are not loaded.
    func strip(asset: VEAssetID, level: Int, index: Int) -> CGImage? {
        let key = StripKey(assetID: asset, level: level, index: index)
        if let image = strips[key] {
            return image
        }
        guard let waveform = waveform(asset: asset),
              let image = Self.render(waveform, level: level, index: index) else { return nil }
        strips[key] = image
        stripOrder.append(key)
        stripsRendered += 1
        if stripOrder.count > stripCapacity {
            strips[stripOrder.removeFirst()] = nil
        }
        return image
    }

    private static func render(_ waveform: VEWaveform, level: Int, index: Int) -> CGImage? {
        let width = tileWidth
        let height = tileHeight
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 0.55, green: 0.95, blue: 0.65, alpha: 0.9))
        let secondsPerPixel = 1.0 / Double(level)
        let start = Double(index) * tileSeconds(level: level)
        let mid = CGFloat(height) / 2
        let half = CGFloat(height) / 2 - 1
        for x in 0 ..< width {
            let t0 = start + Double(x) * secondsPerPixel
            let peak = waveform.peakRange(fromSeconds: t0, toSeconds: t0 + secondsPerPixel)
            // CoreGraphics' origin is bottom-left: maximum is up.
            let top = mid + CGFloat(max(0, peak.maximum)) * half
            let bottom = mid + CGFloat(min(0, peak.minimum)) * half
            context.fill(CGRect(x: CGFloat(x), y: bottom, width: 1, height: max(0.5, top - bottom)))
        }
        return context.makeImage()
    }

    /// Memory pressure: drops the rendered strips (and the peaks too when critical).
    func handleMemoryPressure(critical: Bool) {
        strips.removeAll()
        stripOrder.removeAll()
        if critical {
            waveforms.removeAll()
        }
        version &+= 1
    }

    /// Forgets everything (project closed); loads still running are ignored when they finish.
    func removeAll() {
        generation &+= 1
        waveforms.removeAll()
        inFlight.removeAll()
        failed.removeAll()
        strips.removeAll()
        stripOrder.removeAll()
        version &+= 1
    }
}

/// Whether `error` is the engine's report that a request belonged to a project that was closed
/// meanwhile (not a failure of the media).
func isProjectClosed(_ error: Error?) -> Bool {
    guard let error = error as NSError? else { return false }
    return error.domain == VEEngineErrorDomain && error.code == VEEngineError.Code.projectClosed.rawValue
}
