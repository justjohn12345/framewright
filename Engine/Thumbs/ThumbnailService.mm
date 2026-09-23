#include "ThumbnailService.h"

#include "../Media/PixelBuffer.h"
#include "../Model/TimeUtil.h"
#include "CacheKey.h"

#include <ImageIO/ImageIO.h>
#include <VideoToolbox/VideoToolbox.h>
#include <os/log.h>

#include <algorithm>
#include <cmath>
#include <fstream>
#include <iterator>
#include <sstream>

namespace ve::thumbs {

using namespace ve::media;

namespace {

constexpr uint64_t kDiskFormatVersion = 1;

os_log_t thumbLog() {
    static os_log_t log = os_log_create("ve.thumbs", "thumbnails");
    return log;
}

int64_t toMicros(CMTime t) {
    if (!CMTIME_IS_NUMERIC(t)) {
        return 0;
    }
    return CMTimeConvertScale(t, 1000000, kCMTimeRoundingMethod_RoundHalfAwayFromZero).value;
}

void fitWithin(int maxDimension, int &width, int &height) {
    if (maxDimension <= 0 || (width <= maxDimension && height <= maxDimension)) {
        return;
    }
    const double scale = static_cast<double>(maxDimension) / std::max(width, height);
    width = std::max(1, static_cast<int>(std::lround(width * scale)));
    height = std::max(1, static_cast<int>(std::lround(height * scale)));
}

CFRef<CGColorSpaceRef> sRGB() {
    return CFRef<CGColorSpaceRef>::adopt(CGColorSpaceCreateWithName(kCGColorSpaceSRGB));
}

constexpr CGBitmapInfo kBGRAInfo =
    static_cast<CGBitmapInfo>(kCGImageAlphaPremultipliedFirst) | static_cast<CGBitmapInfo>(kCGBitmapByteOrder32Little);

/// Converts/scales `source` to a 32BGRA buffer of exactly width x height.
Result<PixelBuffer> toBGRA(VTPixelTransferSessionRef session, const PixelBuffer &source, int width, int height) {
    if (source.pixelFormat() == kCVPixelFormatType_32BGRA && static_cast<int>(source.width()) == width &&
        static_cast<int>(source.height()) == height) {
        return source;
    }
    CFRef<CFDictionaryRef> attributes =
        CFRef<CFDictionaryRef>::adopt(createPixelBufferAttributes(kCVPixelFormatType_32BGRA, width, height));
    CVPixelBufferRef raw = nullptr;
    const CVReturn cr =
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes.get(), &raw);
    if (cr != kCVReturnSuccess) {
        return makeError(MediaErrorCode::Internal, "CVPixelBufferCreate failed", "CVReturn", cr);
    }
    PixelBuffer dest = PixelBuffer::adopt(raw);
    const OSStatus st = VTPixelTransferSessionTransferImage(session, source.get(), dest.get());
    if (st != noErr) {
        return makeError(MediaErrorCode::Internal, "VTPixelTransferSessionTransferImage failed", "OSStatus", st);
    }
    return dest;
}

/// Copies a 32BGRA buffer into a CGImage that owns its pixels, rotated clockwise by
/// `rotationDegrees` (0/90/180/270).
Result<ThumbnailImage> copyToImage(const PixelBuffer &bgra, int rotationDegrees) {
    PixelBufferLock lock(bgra.get(), true);
    if (!lock.locked()) {
        return makeError(MediaErrorCode::Internal, "cannot lock pixel buffer");
    }
    const size_t w = bgra.width();
    const size_t h = bgra.height();
    const size_t stride = CVPixelBufferGetBytesPerRow(bgra.get());
    const uint8_t *base = static_cast<const uint8_t *>(CVPixelBufferGetBaseAddress(bgra.get()));
    CFRef<CFMutableDataRef> data = CFRef<CFMutableDataRef>::adopt(CFDataCreateMutable(kCFAllocatorDefault, 0));
    CFDataSetLength(data.get(), static_cast<CFIndex>(w * 4 * h));
    uint8_t *dst = CFDataGetMutableBytePtr(data.get());
    for (size_t y = 0; y < h; ++y) {
        std::copy_n(base + y * stride, w * 4, dst + y * w * 4);
    }
    CFRef<CGDataProviderRef> provider = CFRef<CGDataProviderRef>::adopt(CGDataProviderCreateWithCFData(data.get()));
    CFRef<CGColorSpaceRef> space = sRGB();
    CFRef<CGImageRef> upright = CFRef<CGImageRef>::adopt(CGImageCreate(
        w, h, 8, 32, w * 4, space.get(), kBGRAInfo, provider.get(), nullptr, false, kCGRenderingIntentDefault));
    if (!upright) {
        return makeError(MediaErrorCode::Internal, "CGImageCreate failed");
    }
    const int r = ((rotationDegrees % 360) + 360) % 360;
    if (r == 0) {
        return upright;
    }
    const bool swap = r == 90 || r == 270;
    const size_t ow = swap ? h : w;
    const size_t oh = swap ? w : h;
    CFRef<CGContextRef> ctx =
        CFRef<CGContextRef>::adopt(CGBitmapContextCreate(nullptr, ow, oh, 8, 0, space.get(), kBGRAInfo));
    if (!ctx) {
        return makeError(MediaErrorCode::Internal, "CGBitmapContextCreate failed");
    }
    // CoreGraphics is y-up, so a clockwise (visual) rotation is a negative angle.
    if (r == 90) {
        CGContextTranslateCTM(ctx.get(), 0, oh);
        CGContextRotateCTM(ctx.get(), -M_PI_2);
    } else if (r == 180) {
        CGContextTranslateCTM(ctx.get(), ow, oh);
        CGContextRotateCTM(ctx.get(), M_PI);
    } else {
        CGContextTranslateCTM(ctx.get(), ow, 0);
        CGContextRotateCTM(ctx.get(), M_PI_2);
    }
    CGContextDrawImage(ctx.get(), CGRectMake(0, 0, w, h), upright.get());
    CFRef<CGImageRef> rotated = CFRef<CGImageRef>::adopt(CGBitmapContextCreateImage(ctx.get()));
    if (!rotated) {
        return makeError(MediaErrorCode::Internal, "CGBitmapContextCreateImage failed");
    }
    return rotated;
}

Result<ThumbnailImage> readPNG(const std::string &path) {
    std::ifstream in(path, std::ios::binary);
    if (!in) {
        return makeError(MediaErrorCode::FileNotFound, path);
    }
    std::vector<uint8_t> bytes((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
    CFRef<CFDataRef> data = CFRef<CFDataRef>::adopt(
        CFDataCreate(kCFAllocatorDefault, bytes.data(), static_cast<CFIndex>(bytes.size())));
    CFRef<CGImageSourceRef> source = CFRef<CGImageSourceRef>::adopt(CGImageSourceCreateWithData(data.get(), nullptr));
    const void *keys[] = {kCGImageSourceShouldCacheImmediately};
    const void *values[] = {kCFBooleanTrue};
    CFRef<CFDictionaryRef> options = CFRef<CFDictionaryRef>::adopt(CFDictionaryCreate(
        kCFAllocatorDefault, keys, values, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks));
    CFRef<CGImageRef> image = source ? CFRef<CGImageRef>::adopt(CGImageSourceCreateImageAtIndex(
                                           source.get(), 0, options.get()))
                                     : CFRef<CGImageRef>();
    if (!image) {
        return makeError(MediaErrorCode::CorruptData, "unreadable cached thumbnail " + path);
    }
    return image;
}

Status writePNG(const std::string &path, CGImageRef image, uint64_t &written) {
    CFRef<CFMutableDataRef> data = CFRef<CFMutableDataRef>::adopt(CFDataCreateMutable(kCFAllocatorDefault, 0));
    CFRef<CGImageDestinationRef> dest =
        CFRef<CGImageDestinationRef>::adopt(CGImageDestinationCreateWithData(data.get(), CFSTR("public.png"), 1,
                                                                             nullptr));
    if (!dest) {
        return makeError(MediaErrorCode::Internal, "cannot create PNG encoder");
    }
    CGImageDestinationAddImage(dest.get(), image, nullptr);
    if (!CGImageDestinationFinalize(dest.get())) {
        return makeError(MediaErrorCode::EncodeFailed, "PNG encoding failed");
    }
    written = static_cast<uint64_t>(CFDataGetLength(data.get()));
    return writeFileAtomically(path, CFDataGetBytePtr(data.get()), static_cast<size_t>(CFDataGetLength(data.get())));
}

} // namespace

// MARK: - Worker-local state

/// Per worker thread: the pixel transfer session (VTPixelTransferSession is not thread-safe).
class ThumbnailService::Worker {
  public:
    Result<VTPixelTransferSessionRef> session() {
        if (!session_) {
            const OSStatus st = VTPixelTransferSessionCreate(kCFAllocatorDefault, session_.outPtr());
            if (st != noErr) {
                return makeError(MediaErrorCode::Internal, "VTPixelTransferSessionCreate failed", "OSStatus", st);
            }
        }
        return session_.get();
    }
    ~Worker() {
        if (session_) {
            VTPixelTransferSessionInvalidate(session_.get());
        }
    }

  private:
    CFRef<VTPixelTransferSessionRef> session_;
};

Result<ThumbnailImage> ThumbnailService::renderThumbnail(const PixelBuffer &frame, int maxDimension,
                                                        int rotationDegrees) {
    Worker worker;
    return render(worker, frame, maxDimension, rotationDegrees);
}

Result<ThumbnailImage> ThumbnailService::render(Worker &worker, const PixelBuffer &frame, int maxDimension,
                                               int rotationDegrees) {
    if (!frame || maxDimension <= 0) {
        return makeError(MediaErrorCode::InvalidArgument, "renderThumbnail needs a frame and maxDimension > 0");
    }
    auto session = worker.session();
    if (!session.ok()) {
        return std::move(session).error();
    }
    int w = static_cast<int>(frame.width());
    int h = static_cast<int>(frame.height());
    fitWithin(maxDimension, w, h);
    auto bgra = toBGRA(session.value(), frame, w, h);
    if (!bgra.ok()) {
        return std::move(bgra).error();
    }
    return copyToImage(bgra.value(), rotationDegrees);
}

struct ThumbnailService::DecoderSlot {
    std::string routeKey; ///< Path + file identity.
    int trackIndex = -1;
    int maxDimension = 0;
    std::unique_ptr<IVideoDecoder> decoder;
};

// MARK: - Lifetime

ThumbnailService::ThumbnailService(std::shared_ptr<BackendRouter> router, Config config)
    : router_(std::move(router)), config_(std::move(config)) {
    if (!config_.diskCacheDirectory.empty()) {
        disk_ = std::make_unique<DiskCacheBudget>(config_.diskCacheDirectory, ".png", config_.diskBudgetBytes);
    }
    const int n = std::max(1, config_.threads);
    for (int i = 0; i < n; ++i) {
        threads_.emplace_back([this] { workerMain(); });
    }
}

ThumbnailService::~ThumbnailService() {
    std::vector<Waiter> cancelled;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        stopping_ = true;
        for (auto &job : queue_) {
            jobs_.erase(job->key);
            for (auto &w : job->waiters) {
                cancelled.push_back(std::move(w));
            }
        }
        queue_.clear();
        stats_.cancelled += cancelled.size();
    }
    cv_.notify_all();
    deliver(std::move(cancelled), makeError(MediaErrorCode::Cancelled, "thumbnail service destroyed"));
    for (std::thread &t : threads_) {
        t.join();
    }
    idleDecoders_.clear();
}

// MARK: - Requests

ThumbnailService::Key ThumbnailService::keyFor(const ThumbnailRequest &request) {
    const FileIdentity id = fileIdentity(request.url);
    return Key{request.asset, toMicros(request.time), request.maxDimension, request.trackIndex, id.size,
               id.modifiedNanoseconds};
}

std::string ThumbnailService::diskFileName(const ThumbnailRequest &request) {
    const FileIdentity id = fileIdentity(request.url);
    Hasher h;
    h.add(std::string_view("ve.thumb"))
        .add(kDiskFormatVersion)
        .add(request.url)
        .add(id.size)
        .add(id.modifiedNanoseconds)
        .add(toMicros(request.time))
        .add(static_cast<int64_t>(request.maxDimension))
        .add(static_cast<int64_t>(request.trackIndex));
    return h.hex() + ".png";
}

void ThumbnailService::deliver(std::vector<Waiter> waiters, const Result<ThumbnailImage> &result) {
    for (Waiter &w : waiters) {
        ThumbnailCallback callback = std::move(w.callback);
        Result<ThumbnailImage> copy = result;
        dispatch_async(w.queue, ^{
          callback(copy);
        });
    }
}

void ThumbnailService::request(const ThumbnailRequest &request, dispatch_queue_t queue, ThumbnailCallback callback) {
    if (!callback) {
        return;
    }
    if (queue == nullptr) {
        // No queue to deliver on: report on a global queue rather than dropping the callback.
        queue = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
        deliver({Waiter{queue, std::move(callback)}},
                makeError(MediaErrorCode::InvalidArgument, "thumbnail request without a callback queue"));
        return;
    }
    if (request.url.empty() || request.maxDimension <= 0) {
        deliver({Waiter{queue, std::move(callback)}},
                makeError(MediaErrorCode::InvalidArgument, "thumbnail request needs a path and maxDimension > 0"));
        return;
    }
    const Key key = keyFor(request);
    std::unique_lock<std::mutex> lock(mutex_);
    ++stats_.requests;
    if (stopping_) {
        ++stats_.cancelled;
        lock.unlock();
        deliver({Waiter{queue, std::move(callback)}},
                makeError(MediaErrorCode::Cancelled, "thumbnail service is shutting down"));
        return;
    }
    if (auto it = memory_.find(key); it != memory_.end()) {
        ++stats_.memoryHits;
        lru_.splice(lru_.begin(), lru_, it->second.lru);
        ThumbnailImage image = it->second.image;
        lock.unlock();
        deliver({Waiter{queue, std::move(callback)}}, image);
        return;
    }
    if (auto it = jobs_.find(key); it != jobs_.end()) {
        ++stats_.coalesced;
        it->second->waiters.push_back(Waiter{queue, std::move(callback)});
        return;
    }
    auto job = std::make_shared<Job>();
    job->key = key;
    job->request = request;
    job->waiters.push_back(Waiter{queue, std::move(callback)});
    jobs_[key] = job;
    queue_.push_back(std::move(job));
    lock.unlock();
    cv_.notify_one();
}

void ThumbnailService::cancelPending(AssetId asset) {
    std::vector<Waiter> cancelled;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        for (auto it = queue_.begin(); it != queue_.end();) {
            if ((*it)->key.asset == asset) {
                jobs_.erase((*it)->key);
                for (auto &w : (*it)->waiters) {
                    cancelled.push_back(std::move(w));
                }
                it = queue_.erase(it);
            } else {
                ++it;
            }
        }
        stats_.cancelled += cancelled.size();
    }
    deliver(std::move(cancelled), makeError(MediaErrorCode::Cancelled, "thumbnail request cancelled"));
}

void ThumbnailService::purge(AssetId asset) {
    std::vector<ThumbnailImage> dead; // Released after the lock.
    std::lock_guard<std::mutex> lock(mutex_);
    for (auto it = memory_.begin(); it != memory_.end();) {
        if (it->first.asset == asset) {
            memoryBytes_ -= it->second.bytes;
            lru_.erase(it->second.lru);
            dead.push_back(std::move(it->second.image));
            it = memory_.erase(it);
        } else {
            ++it;
        }
    }
}

ThumbnailService::Stats ThumbnailService::stats() const {
    std::lock_guard<std::mutex> lock(mutex_);
    Stats s = stats_;
    s.memoryBytes = memoryBytes_;
    s.memoryCount = memory_.size();
    s.routeCount = routes_.size();
    return s;
}

void ThumbnailService::insertMemory(const Key &key, const ThumbnailImage &image) {
    const size_t bytes = CGImageGetBytesPerRow(image.get()) * CGImageGetHeight(image.get());
    if (bytes > config_.memoryBudgetBytes) {
        return;
    }
    if (auto it = memory_.find(key); it != memory_.end()) {
        memoryBytes_ -= it->second.bytes;
        lru_.erase(it->second.lru);
        memory_.erase(it);
    }
    lru_.push_front(key);
    memory_[key] = CacheEntry{image, bytes, lru_.begin()};
    memoryBytes_ += bytes;
    while (memoryBytes_ > config_.memoryBudgetBytes && !lru_.empty()) {
        auto victim = memory_.find(lru_.back());
        memoryBytes_ -= victim->second.bytes;
        memory_.erase(victim);
        lru_.pop_back();
    }
}

// MARK: - Work

void ThumbnailService::workerMain() {
    Worker worker;
    std::unique_lock<std::mutex> lock(mutex_);
    for (;;) {
        cv_.wait(lock, [&] { return stopping_ || !queue_.empty(); });
        if (queue_.empty()) {
            return; // stopping_
        }
        std::shared_ptr<Job> job = std::move(queue_.front());
        queue_.pop_front(); // Running jobs stay in jobs_ (for coalescing) but leave queue_.
        lock.unlock();

        // std::thread workers have no autorelease pool: drain the Objective-C objects that
        // decoding, ImageIO and AVFoundation autorelease after every job.
        @autoreleasepool {
            bool fromDisk = false;
            Result<ThumbnailImage> result = produce(job->request, worker, fromDisk);

            lock.lock();
            jobs_.erase(job->key);
            std::vector<Waiter> waiters = std::move(job->waiters);
            if (result.ok()) {
                insertMemory(job->key, result.value());
                ++(fromDisk ? stats_.diskHits : stats_.decodes);
            } else {
                ++stats_.failures;
            }
            lock.unlock();
            deliver(std::move(waiters), result);
        }
        lock.lock();
    }
}

Result<ThumbnailImage> ThumbnailService::produce(const ThumbnailRequest &request, Worker &worker, bool &fromDisk) {
    std::string diskPath;
    if (!config_.diskCacheDirectory.empty()) {
        diskPath = config_.diskCacheDirectory + "/" + diskFileName(request);
        auto cached = readPNG(diskPath);
        if (cached.ok()) {
            fromDisk = true;
            disk_->touch(diskPath);
            return cached;
        }
        // Missing, or unreadable (truncated/corrupt): decode and overwrite it below.
    }
    auto image = decode(request, worker);
    if (image.ok() && !diskPath.empty()) {
        Status st = ensureDirectory(config_.diskCacheDirectory);
        uint64_t written = 0;
        if (st.ok()) {
            st = writePNG(diskPath, image.value().get(), written);
        }
        if (st.ok()) {
            disk_->added(written);
        }
        if (!st.ok()) {
            // The thumbnail itself is fine; the disk cache is an optimisation. Count and log.
            std::lock_guard<std::mutex> lock(mutex_);
            ++stats_.diskWriteFailures;
            os_log_error(thumbLog(), "thumbnail disk cache write failed: %{public}s", st.error().description().c_str());
        }
    }
    return image;
}

Result<std::shared_ptr<const RoutedMediaInfo>> ThumbnailService::route(const std::string &url) {
    const FileIdentity id = fileIdentity(url);
    const std::string key = url + "|" + std::to_string(id.size) + "|" + std::to_string(id.modifiedNanoseconds);
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (auto it = routes_.find(key); it != routes_.end()) {
            routeLru_.splice(routeLru_.begin(), routeLru_, it->second.lru);
            return it->second.routed;
        }
    }
    auto routed = router_->probe(url, config_.routing); // Errors are not remembered.
    if (!routed.ok()) {
        return std::move(routed).error();
    }
    auto shared = std::make_shared<const RoutedMediaInfo>(std::move(routed).value());
    std::lock_guard<std::mutex> lock(mutex_);
    if (auto it = routes_.find(key); it != routes_.end()) {
        return it->second.routed; // Another worker routed it meanwhile.
    }
    routeLru_.push_front(key);
    routes_[key] = RouteEntry{shared, routeLru_.begin()};
    while (routes_.size() > std::max<size_t>(1, config_.maxRoutes)) {
        routes_.erase(routeLru_.back());
        routeLru_.pop_back();
    }
    return shared;
}

Result<ThumbnailImage> ThumbnailService::decode(const ThumbnailRequest &request, Worker &worker) {
    auto routed = route(request.url);
    if (!routed.ok()) {
        return std::move(routed).error();
    }
    const RoutedMediaInfo &info = *routed.value();
    const TrackRoute *route = request.trackIndex < 0 ? info.visualRoute() : info.route(request.trackIndex);
    const TrackInfo *track = route ? info.info.track(route->trackIndex) : nullptr;
    if (track == nullptr || track->kind == TrackKind::Audio) {
        return makeError(MediaErrorCode::NoSuchTrack, "no video track for a thumbnail in " + request.url);
    }
    const FileIdentity id = fileIdentity(request.url);
    const std::string routeKey =
        request.url + "|" + std::to_string(id.size) + "|" + std::to_string(id.modifiedNanoseconds);

    // Check out an idle decoder for this (file, track, size), or open one.
    std::unique_ptr<DecoderSlot> slot;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        for (auto it = idleDecoders_.begin(); it != idleDecoders_.end(); ++it) {
            if ((*it)->routeKey == routeKey && (*it)->trackIndex == route->trackIndex &&
                (*it)->maxDimension == request.maxDimension) {
                slot = std::move(*it);
                idleDecoders_.erase(it);
                break;
            }
        }
    }
    if (!slot) {
        DecodeOptions options;
        options.maxDimension = request.maxDimension;
        auto opened = router_->makeVideoDecoder(info, route->trackIndex, options);
        if (!opened.ok()) {
            return std::move(opened).error();
        }
        slot = std::make_unique<DecoderSlot>();
        slot->routeKey = routeKey;
        slot->trackIndex = route->trackIndex;
        slot->maxDimension = request.maxDimension;
        slot->decoder = std::move(opened.value().decoder);
    }

    const bool still = track->kind == TrackKind::Still;
    const CMTime time = CMTIME_IS_NUMERIC(request.time) ? maxTime(request.time, kCMTimeZero) : kCMTimeZero;
    auto decodeAt = [&](CMTime at) -> Result<std::optional<VideoFrame>> {
        VE_MEDIA_TRY(slot->decoder->seek(at));
        return slot->decoder->next();
    };
    auto frame = decodeAt(still ? kCMTimeZero : time);
    if (frame.ok() && !frame.value() && !still && isPositive(track->frameDuration) && isNumeric(track->duration)) {
        const CMTime last = track->startTime + track->duration - track->frameDuration;
        frame = decodeAt(maxTime(last, kCMTimeZero));
    }
    if (!frame.ok()) {
        return std::move(frame).error(); // The decoder is dropped; it may be in a bad state.
    }
    if (!frame.value()) {
        return makeError(MediaErrorCode::InvalidArgument, "no frame at the requested time in " + request.url);
    }

    // Stills come out of the decoder already oriented (EXIF applied); video carries its
    // rotation in the track.
    auto result = render(worker, frame.value()->image, request.maxDimension, still ? 0 : track->rotationDegrees);

    // Return the decoder for reuse; destroy the least recently used surplus outside the lock.
    std::vector<std::unique_ptr<DecoderSlot>> surplus;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        idleDecoders_.push_front(std::move(slot));
        while (idleDecoders_.size() > static_cast<size_t>(std::max(0, config_.maxIdleDecoders))) {
            surplus.push_back(std::move(idleDecoders_.back()));
            idleDecoders_.pop_back();
        }
    }
    return result;
}

} // namespace ve::thumbs
