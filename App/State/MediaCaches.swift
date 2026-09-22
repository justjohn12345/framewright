import CoreGraphics
import CoreMedia
import Foundation
import VidEditEngine

/// Main-thread cache of thumbnails fetched from the engine, for views that draw many of them
/// (media bin tiles, timeline thumbnail strips, source monitor).
///
/// `image(...)` returns what is cached and starts a fetch for a miss; when images arrive the
/// cache bumps `version` (coalesced to one change per run loop turn) so observing views redraw.
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
    private var failed: Set<Key> = []
    private var flushScheduled = false
    private let capacity: Int

    init(engine: VEEngine, capacity: Int = 600) {
        self.engine = engine
        self.capacity = capacity
    }

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

    /// Forgets everything (project closed).
    func removeAll() {
        images.removeAll()
        order.removeAll()
        inFlight.removeAll()
        failed.removeAll()
        bump()
    }

    private func request(_ key: Key) {
        guard let engine, !inFlight.contains(key), !failed.contains(key) else { return }
        inFlight.insert(key)
        let time = CMTime(value: key.millis, timescale: 1000)
        engine.thumbnail(forAsset: key.assetID, at: time, maxDimension: key.maxDimension) { [weak self] image, _ in
            MainActor.assumeIsolated {
                guard let self, self.inFlight.remove(key) != nil else { return }
                if let image {
                    self.store(image, for: key)
                } else {
                    self.failed.insert(key)
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

/// Main-thread cache of waveform peaks per asset.
@MainActor
final class WaveformCache: ObservableObject {
    @Published private(set) var version = 0

    private weak var engine: VEEngine?
    private var waveforms: [VEAssetID: VEWaveform] = [:]
    private var inFlight: Set<VEAssetID> = []
    private var failed: Set<VEAssetID> = []

    init(engine: VEEngine) {
        self.engine = engine
    }

    /// The peaks if loaded, else nil (and loading starts).
    func waveform(asset: VEAssetID) -> VEWaveform? {
        if let waveform = waveforms[asset] {
            return waveform
        }
        guard let engine, !inFlight.contains(asset), !failed.contains(asset) else { return nil }
        if let cached = engine.cachedWaveform(forAsset: asset) {
            waveforms[asset] = cached
            return cached
        }
        inFlight.insert(asset)
        engine.waveform(forAsset: asset) { [weak self] waveform, _ in
            MainActor.assumeIsolated {
                guard let self, self.inFlight.remove(asset) != nil else { return }
                if let waveform {
                    self.waveforms[asset] = waveform
                    self.version &+= 1
                } else {
                    self.failed.insert(asset)
                }
            }
        }
        return nil
    }

    func removeAll() {
        waveforms.removeAll()
        inFlight.removeAll()
        failed.removeAll()
        version &+= 1
    }
}
